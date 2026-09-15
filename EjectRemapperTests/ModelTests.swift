//
//  ModelTests.swift
//  EjectRemapperTests
//
//  The pure value layer: actions, shortcuts, modifiers, formatting and validation.
//

import XCTest

@testable import EjectRemapper

// MARK: - EjectAction

final class EjectActionTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip(_ action: EjectAction) throws -> EjectAction {
        try decoder.decode(EjectAction.self, from: encoder.encode(action))
    }

    func testEveryCaseSurvivesACodableRoundTrip() throws {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])
        let all: [EjectAction] = [
            .forwardDelete, .lockScreen, .screenshot, .screenshotMenu,
            .customShortcut(shortcut), .original, .disabled,
        ]
        for action in all {
            XCTAssertEqual(try roundTrip(action), action, "\(action) did not survive encoding")
        }
    }

    func testCustomShortcutCarriesItsPayloadThroughEncoding() throws {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansiK, modifiers: [.command, .option, .shift])
        guard case .customShortcut(let decoded) = try roundTrip(.customShortcut(shortcut)) else {
            return XCTFail("Expected a custom shortcut case")
        }
        XCTAssertEqual(decoded, shortcut)
    }

    func testEncodingUsesAnExplicitTypeDiscriminator() throws {
        let data = try encoder.encode(EjectAction.lockScreen)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "lockScreen")
        XCTAssertNil(json["shortcut"], "A payload-free case must not carry a shortcut key")
    }

    func testDecodingAnUnknownActionTypeFails() {
        let json = Data(#"{"type":"teleport"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(EjectAction.self, from: json))
    }

    func testDecodingACustomShortcutWithoutItsPayloadFails() {
        let json = Data(#"{"type":"customShortcut"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(EjectAction.self, from: json))
    }

    func testOnlyOriginalFunctionLetsTheEventThrough() {
        XCTAssertFalse(EjectAction.original.suppressesOriginalEvent)
        for action in [EjectAction.forwardDelete, .lockScreen, .screenshot, .screenshotMenu, .disabled] {
            XCTAssertTrue(action.suppressesOriginalEvent, "\(action) should suppress the original event")
        }
    }

    func testOnlyKeyLikeActionsRepeat() {
        XCTAssertTrue(EjectAction.forwardDelete.supportsKeyRepeat)
        XCTAssertTrue(EjectAction.customShortcut(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])).supportsKeyRepeat)
        for action in [EjectAction.lockScreen, .screenshot, .screenshotMenu, .original, .disabled] {
            XCTAssertFalse(action.supportsKeyRepeat, "\(action) must never repeat")
        }
    }

    func testKindMapsBackToTheAction() {
        XCTAssertEqual(EjectAction.screenshotMenu.kind, .screenshotMenu)
        XCTAssertEqual(EjectAction.customShortcut(KeyboardShortcut(keyCode: 0, modifiers: [])).kind, .customShortcut)
    }

    func testEveryKindHasPresentableText() {
        for kind in EjectActionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.summary.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
    }
}

// MARK: - ModifierFlags

final class ModifierFlagsTests: XCTestCase {

