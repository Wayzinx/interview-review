"""不依赖语音模型的轻量类型，测试和对话稿生成都能单独用。"""

from dataclasses import dataclass


@dataclass
class Segment:
    start: float  # 秒
    end: float
    text: str
    speaker: str = ""
