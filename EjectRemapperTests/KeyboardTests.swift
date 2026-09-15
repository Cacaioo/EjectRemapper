//
//  KeyboardTests.swift
//  EjectRemapperTests
//
//  Event decoding, event generation, the shortcut recorder's conversion rules, hardware
//  compatibility parsing, and the symbolic hot key reader.
//

import AppKit
import CoreGraphics
import XCTest

@testable import EjectRemapper

// MARK: - Decoding the Eject event

final class SystemDefinedEventDecoderTests: XCTestCase {

    func testTheMaskIsExactlyOneBit() {
        // This is the app's central privacy property: only system-defined events are ever observed.
        XCTAssertEqual(SystemDefinedEventDecoder.eventMask, 1 << 14)
        XCTAssertEqual(SystemDefinedEventDecoder.eventMask.nonzeroBitCount, 1)
        XCTAssertEqual(SystemDefinedEventDecoder.systemDefinedType.rawValue, 14)
        XCTAssertEqual(SystemDefinedEventDecoder.eventMask & (1 << CGEventType.keyDown.rawValue), 0,
                       "The mask must never include key events")
    }

    func testConstantsMatchTheHeaders() {
        XCTAssertEqual(SystemDefinedEventDecoder.auxControlButtonsSubtype, 8)   // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        XCTAssertEqual(SystemDefinedEventDecoder.ejectKeySubtype, 10)           // NX_SUBTYPE_EJECT_KEY
        XCTAssertEqual(SystemDefinedEventDecoder.ejectKeyType, 14)              // NX_KEYTYPE_EJECT
        XCTAssertEqual(SystemDefinedEventDecoder.keyDownState, 0x0A)            // NX_KEYDOWN
        XCTAssertEqual(SystemDefinedEventDecoder.keyUpState, 0x0B)              // NX_KEYUP
    }

    /// The exact words Apple's own translator writes for an Eject press.
    func testTheRealEjectPayloads() throws {
        let down = try XCTUnwrap(SystemDefinedEventDecoder.decodeAuxData1(0x000E_0A00))
        XCTAssertEqual(down.keyType, 14)
        XCTAssertTrue(down.isDown)
        XCTAssertFalse(down.isRepeat)

        let up = try XCTUnwrap(SystemDefinedEventDecoder.decodeAuxData1(0x000E_0B00))
        XCTAssertEqual(up.keyType, 14)
        XCTAssertFalse(up.isDown)
    }

    func testRepeatBitIsDecoded() throws {
        let repeated = try XCTUnwrap(SystemDefinedEventDecoder.decodeAuxData1(0x000E_0A01))
        XCTAssertTrue(repeated.isRepeat)
        XCTAssertTrue(repeated.isDown)
    }

    func testOtherMediaKeysDecodeToTheirOwnTypes() throws {
        // 16 is NX_KEYTYPE_PLAY. It must decode, and must not be mistaken for Eject.
        let play = try XCTUnwrap(SystemDefinedEventDecoder.decodeAuxData1(0x0010_0A00))
        XCTAssertEqual(play.keyType, 16)
        XCTAssertNotEqual(play.keyType, SystemDefinedEventDecoder.ejectKeyType)
    }

    func testAnUnknownKeyStateDecodesToNil() {
        XCTAssertNil(SystemDefinedEventDecoder.decodeAuxData1(0x000E_0C00))
        XCTAssertNil(SystemDefinedEventDecoder.decodeAuxData1(0))
    }

    func testDataOneRoundTripsThroughTheBuilder() throws {
        for isDown in [true, false] {
            for isRepeat in [true, false] {
                let data1 = SystemDefinedEventDecoder.auxData1(keyType: 14, isDown: isDown, isRepeat: isRepeat)
                let decoded = try XCTUnwrap(SystemDefinedEventDecoder.decodeAuxData1(data1))
                XCTAssertEqual(decoded.keyType, 14)
                XCTAssertEqual(decoded.isDown, isDown)
                XCTAssertEqual(decoded.isRepeat, isRepeat)
            }
        }
        XCTAssertEqual(SystemDefinedEventDecoder.auxData1(keyType: 14, isDown: true), 0x000E_0A00)
        XCTAssertEqual(SystemDefinedEventDecoder.auxData1(keyType: 14, isDown: false), 0x000E_0B00)
    }

