#!/usr/bin/env bash
#
# build-app.sh — build TriCap and assemble it into a runnable TriCap.app bundle.
#
# This machine has Command Line Tools but no Xcode.app, so `xcodebuild` is unavailable and the
# project is a SwiftPM package. SwiftPM produces a bare Mach-O executable; a menu-bar app needs a
# bundle with an Info.plist (for LSUIElement and the bundle identifier TCC keys permission on),
# so this script does the packaging step Xcode would otherwise do.
#
# Usage:
#   ./scripts/build-app.sh [debug|release]
#
# Environment:
#   CODESIGN_IDENTITY   Signing identity. Defaults to "-" (ad-hoc).
#
# NOTE ON PERMISSION: with an ad-hoc signature the app's TCC identity is its code-directory hash,
# which changes on every rebuild. macOS therefore treats each new build as a different app and
# asks for Screen Recording again. Signing with a stable Developer ID identity avoids that; this
# repository intentionally does not sign, notarize or publish.
#
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/TriCap"
[[ -x "$EXECUTABLE" ]] || { echo "!! executable not found at $EXECUTABLE" >&2; exit 1; }

APP="$ROOT/build/$CONFIGURATION/TriCap.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$EXECUTABLE" "$CONTENTS/MacOS/TriCap"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/CWebP/COPYING" "$CONTENTS/Resources/libwebp-COPYING.txt"
cp "$ROOT/Sources/CWebP/PATENTS" "$CONTENTS/Resources/libwebp-PATENTS.txt"
printf 'APPL????' > "$CONTENTS/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo "==> verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# The whole point of vendoring libwebp is that the shipped binary has no external dependency on
# it. Fail loudly if a Homebrew (or any other) libwebp ever sneaks into the link.
if otool -L "$CONTENTS/MacOS/TriCap" | grep -Eiq 'libwebp|libsharpyuv|/opt/homebrew|/usr/local/(lib|opt)'; then
  echo "!! the executable links against an external libwebp — vendoring is broken" >&2
  otool -L "$CONTENTS/MacOS/TriCap" >&2
  exit 1
fi

echo "==> $APP"
otool -L "$CONTENTS/MacOS/TriCap" | sed 's/^/    /'
