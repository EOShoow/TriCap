# libwebp integration

TriCap compiles libwebp 1.6.0 **into its own binary from vendored source**. The end user never
needs `brew install webp`, and the app links no external image library at all.

## Why vendored source rather than a linked library

| Option | Rejected because |
|---|---|
| Link Homebrew's `libwebp.dylib` | The shipped app would refuse to launch on any Mac without Homebrew. Explicitly forbidden by the brief. |
| Ship a prebuilt `.a`/`.xcframework` | An opaque binary blob in the repository that a reviewer cannot audit and that cannot be rebuilt from a clean checkout. |
| ImageIO's WebP support | macOS ImageIO decodes WebP but its *animated* WebP encoding support is not a documented, guaranteed API surface across the supported OS range. Using libwebp for both still and animated WebP keeps output predictable and identical everywhere. |
| **Vendored C source as a SwiftPM target** | ✅ Auditable, reproducible from a clean checkout, no runtime dependency, one `swift build`. |

## What is vendored

```
Sources/CWebP/
  include/
    CWebP.h              ← TriCap: umbrella header, the only public surface Swift may touch
    module.modulemap     ← TriCap: explicit `header "CWebP.h"` module
    src/webp/*.h         ← libwebp public headers (decode, demux, encode, mux, mux_types,
                           types, format_constants)
  src/dec/   src/demux/  src/dsp/  src/enc/  src/mux/  src/utils/
  sharpyuv/
  COPYING  PATENTS  AUTHORS  LIBWEBP_VERSION  LIBWEBP_TARBALL_SHA256
```

125 `.c` files, 51 headers, ~3.1 MB. Decoder and demuxer are included as well as the encoder:
`WebPAnimDecoder` is what lets TriCap **re-read and verify** every animation it writes rather than
trusting its own encoder.

## Layout choices

libwebp's own sources include each other as `"src/dsp/dsp.h"`, `"sharpyuv/sharpyuv.h"` and
`"src/webp/encode.h"` — paths relative to the library root. Two `-I` paths satisfy all of them:

```swift
cSettings: [
    .headerSearchPath("."),        // finds src/dsp/…, src/enc/…, sharpyuv/…
    .headerSearchPath("include"),  // finds src/webp/… (the public headers)
    .define("WEBP_USE_THREAD", to: "1"),
    .unsafeFlags(["-Wno-unused-function", "-Wno-unused-but-set-variable"]),
]
```

Public headers live at `include/src/webp/` (rather than the conventional `include/webp/`) so that
the *same* `-I<target>/include` serves both the vendored C sources and the hand-written umbrella
header — no duplicated header copies that could drift.

The module map is explicit (`header "CWebP.h"`) rather than an umbrella *directory*, so the Swift
surface is exactly the six headers `CWebP.h` includes and nothing leaks in accidentally.

## SIMD

No architecture flags are passed. libwebp's `dsp.h` enables a code path only when the compiler has
already defined the corresponding macro:

- **arm64** — `WEBP_USE_NEON` is on by default (`__aarch64__`), so the NEON kernels compile and
  the runtime dispatch uses them. This is the configuration TriCap was developed and measured on.
- **x86_64** — `__SSE2__` is always defined on macOS, so the SSE2 kernels compile. SSE4.1 and
  AVX2 kernels compile to nothing without `-msse4.1` / `-mavx2`, and libwebp's runtime dispatch
  correctly does not call them (`WEBP_HAVE_SSE41` / `WEBP_HAVE_AVX2` stay undefined in lock-step
  with `WEBP_USE_*`). The result is **correct but slower** on Intel Macs.

Per-file compiler flags are not expressible in SwiftPM, and enabling AVX2 for the whole target
would make the binary crash on any CPU without it. Encoding a 15-second clip is a background
operation, so the trade is correctness and portability over Intel encode speed. If that ever
matters, the fix is a separate SwiftPM target per ISA level with `.unsafeFlags`.

`WEBP_USE_THREAD=1` enables libwebp's pthread-based multi-threading.

## Re-vendoring

```bash
./scripts/vendor-libwebp.sh 1.6.0
```

Downloads the tarball, **verifies its SHA-256 against the pinned constant**, and rebuilds
`Sources/CWebP/` from it. The script is the executable record of exactly how the vendored tree was
produced; the resulting diff should be reviewable.

## Proof that nothing external is linked

From `scripts/build-app.sh` (it fails the build if this regresses) and reproducible by hand:

```console
$ otool -L build/release/TriCap.app/Contents/MacOS/TriCap | grep -vE '^\s+(/usr/lib|/System)'
(no output — every dylib is an OS one)

$ nm -u build/release/TriCap.app/Contents/MacOS/TriCap | grep -i webp
(no output — no undefined WebP symbol to import)

$ nm -m build/release/TriCap.app/Contents/MacOS/TriCap | grep ' _WebPEncode$'
0000000100059f44 (__TEXT,__text) external _WebPEncode
```

`WebPEncode`, `WebPAnimEncoderAdd`, `WebPAnimDecoderNewInternal` and friends are **defined inside
the executable**. Homebrew's `/opt/homebrew/opt/webp/lib/libwebp.dylib` exists on the development
machine and is entirely irrelevant to the binary.

At runtime the app also reports the version it is actually running:
`WebPGetEncoderVersion()` → `0x010600` → `1.6.0`, shown in the About pane and asserted by the test
suite.

## Swift bridge safety notes

`Sources/ExportCore/WebPCodec.swift` is the only file that talks to libwebp.

- Every `WebPPicture` is `WebPPictureFree`d on all paths, including error paths.
- `WebPMemoryWriter` is `WebPMemoryWriterClear`ed via `defer`; the whole `WebPEncode` call happens
  *inside* `withUnsafeMutablePointer` so the writer pointer never escapes its scope (letting it
  escape and calling `WebPEncode` afterwards would be undefined behaviour).
- `WebPData` from `WebPAnimEncoderAssemble` is `WebPDataClear`ed via `defer`.
- Pixels are always imported with `WebPPictureImportRGBX`, matching TriCap's canonical opaque
  `R G B X` buffer. Importing that buffer as RGBA would read the unused X byte as alpha and produce
  a fully transparent file — `WebPCodecTests.stillIsOpaque` is the regression guard.
- Frame timestamps are validated for strict monotonicity in Swift *before* `WebPAnimEncoderAdd`
  sees them, so libwebp can never fail with a message the user cannot act on.