    func testDecodingARealCGEvent() throws {
        let event = try XCTUnwrap(SyntheticEvent.systemDefined(keyType: 14, isDown: true))
        let media = try XCTUnwrap(SystemDefinedEventDecoder.decode(event))
        XCTAssertEqual(media.keyType, 14)
        XCTAssertTrue(media.isDown)

        let translated = try XCTUnwrap(SystemDefinedEventDecoder.ejectEvent(event))
        XCTAssertEqual(translated.event, .ejectKeyDown)
    }

    func testKeyUpEventTranslatesToKeyUp() throws {
        let event = try XCTUnwrap(SyntheticEvent.systemDefined(keyType: 14, isDown: false))
        let translated = try XCTUnwrap(SystemDefinedEventDecoder.ejectEvent(event))
        XCTAssertEqual(translated.event, .ejectKeyUp)
    }

    func testANonEjectMediaKeyIsNotTreatedAsEject() throws {
        let play = try XCTUnwrap(SyntheticEvent.systemDefined(keyType: 16, isDown: true))
        XCTAssertNil(SystemDefinedEventDecoder.ejectEvent(play),
                     "Play/Pause must pass straight through — the app touches only Eject")
    }

    func testTheWrongSubtypeIsIgnored() throws {
        let event = try XCTUnwrap(SyntheticEvent.systemDefined(keyType: 14, isDown: true, subtype: 7))
        XCTAssertNil(SystemDefinedEventDecoder.decode(event))
    }

    func testTheAuxiliaryEjectSubtypeIsRecognised() throws {
        let event = try XCTUnwrap(SyntheticEvent.systemDefined(
            keyType: 14, isDown: true, subtype: SystemDefinedEventDecoder.ejectKeySubtype))
        XCTAssertTrue(SystemDefinedEventDecoder.isAuxiliaryEjectEvent(event))

        let ordinary = try XCTUnwrap(SyntheticEvent.systemDefined(keyType: 14, isDown: true))
        XCTAssertFalse(SystemDefinedEventDecoder.isAuxiliaryEjectEvent(ordinary))
    }

    func testModifiersAreReadFromTheEventAndMasked() throws {
        let event = try XCTUnwrap(SyntheticEvent.systemDefined(
            keyType: 14, isDown: true, modifiers: [.command, .shift]))
        let modifiers = SystemDefinedEventDecoder.modifiers(of: event)
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertTrue(modifiers.isSubset(of: .all))
    }
}

// MARK: - Generating events

final class KeyboardEventGeneratorTests: XCTestCase {

    private var poster: RecordingEventPoster!
    private var generator: KeyboardEventGenerator!

    override func setUp() {
        super.setUp()
        poster = RecordingEventPoster()
        generator = KeyboardEventGenerator(recording: poster)
    }

    private func firstKeyDown(_ keyCode: UInt16) -> PostedEvent? {
        poster.events.first(where: { $0.type == .keyDown && $0.keyCode == keyCode })
    }

