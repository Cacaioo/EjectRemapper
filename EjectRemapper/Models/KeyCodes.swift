//
//  KeyCodes.swift
//  EjectRemapper
//
//  Carbon virtual key codes, transcribed from the SDK header.
//

import Foundation

/// The Carbon `kVK_*` virtual key codes the app supports, plus the lookup tables that turn a code
/// into something a person can read or a screen reader can pronounce.
///
/// WHY the numbers are written out instead of importing Carbon's `kVK_*` constants:
///
/// - The constants live in `Carbon.HIToolbox`, which drags a very large, mostly deprecated module
///   into every file that needs a key code — including the pure, fast-to-compile model layer.
/// - Virtual key codes are *positional*, not character-based: `0x00` is the key labelled "A" on a
///   US layout and "Q" on a French one. Writing them here, with the header line numbers, makes the
///   table auditable; the label tables are what map a position to a glyph.
/// - Every value below was transcribed from
///   `$(xcrun --show-sdk-path)/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/Events.h`
///   (`kVK_ANSI_*` at lines 197–261, `kVK_*` at 266–314, `kVK_ISO_Section` at 319,
///   `kVK_JIS_*` at 324–328).
enum KeyCodes {

    // MARK: - Letters (Events.h:197-261)

    static let ansiA: UInt16 = 0x00
    static let ansiB: UInt16 = 0x0B
    static let ansiC: UInt16 = 0x08
    static let ansiD: UInt16 = 0x02
    static let ansiE: UInt16 = 0x0E
    static let ansiF: UInt16 = 0x03
    static let ansiG: UInt16 = 0x05
    static let ansiH: UInt16 = 0x04
    static let ansiI: UInt16 = 0x22
    static let ansiJ: UInt16 = 0x26
    static let ansiK: UInt16 = 0x28
    static let ansiL: UInt16 = 0x25
    static let ansiM: UInt16 = 0x2E
    static let ansiN: UInt16 = 0x2D
    static let ansiO: UInt16 = 0x1F
    static let ansiP: UInt16 = 0x23
    static let ansiQ: UInt16 = 0x0C
    static let ansiR: UInt16 = 0x0F
    static let ansiS: UInt16 = 0x01
    static let ansiT: UInt16 = 0x11
    static let ansiU: UInt16 = 0x20
    static let ansiV: UInt16 = 0x09
    static let ansiW: UInt16 = 0x0D
    static let ansiX: UInt16 = 0x07
    static let ansiY: UInt16 = 0x10
    static let ansiZ: UInt16 = 0x06

    // MARK: - Digits (number row)

    static let ansi0: UInt16 = 0x1D
    static let ansi1: UInt16 = 0x12
    static let ansi2: UInt16 = 0x13
    static let ansi3: UInt16 = 0x14
    static let ansi4: UInt16 = 0x15
    static let ansi5: UInt16 = 0x17
    static let ansi6: UInt16 = 0x16
    static let ansi7: UInt16 = 0x1A
    static let ansi8: UInt16 = 0x1C
    static let ansi9: UInt16 = 0x19

    // MARK: - Punctuation

    static let ansiMinus: UInt16 = 0x1B
    static let ansiEqual: UInt16 = 0x18
    static let ansiLeftBracket: UInt16 = 0x21
    static let ansiRightBracket: UInt16 = 0x1E
    static let ansiBackslash: UInt16 = 0x2A
    static let ansiSemicolon: UInt16 = 0x29
    static let ansiQuote: UInt16 = 0x27
    static let ansiComma: UInt16 = 0x2B
    static let ansiPeriod: UInt16 = 0x2F
    static let ansiSlash: UInt16 = 0x2C
    static let ansiGrave: UInt16 = 0x32
    /// The extra key ISO keyboards have next to the left Shift (`Events.h:319`).
    static let isoSection: UInt16 = 0x0A
    /// JIS-only keys (`Events.h:324-326`). Present so a Japanese keyboard can record them.
    static let jisYen: UInt16 = 0x5D
    static let jisUnderscore: UInt16 = 0x5E
    static let jisKeypadComma: UInt16 = 0x5F

    // MARK: - Editing and navigation (Events.h:266-314)

