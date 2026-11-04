#!/bin/bash
# 一键安装：Python 依赖 → 录音器 → App（装到 ~/Applications）→ interview 命令 → Claude Code skill
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

[ "$(uname -s)" = Darwin ] || { echo "只支持 macOS"; exit 1; }
[ "$(uname -m)" = arm64 ] || echo "提示：主要在 Apple 芯片上测试，Intel Mac 转写会慢很多"
xcode-select -p >/dev/null 2>&1 || { echo "需要 Xcode 命令行工具：xcode-select --install"; exit 1; }
command -v uv >/dev/null || { echo "需要 uv：curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }

echo "==> 安装 Python 依赖（首次约几分钟）"
uv sync
echo "==> 编译录音器"
recorder/build.sh
echo "==> 编译 App"
app/build.sh
echo "==> 安装命令行和 Claude Code skill"
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
ln -sfn "$ROOT/bin/interview" "$HOME/.local/bin/interview"
ln -sfn "$ROOT/skill" "$HOME/.claude/skills/interview-review"

command -v claude >/dev/null || echo "提示：没找到 Claude Code，生成复盘需要它（或在 App 设置里改用 DeepSeek）：https://claude.com/claude-code"
echo
echo "完成：打开 ~/Applications/面试复盘.app"
echo "可选：运行 scripts/create-signing-identity.sh，之后重新编译不会丢失录音权限"
