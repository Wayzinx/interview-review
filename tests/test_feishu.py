"""飞书妙记导入：三种导出格式的解析，两种对说话人的方式。"""

import numpy as np

from ir import feishu
from ir.types import Segment

SRT = """1
00:00:00,500 --> 00:00:04,200
说话人 1：你好，先做个自我介绍吧？

2
00:00:05,000 --> 00:00:09,800
说话人 2：好的，我叫张三，做后端开发。

3
00:01:02,000 --> 00:01:05,000
那并发呢？
"""

TXT_HEADER = """面试 2026年10月19日

说话人 1 00:00
你好，先做个自我介绍吧？

说话人 2 00:05
好的，我叫张三，
做后端开发。

说话人 1 01:02:03
那并发呢？
"""

TXT_INLINE = """[00:00:00] 说话人 1：你好，先做个自我介绍吧？
[00:00:05] 说话人 2：好的，我叫张三，做后端开发。
"""


def test_parse_srt_with_and_without_speaker_prefix():
    segs = feishu.parse_srt(SRT)
    assert [(s.start, s.end) for s in segs] == [(0.5, 4.2), (5.0, 9.8), (62.0, 65.0)]
    assert [s.speaker for s in segs] == ["说话人 1", "说话人 2", ""]
    assert segs[1].text == "好的，我叫张三，做后端开发。"


def test_parse_txt_header_lines_and_wrapped_text():
    segs = feishu.parse_txt(TXT_HEADER)
    assert [s.start for s in segs] == [0, 5, 3723]
    assert [s.speaker for s in segs] == ["说话人 1", "说话人 2", "说话人 1"]
    assert segs[1].text == "好的，我叫张三，做后端开发。"
    assert segs[0].end == 5  # 结束时间 = 下一段开始


def test_parse_txt_inline_lines():
    segs = feishu.parse_txt(TXT_INLINE)
    assert [(s.start, s.speaker) for s in segs] == [(0, "说话人 1"), (5, "说话人 2")]
    assert segs[0].text.startswith("你好")


def test_assign_by_energy_uses_interviewer_track():
    sr = 16000
    iv = np.zeros(sr * 10, np.float32)
    me = np.zeros(sr * 10, np.float32)
    iv[0: sr * 4] = 0.1 * np.sin(np.arange(sr * 4))          # 0–4s 面试官
    me[sr * 5: sr * 9] = 0.1 * np.sin(np.arange(sr * 4))     # 5–9s 我
    me[0: sr * 4] += 0.02 * np.sin(np.arange(sr * 4))        # 外放回声：麦克风也录到一点面试官
    segs = [Segment(0.5, 4.0, "问题"), Segment(5.0, 9.0, "回答")]
    feishu.assign_by_energy(segs, iv, me, sr)
    assert [s.speaker for s in segs] == ["面试官", "我"]


def test_assign_by_labels_picks_the_asking_side():
    segs = feishu.parse_srt(SRT)[:2] + [Segment(10, 12, "那你说说缓存击穿怎么处理？", "说话人 1"),
                                       Segment(12, 20, "我们用了互斥锁和逻辑过期两种方案，还做了预热。", "说话人 2")]
    note = feishu.assign_by_labels(segs)
    assert [s.speaker for s in segs] == ["面试官", "我", "面试官", "我"]
    assert "说话人 1" in note