    func testForwardDeleteKeyDownCarriesTheRightKeyAndTag() throws {
        generator.holdDown(KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: []))
        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.type, .keyDown)
        XCTAssertEqual(event.keyCode, KeyCodes.forwardDelete)
        XCTAssertFalse(event.isAutorepeat)
        XCTAssertEqual(event.userData, GeneratedEventTag.userData,
                       "Every generated event must be tagged so it can never be mistaken for a real one")
    }

    func testRepeatsAreMarkedAsAutorepeat() throws {
        let chord = KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [])
        generator.holdDown(chord)
        generator.repeatHeld(chord)
        XCTAssertFalse(try XCTUnwrap(poster.events.first).isAutorepeat)
        let repeated = try XCTUnwrap(poster.events.last)
        XCTAssertEqual(repeated.type, .keyDown)
        XCTAssertTrue(repeated.isAutorepeat)
    }

    /// A recorded custom shortcut such as ⌥⌦ keeps its modifiers alongside the fn Core Graphics adds.
    func testRequestedModifiersSurviveTheAutomaticFnFlag() throws {
        generator.holdDown(KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [.option]))
        let event = try XCTUnwrap(firstKeyDown(KeyCodes.forwardDelete))
        XCTAssertTrue(event.modifiers.contains(.option))
        XCTAssertTrue(event.modifiers.contains(.function), "Precondition: Core Graphics adds fn to ⌦")
    }

    func testReleasingAHeldKeyPostsItsKeyUp() {
        let chord = KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [])
        generator.holdDown(chord)
        generator.releaseHeld(chord)
        XCTAssertTrue(poster.events.contains(where: { $0.type == .keyUp && $0.keyCode == KeyCodes.forwardDelete }))
    }

    /// The full sequence for ⌘⇧4, which is the heart of the custom shortcut feature.
    func testPressingAShortcutProducesTheCorrectSequence() throws {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift]))

        let events = poster.events
        XCTAssertEqual(events.count, 6, "Expected two modifier downs, a key down and up, and two modifier ups")

        // Modifiers go down in Apple's canonical order: ⇧ then ⌘, with the flags accumulating.
        XCTAssertEqual(events[0].keyCode, KeyCodes.shift)
        XCTAssertEqual(events[1].keyCode, KeyCodes.command)
        XCTAssertEqual(events[0].modifiers, [.shift])
        XCTAssertEqual(events[1].modifiers, [.shift, .command])

        // Then the key itself, with the full chord.
        XCTAssertEqual(events[2].type, .keyDown)
        XCTAssertEqual(events[2].keyCode, KeyCodes.ansi4)
        XCTAssertTrue(events[2].modifiers.isSuperset(of: [.command, .shift]))
        XCTAssertEqual(events[3].type, .keyUp)
        XCTAssertEqual(events[3].keyCode, KeyCodes.ansi4)

        // And the modifiers come back up in reverse order, ending with none held.
        XCTAssertEqual(events[4].keyCode, KeyCodes.command)
        XCTAssertEqual(events[5].keyCode, KeyCodes.shift)
        XCTAssertEqual(events[5].modifiers, [])

        XCTAssertTrue(events.allSatisfy { $0.userData == GeneratedEventTag.userData })
    }

    /// ⇧⌘3 and the other system hot keys are sent exactly as a person types them. Sending them as a
    /// flags-only key tap left ⇧⌘ latched for the whole session — the bug this shape fixes.
    func testSystemHotKeysAreSentAsBalancedChords() {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.shift, .command]))
        let events = poster.events
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertTrue(events[2].modifiers.isSuperset(of: [.shift, .command]))
        XCTAssertEqual(events.last?.modifiers, [], "The chord must end with its modifiers released")
    }

    func testCapsLockIsNeverPressedAsAKey() {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.capsLock, .command]))
        let modifierKeys = poster.events.filter { $0.type == .flagsChanged }.map(\.keyCode)
        XCTAssertFalse(modifierKeys.contains(KeyCodes.capsLock),
                       "Pressing Caps Lock would toggle the user's real Caps Lock state")
        XCTAssertTrue(modifierKeys.contains(KeyCodes.command))
    }

    /// Core Graphics adds fn to F13 (and to Forward Delete, the arrows, Home, End and the other F-keys)
    /// by itself. Left alone, that fn would stay set for the session after the key is released.
    func testAKeyThatGetsFnAutomaticallyEndsWithFnCleared() throws {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.f13, modifiers: []))
        let events = poster.events

        XCTAssertEqual(events.first?.type, .keyDown, "A bare key needs no modifier key presses")
        let keyUp = try XCTUnwrap(events.first(where: { $0.type == .keyUp }))
        XCTAssertTrue(keyUp.modifiers.contains(.function), "Precondition: Core Graphics adds fn to F13")

        let restore = try XCTUnwrap(events.last)
        XCTAssertEqual(restore.type, .flagsChanged)
        XCTAssertEqual(restore.modifiers, [])
        XCTAssertNotEqual(restore.keyCode, KeyCodes.function, "Posting the Globe key could open the emoji picker")
        XCTAssertNotEqual(restore.keyCode, KeyCodes.capsLock, "Posting Caps Lock would toggle it")
    }

    func testAChordWhoseReleaseAlreadyRestoresTheSessionPostsNothingExtra() {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command]))
        XCTAssertEqual(poster.events.count, 4, "⌘ down, C down, C up, ⌘ up — no redundant restore event")
    }

    func testRecordingPosterCanBeReset() {
        generator.press(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command]))
        XCTAssertFalse(poster.events.isEmpty)
        poster.reset()
        XCTAssertTrue(poster.events.isEmpty)
    }
}

