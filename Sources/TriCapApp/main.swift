import AppKit

// TriCap is an accessory (menu-bar) app: no Dock icon, no main window, no storyboard.
// `main.swift` is the SwiftPM executable's entry point, so the NSApplication bootstrap is
// written out by hand rather than generated from an @main attribute.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// `--render-ui-snapshots <dir>` draws the real views offscreen and exits. See UISnapshotRenderer.
if UISnapshotRenderer.runIfRequested(arguments: CommandLine.arguments) {
    exit(0)
}

// `--benchmark-export <dir>` measures animation export latency with and without live
// pre-encoding, and exits. See ExportBenchmark.
if ExportBenchmark.runIfRequested(arguments: CommandLine.arguments) {
    application.run()
}

// `--benchmark-recording <dir>` records the real screen through the full production path and
// reports the metrics the release-plan gates are defined against. See RecordingBenchmark.
if RecordingBenchmark.runIfRequested(arguments: CommandLine.arguments) {
    application.run()
}

// `--selftest <dir>` drives the whole capture→annotate→export pipeline and exits non-zero on
// any failed check. See CaptureSelfTest.
_ = CaptureSelfTest.runIfRequested(arguments: CommandLine.arguments)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
