#!/bin/bash
# 构建「面试复盘.app」并安装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="build/面试复盘.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f Resources/AppIcon.icns ]; then
  swiftc -O make_icon.swift -o build/make_icon
  build/make_icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  Sources/*.swift ../recorder/Recorder.swift -o "$APP/Contents/MacOS/InterviewReview"
sed "s#__ROOT__#$ROOT#" Info.plist > "$APP/Contents/Info.plist"
cp Resources/marked.min.js Resources/AppIcon.icns "$APP/Contents/Resources/"
# 用固定的本机签名证书（钥匙串里的 "Interview Review Local Signing"），这样重新编译后
# 系统隐私授权（屏幕录音 / 麦克风 / 钥匙串）都还认得是同一个 App；没有证书时退回临时签名。
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/Interview Review Local Signing/ {print $2; exit}')
codesign --force --sign "${SIGN_ID:--}" --identifier local.interview-review.app "$APP"

# 保护：正在录音时（30 秒内有录音备份在更新）不覆盖安装，免得打断面试
if find "$HOME/Interviews" -maxdepth 2 -name '*.partial.wav' -mtime -30s 2>/dev/null | grep -q .; then
  echo "检测到正在录音，没有覆盖安装（新版本在 $APP，录完再运行一次 build.sh）" >&2
  exit 3
fi

DEST="$HOME/Applications/面试复盘.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "已安装：$DEST"