// MARK: - The modifier-state invariant

/// Every synthesized sequence must leave the session's modifier flags exactly as the physical
/// keyboard has them. `SimulatedSessionPoster` applies the window server rule measured on macOS 26.5:
/// the session's modifiers become the flags of the most recently posted keyboard event.
final class ModifierStateInvariantTests: XCTestCase {

    private func makeGenerator(physical: ModifierFlags) -> (KeyboardEventGenerator, SimulatedSessionPoster) {
        let session = SimulatedSessionPoster(physical: physical)
        let generator = KeyboardEventGenerator(poster: session, physicalModifiers: { session.modifiers })
        return (generator, session)
    }

    func testEverySequenceLeavesTheSessionAsItFoundIt() {
        let sequences: [(String, (KeyboardEventGenerator) -> Void)] = [
            ("⇧⌘3 screenshot", { $0.press(KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.shift, .command])) }),
            ("⇧⌘5 screenshot menu", { $0.press(KeyboardShortcut(keyCode: KeyCodes.ansi5, modifiers: [.shift, .command])) }),
            ("⌃⌘Q lock", { $0.press(KeyboardShortcut(keyCode: KeyCodes.ansiQ, modifiers: [.control, .command])) }),
            ("⌥⇧⌘K custom", { $0.press(KeyboardShortcut(keyCode: KeyCodes.ansiK, modifiers: [.option, .shift, .command])) }),
            ("bare F13", { $0.press(KeyboardShortcut(keyCode: KeyCodes.f13, modifiers: [])) }),
            ("held ⌦", { generator in
                let chord = KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [])
                generator.holdDown(chord)
                generator.repeatHeld(chord)
                generator.releaseHeld(chord)
            }),
            ("held ⌃⌥←", { generator in
                let chord = KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option])
                generator.holdDown(chord)
                generator.repeatHeld(chord)
                generator.releaseHeld(chord)
            }),
        ]

        for physical in [ModifierFlags(), ModifierFlags.capsLock] {
            for (name, run) in sequences {
                let (generator, session) = makeGenerator(physical: physical)
                run(generator)
                XCTAssertEqual(session.modifiers, physical,
                               "\(name) with \(physical.isEmpty ? "nothing" : physical.symbol) physically held")
            }
        }
    }

    func testAChordLeftHeldIsRestoredBeforeTheNextOneStarts() {
        let (generator, session) = makeGenerator(physical: [])
        generator.holdDown(KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.shift, .command]))
        XCTAssertEqual(session.modifiers, [.shift, .command], "Precondition: the chord is held")

        let forwardDelete = KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [])
        generator.holdDown(forwardDelete)
        XCTAssertFalse(session.events.contains(where: {
            $0.type == .keyDown && $0.keyCode == KeyCodes.forwardDelete && $0.modifiers.contains(.command)
        }), "⌦ must not go out as ⇧⌘⌦ because an earlier chord was never released")

        generator.releaseHeld(forwardDelete)
        XCTAssertEqual(session.modifiers, [])
    }

    func testTheRestoreNeverClaimsAHeldModifierWasReleased() throws {
        let (generator, session) = makeGenerator(physical: [.control, .capsLock])
        generator.press(KeyboardShortcut(keyCode: KeyCodes.f13, modifiers: []))

        let restore = try XCTUnwrap(session.events.last)
        XCTAssertEqual(restore.type, .flagsChanged)
        XCTAssertNotEqual(restore.keyCode, KeyCodes.control, "⌃ is physically held, so it must not carry the restore")
        XCTAssertEqual(session.modifiers, [.control, .capsLock])
    }

    func testTheProductionBaselineExcludesModifiersThatCannotBeHeldWhenAnActionRuns() {
        let everything: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn, .maskAlphaShift]
        XCTAssertEqual(KeyboardEventGenerator.baseline(fromSessionFlags: everything), [.function, .capsLock])
        XCTAssertEqual(ModifierFlags.passThroughModifiers, [.command, .control, .option, .shift])
    }

    /// A read taken right after posting can still show this app's own unfinished ⇧⌘ chord. A sequence
    /// that starts then must restore the session to what the user holds, not to that chord.
    func testAStaleReadingOfAnUnfinishedChordIsNotAdoptedAsTheBaseline() {
        let session = SimulatedSessionPoster(physical: [])
        let staleReading: CGEventFlags = [.maskShift, .maskCommand]
        let generator = KeyboardEventGenerator(poster: session, physicalModifiers: {
            KeyboardEventGenerator.baseline(fromSessionFlags: staleReading)
        })

        generator.press(KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: []))

        XCTAssertEqual(session.modifiers, [], "Restoring to the stale ⇧⌘ would reproduce the original bug")
    }
}