    func testRawValuesMatchBothFrameworks() {
        XCTAssertEqual(ModifierFlags.command.rawValue, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(ModifierFlags.shift.rawValue, CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(ModifierFlags.option.rawValue, CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(ModifierFlags.control.rawValue, CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(ModifierFlags.function.rawValue, CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(ModifierFlags.capsLock.rawValue, CGEventFlags.maskAlphaShift.rawValue)

        XCTAssertEqual(ModifierFlags.command.rawValue, UInt64(NSEvent.ModifierFlags.command.rawValue))
        XCTAssertEqual(ModifierFlags.function.rawValue, UInt64(NSEvent.ModifierFlags.function.rawValue))
    }

    func testDeviceDependentBitsAreStrippedFromHardwareFlags() {
        // A real event carries left/right discrimination bits and NX_NONCOALSESCEDMASK (0x100).
        let noisy = CGEventFlags(rawValue: ModifierFlags.command.rawValue | 0x8 | 0x100 | 0x2000)
        XCTAssertEqual(ModifierFlags(cgEventFlags: noisy), .command)
    }

    func testNumericPadAndHelpBitsAreNotModelled() {
        let withExtras = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue
            | NSEvent.ModifierFlags.numericPad.rawValue
            | NSEvent.ModifierFlags.help.rawValue)
        XCTAssertEqual(ModifierFlags(nsEventFlags: withExtras), .command)
    }

    func testOrderFollowsAppleConvention() {
        let all: ModifierFlags = [.command, .shift, .option, .control, .function]
        XCTAssertEqual(all.ordered, [.function, .control, .option, .shift, .command])
    }

    func testSymbolsForSingleAndCombinedFlags() {
        XCTAssertEqual(ModifierFlags.command.symbol, "⌘")
        XCTAssertEqual(ModifierFlags.shift.symbol, "⇧")
        XCTAssertEqual(ModifierFlags.option.symbol, "⌥")
        XCTAssertEqual(ModifierFlags.control.symbol, "⌃")
        XCTAssertEqual(ModifierFlags.capsLock.symbol, "⇪")
        XCTAssertEqual(ModifierFlags.function.symbol, "fn")
        XCTAssertEqual(ModifierFlags([.command, .shift]).symbol, "⇧⌘")
        XCTAssertEqual(ModifierFlags([]).symbol, "")
    }

    func testSpokenNamesAreWordsNotGlyphs() {
        XCTAssertEqual(ModifierFlags.command.spokenName, "Command")
        XCTAssertEqual(ModifierFlags([.shift, .command]).spokenName, "Shift Command")
    }

    func testModifierKeyCodes() {
        XCTAssertEqual(ModifierFlags.command.keyCode, KeyCodes.command)
        XCTAssertEqual(ModifierFlags.function.keyCode, KeyCodes.function)
        XCTAssertNil(ModifierFlags([.command, .shift]).keyCode, "A combination has no single key")
        XCTAssertNil(ModifierFlags([]).keyCode)
    }

    func testSystemComboModifiersCoverTheEjectChords() {
        // ⌃⇧⏏, ⌥⌘⏏, ⌃⏏, ⌃⌘⏏, ⌃⌥⌘⏏ all involve at least one of these.
        XCTAssertTrue(ModifierFlags.systemComboModifiers.contains(.command))
        XCTAssertTrue(ModifierFlags.systemComboModifiers.contains(.control))
        XCTAssertTrue(ModifierFlags.systemComboModifiers.contains(.option))
    }

    func testCodableEncodesAsABareNumber() throws {
        let data = try JSONEncoder().encode(ModifierFlags([.command, .shift]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "1179648")
        XCTAssertEqual(try JSONDecoder().decode(ModifierFlags.self, from: data), [.command, .shift])
    }
}

// MARK: - KeyboardShortcut and its formatter

final class KeyboardShortcutTests: XCTestCase {

    private let formatter = KeyboardShortcutFormatter.fixed

    func testCodableRoundTripAndStoredShape() throws {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])
        let data = try JSONEncoder().encode(shortcut)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["keyCode"] as? Int, Int(KeyCodes.ansiC))
        XCTAssertEqual(json["modifiers"] as? UInt64, ModifierFlags.command.rawValue)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcut.self, from: data), shortcut)
    }

