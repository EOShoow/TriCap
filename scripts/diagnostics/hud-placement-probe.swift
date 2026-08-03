// hud-placement-probe.swift — where does the recording HUD actually land?
//
//     swift scripts/diagnostics/hud-placement-probe.swift
//
// Reproduces `RecordingHUD.makeFloatingWindow(size:belowTopOf:)` as it stood at commit 79d20b3,
// in pure geometry with no window server, and runs it against the selection shapes a user
// actually produces. The point is to have the failure written down as coordinates before any
// code moves: a HUD placed off-screen is invisible, and an invisible Stop button cannot be
// clicked, so a recording can only be ended by waiting out the duration limit.
//
// Reads real `NSScreen` geometry when it can, and falls back to synthetic displays so the
// numbers are reproducible on any machine.

import AppKit

// MARK: - The algorithm under test, transcribed verbatim

/// `RecordingHUD.makeFloatingWindow(size:belowTopOf:)` at 79d20b3.
func legacyPlacement(size: CGSize, region: CGRect, displayBounds: CGRect) -> CGRect {
    var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
    if origin.y < displayBounds.minY + 8 {
        origin.y = region.maxY + 12
    }
    origin.x = min(
        max(displayBounds.minX + 8, origin.x),
        displayBounds.maxX - size.width - 8
    )
    return CGRect(origin: origin, size: size)
}

/// `RecordingHUD.makeFloatingWindow(size:centeredOn:)` at 79d20b3 — no clamping at all.
func legacyCentred(size: CGSize, region: CGRect) -> CGRect {
    CGRect(
        origin: CGPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2),
        size: size
    )
}

// MARK: - Scenarios

struct Display {
    let name: String
    let bounds: CGRect
    /// What `NSScreen.visibleFrame` excludes: menu bar at the top, Dock at the bottom.
    let visible: CGRect
}

struct Scenario {
    let name: String
    let display: Display
    let region: CGRect
}

let hudSize = CGSize(width: 300, height: 74)
let countdownSize = CGSize(width: 180, height: 176)

func syntheticDisplays() -> [Display] {
    let main = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let secondary = CGRect(x: -1280, y: 156, width: 1280, height: 800)
    return [
        Display(name: "main 1470×956",
                bounds: main,
                visible: CGRect(x: 0, y: 74, width: 1470, height: 956 - 74 - 38)),
        Display(name: "secondary at negative x",
                bounds: secondary,
                visible: CGRect(x: -1280, y: 156, width: 1280, height: 800 - 38)),
        Display(name: "small 1280×720",
                bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
                visible: CGRect(x: 0, y: 38, width: 1280, height: 720 - 38 - 25)),
    ]
}

func liveDisplays() -> [Display] {
    NSScreen.screens.enumerated().map { index, screen in
        Display(
            name: "live screen \(index + 1) \(Int(screen.frame.width))×\(Int(screen.frame.height))",
            bounds: screen.frame,
            visible: screen.visibleFrame
        )
    }
}

func scenarios(for displays: [Display]) -> [Scenario] {
    displays.flatMap { display -> [Scenario] in
        let b = display.bounds
        return [
            Scenario(name: "full screen", display: display, region: b),
            Scenario(name: "95% of display height",
                     display: display,
                     region: CGRect(x: b.minX + 20, y: b.minY + b.height * 0.025,
                                    width: b.width - 40, height: b.height * 0.95)),
            Scenario(name: "90% height, flush to bottom",
                     display: display,
                     region: CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height * 0.90)),
            Scenario(name: "90% height, flush to top",
                     display: display,
                     region: CGRect(x: b.minX, y: b.maxY - b.height * 0.90,
                                    width: b.width, height: b.height * 0.90)),
            Scenario(name: "small region, middle",
                     display: display,
                     region: CGRect(x: b.midX - 200, y: b.midY - 150, width: 400, height: 300)),
            Scenario(name: "small region, top-left corner",
                     display: display,
                     region: CGRect(x: b.minX + 4, y: b.maxY - 204, width: 300, height: 200)),
        ]
    }
}

// MARK: - Report

func run(_ title: String, displays: [Display]) {
    print("\n\(title)")
    print(String(repeating: "=", count: title.count))

    var hudFailures = 0
    var countdownFailures = 0
    var total = 0

    for scenario in scenarios(for: displays) {
        total += 1
        let visible = scenario.display.visible
        let hud = legacyPlacement(size: hudSize, region: scenario.region,
                                  displayBounds: scenario.display.bounds)
        let countdown = legacyCentred(size: countdownSize, region: scenario.region)

        let hudOK = visible.contains(hud)
        let countdownOK = visible.contains(countdown)
        if !hudOK { hudFailures += 1 }
        if !countdownOK { countdownFailures += 1 }

        guard !hudOK || !countdownOK else { continue }

        print("\n  \(scenario.display.name) · \(scenario.name)")
        print("    visibleFrame  \(fmt(visible))")
        print("    region        \(fmt(scenario.region))")
        if !hudOK {
            print("    HUD           \(fmt(hud))   ✗ \(reason(hud, in: visible))")
        }
        if !countdownOK {
            print("    countdown     \(fmt(countdown))   ✗ \(reason(countdown, in: visible))")
        }
    }

    print("\n  \(hudFailures)/\(total) HUD placements land outside the visible frame")
    print("  \(countdownFailures)/\(total) countdown placements land outside the visible frame")
}

func fmt(_ r: CGRect) -> String {
    String(format: "(%.0f, %.0f  %.0f×%.0f)", r.minX, r.minY, r.width, r.height)
}

func reason(_ rect: CGRect, in visible: CGRect) -> String {
    var parts: [String] = []
    if rect.minY < visible.minY { parts.append(String(format: "%.0f pt below the bottom", visible.minY - rect.minY)) }
    if rect.maxY > visible.maxY { parts.append(String(format: "%.0f pt above the top", rect.maxY - visible.maxY)) }
    if rect.minX < visible.minX { parts.append(String(format: "%.0f pt off the left", visible.minX - rect.minX)) }
    if rect.maxX > visible.maxX { parts.append(String(format: "%.0f pt off the right", rect.maxX - visible.maxX)) }
    return parts.isEmpty ? "outside" : parts.joined(separator: ", ")
}

run("Synthetic displays (reproducible anywhere)", displays: syntheticDisplays())
let live = liveDisplays()
if !live.isEmpty {
    run("This machine's real displays", displays: live)
}

print("""

Reading this: the fallback branch moves the HUD *above* the region without checking whether it
fits, and no branch ever constrains y to the visible frame. The x clamp also uses the full display
bounds rather than the visible frame, so a HUD can sit under the Dock. A near-full-screen
selection has room neither below nor above, which is exactly when the Stop button is needed and
exactly when it is not on screen.
""")
