import CoreGraphics
import Foundation

/// Ceilings on pinned images.
///
/// A pin holds a decoded bitmap for as long as it is on screen, so "paste as many as you like"
/// is a memory leak with a keyboard shortcut. Both a count and a total-pixel budget are enforced:
/// twenty small pins and two enormous ones are both plausible ways to run out of memory.
public struct PinLimits: Equatable, Sendable {
    public let maxCount: Int
    /// Total pixels across every open pin.
    public let maxTotalPixels: Int
    /// Largest single image accepted, in pixels.
    public let maxSinglePixels: Int

    public init(maxCount: Int = 12, maxTotalPixels: Int = 120_000_000, maxSinglePixels: Int = 40_000_000) {
        self.maxCount = max(1, maxCount)
        self.maxTotalPixels = max(1, maxTotalPixels)
        self.maxSinglePixels = max(1, maxSinglePixels)
    }

    public static let `default` = PinLimits()

    /// Roughly how much memory that pixel budget represents, for the user-facing message.
    public var approximateMemoryBudgetMB: Int { maxTotalPixels * 4 / 1_048_576 }

    /// Why a pin could not be created.
    public enum Rejection: Equatable, Sendable {
        case tooManyPins(limit: Int)
        case imageTooLarge(pixels: Int, limit: Int)
        case wouldExceedTotal(pixels: Int, existing: Int, limit: Int)

        public var message: String {
            switch self {
            case .tooManyPins(let limit):
                return "You already have \(limit) pins open. Close one first."
            case .imageTooLarge(let pixels, let limit):
                return "That image is \(pixels / 1_000_000) MP, larger than the \(limit / 1_000_000) MP a single pin allows."
            case .wouldExceedTotal:
                return "That would use more memory than TriCap allows for pins. Close a pin first."
            }
        }
    }

    /// Whether one more image of `pixels` may be pinned.
    public func admit(newImagePixels pixels: Int, existingCount: Int, existingPixels: Int) -> Rejection? {
        guard existingCount < maxCount else { return .tooManyPins(limit: maxCount) }
        guard pixels <= maxSinglePixels else {
            return .imageTooLarge(pixels: pixels, limit: maxSinglePixels)
        }
        guard existingPixels + pixels <= maxTotalPixels else {
            return .wouldExceedTotal(pixels: pixels, existing: existingPixels, limit: maxTotalPixels)
        }
        return nil
    }
}

/// Where a new pin appears, and how it is kept reachable.
public enum PinPlacement {

    /// Fraction of a pin that must remain inside the screen after any move.
    ///
    /// Without this a pin can be dragged entirely off the edge, at which point there is no way to
    /// grab it again — the window has no title bar and nothing to click.
    public static let minimumVisibleFraction: CGFloat = 0.25

    /// Inset from the visible frame when a pasted image has to be shrunk to fit.
    public static let screenMargin: CGFloat = 24

    /// Scale that fits `imageSize` inside `visibleFrame`, never enlarging.
    public static func fitScale(imageSize: CGSize, in visibleFrame: CGRect, margin: CGFloat = screenMargin) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let available = CGSize(
            width: max(1, visibleFrame.width - margin * 2),
            height: max(1, visibleFrame.height - margin * 2)
        )
        return min(1, min(available.width / imageSize.width, available.height / imageSize.height))
    }

    /// Initial frame for a new pin: fitted to the screen, centred on `anchor`, then clamped fully
    /// on screen so the first thing a user sees is the whole image.
    public static func initialFrame(
        imageSize: CGSize,
        anchor: CGPoint,
        visibleFrame: CGRect,
        margin: CGFloat = screenMargin
    ) -> CGRect {
        let scale = fitScale(imageSize: imageSize, in: visibleFrame, margin: margin)
        let size = CGSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
        let origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        return clampFullyOnScreen(CGRect(origin: origin, size: size), within: visibleFrame)
    }

    /// Push a rect entirely inside `visibleFrame` when it fits, otherwise align its top-left.
    public static func clampFullyOnScreen(_ rect: CGRect, within visibleFrame: CGRect) -> CGRect {
        var result = rect
        if result.width <= visibleFrame.width {
            result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        } else {
            result.origin.x = visibleFrame.minX
        }
        if result.height <= visibleFrame.height {
            result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        } else {
            result.origin.y = visibleFrame.maxY - result.height
        }
        return result
    }

    /// Keep at least ``minimumVisibleFraction`` of a pin on screen after a drag.
    ///
    /// Looser than ``clampFullyOnScreen(_:within:)`` on purpose: a user may legitimately park most
    /// of a pin off the edge, just not all of it.
    public static func clampReachable(
        _ rect: CGRect,
        within visibleFrame: CGRect,
        minimumVisibleFraction: CGFloat = PinPlacement.minimumVisibleFraction
    ) -> CGRect {
        let fraction = min(max(minimumVisibleFraction, 0.01), 1)
        let requiredX = rect.width * fraction
        let requiredY = rect.height * fraction

        var result = rect
        result.origin.x = min(max(result.origin.x, visibleFrame.minX - (rect.width - requiredX)),
                              visibleFrame.maxX - requiredX)
        result.origin.y = min(max(result.origin.y, visibleFrame.minY - (rect.height - requiredY)),
                              visibleFrame.maxY - requiredY)
        return result
    }
}