    /// `kVK_Return`. Named `returnKey` because `return` is a Swift keyword.
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    /// Backspace — Apple calls this "Delete" and labels it ⌫.
    static let delete: UInt16 = 0x33
    static let escape: UInt16 = 0x35
    /// `kVK_ForwardDelete` (`Events.h:305`) — the ⌦ the app synthesises for the Forward Delete
    /// action. A probe confirmed the synthesized event reads back as key code 117 / `U+F728`
    /// (`NSDeleteFunctionKey`) with the fn flag set by Core Graphics
    /// (`docs/TECHNICAL_INVESTIGATION.md` §5).
    static let forwardDelete: UInt16 = 0x75
    static let help: UInt16 = 0x72
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E

    // MARK: - Keypad

    /// `kVK_ANSI_KeypadClear` — the key labelled "clear" on the numeric keypad.
    static let clear: UInt16 = 0x47
    /// Alias of `clear`, under its header name.
    static let keypadClear: UInt16 = 0x47
    static let keypadEnter: UInt16 = 0x4C
    static let keypadDecimal: UInt16 = 0x41
    static let keypadMultiply: UInt16 = 0x43
    static let keypadPlus: UInt16 = 0x45
    static let keypadDivide: UInt16 = 0x4B
    static let keypadMinus: UInt16 = 0x4E
    static let keypadEquals: UInt16 = 0x51
    static let keypad0: UInt16 = 0x52
    static let keypad1: UInt16 = 0x53
    static let keypad2: UInt16 = 0x54
    static let keypad3: UInt16 = 0x55
    static let keypad4: UInt16 = 0x56
    static let keypad5: UInt16 = 0x57
    static let keypad6: UInt16 = 0x58
    static let keypad7: UInt16 = 0x59
    static let keypad8: UInt16 = 0x5B
    static let keypad9: UInt16 = 0x5C

    // MARK: - Function keys
    //
    // Deliberately out of numeric order — the header's own order. F1–F12 are scattered because the
    // codes were assigned as Apple's keyboards grew.

    static let f1: UInt16 = 0x7A
    static let f2: UInt16 = 0x78
    static let f3: UInt16 = 0x63
    static let f4: UInt16 = 0x76
    static let f5: UInt16 = 0x60
    static let f6: UInt16 = 0x61
    static let f7: UInt16 = 0x62
    static let f8: UInt16 = 0x64
    static let f9: UInt16 = 0x65
    static let f10: UInt16 = 0x6D
    static let f11: UInt16 = 0x67
    static let f12: UInt16 = 0x6F
    static let f13: UInt16 = 0x69
    static let f14: UInt16 = 0x6B
    static let f15: UInt16 = 0x71
    static let f16: UInt16 = 0x6A
    static let f17: UInt16 = 0x40
    static let f18: UInt16 = 0x4F
    static let f19: UInt16 = 0x50
    static let f20: UInt16 = 0x5A

    // MARK: - Modifiers (Events.h:271-280)

    static let command: UInt16 = 0x37
    static let rightCommand: UInt16 = 0x36
    static let shift: UInt16 = 0x38
    static let rightShift: UInt16 = 0x3C
    static let option: UInt16 = 0x3A
    static let rightOption: UInt16 = 0x3D
    static let control: UInt16 = 0x3B
    static let rightControl: UInt16 = 0x3E
    static let function: UInt16 = 0x3F
    static let capsLock: UInt16 = 0x39

    // MARK: - Media keys (recognised, never generated)
    //
    // These have virtual key codes but are delivered as `NX_SYSDEFINED` events in practice.
    // Synthesising them as plain key events does nothing, so they are excluded from
    // `supportedKeyCodes`.

    static let volumeUp: UInt16 = 0x48
    static let volumeDown: UInt16 = 0x49
    static let mute: UInt16 = 0x4A

    // MARK: - Sets

    /// Every modifier key code. A modifier can never be a shortcut's *primary* key — it lives in
    /// `ModifierFlags` instead — so the validator rejects these.
    static let modifierKeyCodes: Set<UInt16> = [
        command, rightCommand, shift, rightShift, option, rightOption,
        control, rightControl, function, capsLock,
    ]

