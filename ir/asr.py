"""本地语音识别：fsmn-vad 切句 → SenseVoiceSmall 识别；单文件模式再用 CAM++ 声纹区分两个人。

模型都从 ModelScope 下载到 ~/.cache/modelscope，首次运行约 1GB，之后离线可用。
"""

from __future__ import annotations

import contextlib
import logging
import os
import re
import subprocess
import sys
import tempfile
from functools import lru_cache
from pathlib import Path

import numpy as np
import soundfile as sf

from .types import Segment

SR = 16000

# ModelScope（模型下载站）走代理经常被拒，单独让它直连；其它请求照常走代理。
_DIRECT = "modelscope.cn,.modelscope.cn,.aliyuncs.com"
for _k in ("no_proxy", "NO_PROXY"):
    os.environ[_k] = ",".join(x for x in (os.environ.get(_k, ""), _DIRECT) if x)


def load_audio(path: Path) -> np.ndarray:
    """任意音视频 → 16k 单声道 float32。只用系统自带的 afconvert / avconvert，不依赖 ffmpeg。"""
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", str(path), str(wav)]
        if subprocess.run(cmd, capture_output=True).returncode != 0:
            # 视频容器 afconvert 读不了，先用 avconvert 抽出音轨
            m4a = Path(td) / "a.m4a"
            r = subprocess.run(
                ["avconvert", "--source", str(path), "--preset", "PresetAppleM4A", "--output", str(m4a), "--replace"],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                raise RuntimeError(f"无法读取 {path}：{r.stderr.strip() or r.stdout.strip()}")
            cmd[-2] = str(m4a)
            subprocess.run(cmd, check=True, capture_output=True)
        audio, sr = sf.read(wav, dtype="float32")
    assert sr == SR
    return audio if audio.ndim == 1 else audio.mean(axis=1)


@contextlib.contextmanager
def _quiet():
    """funasr / modelscope 会往终端刷版本号、下载进度和每句的 rtf，全部吞掉。"""
    with open(os.devnull, "w") as null, contextlib.redirect_stdout(null), contextlib.redirect_stderr(null):
        yield


def _device() -> str:
    """Apple 芯片用 GPU（MPS），比 CPU 快约 1.5 倍，结果一致。IR_DEVICE 可强制指定。"""
    if os.environ.get("IR_DEVICE"):
        return os.environ["IR_DEVICE"]
    import torch

    return "mps" if torch.backends.mps.is_available() else "cpu"


@lru_cache(maxsize=None)
def _model(name: str):
    if not (Path.home() / ".cache/modelscope").exists():
        print("首次运行，正在下载语音模型（约 1GB）…", file=sys.stderr)
    with _quiet():
        from funasr import AutoModel

        for lg in ("", "funasr", "modelscope"):
            logging.getLogger(lg).setLevel(logging.ERROR)
        return AutoModel(model=name, disable_update=True, device=_device(), disable_pbar=True)


def _run(name: str, audio: np.ndarray, **kw):
    m = _model(name)
    with _quiet():
        return m.generate(input=audio, disable_pbar=True, **kw)


def vad(audio: np.ndarray, silence_ms: int = 500) -> list[tuple[float, float]]:
    """silence_ms：停顿超过多久算断句。单轨混音要切得更细，才能把一问一答分开。"""
    res = _run("fsmn-vad", audio, max_single_segment_time=30000, max_end_silence_time=silence_ms)
    return [(b / 1000, e / 1000) for b, e in res[0]["value"]]


_TAG = re.compile(r"<\|[^|]*\|>")


def recognize(audio: np.ndarray, spans: list[tuple[float, float]], progress=None) -> list[Segment]:
    from funasr.utils.postprocess_utils import rich_transcription_postprocess

    out = []
    for i, (s, e) in enumerate(spans):
        if progress:
            progress(i / max(len(spans), 1))
        chunk = audio[int(s * SR) : int(e * SR)]
        if len(chunk) < SR * 0.3:
            continue
        res = _run("iic/SenseVoiceSmall", chunk, language="auto", use_itn=True)
        text = _TAG.sub("", rich_transcription_postprocess(res[0]["text"])).strip()
        if text:
            out.append(Segment(s, e, text))
    return out


def transcribe_track(path: Path, speaker: str, progress=None) -> tuple[list[Segment], float]:
    audio = load_audio(path)
    segs = recognize(audio, vad(audio), progress)
    for s in segs:
        s.speaker = speaker
    return segs, len(audio) / SR


# ---------- 单文件：两个人混在一条轨里 ----------

def _embed(audio: np.ndarray, s: float, e: float) -> np.ndarray:
    chunk = audio[int(s * SR) : int(min(e, s + 15) * SR)]
    emb = _run("cam++", chunk)[0]["spk_embedding"]
    v = np.asarray(emb.cpu() if hasattr(emb, "cpu") else emb, dtype=np.float32).reshape(-1)
    return v / (np.linalg.norm(v) + 1e-9)


def _two_clusters(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    """按时长加权的球面 k-means，k=2。"""
    c0 = x[np.argmax(w)]
    c1 = x[np.argmin(x @ c0)]
    cent = np.stack([c0, c1])
    lab = np.zeros(len(x), dtype=int)
    for _ in range(30):
        lab = np.argmax(x @ cent.T, axis=1)
        new = []
        for k in range(2):
            m = lab == k
            v = (x[m] * w[m, None]).sum(0) if m.any() else cent[k]
            new.append(v / (np.linalg.norm(v) + 1e-9))
        new = np.stack(new)
        if np.allclose(new, cent):
            break
        cent = new
    return lab


_ASK = re.compile(r"[？?]|吗|呢|什么|怎么|为什么|如何|哪些|哪个|介绍一下|讲一下|说一下|说说|聊聊|谈谈|有没有")


def _windows(s: float, e: float, win: float = 1.5, hop: float = 0.75) -> list[tuple[float, float]]:
    if e - s <= win:
        return [(s, e)]
    out, t = [], s
    while t + win <= e:
        out.append((t, t + win))
        t += hop
    if out[-1][1] < e - 0.3:
        out.append((e - win, e))
    return out


def diarize(audio: np.ndarray, spans: list[tuple[float, float]], progress=None) -> list[tuple[float, float, int]]:
    """VAD 段内按 1.5s 滑窗取声纹，全局聚成两类；一段里换了人就在换人处切开。"""
    wins, owner = [], []
    for i, (s, e) in enumerate(spans):
        if e - s >= 0.5:
            for w in _windows(s, e):
                wins.append(w)
                owner.append(i)
    if len(wins) < 2:
        return [(s, e, 0) for s, e in spans]
    embs = []
    for k, (a, b) in enumerate(wins):
        if progress and k % 20 == 0:
            progress(k / len(wins))
        embs.append(_embed(audio, a, b))
    x = np.stack(embs)
    lab = _two_clusters(x, np.array([b - a for a, b in wins], dtype=np.float32))

    out: list[tuple[float, float, int]] = []
    for i, (s, e) in enumerate(spans):
        idx = [k for k, o in enumerate(owner) if o == i]
        if not idx:
            out.append((s, e, -1))
            continue
        L = [int(lab[k]) for k in idx]
        if len(L) >= 3:  # 三窗多数表决，去掉单窗抖动
            L = [int(sum(L[max(0, j - 1) : j + 2]) * 2 > len(L[max(0, j - 1) : j + 2])) for j in range(len(L))]
        cur, cs = L[0], s
        for j in range(1, len(L)):
            if L[j] != cur:
                cut = wins[idx[j]][0] + 0.375
                out.append((cs, cut, cur))
                cur, cs = L[j], cut
        out.append((cs, e, cur))
    # 太短没取到声纹的，跟随时间上最近的段
    known = [o for o in out if o[2] >= 0]
    return [
        o if o[2] >= 0 else (o[0], o[1], min(known, key=lambda k: abs(k[0] - o[0]))[2]) if known else (o[0], o[1], 0)
        for o in out
    ]


def transcribe_mixed(path: Path, progress=None) -> tuple[list[Segment], float, str]:
    """progress(0~1)：声纹聚类占前 30%，识别占后 70%。"""
    audio = load_audio(path)
    dur = len(audio) / SR
    p = progress or (lambda _: None)
    parts = diarize(audio, vad(audio, silence_ms=250), lambda f: p(0.3 * f))
    segs, labels = [], []
    for k, (s, e, l) in enumerate(parts):
        p(0.3 + 0.7 * k / max(len(parts), 1))
        for seg in recognize(audio, [(s, e)]):
            segs.append(seg)
            labels.append(l)
    if not segs:
        return segs, dur, "没有识别到语音"
    if len(set(labels)) < 2:
        for s in segs:
            s.speaker = "说话人A"
        return segs, dur, "只识别出一个说话人"

    # 谁是面试官：问句比例高、总时长短的一方
    stat = []
    for k in range(2):
        mine = [s for s, l in zip(segs, labels) if l == k]
        talk = sum(s.end - s.start for s in mine)
        asks = sum(1 for s in mine if _ASK.search(s.text))
        stat.append((asks / max(len(mine), 1), talk))
    total = stat[0][1] + stat[1][1]
    score = [stat[k][0] - 0.5 * stat[k][1] / total for k in range(2)]
    iv = int(np.argmax(score))
    for s, l in zip(segs, labels):
        s.speaker = "面试官" if l == iv else "我"
    note = (
        f"单轨录音，说话人由声纹聚类自动区分（按两个人处理），角色按问句比例推断"
        f"（面试官问句占比 {stat[iv][0]:.0%}，说话 {stat[iv][1] / 60:.1f} 分钟；"
        f"我问句占比 {stat[1 - iv][0]:.0%}，说话 {stat[1 - iv][1] / 60:.1f} 分钟）。"
        f"如果发现角色反了或有段落归错人，以内容为准"
    )
    return segs, dur, note
