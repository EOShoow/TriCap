import Foundation
import os

/// TriCap logs to the unified log only. There is no network code anywhere in this package,
/// no analytics, and no crash reporter — see README "Privacy". `os.Logger` output stays on
/// the machine and is readable with `log stream --predicate 'subsystem == "app.tricap"'`.
public enum TriCapLog {
    public static let subsystem = "app.tricap"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let selection = Logger(subsystem: subsystem, category: "selection")
    public static let annotation = Logger(subsystem: subsystem, category: "annotation")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
