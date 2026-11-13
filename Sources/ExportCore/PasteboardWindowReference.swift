import AppKit
import Foundation
import TriCapKit

public enum PasteboardWindowReference {
    public static let referenceType = NSPasteboard.PasteboardType("app.tricap.window-reference")

    /// Copy both readable instructions and machine-readable identity, without saving a screenshot.
    @MainActor
    @discardableResult
    public static func write(
        _ reference: WindowReference,
        to pasteboard: NSPasteboard = .general
    ) throws -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(try reference.prompt(), forType: .string),
              item.setString(try reference.json(), forType: referenceType) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
