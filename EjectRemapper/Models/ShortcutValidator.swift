//
//  ShortcutValidator.swift
//  EjectRemapper
//

import Foundation

/// Why a recorded shortcut cannot be saved.
///
/// Each case carries a sentence the user can act on. The spec is explicit that an invalid
/// configuration must never be saved silently, and that the app must explain itself.
enum ShortcutValidationError: Error, Equatable, LocalizedError {

    /// Only modifiers were held — there is no key to send.
    case modifierOnly

    /// A key the app cannot reproduce as a `CGEvent`.
    case unsupportedKey(UInt16)

    /// The user pressed ⏏ while recording. Binding Eject to Eject is the one shortcut that could
    /// feed the remapper its own output.
    case ejectKey

    var errorDescription: String? {
        switch self {
        case .modifierOnly:
            return String(localized: "Add a key to the modifiers — a shortcut needs a key such as C or 4.")
        case .unsupportedKey:
            return String(localized: "This key combination can't be generated reliably by macOS.")
        case .ejectKey:
            return String(localized: "The Eject key can't be its own shortcut.")
        }
    }
}

/// Decides whether a recorded shortcut is usable, and warns about ones that are legal but
/// surprising.
///
/// The split between *errors* and *warnings* is deliberate. An error means the app physically
/// cannot deliver the shortcut, so saving it would produce a key that silently does nothing. A
/// warning means it would work exactly as asked, but the result may not be what the user pictured —
/// that is their call to make, not the app's, so the shortcut is saved and the warning is shown
/// beside it.
enum ShortcutValidator {

    /// `nil` when the shortcut can be saved.
    static func validate(_ shortcut: KeyboardShortcut) -> ShortcutValidationError? {
        if shortcut.isModifierOnly {
            return .modifierOnly
        }
        guard KeyCodes.supportedKeyCodes.contains(shortcut.keyCode) else {
            return .unsupportedKey(shortcut.keyCode)
        }
        return nil
    }

    /// Non-blocking notes about a valid shortcut.
    ///
    /// Deliberately short: the point is to catch the handful of chords whose effect is drastic and
    /// easy to trigger by accident, not to maintain a database of what every app binds. Detecting
    /// application-specific conflicts is explicitly out of scope.
    static func warnings(for shortcut: KeyboardShortcut) -> [String] {
        var notes: [String] = []
        let modifiers = shortcut.modifiers

        // ⌘Q and ⌘⌥⎋ close things. Bound to a key you might brush past, that is a data-loss risk.
        if shortcut.keyCode == KeyCodes.ansiQ, modifiers == [.command] {
            notes.append(String(localized: "⌘Q quits the app you're using."))
        }
        if shortcut.keyCode == KeyCodes.escape, modifiers.contains(.command), modifiers.contains(.option) {
            notes.append(String(localized: "⌥⌘⎋ opens Force Quit."))
        }
        if shortcut.keyCode == KeyCodes.ansiQ, modifiers == [.control, .command] {
            notes.append(String(localized: "⌃⌘Q locks the screen — the Lock Screen action does this directly."))
        }
        if shortcut.keyCode == KeyCodes.delete, modifiers == [.command] {
            notes.append(String(localized: "⌘⌫ moves the selected item to the Trash in the Finder."))
        }

        // Caps Lock is a toggle, not a chord. macOS will not deliver it as part of a shortcut in
        // the way a user expects, so it is worth saying out loud rather than letting them wonder.
        if modifiers.contains(.capsLock) {
            notes.append(String(localized: "Caps Lock isn't reliable as part of a shortcut."))
        }

        // A bare letter or digit with no modifier will type that character into whatever has focus.
        if modifiers.isEmpty, KeyCodes.characterKeyCodes.contains(shortcut.keyCode) {
            notes.append(String(localized: "With no modifier, this just types the character."))
        }

        return notes
    }
}
