//
//  KeyboardShortcut.swift
//  EjectRemapper
//

import Foundation

/// A keyboard shortcut, stored the only way a shortcut can survive being written to disk and read
/// back on a different keyboard layout: as a *positional* key code plus a modifier mask.
///
/// WHY not store the displayed string ("⌘ C") or a character ("C"):
///
/// - Virtual key codes are positional. Code `0x08` is the key labelled "C" on a US layout and the
///   same physical key — labelled differently — on AZERTY or Dvorak. Storing the code means the
///   shortcut keeps working when the user switches layout, and it is what
///   `CGEvent(keyboardEventSource:virtualKey:keyDown:)` actually needs.
/// - A display string is a *rendering*, produced on demand by `KeyboardShortcutFormatter` from the
///   current layout. Storing it would bake one language and one layout into the user's settings.
///
/// The spec calls for exactly this split: a structured internal representation, a dynamically
/// generated display form. See `docs/TECHNICAL_INVESTIGATION.md` §5.
///
/// Encoded as `{"keyCode": 8, "modifiers": 1048576}` — small, stable, and readable in
/// `defaults read`.
struct KeyboardShortcut: Codable, Hashable, Sendable {

    /// The Carbon virtual key code of the non-modifier key (see ``KeyCodes``).
    var keyCode: UInt16

    /// The modifiers that must be held with it. May be empty: a bare F13 is a legitimate shortcut.
    var modifiers: ModifierFlags

    init(keyCode: UInt16, modifiers: ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

extension KeyboardShortcut {

    /// `true` when the primary key is a modifier key, which can never be a shortcut on its own.
    ///
    /// Used by ``ShortcutValidator``; kept here because it is a property of the value, not of the
    /// validation policy.
    var isModifierOnly: Bool {
        KeyCodes.isModifier(keyCode)
    }

    /// The fn flag that macOS sets automatically for this key, if any.
    ///
    /// macOS reports arrows, Home/End, Page Up/Down, Forward Delete, Help and F1–F20 with the fn
    /// bit already set, whether or not the user touched the fn key (`KeyCodes.functionFlagKeys`).
    /// The recorder strips that bit when capturing so "⌃⌥←" is stored as Control + Option + Left
    /// rather than as Function + Control + Option + Left, and the generator does not need to
    /// re-add it — Core Graphics sets it again on the synthesized event.
    var impliesFunctionFlag: Bool {
        KeyCodes.functionFlagKeys.contains(keyCode)
    }
}
