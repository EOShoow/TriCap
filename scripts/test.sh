#!/usr/bin/env bash
#
# test.sh — run the TriCap test suite.
#
# Why this wrapper exists: this machine has Command Line Tools but no Xcode.app. The Swift
# toolchain ships swift-testing at
#   /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
# but SwiftPM does not put that directory on the framework search path unless Xcode is the
# active developer directory, so `swift test` alone fails with "no such module 'Testing'".
# Passing -F (compile + link) and two -rpath entries (Testing.framework and the
# lib_TestingInterop.dylib it links against) makes it work with CLT only.
#
# If you have Xcode installed, plain `swift test` works and this script is still fine to use.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
INTEROP_LIB="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"

ARGS=()
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  ARGS+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS")
  ARGS+=(-Xlinker -F -Xlinker "$FRAMEWORKS")
  ARGS+=(-Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
if [[ -d "$INTEROP_LIB" ]]; then
  ARGS+=(-Xlinker -rpath -Xlinker "$INTEROP_LIB")
fi

echo "==> swift test ${*:-}"
exec swift test "${ARGS[@]}" "$@"
