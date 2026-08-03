// CWebP.h — umbrella header for the vendored libwebp C target.
//
// TriCap only ever imports libwebp through this header, which pins the exact
// public surface Swift code is allowed to touch. The nested include paths match
// libwebp's own convention ("src/webp/...") so that the vendored .c files and
// this header resolve headers from the same single -I<target>/include path.

#ifndef TRICAP_CWEBP_UMBRELLA_H
#define TRICAP_CWEBP_UMBRELLA_H

#include "src/webp/types.h"
#include "src/webp/decode.h"
#include "src/webp/encode.h"
#include "src/webp/demux.h"
#include "src/webp/mux_types.h"
#include "src/webp/mux.h"

#endif  // TRICAP_CWEBP_UMBRELLA_H
