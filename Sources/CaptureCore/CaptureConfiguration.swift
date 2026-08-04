import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Builds `SCContentFilter` / `SCStreamConfiguration` for a region.
///
/// Isolated from the services so the two capture paths (still and recording) cannot drift apart
/// in how they map a ``CaptureRegion`` onto ScreenCaptureKit, which is exactly where an off-by-a-
/// scale-factor bug would hide.
enum CaptureConfiguration {

    /// Resolve the SCK display matching our region, and build a filter that excludes TriCap's own
    /// windows so the recording HUD and the menu-bar highlight never end up in the output.
    static func filter(
        for region: CaptureRegion,
        content: SCShareableContent,
        includingOwnWindowIDs requestedOwnWindowIDs: Set<CGWindowID> = []
    ) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == region.display.displayID }) else {
            throw TriCapError.noDisplaysAvailable
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        if ownApps.isEmpty {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        let availableOwnWindowIDs = Set(content.windows.compactMap { window -> CGWindowID? in
            guard window.owningApplication?.bundleIdentifier == ownBundleID else { return nil }
            return window.windowID
        })
        let exceptionIDs = validatedOwnWindowExceptionIDs(
            requested: requestedOwnWindowIDs,
            availableOwnWindowIDs: availableOwnWindowIDs
        )
        let exceptingWindows = content.windows.filter { exceptionIDs.contains($0.windowID) }
        return SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: exceptingWindows
        )
    }

    /// Only windows that both belong to TriCap and were named explicitly can bypass the normal
    /// self-exclusion rule. Production callers request none; the recording benchmark requests its
    /// synthetic motion window so the workload is genuinely present in the captured frames.
    static func validatedOwnWindowExceptionIDs(
        requested: Set<CGWindowID>,
        availableOwnWindowIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        requested.intersection(availableOwnWindowIDs)
    }

    /// Shared configuration for both capture paths.
    ///
    /// - `sourceRect` is in **display-local points**, which is why ``CaptureRegion`` recomputes it
    ///   from the pixel-snapped rect instead of passing the raw drag through.
    /// - `width`/`height` are in **capture pixels**. Passing the pixel-snapped size (optionally
    ///   downscaled by the long-edge cap) means SCK does the resampling for us, and no frame is
    ///   ever larger than the ceiling we agreed to hold in memory.
    /// - `colorSpaceName` is deliberately left unset. The public ScreenCaptureKit contract then
    ///   uses the display's native colour space. Its Objective-C property is non-retaining
    ///   (`assign CFStringRef`), so assigning a dynamically bridged Swift `String` would also create
    ///   a dangling-reference risk during asynchronous capture.
    static func streamConfiguration(
        region: CaptureRegion,
        outputPixelSize: CGSize,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRectInDisplayPoints
        config.width = max(1, Int(outputPixelSize.width.rounded()))
        config.height = max(1, Int(outputPixelSize.height.rounded()))
        config.scalesToFit = false
        config.captureResolution = .best
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true
        config.ignoreShadowsDisplay = true
        return config
    }

    /// Recording variant: adds the frame-rate cap and a small queue depth.
    ///
    /// `queueDepth` bounds how many frames SCK will buffer for us — another piece of the
    /// "no unbounded memory" story. 5 is Apple's documented minimum-latency-safe value.
    static func recordingConfiguration(
        region: CaptureRegion,
        outputPixelSize: CGSize,
        limits: RecordingLimits,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let config = streamConfiguration(region: region, outputPixelSize: outputPixelSize, showsCursor: showsCursor)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, limits.frameRate)))
        config.queueDepth = 5
        config.capturesAudio = false
        return config
    }

    /// Output pixel size for a region after applying the long-edge cap.
    static func outputPixelSize(for region: CaptureRegion, maxLongEdge: Int) -> CGSize {
        OutputSizing.fit(pixelSize: region.nativePixelSize, maxLongEdge: maxLongEdge)
    }
}
