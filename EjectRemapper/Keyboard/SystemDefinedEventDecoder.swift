import AppKit
import CoreGraphics
import Foundation

/// One decoded `NX_SYSDEFINED` / subtype 8 media-key event.
///
/// Why this exists: the Eject key is not a keyboard key at the CGEvent level. It arrives as an
/// opaque "system defined" event whose payload is bit-packed into `data1`. Turning that into a
/// value type at the very edge of the system means nothing above the tap has to know the encoding.
struct MediaKeyEvent: Equatable, Sendable {
    /// `NX_KEYTYPE_*` flavour — 14 is Eject (`ev_keymap.h:71`).
    let keyType: Int
    /// `true` for `NX_KEYDOWN` (0x0A), `false` for `NX_KEYUP` (0x0B).
    let isDown: Bool
    /// Hardware repeat bit. Always `false` for Eject — see `KeyboardInputEvent`.
    let isRepeat: Bool
    /// Modifier flags carried by the event, already masked to the device-independent bits.
    let modifiers: ModifierFlags
}

/// The pure payload of an `NX_SUBTYPE_AUX_CONTROL_BUTTONS` event's `data1` word.
///
/// Split out from `MediaKeyEvent` so the bit arithmetic — the part that is easy to get subtly
/// wrong and impossible to eyeball — can be unit-tested with plain integers, with no `CGEvent`,
/// no `NSEvent`, no AppKit and no permissions involved.
struct AuxControlButtonData: Equatable, Sendable {
    let keyType: Int
    let isDown: Bool
    let isRepeat: Bool
}

/// Decodes the `NX_SYSDEFINED` events through which macOS delivers media keys, including Eject.
///
/// Why a caseless `enum` of statics: the decoder holds no state whatsoever. Every function here is
/// pure with respect to its input, which is what lets the tap callback run it on a real-time thread
/// and lets the test suite exercise it without any system access.
///
/// Encoding evidence (TECHNICAL_INVESTIGATION.md §3). Apple's own translator,
/// `IOHIDFamily-503.215.2/IOHIDSystem/IOHIDSystem.cpp:4977`, writes:
/// ```c
/// outData.compound.subType   = NX_SUBTYPE_AUX_CONTROL_BUTTONS;          /* 8 */
/// outData.compound.misc.L[0] = (flavor << 16) | (eventType << 8) | repeat;
/// ```
/// so an Eject key-down is `data1 == 0x000E0A00` and a key-up is `data1 == 0x000E0B00`.
enum SystemDefinedEventDecoder {

    // MARK: - Constants (all cited to Apple headers)

    /// `NX_SYSDEFINED` — `IOKit/hidsystem/IOLLEvent.h:113`. Absent from Swift's `CGEventType` enum
    /// because CoreGraphics never declared a case for it, so it is constructed from the raw value.
    static let systemDefinedType: CGEventType = CGEventType(rawValue: 14) ?? .null

    /// The tap's entire event mask. Exactly one bit: the app can never observe keyboard key events,
    /// so it cannot read typed text even in principle. This is the app's core privacy property.
    static let eventMask: CGEventMask = 1 << 14

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS` — `IOLLEvent.h:186`. The real media-key signal.
    static let auxControlButtonsSubtype: Int = 8

    /// `NX_SUBTYPE_EJECT_KEY` — `IOLLEvent.h`. A press may surface this *in addition to* the
    /// subtype-8 down/up pair. It must be suppressed alongside them (so no stray event reaches the
    /// system) but must never trigger an action, or the action would fire twice.
    /// See CONTRACT_CORRECTIONS §4 and TECHNICAL_INVESTIGATION.md §3 "Limitations".
    static let ejectKeySubtype: Int = 10

    /// `NX_KEYTYPE_EJECT` — `IOKit/hidsystem/ev_keymap.h:71`.
    static let ejectKeyType: Int = 14

    /// `NX_KEYDOWN` — `IOLLEvent.h:106`.
    static let keyDownState: Int = 0x0A

    /// `NX_KEYUP` — `IOLLEvent.h:107`.
    static let keyUpState: Int = 0x0B

    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`. Hardware events carry device-dependent
    /// low bits (0x1…0x2000) and `NX_NONCOALSESCEDMASK` (0x100) that must be masked off before any
    /// comparison — CONTRACT_CORRECTIONS §5.
    static let deviceIndependentFlagsMask: UInt64 = 0xFFFF_0000