    static func isModifier(_ code: UInt16) -> Bool {
        modifierKeyCodes.contains(code)
    }

    /// Keys for which macOS sets the fn flag by itself.
    ///
    /// WHY this matters: press ⌥← and AppKit reports modifiers `[.option, .function, .numericPad]`,
    /// because the arrow keys are "function keys" internally. If the recorder stored the fn bit,
    /// the saved shortcut would be ⌥fn← — a chord the user never pressed, which then renders wrong
    /// and, worse, generates an extra fn `flagsChanged` event on playback. `ShortcutRecorder`
    /// strips `.function` for exactly these codes, and the generator relies on Core Graphics
    /// re-adding the bit on its own.
    static let functionFlagKeys: Set<UInt16> = [
        leftArrow, rightArrow, upArrow, downArrow,
        home, end, pageUp, pageDown,
        forwardDelete, help,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10,
        f11, f12, f13, f14, f15, f16, f17, f18, f19, f20,
    ]

    /// The letters, digits and punctuation that carry a layout-dependent label.
    /// Used by the label providers to decide whether asking the current keyboard layout makes sense.
    static let characterKeyCodes: Set<UInt16> = [
        ansiA, ansiB, ansiC, ansiD, ansiE, ansiF, ansiG, ansiH, ansiI, ansiJ, ansiK, ansiL, ansiM,
        ansiN, ansiO, ansiP, ansiQ, ansiR, ansiS, ansiT, ansiU, ansiV, ansiW, ansiX, ansiY, ansiZ,
        ansi0, ansi1, ansi2, ansi3, ansi4, ansi5, ansi6, ansi7, ansi8, ansi9,
        ansiMinus, ansiEqual, ansiLeftBracket, ansiRightBracket, ansiBackslash,
        ansiSemicolon, ansiQuote, ansiComma, ansiPeriod, ansiSlash, ansiGrave,
        isoSection, jisYen, jisUnderscore, jisKeypadComma,
    ]

    /// Non-character keys that always render as a fixed symbol or word, whatever the layout.
    static let navigationAndEditingKeyCodes: Set<UInt16> = [
        returnKey, tab, space, delete, escape, forwardDelete, help, clear,
        home, end, pageUp, pageDown, leftArrow, rightArrow, upArrow, downArrow,
    ]

    static let keypadKeyCodes: Set<UInt16> = [
        keypad0, keypad1, keypad2, keypad3, keypad4, keypad5, keypad6, keypad7, keypad8, keypad9,
        keypadDecimal, keypadMultiply, keypadPlus, keypadDivide, keypadMinus, keypadEquals,
        keypadEnter, keypadClear,
    ]