// MARK: - The recorder's conversion rules

@MainActor
final class ShortcutRecorderConversionTests: XCTestCase {

    func testTheSpecifiedCombinationsAreCapturedCorrectly() throws {
        let cases: [(UInt16, NSEvent.ModifierFlags, KeyboardShortcut)] = [
            (KeyCodes.ansiC, [.command],
             KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])),
            (KeyCodes.ansi4, [.command, .shift],
             KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])),
            (KeyCodes.delete, [.option],
             KeyboardShortcut(keyCode: KeyCodes.delete, modifiers: [.option])),
            (KeyCodes.ansiK, [.command, .option, .shift],
             KeyboardShortcut(keyCode: KeyCodes.ansiK, modifiers: [.command, .option, .shift])),
        ]

        for (keyCode, flags, expected) in cases {
            let event = SyntheticEvent.keyDown(keyCode: keyCode, modifiers: flags)
            XCTAssertEqual(ShortcutRecorder.shortcut(from: event), expected)
        }
    }

    /// macOS reports arrows with fn already set. Keeping that bit would store the wrong chord.
    func testTheFunctionFlagIsStrippedFromKeysThatAlwaysCarryIt() throws {
        let event = SyntheticEvent.keyDown(keyCode: KeyCodes.leftArrow,
                                           modifiers: [.control, .option, .function])
        let shortcut = try XCTUnwrap(ShortcutRecorder.shortcut(from: event))
        XCTAssertEqual(shortcut, KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option]))
        XCTAssertFalse(shortcut.modifiers.contains(.function))
    }

    func testTheFunctionFlagIsKeptForOrdinaryKeys() throws {
        let event = SyntheticEvent.keyDown(keyCode: KeyCodes.ansiC, modifiers: [.function, .command])
        let shortcut = try XCTUnwrap(ShortcutRecorder.shortcut(from: event))
        XCTAssertTrue(shortcut.modifiers.contains(.function))
    }

    func testModifierKeysAloneProduceNothing() {
        for code in [KeyCodes.command, KeyCodes.shift, KeyCodes.option, KeyCodes.control, KeyCodes.function] {
            let event = SyntheticEvent.keyDown(keyCode: code, modifiers: [.command])
            XCTAssertNil(ShortcutRecorder.shortcut(from: event),
                         "0x\(String(code, radix: 16)) is a modifier and cannot be a shortcut's key")
        }
    }

    func testNonKeyDownEventsAreIgnored() {
        let event = SyntheticEvent.flagsChanged(keyCode: KeyCodes.command, modifiers: [.command])
        XCTAssertNil(ShortcutRecorder.shortcut(from: event))
    }

    func testDeviceDependentFlagsDoNotLeakIntoARecordedShortcut() throws {
        let noisy = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        let event = SyntheticEvent.keyDown(keyCode: KeyCodes.ansiC, modifiers: noisy)
        let shortcut = try XCTUnwrap(ShortcutRecorder.shortcut(from: event))
        XCTAssertEqual(shortcut.modifiers, .command)
    }
}