/// Scaling a pin under the pointer.
public enum PinZoom {

    public static let minimumScale: CGFloat = 0.1
    public static let maximumScale: CGFloat = 8.0

    public static func clamp(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    /// New frame after zooming to `proposedScale` while keeping `anchor` over the same pixel.
    ///
    /// `anchor` is in screen coordinates. Zooming around the pointer rather than the centre is
    /// what makes a trackpad pinch feel like it is magnifying the thing under your finger.
    public static func frame(
        forScale proposedScale: CGFloat,
        imageSize: CGSize,
        currentFrame: CGRect,
        anchor: CGPoint
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              currentFrame.width > 0, currentFrame.height > 0 else { return currentFrame }

        let scale = clamp(proposedScale)
        let newSize = CGSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )

        // Where the anchor sits within the current frame, as a 0...1 fraction.
        let fractionX = (anchor.x - currentFrame.minX) / currentFrame.width
        let fractionY = (anchor.y - currentFrame.minY) / currentFrame.height

        return CGRect(
            x: anchor.x - newSize.width * fractionX,
            y: anchor.y - newSize.height * fractionY,
            width: newSize.width,
            height: newSize.height
        )
    }

    /// Scale implied by a frame, relative to the image's natural size.
    public static func scale(of frame: CGRect, imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0 else { return 1 }
        return frame.width / imageSize.width
    }
}

/// Opacity range offered by the pin's context menu.
public enum PinOpacity {
    public static let minimum: CGFloat = 0.2
    public static let maximum: CGFloat = 1.0
    public static let steps: [CGFloat] = [1.0, 0.8, 0.6, 0.4, 0.2]

    public static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    public static func label(for value: CGFloat) -> String {
        "\(Int((clamp(value) * 100).rounded()))%"
    }
}

/// How a pin looks, as far as that is a testable number.
public enum PinAppearance {
    /// One radius for every pin, in points — display-only. Copy and Save always hand back the
    /// original pixels; the rounding lives on the window's layer, never in the bitmap.
    public static let cornerRadius: CGFloat = 12

    /// The radius actually applied: uniform, but never so large that a tiny pin turns into a
    /// capsule — capped at half the short edge, and never negative.
    public static func effectiveCornerRadius(for size: CGSize) -> CGFloat {
        let shortEdge = max(0, min(size.width, size.height))
        return min(cornerRadius, shortEdge / 2)
    }
}

/// Which pin "the frontmost pin" means, tracked explicitly.
///
/// This used to be derived from `NSApp.windows.firstIndex(of:)`, on the assumption that AppKit
/// reorders that array as windows come forward. It does not: a window-server probe on this machine
/// showed that after creating A then B, `NSApp.windows == [A, B]`, and ordering A front left the
/// array unchanged. The old ordering therefore resolved to the *oldest* pin, so Escape closed the
/// wrong one — and clicking a pin did not change the answer at all.
///
/// AppKit makes no documented promise about that array's order, so the order TriCap needs is the
/// one TriCap maintains: newest pin in front, and any interaction brings a pin forward.
///
/// Stored back-to-front, so ``frontmost`` is the last element.
public struct PinFocusOrder<ID: Hashable>: Equatable, Sendable where ID: Sendable {

    private(set) public var ids: [ID] = []

    public init(ids: [ID] = []) {
        self.ids = ids
    }

    /// The pin that Escape closes, and that "close the front one" means.
    public var frontmost: ID? { ids.last }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    /// A newly created pin appears in front of the others.
    public mutating func insert(_ id: ID) {
        ids.removeAll { $0 == id }
        ids.append(id)
    }

    /// Bring a pin forward because the user touched it — a click, a drag, a scroll, a pinch or a
    /// right-click. Unknown ids are ignored rather than resurrected, so touching a pin that is
    /// being torn down cannot put it back in the order.
    public mutating func touch(_ id: ID) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        ids.append(id)
    }

    /// Forget a closed pin. Idempotent: closing twice leaves the rest of the order intact, and
    /// ``frontmost`` falls back to whatever was behind it.
    public mutating func remove(_ id: ID) {
        ids.removeAll { $0 == id }
    }

    public mutating func removeAll() {
        ids.removeAll()
    }

    public func contains(_ id: ID) -> Bool { ids.contains(id) }
}
