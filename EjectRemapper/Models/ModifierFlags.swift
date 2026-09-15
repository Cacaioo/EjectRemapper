//
//  ModifierFlags.swift
//  EjectRemapper
//
//  The one modifier representation used by every layer of the app.
//

import AppKit
import CoreGraphics

/// The keyboard modifiers the app understands, in the *shared* raw representation used by both
/// Core Graphics and AppKit.
///
/// WHY a dedicated type instead of using `CGEventFlags` or `NSEvent.ModifierFlags` directly:
///
/// 1. **Two frameworks, one number.** `CGEventFlags` and `NSEvent.ModifierFlags` use identical raw
///    values for the modifier bits (verified numerically for all six bits — see
///    `docs/TECHNICAL_INVESTIGATION.md` §5 "Modifier mapping"; header evidence
///    `CGEventTypes.h:84-98`, `IOLLEvent.h:241-248`, `NSEvent.h:168-178`). The event tap speaks
///    CoreGraphics, the recorder and the UI speak AppKit, and the persisted settings speak JSON.
///    A single `OptionSet` lets the same value cross all three boundaries losslessly.
///
/// 2. **Hardware events carry junk in the low bits.** Real key events set device-dependent bits
///    (left/right discrimination `0x1`…`0x2000`) and `NX_NONCOALSESCEDMASK` (`0x100`). Comparing
///    raw flags without masking makes "⇧⌘" from the left-hand keys unequal to "⇧⌘" from the
///    right-hand keys. Both initialisers below therefore mask down to the six known bits —
///    a stricter form of `NSEvent.ModifierFlags.deviceIndependentFlagsMask` (`0xFFFF0000`), which
///    would still let `.numericPad` and `.help` through. See CONTRACT_CORRECTIONS §5.
///
/// 3. **`Sendable` and `Codable`.** Neither framework type is both; the snapshot the event tap reads
///    on its own thread and the shortcut written to `UserDefaults` need both.
struct ModifierFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: - Members
    //
    // Raw values are `CGEventFlags` / `NSEvent.ModifierFlags` raw values. They are spelled as
    // literals rather than as `CGEventFlags.maskShift.rawValue` so that the numbers this whole
    // subsystem depends on are visible and unit-testable in one place.

    /// ⇪ Caps Lock — `CGEventFlags.maskAlphaShift` / `NSEvent.ModifierFlags.capsLock`.
    static let capsLock = ModifierFlags(rawValue: 0x1_0000)
    /// ⇧ Shift — `CGEventFlags.maskShift` / `NSEvent.ModifierFlags.shift`.
    static let shift = ModifierFlags(rawValue: 0x2_0000)
    /// ⌃ Control — `CGEventFlags.maskControl` / `NSEvent.ModifierFlags.control`.
    static let control = ModifierFlags(rawValue: 0x4_0000)
    /// ⌥ Option — `CGEventFlags.maskAlternate` / `NSEvent.ModifierFlags.option`.
    static let option = ModifierFlags(rawValue: 0x8_0000)
    /// ⌘ Command — `CGEventFlags.maskCommand` / `NSEvent.ModifierFlags.command`.
    static let command = ModifierFlags(rawValue: 0x10_0000)
    /// fn — `CGEventFlags.maskSecondaryFn` / `NSEvent.ModifierFlags.function`.
    ///
    /// macOS sets this bit automatically for the keys in `KeyCodes.functionFlagKeys`, so it is
    /// usually *observed* rather than *requested*.
    static let function = ModifierFlags(rawValue: 0x80_0000)

    /// Every modifier the app recognises. Used as the mask for incoming hardware flags.
    static let all: ModifierFlags = [.capsLock, .shift, .control, .option, .command, .function]

    /// Modifiers that give ⏏ a system-wide meaning macOS handles itself
    /// (⌘⌥⏏ sleep, ⌃⇧⏏ display sleep, ⌃⌘⏏ restart, ⌃⌥⌘⏏ shut down).
    ///
    /// WHY: the app must never swallow these — a remapped Eject key that breaks "restart" would be
    /// a serious regression. `KeyboardEventManager` passes the event through whenever the physical
    /// modifiers intersect this set.
    static let systemComboModifiers: ModifierFlags = [.command, .control, .option]

    /// Every modifier that makes the app leave an Eject press to macOS: ``systemComboModifiers``
    /// plus ⇧, which ⌃⇧⏏ (display sleep) needs.
    ///
    /// Defined once because two layers rely on the same set. `KeyboardEventManager` passes these
    /// presses through, and `KeyboardEventGenerator` depends on that: when an action runs, none of
    /// these can be physically held.
    static let passThroughModifiers: ModifierFlags = systemComboModifiers.union(.shift)

    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`, spelled out for documentation purposes.
    /// `all` is a strict subset of this and is what the initialisers actually apply.
    static let deviceIndependentMask: UInt64 = 0xFFFF_0000

    // MARK: - Framework bridging

    /// Builds a value from Core Graphics flags, discarding every bit the app does not model.
    ///
    /// The mask is essential: a `CGEvent` straight off the HID stream carries left/right
    /// discrimination bits and `NX_NONCOALSESCEDMASK`, which would otherwise leak into stored
    /// shortcuts and into equality comparisons.
    init(cgEventFlags: CGEventFlags) {
        self.init(rawValue: cgEventFlags.rawValue & ModifierFlags.all.rawValue)
    }

    /// Builds a value from AppKit flags (the shortcut recorder and the symbolic hot key
    /// preferences both hand over `NSEvent.ModifierFlags` bits), masked the same way.
    init(nsEventFlags: NSEvent.ModifierFlags) {
        self.init(rawValue: UInt64(nsEventFlags.rawValue) & ModifierFlags.all.rawValue)
    }

    /// The same bits as `CGEventFlags`, for event generation.
    var cgEventFlags: CGEventFlags {
        CGEventFlags(rawValue: rawValue)
    }

    /// The same bits as `NSEvent.ModifierFlags`, for AppKit comparisons and accessibility.
    var nsEventFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(rawValue))
    }

    // MARK: - Ordering

    /// Canonical macOS order: fn ⌃ ⌥ ⇧ ⌘, with ⇪ last.
    ///
    /// WHY this order and not the order the user pressed the keys: Apple's Human Interface
    /// Guidelines fix the display order of modifier symbols, and System Settings › Keyboard
    /// Shortcuts renders ⌘⇧4 as "⇧⌘4". Using the same order everywhere means a recorded shortcut
    /// looks identical to the same shortcut shown by the system. It is also the order in which
    /// `KeyboardEventGenerator` presses the modifier keys, which matches how a human rolls onto a
    /// chord (outermost modifier first).
    static let canonicalOrder: [ModifierFlags] = [.function, .control, .option, .shift, .command, .capsLock]

    /// The members of `self`, in `canonicalOrder`. Unknown bits are dropped.
    var ordered: [ModifierFlags] {
        ModifierFlags.canonicalOrder.filter { contains($0) }
    }

    // MARK: - Presentation

    private static let symbols: [UInt64: String] = [
        ModifierFlags.function.rawValue: "fn",
        ModifierFlags.control.rawValue: "⌃",
        ModifierFlags.option.rawValue: "⌥",
        ModifierFlags.shift.rawValue: "⇧",
        ModifierFlags.command.rawValue: "⌘",
        ModifierFlags.capsLock.rawValue: "⇪",
    ]

    private static let spokenNames: [UInt64: String] = [
        ModifierFlags.function.rawValue: "Function",
        ModifierFlags.control.rawValue: "Control",
        ModifierFlags.option.rawValue: "Option",
        ModifierFlags.shift.rawValue: "Shift",
        ModifierFlags.command.rawValue: "Command",
        ModifierFlags.capsLock.rawValue: "Caps Lock",
    ]

    /// The key-cap symbol for a single modifier: "fn", "⌃", "⌥", "⇧", "⌘", "⇪".
    ///
    /// Defined for single members; for a combination it returns the members' symbols concatenated
    /// in `canonicalOrder` (so `[.shift, .command].symbol == "⇧⌘"`), and "" for the empty set.
    ///
    /// Not localised on purpose: these glyphs are identical in every language macOS ships.
    var symbol: String {
        if let single = ModifierFlags.symbols[rawValue] { return single }
        return ordered.compactMap { ModifierFlags.symbols[$0.rawValue] }.joined()
    }

    /// The spoken name for VoiceOver: "Shift", "Command"… For a combination, the names joined by
    /// spaces in `canonicalOrder`. Screen readers cannot pronounce ⌘.
    var spokenName: String {
        if let single = ModifierFlags.spokenNames[rawValue] { return single }
        return ordered.compactMap { ModifierFlags.spokenNames[$0.rawValue] }.joined(separator: " ")
    }

    // MARK: - Virtual key codes

    private static let keyCodes: [UInt64: UInt16] = [
        ModifierFlags.function.rawValue: KeyCodes.function,
        ModifierFlags.control.rawValue: KeyCodes.control,
        ModifierFlags.option.rawValue: KeyCodes.option,
        ModifierFlags.shift.rawValue: KeyCodes.shift,
        ModifierFlags.command.rawValue: KeyCodes.command,
        ModifierFlags.capsLock.rawValue: KeyCodes.capsLock,
    ]

    /// The virtual key code of the *left-hand* physical key for a single modifier, or `nil` for a
    /// combination or the empty set.
    ///
    /// WHY: `KeyboardEventGenerator` has to emit a `flagsChanged` event per modifier, and a
    /// `flagsChanged` event needs a key code. The left-hand codes are used because they are the
    /// ones present on every Apple keyboard (`Events.h:271-280`).
    ///
    /// Caps Lock's code is included for completeness, but the generator never presses it — doing so
    /// would toggle the user's real Caps Lock state; it only sets the flag.
    var keyCode: UInt16? {
        ModifierFlags.keyCodes[rawValue]
    }

    // MARK: - Codable

    /// Encoded as a bare number (`"modifiers": 1179648`) rather than as `{"rawValue": …}`.
    ///
    /// WHY: the stored JSON is small, human-readable in `defaults read`, and matches the shape of
    /// the numbers macOS itself stores in `com.apple.symbolichotkeys`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt64.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
