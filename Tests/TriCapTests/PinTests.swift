import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ExportCore
@testable import TriCapKit

@Suite("Pin memory limits")
struct PinLimitsTests {

    let limits = PinLimits(maxCount: 3, maxTotalPixels: 10_000_000, maxSinglePixels: 6_000_000)

    @Test("A first pin within budget is admitted")
    func admitsFirst() {
        #expect(limits.admit(newImagePixels: 1_000_000, existingCount: 0, existingPixels: 0) == nil)
    }

    @Test("The count ceiling is enforced before anything else")
    func countCeiling() {
        #expect(
            limits.admit(newImagePixels: 1, existingCount: 3, existingPixels: 0)
                == .tooManyPins(limit: 3)
        )
    }

    @Test("A single oversized image is refused even with an empty board")
    func singleImageCeiling() {
        // Twenty small pins and one enormous one are both ways to exhaust memory, so both are
        // capped.
        let rejection = limits.admit(newImagePixels: 9_000_000, existingCount: 0, existingPixels: 0)
        #expect(rejection == .imageTooLarge(pixels: 9_000_000, limit: 6_000_000))
    }

    @Test("The running total is enforced across pins")
    func totalCeiling() {
        let rejection = limits.admit(newImagePixels: 5_000_000, existingCount: 1, existingPixels: 6_000_000)
        #expect(rejection == .wouldExceedTotal(pixels: 5_000_000, existing: 6_000_000, limit: 10_000_000))
    }

    @Test("Exactly hitting the total is allowed")
    func totalBoundaryIsInclusive() {
        #expect(limits.admit(newImagePixels: 4_000_000, existingCount: 1, existingPixels: 6_000_000) == nil)
    }

    @Test("Every rejection explains itself in a sentence a user can act on")
    func rejectionsHaveMessages() {
        let all: [PinLimits.Rejection] = [
            .tooManyPins(limit: 3),
            .imageTooLarge(pixels: 9_000_000, limit: 6_000_000),
            .wouldExceedTotal(pixels: 5_000_000, existing: 6_000_000, limit: 10_000_000),
        ]
        for rejection in all {
            #expect(!rejection.message.isEmpty)
            #expect(rejection.message.hasSuffix("."))
        }
    }

    @Test("The shipped defaults are self-consistent")
    func defaultsAreSane() {
        let defaults = PinLimits.default
        #expect(defaults.maxSinglePixels <= defaults.maxTotalPixels)
        #expect(defaults.maxCount >= 2)
        #expect(defaults.approximateMemoryBudgetMB > 0)
    }
}

@Suite("Pin placement")
struct PinPlacementTests {