    // MARK: - Pure decoding

    /// Decodes the bit-packed `data1` word of an `NX_SUBTYPE_AUX_CONTROL_BUTTONS` event.
    ///
    /// Returns `nil` when the key-state field is neither `NX_KEYDOWN` nor `NX_KEYUP`, which is how
    /// unrelated payloads that happen to reach this function are rejected.
    ///
    /// This is deliberately free of any Apple type so it is unit-testable in isolation.
    static func decodeAuxData1(_ data1: Int) -> AuxControlButtonData? {
        let keyType = (data1 >> 16) & 0xFFFF
        let keyState = (data1 >> 8) & 0xFF
        let isRepeat = (data1 & 0x1) == 1
        switch keyState {
        case keyDownState:
            return AuxControlButtonData(keyType: keyType, isDown: true, isRepeat: isRepeat)
        case keyUpState:
            return AuxControlButtonData(keyType: keyType, isDown: false, isRepeat: isRepeat)
        default:
            return nil
        }
    }

    /// Builds the `data1` word for a given media key — the exact inverse of ``decodeAuxData1(_:)``.
    ///
    /// Only used by tests, which need to synthesize `NSEvent.otherEvent(…)` payloads; keeping it
    /// next to the decoder guarantees the two stay in step.
    static func auxData1(keyType: Int, isDown: Bool, isRepeat: Bool = false) -> Int {
        ((keyType & 0xFFFF) << 16) | (((isDown ? keyDownState : keyUpState) & 0xFF) << 8) | (isRepeat ? 1 : 0)
    }

    // MARK: - CGEvent bridging

    /// Decodes a `CGEvent` into a ``MediaKeyEvent``, or `nil` if it is not a subtype-8 media key.
    ///
    /// Why `NSEvent(cgEvent:)`: `subtype` and `data1` live in the `NX_` compound payload, which
    /// CoreGraphics exposes no field accessor for. AppKit's bridge is the only public way to read
    /// them. It was measured at ~17.8 µs per call over 10,000 iterations — acceptable for at most
    /// two events per key press, and the only allocation the tap callback ever performs.
    static func decode(_ event: CGEvent) -> MediaKeyEvent? {
        guard event.type == systemDefinedType, let nsEvent = NSEvent(cgEvent: event) else { return nil }
        guard nsEvent.type == .systemDefined, Int(nsEvent.subtype.rawValue) == auxControlButtonsSubtype else {
            return nil
        }
        guard let data = decodeAuxData1(nsEvent.data1) else { return nil }
        return MediaKeyEvent(
            keyType: data.keyType,
            isDown: data.isDown,
            isRepeat: data.isRepeat,
            modifiers: modifiers(of: event)
        )
    }

    /// Decodes a `CGEvent` as an Eject press specifically, mapping it onto the app's own vocabulary.
    ///
    /// Returns `nil` for every other media key (volume, brightness, play/pause…), which is what
    /// guarantees the app never disturbs them.
    static func ejectEvent(_ event: CGEvent) -> (event: KeyboardInputEvent, modifiers: ModifierFlags)? {
        guard let media = decode(event), media.keyType == ejectKeyType else { return nil }
        let input: KeyboardInputEvent
        if media.isDown {
            input = media.isRepeat ? .ejectKeyRepeat : .ejectKeyDown
        } else {
            input = .ejectKeyUp
        }
        return (input, media.modifiers)
    }

    /// `true` when the event is the auxiliary `NX_SUBTYPE_EJECT_KEY` (subtype 10) notification.
    ///
    /// The detector suppresses these in lock step with the subtype-8 pair but never dispatches an
    /// action for them — CONTRACT_CORRECTIONS §4.
    static func isAuxiliaryEjectEvent(_ event: CGEvent) -> Bool {
        guard event.type == systemDefinedType, let nsEvent = NSEvent(cgEvent: event) else { return false }
        guard nsEvent.type == .systemDefined else { return false }
        return Int(nsEvent.subtype.rawValue) == ejectKeySubtype
    }

    /// The event's modifiers, masked to the device-independent bits before anything compares them.
    static func modifiers(of event: CGEvent) -> ModifierFlags {
        ModifierFlags(cgEventFlags: CGEventFlags(rawValue: event.flags.rawValue & deviceIndependentFlagsMask))
    }
}
