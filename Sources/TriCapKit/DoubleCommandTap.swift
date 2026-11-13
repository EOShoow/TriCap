import Foundation

/// Recognises Command-Command: two quick taps of ⌘ with nothing else pressed, or both ⌘ keys
/// held together. It is the gesture Codex's Appshots uses to attach the front window.
///
/// A pure state machine: the app feeds it modifier changes and key presses from a listen-only
/// event tap, tests feed it timestamps. Any other key or modifier breaks the sequence, so a quick
/// ⌘C followed by ⌘V never counts.
public struct DoubleCommandTap: Sendable {
    /// Longest a tap may hold ⌘ down; anything longer is a held modifier, not a tap.
    public static let maximumHold: TimeInterval = 0.35
    /// Longest gap between releasing the first tap and pressing the second.
    public static let maximumGap: TimeInterval = 0.4

    private var pressedAt: TimeInterval?
    private var firstTapEndedAt: TimeInterval?
    /// After a both-⌘ chord fires, ignore everything until ⌘ is fully released.
    private var chordFired = false

    public init() {}

    /// Feed every modifier change.
    /// - Parameters:
    ///   - command: ⌘ is held.
    ///   - bothCommands: the left and the right ⌘ are both held.
    ///   - others: ⇧, ⌥, ⌃ or fn is held. Caps Lock is a state, not a press, and does not count.
    /// - Returns: `true` exactly once per recognised gesture.
    public mutating func modifiersChanged(
        command: Bool, bothCommands: Bool, others: Bool, at time: TimeInterval
    ) -> Bool {
        if others {
            reset()
            return false
        }
        if chordFired {
            if !command { chordFired = false }
            return false
        }
        if bothCommands {
            reset()
            chordFired = true
            return true
        }
        if command {
            if let end = firstTapEndedAt, time - end > Self.maximumGap { firstTapEndedAt = nil }
            pressedAt = time
            return false
        }
        // Everything is released: was that a tap?
        guard let start = pressedAt, time - start <= Self.maximumHold else {
            reset()
            return false
        }
        pressedAt = nil
        if firstTapEndedAt != nil {
            firstTapEndedAt = nil
            return true
        }
        firstTapEndedAt = time
        return false
    }

    /// Any ordinary key press cancels a sequence in progress.
    public mutating func keyPressed() {
        reset()
    }

    private mutating func reset() {
        pressedAt = nil
        firstTapEndedAt = nil
    }
}