    let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)

    @Test("An image that already fits is not scaled")
    func noUpscale() {
        let scale = PinPlacement.fitScale(imageSize: CGSize(width: 400, height: 300), in: visible)
        #expect(scale == 1)
    }

    @Test("An oversized image is scaled down to fit with a margin")
    func scalesDown() {
        let scale = PinPlacement.fitScale(imageSize: CGSize(width: 4000, height: 3000), in: visible)
        #expect(scale < 1)
        #expect(4000 * scale <= visible.width)
        #expect(3000 * scale <= visible.height)
    }

    @Test("A new pin is centred on the pointer and fully on screen")
    func initialFrameIsOnScreen() {
        let frame = PinPlacement.initialFrame(
            imageSize: CGSize(width: 400, height: 300),
            anchor: CGPoint(x: 700, y: 400),
            visibleFrame: visible
        )
        #expect(frame.width == 400)
        #expect(visible.contains(frame))
    }

    @Test("A pin created near a corner is pushed fully into view")
    func cornerAnchorIsClamped() {
        // Pasting with the pointer at the very edge must not put most of the image off screen.
        let frame = PinPlacement.initialFrame(
            imageSize: CGSize(width: 400, height: 300),
            anchor: CGPoint(x: 5, y: 5),
            visibleFrame: visible
        )
        #expect(visible.contains(frame))
        #expect(frame.minX >= visible.minX)
        #expect(frame.minY >= visible.minY)
    }

    @Test("A dragged pin can hang off the edge but never disappear")
    func dragKeepsPinReachable() {
        // The window is borderless with no title bar, so a pin dragged entirely off screen could
        // never be grabbed again.
        let pin = CGRect(x: 0, y: 0, width: 400, height: 300)
        let farOff = pin.offsetBy(dx: 5000, dy: 5000)
        let clamped = PinPlacement.clampReachable(farOff, within: visible)

        #expect(clamped.intersects(visible))
        let overlap = clamped.intersection(visible)
        #expect(overlap.width >= pin.width * PinPlacement.minimumVisibleFraction - 0.01)
    }

    @Test("Dragging off the opposite edge is clamped too", arguments: [
        CGPoint(x: -5000, y: 0), CGPoint(x: 0, y: -5000), CGPoint(x: -5000, y: -5000),
    ])
    func dragClampsInEveryDirection(offset: CGPoint) {
        let pin = CGRect(x: 500, y: 400, width: 400, height: 300)
        let moved = pin.offsetBy(dx: offset.x, dy: offset.y)
        let clamped = PinPlacement.clampReachable(moved, within: visible)
        #expect(clamped.intersects(visible))
    }

    @Test("An image larger than the screen is anchored rather than centred off-screen")
    func oversizedPinAnchors() {
        let huge = CGRect(x: -500, y: -500, width: 3000, height: 2000)
        let clamped = PinPlacement.clampFullyOnScreen(huge, within: visible)
        #expect(clamped.minX == visible.minX)
        #expect(clamped.maxY == visible.maxY, "the top-left corner is what a user looks at first")
    }

    @Test("A zero-size image does not divide by zero")
    func zeroSizeImage() {
        #expect(PinPlacement.fitScale(imageSize: .zero, in: visible) == 1)
        let frame = PinPlacement.initialFrame(imageSize: .zero, anchor: .zero, visibleFrame: visible)
        #expect(frame.width >= 1)
        #expect(frame.height >= 1)
    }
}

@Suite("Pin zoom")
struct PinZoomTests {

    let imageSize = CGSize(width: 400, height: 300)

    @Test("Scale is clamped at both ends")
    func clampsScale() {
        #expect(PinZoom.clamp(0.001) == PinZoom.minimumScale)
        #expect(PinZoom.clamp(1000) == PinZoom.maximumScale)
        #expect(PinZoom.clamp(1.5) == 1.5)
    }

    @Test("Zooming keeps the anchor over the same part of the image")
    func zoomIsAnchored() {
        // Zooming under the pointer is what makes a trackpad pinch feel like magnification rather
        // than a jump.
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let anchor = CGPoint(x: 200, y: 150)   // 25% across, ~16.7% up

        let zoomed = PinZoom.frame(forScale: 2, imageSize: imageSize, currentFrame: frame, anchor: anchor)

        let fractionBefore = (anchor.x - frame.minX) / frame.width
        let fractionAfter = (anchor.x - zoomed.minX) / zoomed.width
        #expect(abs(fractionBefore - fractionAfter) < 0.001)
    }

    @Test("Zooming to a clamped scale still produces a valid frame")
    func clampedZoomIsValid() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let zoomed = PinZoom.frame(
            forScale: 500, imageSize: imageSize, currentFrame: frame, anchor: CGPoint(x: 200, y: 150)
        )
        #expect(zoomed.width == imageSize.width * PinZoom.maximumScale)
        #expect(zoomed.height > 0)
    }

    @Test("scale(of:) inverts frame(forScale:)")
    func scaleRoundTrips() {
        let frame = PinZoom.frame(
            forScale: 1.75,
            imageSize: imageSize,
            currentFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            anchor: .zero
        )
        #expect(abs(PinZoom.scale(of: frame, imageSize: imageSize) - 1.75) < 0.01)
    }

    @Test("A degenerate current frame is returned unchanged rather than producing NaN")
    func degenerateFrame() {
        let empty = CGRect(x: 10, y: 10, width: 0, height: 0)
        #expect(PinZoom.frame(forScale: 2, imageSize: imageSize, currentFrame: empty, anchor: .zero) == empty)
    }
}

