#!/usr/bin/env bash
#
# vendor-libwebp.sh — reproducibly re-vendor the libwebp sources under Sources/CWebP.
#
# The vendored copy is committed to this repository so that a clean `swift build`
# needs no network access and the shipped app never depends on a Homebrew (or any
# other system-wide) libwebp. This script exists to document *exactly* how the
# vendored tree was produced and to make refreshing it auditable.
#
# Usage:  ./scripts/vendor-libwebp.sh [version]
#
set -euo pipefail

VERSION="${1:-1.6.0}"
TARBALL_SHA256_1_6_0="93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CWebP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URL="https://github.com/webmproject/libwebp/archive/refs/tags/v${VERSION}.tar.gz"
echo "==> downloading $URL"
curl -fsSL --max-time 300 -o "$WORK/libwebp.tar.gz" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/libwebp.tar.gz" | awk '{print $1}')"
echo "==> sha256 $ACTUAL"
if [[ "$VERSION" == "1.6.0" && "$ACTUAL" != "$TARBALL_SHA256_1_6_0" ]]; then
  echo "!! sha256 mismatch for libwebp 1.6.0" >&2
  echo "   expected $TARBALL_SHA256_1_6_0" >&2
  exit 1
fi

tar xzf "$WORK/libwebp.tar.gz" -C "$WORK"
SRC="$WORK/libwebp-${VERSION}"

rm -rf "$DEST/src" "$DEST/sharpyuv" "$DEST/include/src"
mkdir -p "$DEST/include/src/webp"

# Private sources + private headers keep their upstream relative layout because
# libwebp's own sources include each other as "src/dsp/dsp.h", "sharpyuv/...".
for d in dec demux dsp enc mux utils; do
  mkdir -p "$DEST/src/$d"
  cp "$SRC/src/$d"/*.c "$DEST/src/$d/"
  # src/demux ships no private headers; tolerate that.
  cp "$SRC/src/$d"/*.h "$DEST/src/$d/" 2>/dev/null || true
done
mkdir -p "$DEST/sharpyuv"
cp "$SRC/sharpyuv"/*.c "$SRC/sharpyuv"/*.h "$DEST/sharpyuv/"

# Public headers live under include/src/webp so that both the C sources
# (#include "src/webp/encode.h") and the hand-written module map resolve them
# from the single -I<target>/include search path.
cp "$SRC/src/webp"/*.h "$DEST/include/src/webp/"

# Upstream legal / provenance files.
cp "$SRC/COPYING" "$DEST/COPYING"
cp "$SRC/PATENTS" "$DEST/PATENTS"
cp "$SRC/AUTHORS" "$DEST/AUTHORS"
printf '%s\n' "$VERSION" > "$DEST/LIBWEBP_VERSION"
printf '%s\n' "$ACTUAL" > "$DEST/LIBWEBP_TARBALL_SHA256"

echo "==> vendored libwebp $VERSION into $DEST"
find "$DEST" -name '*.c' | wc -l | xargs echo "    C files:"
find "$DEST" -name '*.h' | wc -l | xargs echo "    headers:"