    func testEqualityAndHashing() {
        let a = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])
        let b = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])
        let c = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command, .shift])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    /// The five combinations the specification names.
    func testFormattingOfTheSpecifiedCombinations() {
        let cases: [(KeyboardShortcut, String)] = [
            (KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command]), "⌘ C"),
            (KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift]), "⇧ ⌘ 4"),
            (KeyboardShortcut(keyCode: KeyCodes.delete, modifiers: [.option]), "⌥ ⌫"),
            (KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option]), "⌃ ⌥ ←"),
            (KeyboardShortcut(keyCode: KeyCodes.ansiK, modifiers: [.command, .option, .shift]), "⌥ ⇧ ⌘ K"),
        ]
        for (shortcut, expected) in cases {
            XCTAssertEqual(formatter.string(for: shortcut), expected)
        }
    }

    func testModifiersAlwaysRenderInAppleOrderRegardlessOfHowTheyWereBuilt() {
        let built = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])
        let reversed = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.shift, .command])
        XCTAssertEqual(formatter.string(for: built), formatter.string(for: reversed))
        XCTAssertEqual(formatter.string(for: built), "⇧ ⌘ 4")
    }

    func testSymbolsAreReturnedAsSeparateKeyCaps() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])
        XCTAssertEqual(formatter.symbols(for: shortcut), ["⇧", "⌘", "4"])
    }

    func testSpokenDescriptionsUseWords() {
        XCTAssertEqual(
            formatter.spokenDescription(for: KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])),
            "Shift Command 4"
        )
        XCTAssertEqual(
            formatter.spokenDescription(for: KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option])),
            "Control Option Left Arrow"
        )
        XCTAssertEqual(
            formatter.spokenDescription(for: KeyboardShortcut(keyCode: KeyCodes.delete, modifiers: [.option])),
            "Option Delete"
        )
    }

    func testShortcutWithNoModifiersFormatsAsTheBareKey() {
        XCTAssertEqual(formatter.string(for: KeyboardShortcut(keyCode: KeyCodes.f13, modifiers: [])), "F13")
    }

    func testLayoutIndependentKeysWinOverTheLayout() {
        // Return, Escape and the F keys have no printable character; the special table must be used.
        XCTAssertEqual(formatter.keyLabel(for: KeyCodes.returnKey), "↩")
        XCTAssertEqual(formatter.keyLabel(for: KeyCodes.escape), "⎋")
        XCTAssertEqual(formatter.keyLabel(for: KeyCodes.forwardDelete), "⌦")
        XCTAssertEqual(formatter.keyLabel(for: KeyCodes.f1), "F1")
        XCTAssertEqual(formatter.keyLabel(for: KeyCodes.f20), "F20")
    }

    func testUnknownKeyCodeFallsBackToAVisibleCode() {
        let label = formatter.keyLabel(for: 0xFE)
        XCTAssertTrue(label.contains("0xFE"), "Expected the raw code to stay visible, got \(label)")
    }

    func testFunctionFlagKeysAreRecognised() {
        XCTAssertTrue(KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: []).impliesFunctionFlag)
        XCTAssertTrue(KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: []).impliesFunctionFlag)
        XCTAssertFalse(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: []).impliesFunctionFlag)
    }
}

// MARK: - Key codes

final class KeyCodesTests: XCTestCase {

    func testModifiersAreNotUsableAsPrimaryKeys() {
        for code in KeyCodes.modifierKeyCodes {
            XCTAssertTrue(KeyCodes.isModifier(code))
            XCTAssertFalse(KeyCodes.supportedKeyCodes.contains(code),
                           "Modifier 0x\(String(code, radix: 16)) must not be offered as a shortcut key")
        }
    }

    func testTheKeysTheSpecificationNamesAreAllSupported() {
        let required: [UInt16] = [
            KeyCodes.returnKey, KeyCodes.escape, KeyCodes.tab, KeyCodes.space,
            KeyCodes.delete, KeyCodes.forwardDelete,
            KeyCodes.leftArrow, KeyCodes.rightArrow, KeyCodes.upArrow, KeyCodes.downArrow,
            KeyCodes.home, KeyCodes.end, KeyCodes.pageUp, KeyCodes.pageDown,
            KeyCodes.f1, KeyCodes.f20,
            KeyCodes.ansiA, KeyCodes.ansiZ, KeyCodes.ansi0, KeyCodes.ansi9,
            KeyCodes.ansiComma, KeyCodes.ansiSlash,
            KeyCodes.keypad0, KeyCodes.keypadEnter,
        ]
        for code in required {
            XCTAssertTrue(KeyCodes.supportedKeyCodes.contains(code),
                          "0x\(String(code, radix: 16)) should be supported")
        }
    }