@Suite("Pin opacity")
struct PinOpacityTests {

    @Test("Opacity is clamped to a range that keeps the pin visible")
    func clamps() {
        #expect(PinOpacity.clamp(0) == PinOpacity.minimum)
        #expect(PinOpacity.clamp(5) == PinOpacity.maximum)
        // Fully transparent would be indistinguishable from a lost pin.
        #expect(PinOpacity.minimum > 0)
    }

    @Test("Every offered step is inside the allowed range and labelled as a percentage")
    func stepsAreValid() {
        for step in PinOpacity.steps {
            #expect(PinOpacity.clamp(step) == step)
            #expect(PinOpacity.label(for: step).hasSuffix("%"))
        }
        #expect(PinOpacity.steps.contains(1.0), "there must be a way back to fully opaque")
    }
}

@Suite("Pin appearance")
struct PinAppearanceTests {

    @Test("Every ordinary pin gets the one shared radius")
    func uniformRadius() {
        // The whole point of the change: 4 pt read as barely-not-square, and different-looking
        // corners across pins would be worse than either. One number, everywhere.
        #expect(PinAppearance.cornerRadius == 12)
        for size in [CGSize(width: 400, height: 300), CGSize(width: 1200, height: 800),
                     CGSize(width: 64, height: 64)] {
            #expect(PinAppearance.effectiveCornerRadius(for: size) == 12)
        }
    }

    @Test("A tiny pin clamps to half its short edge instead of becoming a capsule")
    func tinyPinClamps() {
        #expect(PinAppearance.effectiveCornerRadius(for: CGSize(width: 16, height: 100)) == 8)
        #expect(PinAppearance.effectiveCornerRadius(for: CGSize(width: 100, height: 10)) == 5)
    }

    @Test("Degenerate sizes never yield a negative radius")
    func degenerateSizes() {
        #expect(PinAppearance.effectiveCornerRadius(for: .zero) == 0)
        #expect(PinAppearance.effectiveCornerRadius(for: CGSize(width: -50, height: 40)) == 0)
    }
}

@Suite("Pin focus order")
struct PinFocusOrderTests {

    private func order(_ ids: [Int] = []) -> PinFocusOrder<Int> { PinFocusOrder(ids: ids) }

    @Test("An empty board has no frontmost pin")
    func emptyOrder() {
        #expect(order().frontmost == nil)
        #expect(order().isEmpty)
    }

    @Test("A newly created pin is the frontmost one")
    func newestIsFrontmost() {
        // The regression: this used to be derived from `NSApp.windows.firstIndex`, which a probe
        // showed keeps creation order and does not change when a window is ordered front — so
        // Escape closed the *oldest* pin instead of the newest.
        var focus = order()
        focus.insert(1)
        focus.insert(2)
        #expect(focus.frontmost == 2)
        #expect(focus.ids == [1, 2])
    }

    @Test("Interacting with an older pin brings it forward")
    func interactionChangesFrontmost() {
        var focus = order([1, 2])
        focus.touch(1)
        #expect(focus.frontmost == 1)
        #expect(focus.count == 2, "touching must not duplicate the entry")
    }

    @Test("Touching the pin that is already in front changes nothing")
    func touchingFrontmostIsStable() {
        var focus = order([1, 2])
        focus.touch(2)
        #expect(focus.ids == [1, 2])
    }

    @Test("Closing the front pin falls back to the one behind it")
    func closeFallsBack() {
        var focus = order([1, 2, 3])
        focus.remove(3)
        #expect(focus.frontmost == 2)
        focus.remove(2)
        #expect(focus.frontmost == 1)
        focus.remove(1)
        #expect(focus.frontmost == nil)
    }

