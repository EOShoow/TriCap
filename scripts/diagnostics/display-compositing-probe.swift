// display-compositing-probe.swift
//
// Answers one question, using no TriCap code at all: **is the window server actually compositing
// live right now?**
//
// A Mac whose display has slept, or whose session is detached, keeps reporting a capturable
// display through ScreenCaptureKit and keeps listing windows as `isOnScreen = true` — but every
// capture returns the same frozen frame. Under those conditions any screen recording is a single
// frame, no matter how correct the recorder is. This probe distinguishes that environment state
// from a defect in TriCap.
//
// Build and run:
//     swiftc -O scripts/diagnostics/display-compositing-probe.swift -o /tmp/probe
//     caffeinate -dimsu /tmp/probe
//
// Expected on a live display: "all identical: false".
// "all identical: true" means the screen is frozen and screen-capture verification is meaningless
// until the display is genuinely awake.

import AppKit
import ScreenCaptureKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first else {
    print("no NSScreen — nothing to probe")
    exit(1)
}
print("screen frame: \(screen.frame)  scale: \(screen.backingScaleFactor)")

// A window of our own that we will move and recolour between captures.
let marker = NSWindow(
    contentRect: CGRect(x: 120, y: 120, width: 200, height: 200),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
marker.isOpaque = true
marker.hasShadow = false
marker.level = .floating
let markerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
markerView.wantsLayer = true
markerView.layer?.backgroundColor = NSColor.systemPink.cgColor
marker.contentView = markerView
marker.orderFrontRegardless()
marker.displayIfNeeded()

var finished = false

Task { @MainActor in
    defer { finished = true }

    try? await Task.sleep(nanoseconds: 700_000_000)

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        print("SCShareableContent failed: \(error)")
        print("=> Screen Recording permission is missing for this binary.")
        return
    }

    print("displays: \(content.displays.count)  applications: \(content.applications.count)")
    guard let display = content.displays.first else {
        print("=> ScreenCaptureKit reports NO capturable display: the screen is asleep or the")
        print("   session is locked. Wake it (e.g. `caffeinate -u -t 2`) and re-run.")
        return
    }

    let pid = ProcessInfo.processInfo.processIdentifier
    for window in content.windows where window.owningApplication?.processID == pid {
        print("our marker window: frame=\(window.frame) isOnScreen=\(window.isOnScreen) layer=\(window.windowLayer)")
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = display.width / 2
    config.height = display.height / 2
    config.showsCursor = false

    var digests: [Int] = []
    for step in 0..<3 {
        markerView.layer?.backgroundColor = NSColor(
            hue: CGFloat(step) / 3.0, saturation: 1, brightness: 1, alpha: 1
        ).cgColor
        marker.setFrameOrigin(CGPoint(x: 120 + CGFloat(step) * 150, y: 120))
        marker.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 600_000_000)

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let bytes = (image.dataProvider?.data as Data?) ?? Data()
            digests.append(bytes.hashValue)
            print("capture \(step): \(image.width)x\(image.height)")
        } catch {
            print("capture \(step) failed: \(error)")
            return
        }
    }

    let identical = Set(digests).count == 1
    print("all identical: \(identical)")
    if identical {
        print("=> The display is NOT compositing live. Screen-capture verification cannot")
        print("   distinguish a working recorder from a broken one under these conditions.")
    } else {
        print("=> The display is compositing live; screen-capture verification is meaningful.")
    }
}

while !finished {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