// MARK: - Symbolic hot keys

final class SymbolicHotKeyTests: XCTestCase {

    /// The exact numbers read from the development machine's live preferences.
    func testParsingTheRealScreenshotShortcut() throws {
        let shortcut = try XCTUnwrap(SymbolicHotKeyReader.parse(parameters: [51, 20, 1_179_648]))
        XCTAssertEqual(shortcut.keyCode, KeyCodes.ansi3)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    func testParsingTheScreenshotOptionsShortcut() throws {
        let shortcut = try XCTUnwrap(SymbolicHotKeyReader.parse(parameters: [53, 23, 1_179_648]))
        XCTAssertEqual(shortcut.keyCode, KeyCodes.ansi5)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    func testTheModifierMaskUsesCocoaBitsNotCarbonBits() throws {
        // 1179648 == 0x120000 == command (1<<20) | shift (1<<17). The Carbon cmdKey is 1<<8.
        let shortcut = try XCTUnwrap(SymbolicHotKeyReader.parse(parameters: [51, 20, 0x12_0000]))
        XCTAssertEqual(shortcut.modifiers.rawValue, 0x12_0000)
        XCTAssertNotEqual(shortcut.modifiers.rawValue, 1 << 8)
    }

    func testAClearedShortcutParsesToNothing() {
        XCTAssertNil(SymbolicHotKeyReader.parse(parameters: [65535, 65535, 0]))
    }

    func testTooFewParametersParseToNothing() {
        XCTAssertNil(SymbolicHotKeyReader.parse(parameters: [51, 20]))
        XCTAssertNil(SymbolicHotKeyReader.parse(parameters: []))
    }

    func testAMissingDomainFallsBackToApplesDefaults() {
        let hotKey = SymbolicHotKeyReader.hotKey(id: SymbolicHotKeyReader.saveScreenAsFile, defaults: nil)
        XCTAssertTrue(hotKey.isEnabled)
        XCTAssertEqual(hotKey.shortcut.keyCode, KeyCodes.ansi3)
        XCTAssertEqual(hotKey.shortcut.modifiers, [.command, .shift])
    }

    func testAnEntryInTheDomainIsRead() throws {
        let (defaults, suiteName) = makeScratchDefaults("symbolicHotKeys")
        defer { destroyScratchDefaults(suiteName) }

        defaults.set([
            "28": ["enabled": true, "value": ["parameters": [55, 7, 1_048_576], "type": "standard"]],
        ], forKey: SymbolicHotKeyReader.dictionaryKey)

        let hotKey = SymbolicHotKeyReader.hotKey(id: 28, defaults: defaults)
        XCTAssertTrue(hotKey.isEnabled)
        XCTAssertEqual(hotKey.shortcut.keyCode, 7)
        XCTAssertEqual(hotKey.shortcut.modifiers, [.command])
    }

    func testADisabledEntryIsReportedAsDisabled() throws {
        let (defaults, suiteName) = makeScratchDefaults("disabledHotKey")
        defer { destroyScratchDefaults(suiteName) }

        defaults.set([
            "28": ["enabled": false, "value": ["parameters": [51, 20, 1_179_648], "type": "standard"]],
        ], forKey: SymbolicHotKeyReader.dictionaryKey)

        XCTAssertFalse(SymbolicHotKeyReader.hotKey(id: 28, defaults: defaults).isEnabled)
    }

    func testEnabledWrittenAsANumberIsUnderstood() throws {
        let (defaults, suiteName) = makeScratchDefaults("numericEnabled")
        defer { destroyScratchDefaults(suiteName) }

        defaults.set([
            "28": ["enabled": 0, "value": ["parameters": [51, 20, 1_179_648], "type": "standard"]],
        ], forKey: SymbolicHotKeyReader.dictionaryKey)

        XCTAssertFalse(SymbolicHotKeyReader.hotKey(id: 28, defaults: defaults).isEnabled)
    }

    func testTheDefaultsAreApplesRealDefaults() {
        XCTAssertEqual(SymbolicHotKeyReader.defaultShortcuts[28],
                       KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.shift, .command]))
        XCTAssertEqual(SymbolicHotKeyReader.defaultShortcuts[184],
                       KeyboardShortcut(keyCode: KeyCodes.ansi5, modifiers: [.shift, .command]))
    }
}