    @Test("Removing the same pin twice is harmless and leaves the rest alone")
    func removeIsIdempotent() {
        var focus = order([1, 2, 3])
        focus.remove(2)
        focus.remove(2)
        #expect(focus.ids == [1, 3])
        #expect(focus.frontmost == 3)
    }

    @Test("Touching a pin that is not on the board does not resurrect it")
    func touchingUnknownIsIgnored() {
        // A pin being torn down can still deliver a trailing event; that must not put it back.
        var focus = order([1, 2])
        focus.remove(2)
        focus.touch(2)
        #expect(focus.ids == [1])
        #expect(focus.frontmost == 1)
    }

    @Test("Inserting an id already present moves it forward rather than duplicating it")
    func reinsertMovesForward() {
        var focus = order([1, 2])
        focus.insert(1)
        #expect(focus.ids == [2, 1])
        #expect(focus.count == 2)
    }

    @Test("removeAll empties the order")
    func removeAllClears() {
        var focus = order([1, 2, 3])
        focus.removeAll()
        #expect(focus.isEmpty)
        #expect(focus.frontmost == nil)
    }

    @Test("Create two, interact with the first, then close — the interacted one goes")
    func createTwoInteractThenClose() {
        // The end-to-end sequence a user performs: pin A, pin B, click A, press Escape.
        var focus = order()
        focus.insert(1)          // pin A
        focus.insert(2)          // pin B — now in front
        focus.touch(1)           // the user clicks A
        #expect(focus.frontmost == 1)

        focus.remove(focus.frontmost!)   // Escape
        #expect(focus.frontmost == 2, "and Escape again closes B")
    }
}

@Suite("Clipboard copy notice")
struct ClipboardCopyNoticeTests {

    @Test("A plain sRGB copy confirms the copy and the size")
    func sRGB() {
        let notice = ClipboardCopyNotice.success(
            width: 1440, height: 900, wroteRasterData: true, colorNotice: nil
        )
        #expect(notice.message == "Copied 1440 × 900")
        #expect(!notice.isWarning)
    }

    @Test("A P3 or HDR copy still says it was copied")
    func wideGamutStillConfirms() {
        // The regression: the colour advisory used to *replace* the confirmation, so on a modern
        // P3 display — the common case — the user was never told the screenshot had been copied.
        let notice = ClipboardCopyNotice.success(
            width: 1440, height: 900, wroteRasterData: true,
            colorNotice: "Converted from Display P3 to sRGB."
        )
        #expect(notice.message.contains("Copied"))
        #expect(notice.message.contains("1440 × 900"))
        #expect(notice.message.contains("Display P3"), "the advisory is kept, not dropped")
        #expect(notice.isWarning, "still worth flagging — but as a successful copy")
    }

    @Test("The confirmation comes before the colour advisory")
    func successLeadsTheMessage() {
        let notice = ClipboardCopyNotice.success(
            width: 800, height: 600, wroteRasterData: true, colorNotice: "HDR was tone-mapped."
        )
        #expect(notice.message.hasPrefix("Copied 800 × 600"))
    }

    @Test("An image-only pasteboard is flagged without losing the confirmation")
    func imageOnly() {
        let notice = ClipboardCopyNotice.success(
            width: 640, height: 480, wroteRasterData: false, colorNotice: nil
        )
        #expect(notice.message == "Copied 640 × 480 (image only)")
        #expect(!notice.isWarning)
    }

    @Test("Image-only and a colour advisory together keep all three facts")
    func imageOnlyAndWideGamut() {
        let notice = ClipboardCopyNotice.success(
            width: 640, height: 480, wroteRasterData: false, colorNotice: "Converted to sRGB."
        )
        #expect(notice.message.hasPrefix("Copied 640 × 480 (image only)"))
        #expect(notice.message.contains("Converted to sRGB."))
        #expect(notice.isWarning)
    }

