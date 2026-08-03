# Third-party licences

TriCap has exactly one third-party dependency. Everything else is Apple platform API.

---

## libwebp 1.6.0

- **Upstream:** https://chromium.googlesource.com/webm/libwebp
  (mirror used for the fetch: `https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz`)
- **SHA-256 of the fetched tarball:** `93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136`
- **Licence:** BSD-3-Clause, plus the separate WebM patent grant
- **Vendored at:** `Sources/CWebP/` — source only, no binaries
- **Verbatim licence files shipped in the app bundle:**
  `TriCap.app/Contents/Resources/libwebp-COPYING.txt` and `libwebp-PATENTS.txt`
- **In-repo copies:** [`Sources/CWebP/COPYING`](Sources/CWebP/COPYING),
  [`Sources/CWebP/PATENTS`](Sources/CWebP/PATENTS),
  [`Sources/CWebP/AUTHORS`](Sources/CWebP/AUTHORS)
- **Modifications:** none. The `.c`/`.h` files are byte-identical to upstream; only the directory
  layout differs (public headers moved to `include/src/webp/` so one `-I` path serves both the
  vendored C sources and the module map). `Sources/CWebP/include/CWebP.h` and
  `include/module.modulemap` are TriCap files, not libwebp files.

### Licence text

> Copyright (c) 2010, Google Inc. All rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification, are permitted
> provided that the following conditions are met:
>
> * Redistributions of source code must retain the above copyright notice, this list of conditions
>   and the following disclaimer.
> * Redistributions in binary form must reproduce the above copyright notice, this list of
>   conditions and the following disclaimer in the documentation and/or other materials provided
>   with the distribution.
> * Neither the name of Google nor the names of its contributors may be used to endorse or promote
>   products derived from this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
> IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
> FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
> CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
> DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
> DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
> IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
> OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The full text, together with the WebM patent grant (`PATENTS`), is reproduced verbatim in
`Sources/CWebP/` and copied into the app bundle by `scripts/build-app.sh`.

### Obligations, and how TriCap meets them

| BSD-3-Clause obligation | How TriCap complies |
|---|---|
| Retain the copyright notice in source redistributions | `Sources/CWebP/COPYING` is committed unmodified alongside the sources |
| Reproduce the notice in binary redistributions | `build-app.sh` copies `COPYING` and `PATENTS` into `TriCap.app/Contents/Resources/`; `Info.plist`'s `NSHumanReadableCopyright` points at this file |
| Do not use Google's name to endorse | TriCap makes no such claim; the About pane says only "Animated WebP encoded by libwebp 1.6.0, compiled into the app" |

---

## Apple frameworks

ScreenCaptureKit, AppKit, SwiftUI, Core Graphics, Core Text, Core Media, Core Video, ImageIO,
UniformTypeIdentifiers, Carbon (HIToolbox) and `os` are used under the macOS SDK licence. No
private interfaces are used — see the symbol audit in REVIEW_HANDOFF.md.

---

## Nothing else

There are no Swift Package Manager dependencies (`Package.swift` declares no `.package(...)`
entries), no CocoaPods, no Carthage, no Homebrew requirement at build or run time.