    func testKeyCodesAreDistinct() {
        // 0x5A is F20, not Keypad 8 — a classic transcription error worth pinning down.
        XCTAssertEqual(KeyCodes.f20, 0x5A)
        XCTAssertEqual(KeyCodes.keypad8, 0x5B)
        XCTAssertEqual(KeyCodes.forwardDelete, 0x75)
        XCTAssertEqual(KeyCodes.delete, 0x33)
        XCTAssertNotEqual(KeyCodes.delete, KeyCodes.forwardDelete)
    }

    func testEveryFunctionFlagKeyIsAlsoSupported() {
        for code in KeyCodes.functionFlagKeys {
            XCTAssertTrue(KeyCodes.supportedKeyCodes.contains(code))
        }
    }
}

// MARK: - Validation

final class ShortcutValidatorTests: XCTestCase {

    func testAModifierAloneIsRejected() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.shift, modifiers: [.shift])
        XCTAssertEqual(ShortcutValidator.validate(shortcut), .modifierOnly)
    }

    func testAnUnsupportedKeyIsRejectedWithItsCode() {
        let shortcut = KeyboardShortcut(keyCode: 0xFE, modifiers: [.command])
        XCTAssertEqual(ShortcutValidator.validate(shortcut), .unsupportedKey(0xFE))
    }

    func testOrdinaryShortcutsAreAccepted() {
        let valid = [
            KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command]),
            KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift]),
            KeyboardShortcut(keyCode: KeyCodes.delete, modifiers: [.option]),
            KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option]),
            KeyboardShortcut(keyCode: KeyCodes.f13, modifiers: []),
        ]
        for shortcut in valid {
            XCTAssertNil(ShortcutValidator.validate(shortcut), "\(shortcut) should be valid")
        }
    }

    func testEveryErrorExplainsItself() {
        let errors: [ShortcutValidationError] = [.modifierOnly, .unsupportedKey(0xFE), .ejectKey]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) needs a message")
        }
    }

    func testDangerousButLegalShortcutsProduceAWarningRatherThanAnError() {
        let quit = KeyboardShortcut(keyCode: KeyCodes.ansiQ, modifiers: [.command])
        XCTAssertNil(ShortcutValidator.validate(quit), "⌘Q is legal — it must not be blocked")
        XCTAssertFalse(ShortcutValidator.warnings(for: quit).isEmpty, "⌘Q should warn")
    }

    func testCapsLockWarns() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.capsLock, .command])
        XCTAssertFalse(ShortcutValidator.warnings(for: shortcut).isEmpty)
    }

    func testAnUnmodifiedLetterWarnsThatItJustTypes() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [])
        XCTAssertFalse(ShortcutValidator.warnings(for: shortcut).isEmpty)
    }

    func testAnOrdinaryShortcutHasNoWarnings() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])
        XCTAssertTrue(ShortcutValidator.warnings(for: shortcut).isEmpty)
    }
}

// MARK: - About credit

@MainActor
final class AboutCreditTests: XCTestCase {

    func testTheCreditNamesTheAuthorAndTheCountry() {
        let plain = String(AboutView.creditLine.characters)
        XCTAssertEqual(plain, "Made by Cacaio in Brazil")
    }

    func testTheAuthorsNameIsALinkToTheirGitHubPage() throws {
        let line = AboutView.creditLine
        let range = try XCTUnwrap(line.range(of: AboutView.authorName),
                                  "The author's name must appear in the credit line")
        XCTAssertEqual(line[range].link, AboutView.authorURL)
        XCTAssertEqual(AboutView.authorURL.absoluteString, "https://github.com/Cacaioo")
    }

    func testOnlyTheAuthorsNameIsLinked() {
        let line = AboutView.creditLine
        // "Brazil" is part of the sentence, not part of the link.
        let brazil = line.range(of: "Brazil")
        XCTAssertNotNil(brazil)
        XCTAssertNil(line[brazil!].link, "Only the name should be clickable")
    }

    func testTheLinkedNameIsUnderlinedSoItLooksClickable() throws {
        let line = AboutView.creditLine
        let range = try XCTUnwrap(line.range(of: AboutView.authorName))
        XCTAssertEqual(line[range].underlineStyle, .single)
    }
}