    @Test("Every outcome names the pixel size", arguments: [
        (true, String?.none), (true, .some("note")), (false, String?.none), (false, .some("note")),
    ])
    func alwaysStatesTheSize(raster: Bool, colorNotice: String?) {
        let notice = ClipboardCopyNotice.success(
            width: 123, height: 45, wroteRasterData: raster, colorNotice: colorNotice
        )
        #expect(notice.message.contains("Copied"))
        #expect(notice.message.contains("123 × 45"))
        #expect(!notice.systemImage.isEmpty)
    }

    @Test("An empty colour notice is treated as no notice")
    func emptyColorNotice() {
        let notice = ClipboardCopyNotice.success(
            width: 10, height: 10, wroteRasterData: true, colorNotice: ""
        )
        #expect(notice.message == "Copied 10 × 10")
        #expect(!notice.isWarning)
    }
}

@Suite("Pasteboard image policy")
struct PasteboardImagePolicyTests {

    @Test("PNG is preferred over TIFF when both are offered")
    func prefersPNG() {
        let result = PasteboardImage.preferredType(
            available: [.tiff, .png], canProvideImageObject: true
        )
        #expect(result == .success(.png))
    }

    @Test("TIFF is used when PNG is absent")
    func fallsBackToTIFF() {
        let result = PasteboardImage.preferredType(available: [.tiff], canProvideImageObject: true)
        #expect(result == .success(.tiff))
    }

    @Test("An NSImage-only pasteboard is accepted with no raw type")
    func imageObjectOnly() {
        // A PDF or a file promise: AppKit can rasterise it even though no bitmap type is offered.
        let result = PasteboardImage.preferredType(available: [.pdf], canProvideImageObject: true)
        guard case .success(let type) = result else {
            Issue.record("expected success")
            return
        }
        #expect(type == nil)
    }

    @Test("An empty pasteboard reports empty, not unsupported")
    func emptyPasteboard() {
        let result = PasteboardImage.preferredType(available: [], canProvideImageObject: false)
        #expect(result == .failure(.empty))
    }

    @Test("A text-only pasteboard reports unsupported content")
    func textOnly() {
        // The distinction matters: "the clipboard is empty" and "that is not an image" send the
        // user to different places.
        let result = PasteboardImage.preferredType(available: [.string], canProvideImageObject: false)
        #expect(result == .failure(.unsupportedContent))
    }

    @Test("Both failures explain themselves")
    func failureMessages() {
        #expect(PasteboardImage.ReadFailure.empty.message.contains("empty"))
        #expect(PasteboardImage.ReadFailure.unsupportedContent.message.contains("image"))
    }

    @Test("A round trip through PNG data preserves the pixels")
    func decodeRoundTrip() throws {
        let source = WebPTestImages.solid(width: 32, height: 24, red: 0.2, green: 0.6, blue: 0.9)
        let png = try #require(ImageProcessing.pngData(from: source))
        let decoded = try #require(PasteboardImage.decode(data: png))

        #expect(decoded.width == 32)
        #expect(decoded.height == 24)
        // Normalised into TriCap's canonical space, exactly like a captured image.
        #expect(decoded.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test("Garbage bytes decode to nothing rather than a broken image")
    func decodeGarbage() {
        #expect(PasteboardImage.decode(data: Data(repeating: 0x7F, count: 512)) == nil)
        #expect(PasteboardImage.decode(data: Data()) == nil)
    }

    @Test("A write receipt reports whether raster data made it")
    func writeReceipt() {
        let both = PasteboardImage.WriteReceipt(types: ["public.png", "public.tiff"])
        #expect(both.wroteRasterData)
        let imageOnly = PasteboardImage.WriteReceipt(types: ["public.tiff"])
        #expect(!imageOnly.wroteRasterData)
    }
}
