"""对话稿生成逻辑：回声去重、附和声过滤、合并发言、标记与录音缺口。不依赖语音模型。"""

import json
from dataclasses import dataclass

from ir import cli


@dataclass
class Seg:
    start: float
    end: float
    text: str
    speaker: str = ""


def test_drop_echo_removes_interviewer_sentence_heard_by_mic():
    iv = [Seg(20, 26, "你刚才提到Redis缓存优化，具体说说你是怎么解决缓存击穿问题的。", "面试官")]
    me = [Seg(20.5, 34, "你刚才提到redis缓存优化，具体说说你是怎么解决缓存击穿问题的。缓存击穿的话，我们加了互斥锁。", "我")]
    kept, dropped = cli.drop_echo(me, iv)
    assert dropped == 1
    assert kept[0].text == "缓存击穿的话，我们加了互斥锁。"
    assert kept[0].start > 20.5  # 去掉开头的回声后，起始时间往后挪


def test_drop_echo_keeps_sentences_that_only_share_a_few_words():
    iv = [Seg(0, 5, "你好，我是今天的面试官，先请你做个简单的自我介绍吧。", "面试官")]
    me = [Seg(6, 9, "好的，面试官您好。我叫张三。", "我")]
    kept, dropped = cli.drop_echo(me, iv)
    assert dropped == 0
    assert kept[0].text == "好的，面试官您好。我叫张三。"


def test_backchannel_only_when_other_side_is_talking():
    other = [Seg(10, 20, "我们的系统是这样设计的", "我")]
    assert cli.is_backchannel(Seg(12, 12.5, "嗯。", "面试官"), other)
    assert not cli.is_backchannel(Seg(30, 30.5, "嗯。", "面试官"), other)
    assert not cli.is_backchannel(Seg(12, 14, "那并发呢？", "面试官"), other)


def test_turns_merge_same_speaker_and_split_on_long_pause():
    segs = [Seg(0, 2, "第一句", "我"), Seg(3, 5, "第二句。", "我"), Seg(20, 22, "隔了很久", "我")]
    turns = cli.to_turns(segs)
    assert [t["text"] for t in turns] == ["第一句，第二句。", "隔了很久"]


def test_transcript_places_markers_and_gaps_in_time_order(tmp_path):
    (tmp_path / "markers.json").write_text(json.dumps([{"t": 25}]))
    (tmp_path / "meta.json").write_text(json.dumps({"gaps": [[40, 60, "录音中断"]]}))
    segs = [
        Seg(0, 5, "先做个自我介绍吧？", "面试官"),
        Seg(6, 30, "我叫张三，做后端。", "我"),
        Seg(61, 65, "那我们聊下一个问题。", "面试官"),
    ]
    out = cli.write_transcript(tmp_path, segs, 70, "dual", "测试")
    body = out.read_text().split("---", 1)[1]
    lines = [l for l in body.splitlines() if l.strip()]
    assert "自我介绍" in lines[0]
    assert "张三" in lines[1]
    assert lines[2].startswith("> 🚩 **[00:00:25]")
    assert lines[3].startswith("> ⚠️ **[00:00:40 – 00:01:00] 录音缺口**")
    assert "下一个问题" in lines[4]
    assert "录音缺口：00:00:40–00:01:00" in out.read_text()


def test_swap_speakers_roundtrip(tmp_path):
    segs = [Seg(0, 3, "你好", "面试官"), Seg(4, 8, "您好", "我")]
    cli.write_transcript(tmp_path, segs, 10, "mixed", "单轨")
    cli._rewrite(tmp_path, swap=True)
    data = json.loads((tmp_path / "transcript.json").read_text())
    assert [s["speaker"] for s in data["segments"]] == ["我", "面试官"]
    assert data["note"].endswith("已手动对调过说话人")
    cli._rewrite(tmp_path, swap=True)
    data = json.loads((tmp_path / "transcript.json").read_text())
    assert [s["speaker"] for s in data["segments"]] == ["面试官", "我"]
    assert "对调" not in data["note"]
