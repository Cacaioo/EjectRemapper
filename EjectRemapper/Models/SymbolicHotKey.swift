//
//  SymbolicHotKey.swift
//  EjectRemapper
//

import AppKit
import Foundation

/// One of macOS's own system-wide keyboard shortcuts, as the user has it configured.
///
/// The app reads two of them — the screenshot chords — so that "Screenshot" sends whatever the user
/// actually has bound rather than a hard-coded ⇧⌘3. If they moved the shortcut, the app follows.
struct SymbolicHotKey: Equatable, Sendable {
    /// The entry's numeric identifier in `com.apple.symbolichotkeys`.
    let id: Int
    /// Whether the user has this system shortcut switched on.
    let isEnabled: Bool
    /// The chord itself.
    let shortcut: KeyboardShortcut
}

/// Reads `com.apple.symbolichotkeys` — the preference domain where macOS stores the shortcuts shown
/// in System Settings › Keyboard › Keyboard Shortcuts.
///
/// WHY read a preference domain rather than hard-coding ⇧⌘3:
/// the screenshot actions work by *asking the system to take the screenshot*, which it does by
/// recognising its own chord. Send the wrong chord and nothing happens. Reading the live value means
/// a user who rebound screenshots to ⌃⌥4 still gets a working Eject key.
///
/// Format of an entry, verified live on macOS 26.5 (see `docs/TECHNICAL_INVESTIGATION.md` §7):
///
/// ```
/// 28 = { enabled = 1; value = { parameters = (51, 20, 1179648); type = standard; }; }
///                                            │   │    └── modifier mask, Cocoa bits
///                                            │   └─────── virtual key code (0x14 = "3")
///                                            └─────────── unicode character ('3'), unused here
/// ```
///
/// The mask uses the `NSEvent.ModifierFlags` device-independent bits (shift `1<<17`, control
/// `1<<18`, option `1<<19`, command `1<<20`) — **not** the Carbon `cmdKey`/`shiftKey` bits, which
/// are entirely different numbers. `1179648 = 0x120000` is ⌘ + ⇧.
///
/// This type only ever *reads*. Writing to this domain would change the user's system shortcuts,
/// which the app has no business doing.
enum SymbolicHotKeyReader {

    /// "Save picture of screen as a file" — ⇧⌘3 by default.
    static let saveScreenAsFile = 28

    /// "Copy picture of selected area to the clipboard" — ⇧⌘4 by default. Not used by the app;
    /// present because it is the entry most often confused with 28 and it makes the test fixture
    /// clearer.
    static let saveSelectedAreaAsFile = 30

    /// "Screenshot and recording options" — ⇧⌘5 by default. The fallback for the Screenshot Menu
    /// action, used only if launching Screenshot.app fails.
    static let screenshotAndRecordingOptions = 184

    /// The preference domain. Read-only.
    static let domain = "com.apple.symbolichotkeys"

    /// The key inside that domain.
    static let dictionaryKey = "AppleSymbolicHotKeys"

    /// Apple's factory defaults, used when the domain has no entry for an id — which is the normal
    /// state on a Mac where the user has never changed a screenshot shortcut.
    static let defaultShortcuts: [Int: KeyboardShortcut] = [
        saveScreenAsFile: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.shift, .command]),
        saveSelectedAreaAsFile: KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.shift, .command]),
        screenshotAndRecordingOptions: KeyboardShortcut(keyCode: KeyCodes.ansi5, modifiers: [.shift, .command]),
    ]

    /// Reads one entry, falling back to the factory default.
    ///
    /// A missing entry means "the user has never touched this", so the default applies and the hot
    /// key counts as enabled. An entry that exists but is malformed is treated the same way rather
    /// than failing: the worst case is that the app sends the standard chord, which is what the
    /// user almost certainly has.
    ///
    /// - Parameter defaults: injectable so tests can supply a fixture domain instead of the user's.
    static func hotKey(id: Int, defaults: UserDefaults? = UserDefaults(suiteName: domain)) -> SymbolicHotKey {
        let fallback = defaultShortcuts[id] ?? KeyboardShortcut(keyCode: 0, modifiers: [])

        guard let defaults,
              let all = defaults.dictionary(forKey: dictionaryKey),
              let entry = all[String(id)] as? [String: Any]
        else {
            return SymbolicHotKey(id: id, isEnabled: true, shortcut: fallback)
        }

        let isEnabled = enabledFlag(in: entry)

        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              let shortcut = parse(parameters: parameters.compactMap { ($0 as? NSNumber)?.intValue })
        else {
            return SymbolicHotKey(id: id, isEnabled: isEnabled, shortcut: fallback)
        }

        return SymbolicHotKey(id: id, isEnabled: isEnabled, shortcut: shortcut)
    }

    /// Decodes `[unicodeChar, keyCode, modifierMask]`.
    ///
    /// Returns `nil` for the sentinel macOS writes when a shortcut has been cleared but the entry
    /// kept: `65535` (`0xFFFF`) in either of the first two slots means "no key".
    static func parse(parameters: [Int]) -> KeyboardShortcut? {
        guard parameters.count >= 3 else { return nil }

        let keyCodeValue = parameters[1]
        guard keyCodeValue >= 0, keyCodeValue < 0xFFFF else { return nil }

        let mask = parameters[2]
        guard mask >= 0 else { return nil }

        let modifiers = ModifierFlags(nsEventFlags: NSEvent.ModifierFlags(rawValue: UInt(mask)))
        return KeyboardShortcut(keyCode: UInt16(keyCodeValue), modifiers: modifiers)
    }

    /// `enabled` is written as a boolean by System Settings and as `0`/`1` by `defaults write`, so
    /// both spellings have to be accepted. Absent means enabled.
    private static func enabledFlag(in entry: [String: Any]) -> Bool {
        if let flag = entry["enabled"] as? Bool { return flag }
        if let number = entry["enabled"] as? NSNumber { return number.intValue != 0 }
        return true
    }
}
