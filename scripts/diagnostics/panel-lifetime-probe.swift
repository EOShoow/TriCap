// panel-lifetime-probe.swift — how long does AppKit hold a panel that has been on screen?
//
//     swift scripts/diagnostics/panel-lifetime-probe.swift
//
// Why this exists: the runnable self-test used to assert that a `PinWindow` deallocates once the
// pinboard closes it. That assertion failed, and the obvious reading — "TriCap has a retain
// cycle" — is wrong. This probe contains **no TriCap code at all**: a plain `NSPanel`, a plain
// `NSView`, a plain `NSImageView`. It still outlives `close()`, and whether it does depends on
// where the autorelease pool boundary and the run-loop spin fall relative to each other.
//
// So the window shell's lifetime after `close()` is AppKit's business, not something TriCap owns
// or can assert on. What TriCap *can* guarantee is that it releases the pixels itself, which is
// why `PinWindow.tearDown()` nils the image rather than relying on deallocation, and why the
// self-test asserts the bitmap is gone instead of asserting the object is gone.
//
// A pin holds a full-resolution screenshot, so this is the difference between giving back
// megabytes promptly and giving them back whenever AppKit feels like it.

import AppKit

@MainActor
final class Probe: NSPanel {
    let image: CGImage
    private let imageView = NSImageView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false   // ARC owns it, so AppKit must not release it
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        imageView.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        imageView.frame = content.bounds
        content.addSubview(imageView)
        contentView = content
    }
}

func spinRunLoop(seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func makeImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    return context.makeImage()!
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let image = makeImage()
    print("A plain NSPanel — no TriCap code — closed and then checked:\n")

    for shown in [false, true] {
        for spinInsidePool in [true, false] {
            weak var weak: Probe?
            autoreleasepool {
                let panel = Probe(image: image, frame: NSRect(x: 300, y: 300, width: 320, height: 240))
                weak = panel
                if shown { panel.orderFrontRegardless() }
                panel.orderOut(nil)
                panel.contentView = nil
                panel.close()
                if spinInsidePool { spinRunLoop(seconds: 0.2) }
            }
            if !spinInsidePool { autoreleasepool { spinRunLoop(seconds: 0.2) } }
            autoreleasepool {}

            let where_ = spinInsidePool ? "spun inside the pool" : "spun after the pool"
            let was = shown ? "shown   " : "unshown "
            print("  \(was) · \(where_.padding(toLength: 22, withPad: " ", startingAt: 0)) -> "
                  + (weak == nil ? "deallocated" : "STILL ALIVE"))
        }
    }

    print("""

    A window that was never on screen goes away immediately. One that *was* on screen outlives
    close() here no matter where the pool boundary and the run-loop spin fall — and there is no
    TriCap object anywhere in this file. So "the pin window is still alive" is not evidence of a
    retain cycle in TriCap, and PinWindow.tearDown() releases the bitmap explicitly rather than
    waiting for a dealloc that is not ours to schedule.
    """)
}
