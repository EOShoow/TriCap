// generate-icon.swift — TriCap's application icon, drawn from scratch.
//
// This *is* the icon source: there is no .sketch, .afdesign or downloaded asset anywhere in the
// repository. Every shape below is a Core Graphics path with numbers you can edit, so the icon is
// reviewable in a diff and reproducible on any machine with the Swift toolchain.
//
//     swift scripts/generate-icon.swift Resources/AppIcon
//
// Design: a viewfinder — four corner brackets around an open centre — in a deep-to-bright blue
// vertical gradient, with a single small coral shutter dot at the optical centre. No text, no
// letterforms, no third-party marks. The brackets thicken and the dot grows proportionally at
// small sizes so the silhouette survives at 16 pt, where a hairline would disappear.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

/// Deep navy at the top of the rounded square.
let deepBlue = CGColor(srgbRed: 0.055, green: 0.180, blue: 0.420, alpha: 1)
/// Bright azure at the bottom.
let brightBlue = CGColor(srgbRed: 0.145, green: 0.510, blue: 0.925, alpha: 1)
/// The viewfinder brackets: near-white, so they read on the blue at any size.
let bracketColor = CGColor(srgbRed: 0.965, green: 0.980, blue: 1.0, alpha: 1)
/// The shutter dot. Deliberately the only warm colour, and a small fraction of the area.
let coral = CGColor(srgbRed: 1.0, green: 0.376, blue: 0.325, alpha: 1)

// MARK: - Drawing

/// Render the icon at `size` × `size` pixels.
///
/// Everything is expressed as a fraction of `size`, so the geometry is identical at every
/// resolution and only the stroke weight is deliberately adjusted for legibility.
func drawIcon(size: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: Int(size) * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // --- rounded-square body -------------------------------------------------------------
    // macOS icons sit on a squircle inset from the canvas; 10% inset with a 22.5% corner radius
    // matches the proportions of the system's own app icons closely enough to sit beside them.
    let inset = size * 0.10
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = body.width * 0.225
    let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [deepBlue, brightBlue] as CFArray,
        locations: [0, 1]
    ) {
        // Top-to-bottom: deep at the top, bright at the bottom.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }
    context.restoreGState()

    // --- viewfinder brackets ---------------------------------------------------------------
    // Four corner brackets around an open centre. At 16 px a proportional stroke lands under one
    // pixel and vanishes, so the weight is nudged up as the canvas shrinks.
    let isSmall = size <= 32
    let smallSizeBoost: CGFloat = isSmall ? 1.35 : (size <= 64 ? 1.15 : 1.0)
    let strokeWidth = max(1.5, size * 0.062 * smallSizeBoost)
    // The brackets also move outwards and grow longer as the canvas shrinks: at 16 px a 20% inset
    // leaves a frame barely 7 px across, where four separate brackets turn to mush.
    // Not too far out, though: pushed past ~0.18 the brackets crowd the rounded corner and read as
    // a broken second outline rather than a viewfinder.
    let bracketInset = body.width * (isSmall ? 0.18 : 0.20)
    let frame = body.insetBy(dx: bracketInset, dy: bracketInset)
    // How far each bracket runs along its edges before stopping.
    let armLength = frame.width * (isSmall ? 0.34 : 0.30)
    let bracketRadius = strokeWidth * 0.9

    context.setStrokeColor(bracketColor)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1),    // bottom-left
        (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),   // bottom-right
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),   // top-left
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),  // top-right
    ]

    for (corner, dx, dy) in corners {
        context.beginPath()
        // Horizontal arm, into a rounded elbow, then the vertical arm.
        context.move(to: CGPoint(x: corner.x + dx * armLength, y: corner.y))
        context.addLine(to: CGPoint(x: corner.x + dx * bracketRadius, y: corner.y))
        context.addQuadCurve(
            to: CGPoint(x: corner.x, y: corner.y + dy * bracketRadius),
            control: corner
        )
        context.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * armLength))
        context.strokePath()
    }

    // --- shutter dot -----------------------------------------------------------------------
    // Small, warm, and exactly centred: the one point of contrast, and what makes the mark read
    // as a camera rather than a crop tool.
    let dotRadius = max(1.2, frame.width * 0.105 * (size <= 32 ? 1.25 : 1.0))
    let dot = CGRect(
        x: body.midX - dotRadius,
        y: body.midY - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    context.setFillColor(coral)
    context.fillEllipse(in: dot)

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

/// A contact sheet: every size on a light and a dark background, for eyeballing legibility.
///
/// Each tile is drawn at its *true* pixel size — the whole point is to see whether the 16 px
/// rendering still reads, so nothing here is scaled up for convenience.
func writeContactSheet(sizes: [Int], to url: URL, darkBackground: Bool) throws {
    let padding = 32
    let tallest = sizes.max() ?? 0
    let totalWidth = sizes.reduce(padding) { $0 + $1 + padding }
    let totalHeight = tallest + padding * 2

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: totalWidth, height: totalHeight,
        bitsPerComponent: 8, bytesPerRow: totalWidth * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return }

    context.setFillColor(darkBackground
        ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        : CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

    // Bottom-aligned, so the small tiles sit on a common baseline and are easy to compare.
    var x = padding
    for size in sizes {
        if let image = drawIcon(size: CGFloat(size)) {
            context.draw(image, in: CGRect(x: x, y: padding, width: size, height: size))
        }
        x += size + padding
    }

    guard let sheet = context.makeImage() else { return }
    try writePNG(sheet, to: url)
}

// MARK: - Main

let arguments = CommandLine.arguments
let outputDirectory = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "Resources/AppIcon",
    isDirectory: true
)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// The set `iconutil` expects, at 1× and 2×.
let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = outputDirectory.appendingPathComponent("TriCap.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in iconsetEntries {
    guard let image = drawIcon(size: CGFloat(entry.pixels)) else {
        FileHandle.standardError.write(Data("failed to render \(entry.name)\n".utf8))
        exit(1)
    }
    try writePNG(image, to: iconset.appendingPathComponent("\(entry.name).png"))
}

// The 1024 master, kept beside the iconset for documentation and for the App Store size.
if let master = drawIcon(size: 1024) {
    try writePNG(master, to: outputDirectory.appendingPathComponent("TriCap-1024.png"))
}

// Legibility check sheets.
let checkSizes = [16, 32, 128, 256, 512, 1024]
try writeContactSheet(
    sizes: checkSizes,
    to: outputDirectory.appendingPathComponent("icon-check-light.png"),
    darkBackground: false
)
try writeContactSheet(
    sizes: checkSizes,
    to: outputDirectory.appendingPathComponent("icon-check-dark.png"),
    darkBackground: true
)

print("wrote \(iconsetEntries.count) iconset images, the 1024 master and two check sheets to \(outputDirectory.path)")
