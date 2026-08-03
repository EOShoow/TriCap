import Foundation

extension KeyedDecodingContainer {
    /// Decode a `RawRepresentable` value, treating an unrecognised raw value as absent.
    ///
    /// `decodeIfPresent` returns `nil` only when the key is missing; when the key is present but
    /// holds a raw value the enum no longer has, it *throws*. Settings are decoded with `try?`, so
    /// that one unknown string would silently discard every other setting the user had — a save
    /// folder, a vault root, a hot key — because a case was renamed or written by a newer build.
    func decodeTolerantly<T>(_ type: T.Type, forKey key: Key) -> T?
    where T: RawRepresentable & Decodable, T.RawValue: Decodable {
        guard contains(key) else { return nil }
        if let value = try? decodeIfPresent(type, forKey: key) { return value }
        return nil
    }
}
