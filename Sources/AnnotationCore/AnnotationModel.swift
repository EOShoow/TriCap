import CoreGraphics
import Foundation

/// The MVP annotation tool set.
public enum AnnotationTool: String, Codable, CaseIterable, Sendable, Identifiable {
    case arrow
    case rectangle
    case text
    case freehand
    case mosaic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .freehand: return "Pen"
        case .mosaic: return "Mosaic"
        }
    }

    /// 1-based position in the toolbar, which is also its keyboard shortcut.
    public var shortcutNumber: Int {
        switch self {
        case .arrow: return 1
        case .rectangle: return 2
        case .text: return 3
        case .freehand: return 4
        case .mosaic: return 5
        }
    }

    /// Tooltip copy: what the tool does, not just what it is called.
    public var toolTip: String {
        switch self {
        case .arrow: return "Arrow — point at something (\u{2318}1)"
        case .rectangle: return "Rectangle — box something off (\u{2318}2)"
        case .text: return "Text — click, then type (\u{2318}3)"
        case .freehand: return "Pen — draw freehand (\u{2318}4)"
        // "Pixelate", not "blur": the effect is a block mosaic, and calling it a blur promises a
        // different look. It is visual obscuration, not irreversible redaction — for secrets a
        // filled rectangle is the honest tool.
        case .mosaic: return "Mosaic — pixelate anything private (\u{2318}5)"
        }
    }

    /// SF Symbol used by the editor toolbar.
    public var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        // `textformat` is a locale-adaptive symbol: on a Chinese system it renders as 格式,
        // which reads as a word next to four pictographs. `t.square` is stable everywhere.
        case .text: return "t.square"
        case .freehand: return "scribble"
        case .mosaic: return "mosaic"
        }
    }
}

/// Straight RGBA in sRGB, 0...1. Stored as components rather than an `NSColor` so the whole
/// annotation model stays `Codable`, `Equatable` and testable without AppKit.
public struct AnnotationColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    public var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        ) ?? CGColor(gray: 0, alpha: 1)
    }

    public static let red = AnnotationColor(red: 0.93, green: 0.21, blue: 0.18)
    public static let yellow = AnnotationColor(red: 1.0, green: 0.78, blue: 0.06)
    public static let green = AnnotationColor(red: 0.20, green: 0.74, blue: 0.36)
    public static let blue = AnnotationColor(red: 0.15, green: 0.51, blue: 0.94)
    public static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    public static let black = AnnotationColor(red: 0, green: 0, blue: 0)

    public static let palette: [AnnotationColor] = [.red, .yellow, .green, .blue, .white, .black]
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// Per-item appearance.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: AnnotationColor
    /// Stroke width in canvas pixels.
    public var lineWidth: CGFloat
    /// Point size for `.text`, in canvas pixels.
    public var fontSize: CGFloat
    /// Edge length of one mosaic cell, in canvas pixels.
    public var mosaicBlockSize: CGFloat
    /// Fill rectangles instead of stroking them.
    public var filled: Bool

    public init(
        color: AnnotationColor = .red,
        lineWidth: CGFloat = 4,
        fontSize: CGFloat = 28,
        mosaicBlockSize: CGFloat = 14,
        filled: Bool = false
    ) {
        self.color = color
        self.lineWidth = max(1, lineWidth)
        self.fontSize = max(6, fontSize)
        self.mosaicBlockSize = max(2, mosaicBlockSize)
        self.filled = filled
    }

    public static let `default` = AnnotationStyle()
}

/// Geometry of one annotation.
///
/// **Coordinate space:** every point is in *canvas pixels* — the pixel grid of the image being
/// annotated, origin at the **top-left**, +y **down**. That matches what the user sees and what
/// the editor view reports; `AnnotationRenderer` performs the single flip needed to draw into a
/// bottom-left-origin `CGContext`. Nothing else in the codebase flips these.
public enum AnnotationShape: Codable, Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case text(origin: CGPoint, string: String)
    case freehand(points: [CGPoint])
    case mosaic(CGRect)

    public var tool: AnnotationTool {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .text: return .text
        case .freehand: return .freehand
        case .mosaic: return .mosaic
        }
    }

    /// Axis-aligned bounds ignoring stroke width; used for hit-testing and dirty rects.
    public var bounds: CGRect {
        switch self {
        case .arrow(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .rectangle(let r), .mosaic(let r):
            return r.standardized
        case .text(let origin, _):
            return CGRect(origin: origin, size: .zero)
        case .freehand(let points):
            guard let first = points.first else { return .zero }
            var rect = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
            return rect
        }
    }

    /// Shapes that collapse to nothing are dropped rather than stored as invisible items.
    public var isDegenerate: Bool {
        switch self {
        case .arrow(let a, let b):
            return hypot(a.x - b.x, a.y - b.y) < 2
        case .rectangle(let r), .mosaic(let r):
            return r.standardized.width < 2 || r.standardized.height < 2
        case .text(_, let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .freehand(let points):
            return points.count < 2
        }
    }
}

/// One annotation: geometry plus appearance plus a stable identity.
public struct AnnotationItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var shape: AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle = .default) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    public var tool: AnnotationTool { shape.tool }
}
