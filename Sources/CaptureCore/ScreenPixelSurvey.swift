import CoreGraphics
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Snapshots what is on each display, once, and turns it into the rectangles
/// ``VisualRegionDetector`` can find in it.
///
/// **Why it happens before the overlay.** The selection overlay is a dimming layer covering every
/// screen, and the recording HUD and mode banner sit on top of it. Sampling the screen afterwards
/// would detect TriCap's own chrome — the dimmed rectangle, the banner, the highlight box — and
/// offer them back to the user as things to capture. So the pixels are taken while the screen
/// still shows only the user's content, and the capture filter excludes TriCap's own windows on
/// top of that, the same way every other capture path in this app does.
///
/// **Why detection does not happen there too.** Reading two displays costs a ScreenCaptureKit
/// round trip each and detection costs tens of milliseconds more; spending all of it before the
/// overlay appears would put a visible stall between the hot key and the crosshair. So this type
/// splits in half: ``currentFields(displays:)`` is awaited before the overlay (it must be), and
/// ``detectedRegions(in:)`` runs off the main actor while the overlay is already up and usable.
/// Window highlighting works from the first frame; visual regions light up a moment later.
public enum ScreenPixelSurvey {

    /// One display's pixels, ready to detect in.
    public struct DisplayField: Sendable {
        public let display: DisplayGeometry
        public let field: PixelField

        public init(display: DisplayGeometry, field: PixelField) {
            self.display = display
            self.field = field
        }
    }

    /// Ceiling on the sampled long edge.
    ///
    /// Only very large non-Retina panels reach it. Past this the field is sampled more coarsely
    /// than one sample per point and boundary accuracy degrades proportionally — worth saying out
    /// loud, because everywhere else in this file one sample is at most two source pixels.
    public static let maxFieldLongEdge = 2600

    /// Every visual edge is sampled across its colour transition, which can include a one-to-three
    /// pixel outline or anti-aliased rim. Keep that transition outside the click/drag capture.
    /// This is deliberately in source pixels, so the visual protection is the same on 1× and
    /// Retina displays.
    public static let visualRegionCaptureInsetPixels: CGFloat = 3

    /// The size to sample one display at.
    ///
    /// The display's **point** grid, not its pixel grid. On a Retina display that is half the
    /// pixels in each axis — one sample per point, two source pixels — and on a 1× display it is
    /// the pixel grid exactly. Both satisfy the accuracy this feature promises: a detected
    /// boundary is within two source pixels of the real one, which is what
    /// `downscaleErrorBound` in the tests measures. Sampling the full pixel grid would double the
    /// work for accuracy finer than the point the user is pointing with.
    public static func fieldSize(for display: DisplayGeometry) -> CGSize {
        let points = display.quartzBounds.size
        let width = max(1, points.width.rounded())
        let height = max(1, points.height.rounded())
        return OutputSizing.fit(
            pixelSize: CGSize(width: width, height: height), maxLongEdge: maxFieldLongEdge
        )
    }

    /// Read every display, once. Must be awaited *before* the selection overlay is shown.
    ///
    /// Returns whatever succeeded. A display that cannot be read contributes nothing and the
    /// others still work — the same degradation as the window list, and for the same reason:
    /// losing an enhancement must never cost the user their capture.
    public static func currentFields(displays: [DisplayGeometry]) async -> [DisplayField] {
        guard !displays.isEmpty else { return [] }

        let content: SCShareableContent
        do {
            content = try await ScreenRecordingPermission.shareableContent()
        } catch {
            TriCapLog.selection.error(
                "screen pixels unavailable: \(error.localizedDescription, privacy: .public) — window selection only"
            )
            return []
        }

        var fields: [DisplayField] = []
        for display in displays {
            guard let field = await field(of: display, content: content) else { continue }
            fields.append(DisplayField(display: display, field: field))
        }
        return fields
    }

    private static func field(of display: DisplayGeometry, content: SCShareableContent) async -> PixelField? {
        // A whole-display region, built by the same type every other capture goes through, so the
        // sampled rectangle cannot drift from what a capture of this display would actually be.
        guard let whole = CaptureRegion(appKitGlobalRect: display.appKitBounds, display: display) else {
            return nil
        }

        let size = fieldSize(for: display)
        do {
            let filter = try CaptureConfiguration.filter(for: whole, content: content)
            let config = CaptureConfiguration.streamConfiguration(
                region: whole, outputPixelSize: size, showsCursor: false
            )
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            guard let rgbx = ImageProcessing.rgbxBytes(image) else { return nil }
            return PixelField(width: rgbx.width, height: rgbx.height, bytes: rgbx.bytes)
        } catch {
            TriCapLog.selection.error(
                "display \(display.displayID, privacy: .public) pixels unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Run detection over already-captured fields. Pure CPU work — no window server, no SCK.
    public static func detectedRegions(
        in fields: [DisplayField],
        options: VisualRegionDetector.Options = .default
    ) -> [VisualRegionCandidate] {
        var candidates: [VisualRegionCandidate] = []
        for entry in fields {
            let found = VisualRegionDetector.detect(in: entry.field, options: options)
            candidates += VisualRegionMapping.candidates(
                from: found,
                fieldSize: entry.field.size,
                display: entry.display,
                startingID: candidates.count,
                captureInsetInPixels: visualRegionCaptureInsetPixels
            )
        }
        return candidates
    }

    /// Detection, off the main actor.
    ///
    /// The overlay is already on screen and taking mouse events by the time this is called, so the
    /// work must not happen on the main actor at any point — a stalled overlay is worse than no
    /// visual regions at all.
    public static func detectedRegions(
        in fields: [DisplayField],
        options: VisualRegionDetector.Options = .default,
        priority: TaskPriority = .userInitiated
    ) async -> [VisualRegionCandidate] {
        guard !fields.isEmpty else { return [] }
        return await Task.detached(priority: priority) {
            let started = DispatchTime.now().uptimeNanoseconds
            let candidates = detectedRegions(in: fields, options: options)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            TriCapLog.selection.info(
                "visual regions: \(candidates.count, privacy: .public) across \(fields.count, privacy: .public) display(s) in \(milliseconds, privacy: .public) ms"
            )
            return candidates
        }.value
    }
}
