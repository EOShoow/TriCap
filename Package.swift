// swift-tools-version: 6.0
//
// TriCap — native macOS menu-bar region screenshot + short animated-WebP recorder.
//
// This machine has Command Line Tools only (no Xcode.app), so the project is a
// SwiftPM package rather than an .xcodeproj. `scripts/build-app.sh` assembles the
// SwiftPM executable into a proper TriCap.app bundle. See ARCHITECTURE.md.

import PackageDescription

let package = Package(
    name: "TriCap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TriCap", targets: ["TriCapApp"]),
        .library(name: "TriCapKit", targets: ["TriCapKit"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "SelectionUI", targets: ["SelectionUI"]),
        .library(name: "AnnotationCore", targets: ["AnnotationCore"]),
        .library(name: "ExportCore", targets: ["ExportCore"]),
    ],
    targets: [
        // Vendored libwebp 1.6.0 (BSD-3-Clause). See Sources/CWebP/COPYING and
        // docs/LIBWEBP.md. Vendored on purpose: the shipped app must not require
        // `brew install webp` on the end user's machine.
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            exclude: [
                "COPYING", "PATENTS", "AUTHORS",
                "LIBWEBP_VERSION", "LIBWEBP_TARBALL_SHA256",
            ],
            sources: ["src", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [
                // libwebp sources include each other as "src/dsp/dsp.h" and
                // "sharpyuv/sharpyuv.h" relative to the library root, and the
                // public headers as "src/webp/encode.h" relative to include/.
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("WEBP_USE_THREAD", to: "1"),
                // Keep the encoder deterministic and free of stdio chatter.
                .unsafeFlags(["-Wno-unused-function", "-Wno-unused-but-set-variable"]),
            ]
        ),

        // Shared vocabulary: coordinate spaces, limits, settings, errors.
        .target(name: "TriCapKit"),

        .target(name: "CaptureCore", dependencies: ["TriCapKit"]),
        .target(name: "SelectionUI", dependencies: ["TriCapKit"]),
        .target(name: "AnnotationCore", dependencies: ["TriCapKit"]),
        .target(name: "ExportCore", dependencies: ["TriCapKit", "AnnotationCore", "CWebP"]),

        .executableTarget(
            name: "TriCapApp",
            dependencies: ["TriCapKit", "CaptureCore", "SelectionUI", "AnnotationCore", "ExportCore"]
        ),

        .testTarget(
            name: "TriCapTests",
            dependencies: ["TriCapKit", "CaptureCore", "SelectionUI", "AnnotationCore", "ExportCore", "CWebP"]
        ),
    ]
)