// MARK: - Hardware compatibility

final class KeyboardCompatibilityTests: XCTestCase {

    /// The real 182-byte report descriptor of the Apple Magic Keyboard A1644, read from the
    /// IORegistry of the development machine. The Eject declaration is the
    /// `05 0C 75 01 95 01 09 B8` run near the end of the first collection.
    private static let magicKeyboardA1644: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08,
        0x81, 0x01, 0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xFF,
        0x00, 0x05, 0x07, 0x19, 0x00, 0x29, 0xFF, 0x81, 0x00, 0x05, 0x0C, 0x75, 0x01, 0x95,
        0x01, 0x09, 0xB8, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02, 0x05, 0xFF, 0x09, 0x03, 0x75,
        0x07, 0x95, 0x01, 0x81, 0x02, 0xC0, 0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x52,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x09, 0xCD, 0x81, 0x02, 0x09, 0xB3,
        0x81, 0x02, 0x09, 0xB4, 0x81, 0x02, 0x09, 0xB5, 0x81, 0x02, 0x09, 0xB6, 0x81, 0x02,
        0x81, 0x01, 0x81, 0x01, 0x81, 0x01, 0x85, 0x09, 0x15, 0x00, 0x25, 0x01, 0x75, 0x08,
        0x95, 0x01, 0x06, 0x01, 0xFF, 0x09, 0x0B, 0xB1, 0x02, 0x75, 0x08, 0x95, 0x02, 0xB1,
        0x01, 0xC0, 0x06, 0x00, 0xFF, 0x09, 0x06, 0xA1, 0x01, 0x06, 0x00, 0xFF, 0x09, 0x06,
        0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x85, 0x3F, 0x81, 0x22, 0xC0,
    ]

    /// A plain boot keyboard: modifiers, reserved byte, LEDs and the key array. No consumer page.
    private static let plainBootKeyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
        0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x03,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01,
        0x75, 0x03, 0x91, 0x03, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07,
        0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
    ]

    func testTheRealMagicKeyboardDescriptorDeclaresEject() {
        XCTAssertEqual(Self.magicKeyboardA1644.count, 182, "Descriptor fixture should be the real 182 bytes")
        XCTAssertTrue(KeyboardCompatibility.descriptorDeclaresEject(Self.magicKeyboardA1644))
    }

    func testAPlainKeyboardDoesNotDeclareEject() {
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject(Self.plainBootKeyboard))
    }

    func testAConsumerUsageOtherThanEjectIsNotAMatch() {
        // Play/Pause (0xCD) on the consumer page, and nothing else.
        let descriptor: [UInt8] = [0x05, 0x0C, 0x09, 0xCD, 0x81, 0x02]
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject(descriptor))
    }

    func testEjectOnADifferentPageIsNotAMatch() {
        // Usage 0xB8 on the Generic Desktop page means something else entirely.
        let descriptor: [UInt8] = [0x05, 0x01, 0x09, 0xB8, 0x81, 0x02]
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject(descriptor))
    }

    func testAUsageRangeSpanningEjectCounts() {
        // Usage Minimum 0xB0, Usage Maximum 0xC0 on the consumer page covers 0xB8.
        let descriptor: [UInt8] = [0x05, 0x0C, 0x19, 0xB0, 0x29, 0xC0, 0x81, 0x00]
        XCTAssertTrue(KeyboardCompatibility.descriptorDeclaresEject(descriptor))
    }

    func testAUsageRangeBelowEjectDoesNotCount() {
        let descriptor: [UInt8] = [0x05, 0x0C, 0x19, 0xB0, 0x29, 0xB6, 0x81, 0x00]
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject(descriptor))
    }

    func testAFourByteUsageCarriesItsOwnPage() {
        // 0x0B is Usage with a 4-byte payload: 0x000C00B8 = consumer page, eject.
        let descriptor: [UInt8] = [0x0B, 0xB8, 0x00, 0x0C, 0x00, 0x81, 0x02]
        XCTAssertTrue(KeyboardCompatibility.descriptorDeclaresEject(descriptor))
    }

    func testAnEmptyOrTruncatedDescriptorIsHandled() {
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject([]))
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject([0x05]))            // page, no payload
        XCTAssertFalse(KeyboardCompatibility.descriptorDeclaresEject([0x05, 0x0C, 0x09])) // usage, no payload
    }

    func testTheProductTableClassifiesTheKnownKeyboards() {
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x0267]?.variant, .eject)
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x026C]?.variant, .eject)
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x029C]?.variant, .lock)
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x0320]?.variant, .lock)
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x029A]?.variant, .touchID)
        XCTAssertEqual(KeyboardCompatibility.knownAppleKeyboards[0x0321]?.variant, .touchID)
    }

    func testAssessmentReportsSupportWhenAnEjectKeyboardIsPresent() {
        let keyboard = HIDKeyboardInfo(name: "MagicKeyboard", vendorID: 0x004C, productID: 0x0267,
                                       transport: "Bluetooth", variant: .eject, declaresEjectUsage: true)
        guard case .supported(let found) = KeyboardCompatibility.assess(keyboards: [keyboard]) else {
            return XCTFail("Expected the keyboard to be supported")
        }
        XCTAssertEqual(found, keyboard)
    }

    func testAssessmentExplainsTheLockKeySpecifically() {
        let keyboard = HIDKeyboardInfo(name: "Magic Keyboard", vendorID: 0x004C, productID: 0x029C,
                                       transport: "Bluetooth", variant: .lock, declaresEjectUsage: false)
        guard case .unsupported(let reason, _) = KeyboardCompatibility.assess(keyboards: [keyboard]) else {
            return XCTFail("Expected an unsupported verdict")
        }
        XCTAssertTrue(reason.contains("Lock"), "The reason should name the Lock key, got: \(reason)")
    }

    func testAssessmentExplainsTouchIDSpecifically() {
        let keyboard = HIDKeyboardInfo(name: "Magic Keyboard with Touch ID", vendorID: 0x004C,
                                       productID: 0x029A, transport: "Bluetooth",
                                       variant: .touchID, declaresEjectUsage: false)
        guard case .unsupported(let reason, _) = KeyboardCompatibility.assess(keyboards: [keyboard]) else {
            return XCTFail("Expected an unsupported verdict")
        }
        XCTAssertTrue(reason.contains("Touch ID"), "The reason should name Touch ID, got: \(reason)")
    }

    func testAssessmentReportsWhenThereIsNoKeyboardAtAll() {
        guard case .noKeyboardFound = KeyboardCompatibility.assess(keyboards: []) else {
            return XCTFail("Expected noKeyboardFound")
        }
    }

    func testOneSupportedKeyboardAmongUnsupportedOnesWins() {
        let builtIn = HIDKeyboardInfo(name: "Apple Internal Keyboard", vendorID: 0x05AC, productID: 0x0342,
                                      transport: "SPI", variant: .none, declaresEjectUsage: false)
        let magic = HIDKeyboardInfo(name: "MagicKeyboard", vendorID: 0x004C, productID: 0x0267,
                                    transport: "Bluetooth", variant: .eject, declaresEjectUsage: true)
        guard case .supported = KeyboardCompatibility.assess(keyboards: [builtIn, magic]) else {
            return XCTFail("A connected Eject keyboard should win over a built-in one")
        }
    }
}
