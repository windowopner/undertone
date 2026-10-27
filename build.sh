#!/bin/bash
# Builds Undertone.app, installs it to /Applications (or ~/Applications) and launches it.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc가 없어. 먼저 터미널에서: xcode-select --install"
  exit 1
fi

APP="build/Undertone.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 빌드 중…"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework CoreMedia -framework ServiceManagement -framework SceneKit -framework Metal -framework MetalKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Undertone"

cp Info.plist "$APP/Contents/Info.plist"
IDENTITY="Undertone Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "✓ '$IDENTITY' 인증서로 서명 — 오디오 권한이 빌드 후에도 유지됨"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "⚠ 임시 서명 — 빌드할 때마다 오디오 권한을 다시 허용해야 해 (./setup-signing.sh 한 번 실행하면 해결)"
fi

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

pkill -x Undertone 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Undertone.app"
cp -R "$APP" "$DEST/"

echo "✓ 설치 완료: $DEST/Undertone.app"
open "$DEST/Undertone.app"
