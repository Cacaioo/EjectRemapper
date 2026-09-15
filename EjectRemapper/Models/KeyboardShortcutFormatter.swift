//
//  KeyboardShortcutFormatter.swift
//  EjectRemapper
//

import Carbon.HIToolbox
import Foundation

/// Turns a virtual key code into the glyph printed on that key.
///
/// WHY this is a protocol with two implementations: the *displayed* form of a shortcut depends on
/// the keyboard layout (code `0x0C` is "Q" on QWERTY and "A" on AZERTY), but a test that asserts
/// "⌘ C" must not depend on whatever layout the machine running it happens to use. The live
/// implementation asks macOS; the test implementation answers from a fixed table.
protocol KeyLabelProvider: Sendable {
    /// The glyph for a key, or `nil` if this provider cannot name it.
    func label(forKeyCode keyCode: UInt16) -> String?
}

/// A fixed US QWERTY table.
///
/// Used as the deterministic fixture in tests and as the fallback whenever the live layout cannot
/// answer — which happens for dead keys, for layouts with no ASCII equivalent (Cyrillic, Greek),
/// and during early launch before an input source is available.
struct USQWERTYKeyLabelProvider: KeyLabelProvider {

    init() {}

    private static let labels: [UInt16: String] = [
        KeyCodes.ansiA: "A", KeyCodes.ansiB: "B", KeyCodes.ansiC: "C", KeyCodes.ansiD: "D",
        KeyCodes.ansiE: "E", KeyCodes.ansiF: "F", KeyCodes.ansiG: "G", KeyCodes.ansiH: "H",
        KeyCodes.ansiI: "I", KeyCodes.ansiJ: "J", KeyCodes.ansiK: "K", KeyCodes.ansiL: "L",
        KeyCodes.ansiM: "M", KeyCodes.ansiN: "N", KeyCodes.ansiO: "O", KeyCodes.ansiP: "P",
        KeyCodes.ansiQ: "Q", KeyCodes.ansiR: "R", KeyCodes.ansiS: "S", KeyCodes.ansiT: "T",
        KeyCodes.ansiU: "U", KeyCodes.ansiV: "V", KeyCodes.ansiW: "W", KeyCodes.ansiX: "X",
        KeyCodes.ansiY: "Y", KeyCodes.ansiZ: "Z",
        KeyCodes.ansi0: "0", KeyCodes.ansi1: "1", KeyCodes.ansi2: "2", KeyCodes.ansi3: "3",
        KeyCodes.ansi4: "4", KeyCodes.ansi5: "5", KeyCodes.ansi6: "6", KeyCodes.ansi7: "7",
        KeyCodes.ansi8: "8", KeyCodes.ansi9: "9",
        KeyCodes.ansiMinus: "-", KeyCodes.ansiEqual: "=",
        KeyCodes.ansiLeftBracket: "[", KeyCodes.ansiRightBracket: "]",
        KeyCodes.ansiBackslash: "\\", KeyCodes.ansiSemicolon: ";", KeyCodes.ansiQuote: "'",
        KeyCodes.ansiComma: ",", KeyCodes.ansiPeriod: ".", KeyCodes.ansiSlash: "/",
        KeyCodes.ansiGrave: "`",
        KeyCodes.isoSection: "§", KeyCodes.jisYen: "¥", KeyCodes.jisUnderscore: "_",
        KeyCodes.jisKeypadComma: ",",
    ]

    func label(forKeyCode keyCode: UInt16) -> String? {
        Self.labels[keyCode]
    }
}

/// Asks macOS what is printed on the key, using the user's current keyboard layout.
///
/// Implementation notes:
/// - `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` rather than
///   `TISCopyCurrentKeyboardInputSource`: with a Chinese or Japanese input method active the
///   current source has no layout data at all, while the ASCII-capable one always resolves to the
///   underlying roman layout — which is the layout whose key caps the user is looking at.
/// - `UCKeyTranslate` is called with no modifiers and a dead-key state that is discarded, so "⌥ E"
///   shows as "E" rather than as a combining accent.
/// - Any failure falls through to ``USQWERTYKeyLabelProvider``, so the formatter never has to deal
///   with a missing label for a normal key.
struct CurrentLayoutKeyLabelProvider: KeyLabelProvider {

    private let fallback = USQWERTYKeyLabelProvider()

    init() {}

    func label(forKeyCode keyCode: UInt16) -> String? {
        if let translated = Self.translate(keyCode: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return fallback.label(forKeyCode: keyCode)
    }

    private static func translate(keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)

            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,                                  // no modifiers: we want the bare key cap
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// Renders a ``KeyboardShortcut`` for people: as key-cap symbols for the eye, and as words for
/// VoiceOver.
///
/// The display order is Apple's, not the user's: fn ⌃ ⌥ ⇧ ⌘ (see
/// `ModifierFlags.canonicalOrder`). A shortcut recorded as ⌘⇧4 therefore renders as "⇧ ⌘ 4", which
/// is exactly how System Settings writes it. Matching the system matters more than matching the
/// order the keys were pressed in.
struct KeyboardShortcutFormatter: Sendable {

    private let labels: any KeyLabelProvider
    private let separator: String

    /// - Parameters:
    ///   - labels: where key glyphs come from. Defaults to the live layout; tests inject
    ///     ``USQWERTYKeyLabelProvider`` for determinism.
    ///   - separator: what goes between symbols. A thin space reads better than a normal one in the
    ///     UI, but the default plain space is what the tests assert on.
    init(labels: any KeyLabelProvider = CurrentLayoutKeyLabelProvider(), separator: String = " ") {
        self.labels = labels
        self.separator = separator
    }

    /// The shortcut as an ordered list of symbols, e.g. `["⇧", "⌘", "4"]`.
    ///
    /// Returned as a list rather than a string so the UI can draw each symbol in its own key-cap
    /// box without having to split a string back apart.
    func symbols(for shortcut: KeyboardShortcut) -> [String] {
        shortcut.modifiers.ordered.map(\.symbol) + [keyLabel(for: shortcut.keyCode)]
    }

    /// The shortcut as one string, e.g. `"⇧ ⌘ 4"`.
    func string(for shortcut: KeyboardShortcut) -> String {
        symbols(for: shortcut).joined(separator: separator)
    }

    /// The shortcut in words, e.g. `"Shift Command 4"`.
    ///
    /// This is the accessibility value of every shortcut the app displays. A screen reader cannot
    /// pronounce ⇧ or ⌘, and reading "4" alone would be actively misleading.
    func spokenDescription(for shortcut: KeyboardShortcut) -> String {
        let modifiers = shortcut.modifiers.ordered.map(\.spokenName)
        return (modifiers + [spokenKeyName(for: shortcut.keyCode)]).joined(separator: " ")
    }

    /// The label for the primary key alone.
    ///
    /// Layout-independent keys win over the layout: `UCKeyTranslate` answers `U+000D` for Return
    /// and a private-use character for F1, neither of which can be drawn, so
    /// `KeyCodes.specialKeyLabels` is consulted first.
    func keyLabel(for keyCode: UInt16) -> String {
        if let special = KeyCodes.specialKeyLabels[keyCode] { return special }
        if let label = labels.label(forKeyCode: keyCode) { return label }
        return KeyCodes.fallbackLabel(for: keyCode)
    }

    /// The spoken name for the primary key alone.
    func spokenKeyName(for keyCode: UInt16) -> String {
        if let spoken = KeyCodes.spokenNames[keyCode] { return spoken }
        if let label = labels.label(forKeyCode: keyCode) { return label }
        return KeyCodes.fallbackLabel(for: keyCode)
    }
}
