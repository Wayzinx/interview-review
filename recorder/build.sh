#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../bin
swiftc -O -swift-version 5 \
  -target arm64-apple-macos15.0 \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
  Recorder.swift main.swift -o ../bin/interview-recorder
codesign --force --sign - --identifier local.interview-review.recorder ../bin/interview-recorder
echo "built ../bin/interview-recorder"
