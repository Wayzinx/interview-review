#!/bin/bash
# 打包 DMG：App 里内置转写程序、复盘规则和 uv，用户首次启动时自动准备运行环境，不需要命令行。
# 产物：dist/面试复盘-<版本>-arm64.dmg
# 没有 Apple 开发者账号，只能临时签名（ad-hoc），用户第一次打开要在「隐私与安全性」里点「仍要打开」。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION=$(grep '^version' pyproject.toml | cut -d'"' -f2)
UV=$(command -v uv) || { echo "需要 uv"; exit 1; }
file -L "$UV" | grep -q arm64 || { echo "uv 不是 arm64 版本"; exit 1; }

echo "==> 编译 App"
IR_DIST=1 app/build.sh
APP="$ROOT/app/build/面试复盘.app"

echo "==> 内置转写程序、复盘规则和 uv"
R="$APP/Contents/Resources/runtime"
rm -rf "$R" && mkdir -p "$R"
cp -R ir pyproject.toml uv.lock "$R/"
find "$R" -name __pycache__ -prune -exec rm -rf {} +
cp -R skill "$R/skill"
cp -L "$UV" "$R/uv"
echo "$VERSION-$(git rev-parse --short HEAD 2>/dev/null || date +%s)" > "$R/VERSION"

echo "==> 临时签名"
codesign --force --sign - "$R/uv"
codesign --force --sign - --identifier local.interview-review.app "$APP"
codesign --verify --strict "$APP"

echo "==> 生成 DMG"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
rm -rf "$DIST" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/先看我.txt" <<TXT
面试复盘 $VERSION

1. 把「面试复盘」拖到「Applications」。
2. 第一次打开时 macOS 会提示"无法验证开发者"（没有付费开发者账号做公证）：
   打开「系统设置 → 隐私与安全性」，在下方找到面试复盘，点「仍要打开」。
3. 首次转写会自动下载 Python 和语音识别依赖（约 1GB，几分钟），之后离线可用。
4. 生成复盘需要已登录的 Claude Code（https://claude.com/claude-code），或在设置里填 DeepSeek API key。

项目主页：https://github.com/Wayzinx/interview-review
TXT
DMG="$DIST/面试复盘-$VERSION-arm64.dmg"
hdiutil create -volname "面试复盘" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
ls -lh "$DMG"
