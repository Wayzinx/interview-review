"""interview-py：会话目录管理 + 转写成对话稿。录音由 bin/interview-recorder 负责。"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ.get("INTERVIEW_HOME", Path.home() / "Interviews"))


def fmt(t: float) -> str:
    t = int(t)
    return f"{t // 3600:02d}:{t // 60 % 60:02d}:{t % 60:02d}"


def _plain(s: str) -> str:
    return re.sub(r"[\W_]+", "", s)


def new_session(name: str) -> Path:
    slug = re.sub(r"[\s/\\:]+", "-", name.strip()) or "面试"
    d = HOME / f"{datetime.now():%Y-%m-%d_%H%M}_{slug}"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------- 合并成对话 ----------

_SENT = re.compile(r"(?<=[。！？!?；;])")


def drop_echo(mine, theirs):
    """外放时麦克风会录进面试官的声音。逐句看：前后 3 秒内面试官说过几乎同样的话，就是回声。

    只数 ≥3 字的连续重合，避免"好的，面试官您好"这种碰巧共用几个字的句子被误删。
    """
    keep, dropped = [], 0
    for m in mine:
        ref = "".join(_plain(t.text) for t in theirs if t.start - 3 <= m.end and t.end + 3 >= m.start)
        sents = _SENT.split(m.text)
        echo = []
        for sent in sents:
            p = _plain(sent)
            hit = 0
            if ref and len(p) >= 6:
                sm = difflib.SequenceMatcher(None, p, ref, autojunk=False)
                hit = sum(b.size for b in sm.get_matching_blocks() if b.size >= 3)
            echo.append(hit / max(len(p), 1) > 0.6)
        if not any(echo):
            keep.append(m)
            continue
        dropped += sum(echo)
        # 去掉开头的回声后，按字数比例把起始时间往后挪
        total = max(sum(len(x) for x in sents), 1)
        lead = 0
        for x, e in zip(sents, echo):
            if not e:
                break
            lead += len(x)
        m.start += (m.end - m.start) * lead / total
        m.text = "".join(x for x, e in zip(sents, echo) if not e).strip()
        if _plain(m.text):
            keep.append(m)
    return keep, dropped


_FILLER = re.compile(r"^(嗯|啊|哦|噢|呃|额|唔|对|是|好|行|好的|嗯哼|ok|okay|en|um|uh|mm|yeah)+$", re.I)


def is_backchannel(s, others) -> bool:
    """对方说话时插的"嗯/对/好的"，留着会把一段回答切碎。"""
    t = _plain(s.text)
    if len(t) > 4 or not _FILLER.match(t):
        return False
    return any(o.start - 1 <= s.start <= o.end + 1 for o in others)


def to_turns(segs, gap: float = 8.0) -> list[dict]:
    turns: list[dict] = []
    for s in sorted(segs, key=lambda x: x.start):
        if turns and turns[-1]["speaker"] == s.speaker and s.start - turns[-1]["end"] < gap:
            prev = turns[-1]
            sep = "" if re.search(r"[。！？!?，,；;…]$", prev["text"]) else "，"
            prev["text"] += sep + s.text
            prev["end"] = s.end
        else:
            turns.append({"speaker": s.speaker, "start": s.start, "end": s.end, "text": s.text})
    return turns


def write_transcript(d: Path, segs, duration: float, mode: str, note: str) -> Path:
    by = {}
    for s in segs:
        by.setdefault(s.speaker, []).append(s)
    shown = [s for s in segs if not is_backchannel(s, [o for o in segs if o.speaker != s.speaker])]
    turns = to_turns(shown)

    talk = {k: sum(s.end - s.start for s in v) / 60 for k, v in by.items()}
    (d / "transcript.json").write_text(
        json.dumps(
            {
                "mode": mode,
                "duration": duration,
                "note": note,
                "segments": [s.__dict__ for s in sorted(segs, key=lambda x: x.start)],
                "turns": turns,
            },
            ensure_ascii=False,
            indent=1,
        )
    )
    # 录音缺口（meta.json 的 gaps）：这段时间没录到，复盘时不要把前后两句当成连着的
    gaps = []
    if (d / "meta.json").exists():
        try:
            gaps = [(float(g[0]), float(g[1]), g[2] if len(g) > 2 else "") for g in json.loads((d / "meta.json").read_text()).get("gaps", [])]
        except (ValueError, TypeError, IndexError):
            gaps = []
    lines = [
        "# 面试对话稿",
        "",
        f"- 会话：{d.name}",
        f"- 时长：{fmt(duration)}；面试官说话约 {talk.get('面试官', 0):.1f} 分钟，我说话约 {talk.get('我', 0):.1f} 分钟",
        f"- 说明：{note}",
        *([f"- 录音缺口：" + "；".join(f"{fmt(a)}–{fmt(b)}" for a, b, _ in gaps) + "（这段没录到，复盘时注意前后不连续）"] if gaps else []),
        "- 识别：本地 SenseVoice 自动转写，英文术语/专有名词可能有同音错字，按上下文理解",
        "",
        "---",
        "",
    ]
    # 面试时按快捷键打的标记：插在对应时刻那句话后面
    marks = []
    if (d / "markers.json").exists():
        try:
            marks = sorted(float(m["t"] if isinstance(m, dict) else m) for m in json.loads((d / "markers.json").read_text()))
        except (ValueError, KeyError, TypeError):
            marks = []
    events = [(t["start"], 0, t) for t in turns] + [(m, 1, None) for m in marks] + [(g[0], 2, g) for g in gaps]
    for at, kind, t in sorted(events, key=lambda e: (e[0], e[1])):
        if kind == 0:
            lines.append(f"**[{fmt(t['start'])}] {t['speaker']}**：{t['text']}")
        elif kind == 1:
            lines.append(f"> 🚩 **[{fmt(at)}] 我在这里做了标记**：面试时觉得这里没答好 / 想重点复盘")
        else:
            lines.append(f"> ⚠️ **[{fmt(t[0])} – {fmt(t[1])}] 录音缺口**：这 {int(t[1] - t[0])} 秒没录到（{t[2] or '录音中断'}），前后内容不连续")
        lines.append("")
    out = d / "transcript.md"
    out.write_text("\n".join(lines))
    return out


# ---------- 子命令 ----------

def cmd_new(a):
    print(new_session(a.name))


def cmd_import(a):
    src = Path(a.file).expanduser().resolve()
    if not src.exists():
        sys.exit(f"找不到文件：{src}")
    d = new_session(a.name or src.stem)
    # 只留音频，统一成 16k 单声道 m4a，视频再大也只占几十 MB
    tmp = d / "mixed.m4a"
    r = subprocess.run(["afconvert", "-f", "m4af", "-d", "aac@16000", "-c", "1", "--mix", "-b", "32000", str(src), str(tmp)],
                       capture_output=True)
    if r.returncode != 0:
        r = subprocess.run(["avconvert", "--source", str(src), "--preset", "PresetAppleM4A", "--output", str(tmp), "--replace"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"无法读取 {src}：{r.stderr or r.stdout}")
    print(d)


def _progress(lo: float, hi: float):
    """给 App 用：stderr 输出 "PROGRESS <0-100>"，整数变化时才打。"""
    last = [-1]

    def f(x: float):
        v = int(lo + (hi - lo) * x)
        if v != last[0]:
            last[0] = v
            print(f"PROGRESS {v}", file=sys.stderr, flush=True)

    return f


def cmd_transcribe(a):
    from . import asr

    d = Path(a.dir).expanduser().resolve()
    t0 = time.time()
    iv, me, mixed = d / "interviewer.m4a", d / "me.m4a", d / "mixed.m4a"
    if not mixed.exists() and iv.exists() != me.exists():
        # 只剩一条轨（比如另一条没录到声音）：当单轨处理，靠声纹区分
        mixed = iv if iv.exists() else me
        iv = me = d / "__none__"
    if iv.exists() and me.exists():
        print("转写面试官音轨…", file=sys.stderr)
        iv_segs, dur1 = asr.transcribe_track(iv, "面试官", _progress(0, 50))
        print("转写我的音轨…", file=sys.stderr)
        me_segs, dur2 = asr.transcribe_track(me, "我", _progress(50, 100))
        me_segs, dropped = drop_echo(me_segs, iv_segs)
        note = "双轨录音（系统声音=面试官，麦克风=我），说话人准确"
        if dropped:
            note += f"；麦克风里录进了 {dropped} 句面试官的外放声音，已自动去掉"
        out = write_transcript(d, iv_segs + me_segs, max(dur1, dur2), "dual", note)
    elif mixed.exists():
        print("转写并区分说话人…", file=sys.stderr)
        segs, dur, note = asr.transcribe_mixed(mixed, _progress(0, 100))
        out = write_transcript(d, segs, dur, "mixed", note)
    else:
        sys.exit(f"{d} 里没有录音（interviewer.m4a + me.m4a，或 mixed.m4a）")
    print("PROGRESS 100", file=sys.stderr)
    print(f"完成，用时 {time.time() - t0:.0f} 秒 → {out}", file=sys.stderr)
    print(out)


def _rewrite(d: Path, swap: bool):
    from .types import Segment

    data = json.loads((d / "transcript.json").read_text())
    flip = {"面试官": "我", "我": "面试官"} if swap else {}
    segs = [Segment(x["start"], x["end"], x["text"], flip.get(x["speaker"], x["speaker"])) for x in data["segments"]]
    note = data.get("note", "")
    if swap:
        tag = "；已手动对调过说话人"
        note = note.replace(tag, "") if tag in note else note + tag
    return write_transcript(d, segs, data.get("duration", 0), data.get("mode", "mixed"), note)


def cmd_swap(a):
    """单轨录音角色判反了：对调"面试官"和"我"，重新生成对话稿。"""
    print(_rewrite(Path(a.dir).expanduser().resolve(), swap=True))


def cmd_render(a):
    """不重跑识别，用 transcript.json 重新生成对话稿（改了标记、缺口之后用）。"""
    print(_rewrite(Path(a.dir).expanduser().resolve(), swap=False))


def cmd_ls(a):
    if not HOME.exists():
        return
    for d in sorted(HOME.iterdir(), reverse=True):
        if not d.is_dir() or d.name.startswith("_"):
            continue
        has = lambda f: (d / f).exists()
        state = "已复盘" if has("report.md") else "已转写" if has("transcript.md") else "仅录音" if any(
            has(f) for f in ("me.m4a", "mixed.m4a")) else "空"
        print(f"{state}\t{d}")


def main():
    p = argparse.ArgumentParser(prog="interview-py")
    sub = p.add_subparsers(required=True)
    s = sub.add_parser("new", help="新建会话目录并打印路径")
    s.add_argument("name", nargs="?", default="面试")
    s.set_defaults(fn=cmd_new)
    s = sub.add_parser("import", help="导入已有录音/录屏文件")
    s.add_argument("file")
    s.add_argument("name", nargs="?")
    s.set_defaults(fn=cmd_import)
    s = sub.add_parser("transcribe", help="转写会话目录，生成 transcript.md")
    s.add_argument("dir")
    s.set_defaults(fn=cmd_transcribe)
    s = sub.add_parser("swap", help="对调说话人（单轨录音角色判反时用）")
    s.add_argument("dir")
    s.set_defaults(fn=cmd_swap)
    s = sub.add_parser("render", help="用已有识别结果重新生成对话稿")
    s.add_argument("dir")
    s.set_defaults(fn=cmd_render)
    s = sub.add_parser("ls", help="列出所有面试")
    s.set_defaults(fn=cmd_ls)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
