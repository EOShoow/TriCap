import CoreGraphics
import Foundation
import ScreenCaptureKit
import TriCapKit

/// Single-frame region capture via `SCScreenshotManager` (macOS 14+).
public enum StillCaptureService {

    /// Capture `region` at its native pixel size.
    ///
    /// Stills are *not* subject to the animated-WebP long-edge cap — a screenshot should keep
    /// full Retina detail. The cap only exists to bound recording memory.
    public static func capture(region: CaptureRegion, showsCursor: Bool = false) async throws -> CapturedStill {
        let content = try await ScreenRecordingPermission.shareableContent()
        let filter = try CaptureConfiguration.filter(for: region, content: content)
        let config = CaptureConfiguration.streamConfiguration(
            region: region,
            outputPixelSize: region.nativePixelSize,
            showsCursor: showsCursor
        )

        let raw: CGImage
        do {
            raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw TriCapError.captureFailed((error as NSError).localizedDescription)
        }

        guard let normalized = ImageProcessing.normalizedToSRGB(
            raw,
            fallbackSourceColorSpace: region.display.displayColorSpace,
            sourceDisplayIsWideGamutOrHDR: region.display.needsColorConversionNotice
        ) else {
            throw TriCapError.captureFailed("Could not render the capture into sRGB.")
        }

        TriCapLog.capture.info(
            "still captured \(normalized.image.width, privacy: .public)x\(normalized.image.height, privacy: .public) source=\(normalized.outcome.sourceName, privacy: .public) converted=\(normalized.outcome.converted, privacy: .public)"
        )

        return CapturedStill(image: normalized.image, region: region, colorSpace: normalized.outcome)
    }
}
