"""飞书妙记导入：解析妙记导出的文字记录（srt / txt / docx），对上说话人，替换本地转写。

流程：先 make_upload_mix() 生成上传用的混音 → 用户在个人飞书账号的妙记里上传、导出文字记录 → parse_file()
→ 双轨录音按两条轨的音量判定说话人（面试官那条轨只有对方的声音，比妙记自己的"说话人 1/2"更可靠），
单轨录音按妙记的说话人标签 + 问句比例推断。

妙记导出的具体格式没有公开文档，这里尽量宽松：时间戳支持 mm:ss / hh:mm:ss / 带毫秒，说话人可有可无。
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

from .types import Segment

_TS = r"(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?"


def _secs(ts: str) -> float:
    ts = ts.replace(",", ".")
    parts = [float(p) for p in ts.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, s = parts
    return h * 3600 + m * 60 + s


_SPK_PREFIX = re.compile(r"^\s*(?P<spk>[^:：]{1,20}?)\s*[:：]\s*(?P<text>.+)$")


def _split_speaker(text: str) -> tuple[str | None, str]:
    """"说话人 1：内容" → ("说话人 1", "内容")；没有前缀就原样返回。只认短名字，避免把句子里的冒号当成说话人。"""
    m = _SPK_PREFIX.match(text)
    if m and len(m["spk"]) <= 20 and not re.search(r"[，。？！,.?!]", m["spk"]):
        return m["spk"].strip(), m["text"].strip()
    return None, text.strip()


def parse_srt(text: str) -> list[Segment]:
    segs = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip()):
        lines = [l for l in block.split("\n") if l.strip()]
        for i, l in enumerate(lines):
            m = re.match(rf"\s*({_TS})\s*-->\s*({_TS})", l)
            if m:
                body = " ".join(lines[i + 1:]).strip()
                if body:
                    spk, txt = _split_speaker(body)
                    segs.append(Segment(_secs(m[1]), _secs(m[2]), txt, spk or ""))
                break
    return segs


# 一行里只有"说话人 + 时间"（顺序不限，时间可带括号），下面跟着正文
_NAME = r"[^:：，。？！,.?!\s\d][^:：，。？！,.?!]{0,29}?"  # 说话人名字：不以数字开头，不含冒号和句读
_HEADER = [
    re.compile(rf"^\s*(?P<spk>{_NAME})?\s*[\[(（]?(?P<ts>{_TS})[\])）]?\s*$"),
    re.compile(rf"^\s*[\[(（]?(?P<ts>{_TS})[\])）]?\s+(?P<spk>{_NAME})\s*$"),
]
# 一行里"时间 说话人：正文"或"说话人 时间：正文"
_INLINE = re.compile(rf"^\s*(?:(?P<spk1>{_NAME})\s+)?[\[(（]?(?P<ts>{_TS})[\])）]?\s*(?P<spk2>{_NAME})?\s*[:：]\s*(?P<text>.+)$")


def parse_txt(text: str) -> list[Segment]:
    segs: list[Segment] = []
    cur: Segment | None = None
    for raw in text.replace("\r\n", "\n").split("\n"):
        line = raw.strip()
        if not line:
            continue
        header = next((m for p in _HEADER if (m := p.match(line))), None)
        if header:
            cur = Segment(_secs(header["ts"]), 0, "", (header["spk"] or "").strip(" ：:-"))
            segs.append(cur)
            continue
        inline = _INLINE.match(line)
        if inline:
            spk = (inline["spk1"] or inline["spk2"] or "").strip()
            cur = Segment(_secs(inline["ts"]), 0, inline["text"].strip(), spk)
            segs.append(cur)
            continue
        if cur is not None:
            cur.text = (cur.text + line) if not cur.text else f"{cur.text}{'' if cur.text[-1] in '，。？！,.?!' else '，'}{line}"
    segs = [s for s in segs if s.text]
    for a, b in zip(segs, segs[1:]):
        a.end = max(a.start + 0.5, b.start)
    if segs:
        segs[-1].end = segs[-1].start + max(3.0, len(segs[-1].text) * 0.25)
    return segs


def parse_file(path: Path) -> list[Segment]:
    path = Path(path)
    ext = path.suffix.lower()
    if ext in (".docx", ".doc", ".rtf"):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "a.txt"
            subprocess.run(["textutil", "-convert", "txt", "-output", str(out), str(path)], check=True, capture_output=True)
            text = out.read_text(encoding="utf-8", errors="ignore")
    else:
        raw = path.read_bytes()
        text = next((raw.decode(enc) for enc in ("utf-8-sig", "utf-16", "gb18030") if _decodes(raw, enc)), raw.decode("utf-8", "ignore"))
    segs = parse_srt(text) if "-->" in text else parse_txt(text)
    if not segs:
        raise ValueError(f"没从「{path.name}」里解析出带时间的文字。请在妙记里导出「文字记录」（txt / srt / Word 都行）。")
    return segs


def _decodes(raw: bytes, enc: str) -> bool:
    try:
        raw.decode(enc)
        return True
    except UnicodeDecodeError:
        return False


# ---------- 对说话人 ----------

def assign_by_energy(segs: list[Segment], iv, me, sr: int = 16000) -> None:
    """双轨：面试官那条轨（电脑播放的声音）只有对方的声音。按 100ms 一帧数：面试官轨有声的帧 vs 只有我的轨有声的帧。"""
    import numpy as np

    hop = sr // 10

    def frames_db(a):
        n = len(a) // hop
        x = np.asarray(a[: n * hop], dtype=np.float32).reshape(n, hop)
        return 10 * np.log10((x ** 2).mean(axis=1) + 1e-12)

    ivd, med = frames_db(iv), frames_db(me)
    for s in segs:
        a, b = int(s.start * 10), max(int(s.end * 10), int(s.start * 10) + 1)
        iv_on = ivd[a:b] > -45
        me_only = (med[a:b] > -45) & ~iv_on
        s.speaker = "面试官" if iv_on.sum() >= me_only.sum() and iv_on.sum() > 0 else "我"


_ASK = re.compile(r"[？?]|吗|呢|什么|怎么|为什么|如何|哪些|哪个|介绍一下|讲一下|说一下|说说|聊聊|谈谈|有没有")


def assign_by_labels(segs: list[Segment]) -> str:
    """单轨：用妙记的说话人标签；出现最多的两个人里，问句多、说话少的是面试官。返回说明文字。"""
    labels = Counter(s.speaker for s in segs if s.speaker)
    if len(labels) < 2:
        for s in segs:
            s.speaker = s.speaker or "说话人"
        return "妙记没有区分说话人，请按内容判断"
    top = [l for l, _ in labels.most_common(2)]

    def score(label):
        mine = [s for s in segs if s.speaker == label]
        asks = sum(1 for s in mine if _ASK.search(s.text)) / max(len(mine), 1)
        talk = sum(len(s.text) for s in mine)
        return asks - 0.5 * talk / max(sum(len(s.text) for s in segs), 1)

    iv = max(top, key=score)
    for s in segs:
        if s.speaker == iv:
            s.speaker = "面试官"
        elif s.speaker in top:
            s.speaker = "我"
    return f"说话人按妙记的标签推断（「{iv}」= 面试官），如果角色反了可以对调"


# ---------- 上传用的音频 ----------

def make_upload_mix(d: Path) -> Path:
    """两条轨混成一个文件给妙记上传（时间轴和本地完全一致，导回来的时间戳能直接对上）。"""
    from .asr import SR, load_audio

    out = d / "飞书妙记上传.m4a"
    iv, me, mixed = d / "interviewer.m4a", d / "me.m4a", d / "mixed.m4a"
    if mixed.exists():
        src = mixed
    elif iv.exists() or me.exists():
        import numpy as np
        import soundfile as sf

        parts = [load_audio(p) for p in (iv, me) if p.exists()]
        n = max(len(p) for p in parts)
        mix = np.zeros(n, np.float32)
        for p in parts:
            mix[: len(p)] += p
        peak = float(np.abs(mix).max() or 1)
        mix = mix / max(peak, 1.0)
        with tempfile.TemporaryDirectory() as td:
            wav = Path(td) / "mix.wav"
            sf.write(wav, mix, SR, subtype="PCM_16")
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac@16000", "-b", "48000", str(wav), str(out)], check=True)
        return out
    else:
        raise FileNotFoundError(f"{d} 里没有录音")
    subprocess.run(["cp", str(src), str(out)], check=True)
    return out