    static let functionKeyCodes: Set<UInt16> = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10,
        f11, f12, f13, f14, f15, f16, f17, f18, f19, f20,
    ]

    /// Every key code `KeyboardEventGenerator` can reproduce as a real key press.
    ///
    /// Excluded on purpose:
    /// - **Modifiers** — they are flags, not primary keys.
    /// - **Volume/Mute (`0x48`–`0x4A`)** — the hardware delivers them as `NX_SYSDEFINED` media
    ///   events; posting them as key events is silently ignored.
    /// - **`kVK_JIS_Eisu` (`0x66`) and `kVK_JIS_Kana` (`0x68`)** — input-method switches handled
    ///   by the text input system, not by key posting.
    /// - **`kVK_ContextualMenu` (`0x6E`)** — absent from Apple keyboards and has no stable label.
    /// - **Undefined codes** (`0x34`, `0x42`, `0x44`, `0x46`, `0x4D`, `0x6C`, `0x70`, and
    ///   everything above `0x7E`).
    ///
    /// `ShortcutValidator` turns anything outside this set into `.unsupportedKey`, so the user is
    /// told at recording time rather than silently getting a shortcut that never fires.
    static let supportedKeyCodes: Set<UInt16> =
        characterKeyCodes
        .union(navigationAndEditingKeyCodes)
        .union(keypadKeyCodes)
        .union(functionKeyCodes)

    // MARK: - Labels
    //
    // Not localised: these are Apple's own key-cap glyphs and the short English words System
    // Settings uses. They are also the fixture the formatter tests assert against, so they must be
    // identical in every locale.

    /// Key-cap labels for keys whose glyph does not depend on the keyboard layout.
    ///
    /// Takes precedence over layout translation in `KeyboardShortcutFormatter`: asking
    /// `UCKeyTranslate` for `0x24` yields `U+000D`, and for `0x7A` a private-use character —
    /// neither of which can be drawn.
    static let specialKeyLabels: [UInt16: String] = {
        var labels: [UInt16: String] = [
            returnKey: "↩",
            tab: "⇥",
            space: "Space",
            delete: "⌫",
            escape: "⎋",
            forwardDelete: "⌦",
            leftArrow: "←",
            rightArrow: "→",
            upArrow: "↑",
            downArrow: "↓",
            home: "↖",
            end: "↘",
            pageUp: "⇞",
            pageDown: "⇟",
            help: "Help",
            clear: "Clear",
            keypadEnter: "Keypad Enter",
            keypadDecimal: "Keypad .",
            keypadMultiply: "Keypad *",
            keypadPlus: "Keypad +",
            keypadDivide: "Keypad /",
            keypadMinus: "Keypad -",
            keypadEquals: "Keypad =",
        ]
        for (index, code) in keypadDigitCodes.enumerated() {
            labels[code] = "Keypad \(index)"
        }
        for (index, code) in functionKeyCodesInOrder.enumerated() {
            labels[code] = "F\(index + 1)"
        }
        return labels
    }()

    /// Names VoiceOver can pronounce, for the keys whose label is a symbol.
    ///
    /// WHY: "⌘ ⇧ 4" read aloud is meaningless. `KeyboardShortcutFormatter.spokenDescription(for:)`
    /// uses this table for the accessibility value of every shortcut shown in the UI.
    static let spokenNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            returnKey: "Return",
            tab: "Tab",
            space: "Space",
            delete: "Delete",
            escape: "Escape",
            forwardDelete: "Forward Delete",
            leftArrow: "Left Arrow",
            rightArrow: "Right Arrow",
            upArrow: "Up Arrow",
            downArrow: "Down Arrow",
            home: "Home",
            end: "End",
            pageUp: "Page Up",
            pageDown: "Page Down",
            help: "Help",
            clear: "Clear",
            keypadEnter: "Keypad Enter",
            keypadDecimal: "Keypad Decimal",
            keypadMultiply: "Keypad Multiply",
            keypadPlus: "Keypad Plus",
            keypadDivide: "Keypad Divide",
            keypadMinus: "Keypad Minus",
            keypadEquals: "Keypad Equals",
            ansiMinus: "Minus",
            ansiEqual: "Equals",
            ansiLeftBracket: "Left Bracket",
            ansiRightBracket: "Right Bracket",
            ansiBackslash: "Backslash",
            ansiSemicolon: "Semicolon",
            ansiQuote: "Quote",
            ansiComma: "Comma",
            ansiPeriod: "Period",
            ansiSlash: "Slash",
            ansiGrave: "Grave Accent",
            isoSection: "Section",
            jisYen: "Yen",
            jisUnderscore: "Underscore",
            jisKeypadComma: "Keypad Comma",
        ]
        for (index, code) in keypadDigitCodes.enumerated() {
            names[code] = "Keypad \(index)"
        }
        for (index, code) in functionKeyCodesInOrder.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    /// Keypad digits 0…9 in numeric order (note `0x5A` is F20, not Keypad 8 — hence the explicit
    /// list rather than a range).
    private static let keypadDigitCodes: [UInt16] = [
        keypad0, keypad1, keypad2, keypad3, keypad4,
        keypad5, keypad6, keypad7, keypad8, keypad9,
    ]

    /// F1…F20 in numeric order.
    private static let functionKeyCodesInOrder: [UInt16] = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10,
        f11, f12, f13, f14, f15, f16, f17, f18, f19, f20,
    ]

    /// The placeholder shown for a key code the app has no label for, e.g. "Key 0x6E".
    /// Keeping the raw code visible makes bug reports actionable.
    static func fallbackLabel(for keyCode: UInt16) -> String {
        String(format: "Key 0x%02X", keyCode)
    }
}
