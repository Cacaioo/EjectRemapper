//
//  IntegrationTests.swift
//  EjectRemapperTests
//
//  Settings persistence, permission handling, login items, and the disposition rules that decide
//  what happens to every Eject press. These are the tests that map onto the specification's
//  acceptance criteria.
//

import AppKit
import XCTest

@testable import EjectRemapper

// MARK: - Settings

@MainActor
final class AppSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let scratch = makeScratchDefaults("appSettings")
        defaults = scratch.defaults
        suiteName = scratch.suiteName
    }

    override func tearDown() {
        destroyScratchDefaults(suiteName)
        super.tearDown()
    }

    func testDefaultsAreSensibleOnFirstLaunch() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.isRemappingEnabled)
        XCTAssertTrue(settings.showMenuBarIcon)
        XCTAssertFalse(settings.hasPromptedForAccessibility)
        XCTAssertEqual(settings.actionKind, .forwardDelete)
        XCTAssertNil(settings.customShortcut)
    }

    func testEverySettingSurvivesARelaunch() {
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])

        let first = AppSettings(defaults: defaults)
        first.actionKind = .customShortcut
        first.customShortcut = shortcut
        first.isRemappingEnabled = false
        first.showMenuBarIcon = false
        first.hasPromptedForAccessibility = true

        // A second instance reads what the first wrote, which is what a relaunch does.
        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.actionKind, .customShortcut)
        XCTAssertEqual(second.customShortcut, shortcut)
        XCTAssertFalse(second.isRemappingEnabled)
        XCTAssertFalse(second.showMenuBarIcon)
        XCTAssertTrue(second.hasPromptedForAccessibility)
    }

    func testWritesReachTheStoreImmediately() {
        let settings = AppSettings(defaults: defaults)
        settings.actionKind = .lockScreen
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.actionKind), "lockScreen",
                       "There is no save button, so every change must be written through")
    }

    func testClearingTheShortcutRemovesItFromTheStore() {
        let settings = AppSettings(defaults: defaults)
        settings.customShortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])
        XCTAssertNotNil(defaults.data(forKey: AppSettings.Keys.customShortcut))

        settings.customShortcut = nil
        XCTAssertNil(defaults.data(forKey: AppSettings.Keys.customShortcut))
        XCTAssertNil(AppSettings(defaults: defaults).customShortcut)
    }

    func testResolvedActionMapsEveryKind() {
        let settings = AppSettings(defaults: defaults)
        let expected: [EjectActionKind: EjectAction] = [
            .forwardDelete: .forwardDelete,
            .lockScreen: .lockScreen,
            .screenshot: .screenshot,
            .screenshotMenu: .screenshotMenu,
            .original: .original,
            .disabled: .disabled,
        ]
        for (kind, action) in expected {
            settings.actionKind = kind
            XCTAssertEqual(settings.resolvedAction, action)
        }
    }

    func testCustomShortcutWithoutAShortcutFallsBackToDisabled() {
        let settings = AppSettings(defaults: defaults)
        settings.actionKind = .customShortcut
        settings.customShortcut = nil

        XCTAssertEqual(settings.resolvedAction, .disabled,
                       "Doing nothing is the honest reading of 'a custom shortcut, but there isn't one'")
        XCTAssertNotNil(settings.configurationWarning, "and the user must be told why")
    }

    func testCustomShortcutWithAShortcutResolvesToIt() {
        let settings = AppSettings(defaults: defaults)
        let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])
        settings.actionKind = .customShortcut
        settings.customShortcut = shortcut

        XCTAssertEqual(settings.resolvedAction, .customShortcut(shortcut))
        XCTAssertNil(settings.configurationWarning)
    }

    func testAnUnknownStoredActionFallsBackRatherThanFailing() {
        defaults.set("teleport", forKey: AppSettings.Keys.actionKind)
        XCTAssertEqual(AppSettings(defaults: defaults).actionKind, .forwardDelete,
                       "A downgrade from a future version must not break the app")
    }

    func testCorruptShortcutDataIsIgnored() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AppSettings.Keys.customShortcut)
        XCTAssertNil(AppSettings(defaults: defaults).customShortcut)
    }
}

// MARK: - Permissions

@MainActor
final class PermissionManagerTests: XCTestCase {

    func testGrantedRequiresBothTheCheckAndAWorkingTap() {
        let granted = PermissionManager(isTrusted: { true }, canCreateEventTap: { true },
                                        promptForAccess: { true }, openURL: { _ in true })
        granted.refresh()
        XCTAssertEqual(granted.status, .granted)
    }

    /// The revocation case: the system still says "trusted" but a tap can no longer be created.
    func testAStaleTrustedAnswerIsCaughtByTheTapProbe() {
        let stale = PermissionManager(isTrusted: { true }, canCreateEventTap: { false },
                                      promptForAccess: { true }, openURL: { _ in true })
        stale.refresh()
        XCTAssertEqual(stale.status, .denied,
                       "AXIsProcessTrusted can go stale; the tap probe is the reliable signal")
    }

    func testDeniedWhenNotTrusted() {
        let denied = PermissionManager(isTrusted: { false }, canCreateEventTap: { false },
                                       promptForAccess: { false }, openURL: { _ in true })
        denied.refresh()
        XCTAssertEqual(denied.status, .denied)
    }

    func testThePromptIsShownAtMostOncePerLaunch() {
        let prompts = CountBox()
        let manager = PermissionManager(
            isTrusted: { false },
            canCreateEventTap: { false },
            promptForAccess: { prompts.increment(); return false },
            openURL: { _ in true }
        )

        manager.requestAccess()
        manager.requestAccess()
        manager.requestAccess()

        XCTAssertEqual(prompts.value, 1, "Nagging on every call would be obnoxious")
        XCTAssertTrue(manager.hasPromptedThisLaunch)
    }

    func testNoPromptWhenAccessIsAlreadyGranted() {
        let prompts = CountBox()
        let manager = PermissionManager(
            isTrusted: { true },
            canCreateEventTap: { true },
            promptForAccess: { prompts.increment(); return true },
            openURL: { _ in true }
        )

        manager.requestAccess()
        XCTAssertEqual(prompts.value, 0)
    }

    func testOpeningSettingsUsesTheModernURLFirst() {
        let opened = URLBox()
        let manager = PermissionManager(
            isTrusted: { false }, canCreateEventTap: { false }, promptForAccess: { false },
            openURL: { url in
                opened.value = url
                return true
            }
        )

        manager.openAccessibilitySettings()

        let string = opened.value?.absoluteString ?? ""
        XCTAssertTrue(string.contains("Privacy_Accessibility"), "Got: \(string)")
        XCTAssertTrue(string.contains("com.apple.settings.PrivacySecurity.extension"),
                      "macOS 13+ uses the new pane identifier. Got: \(string)")
    }

    func testTheLegacyURLIsTriedWhenTheModernOneFails() {
        let attempts = URLListBox()
        let manager = PermissionManager(
            isTrusted: { false }, canCreateEventTap: { false }, promptForAccess: { false },
            openURL: { url in
                attempts.append(url)
                return false            // nothing handles it
            }
        )

        manager.openAccessibilitySettings()
        XCTAssertEqual(attempts.value.count, 2, "Both the modern and the legacy URL should be tried")
    }

    func testStatusStartsUnknownBeforeAnyCheck() {
        let manager = PermissionManager(isTrusted: { true }, canCreateEventTap: { true },
                                        promptForAccess: { true }, openURL: { _ in true })
        XCTAssertEqual(manager.status, .unknown)
    }
}

// MARK: - Login items

@MainActor
final class LoginItemManagerTests: XCTestCase {

    func testStatusMapping() {
        XCTAssertEqual(LoginItemManager.map(.enabled), .enabled)
        XCTAssertEqual(LoginItemManager.map(.notRegistered), .disabled)
        XCTAssertEqual(LoginItemManager.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemManager.map(.notFound), .notFound)
    }

    func testAnInertServiceReportsItsConfiguredStatus() {
        let manager = LoginItemManager(service: InertLoginItemService(status: .enabled))
        manager.refresh()
        XCTAssertTrue(manager.isEnabled)
    }

    func testRequiresApprovalIsNotAnError() {
        let manager = LoginItemManager(service: InertLoginItemService(status: .requiresApproval))
        manager.refresh()
        XCTAssertTrue(manager.needsApproval,
                      "Registration succeeded; the user just has to allow it in System Settings")
        XCTAssertFalse(manager.isEnabled)
    }

    func testDisabledIsReportedForBothNotRegisteredAndNotFound() {
        let notRegistered = LoginItemManager(service: InertLoginItemService(status: .notRegistered))
        notRegistered.refresh()
        XCTAssertFalse(notRegistered.isEnabled)

        // macOS reports .notFound after a user switches the item off themselves.
        let notFound = LoginItemManager(service: InertLoginItemService(status: .notFound))
        notFound.refresh()
        XCTAssertFalse(notFound.isEnabled)
    }
}

// MARK: - Dispositions: what happens to each press

@MainActor
final class KeyboardEventManagerTests: XCTestCase {

    private var suiteName: String!
    private var settings: AppSettings!
    private var permissions: PermissionManager!
    private var detector: FakeEjectKeyDetector!
    private var handlers: [EjectActionKind: SpyActionHandler]!
    private var dispatcher: ActionDispatcher!
    private var manager: KeyboardEventManager!

    override func setUp() {
        super.setUp()
        let scratch = makeScratchDefaults("keyboardManager")
        suiteName = scratch.suiteName
        settings = AppSettings(defaults: scratch.defaults)

        permissions = PermissionManager(isTrusted: { true }, canCreateEventTap: { true },
                                        promptForAccess: { true }, openURL: { _ in true })
        permissions.refresh()

        detector = FakeEjectKeyDetector()
        handlers = Dictionary(uniqueKeysWithValues: EjectActionKind.allCases.map { ($0, SpyActionHandler()) })
        dispatcher = ActionDispatcher(handlers: handlers.mapValues { $0 as any EjectActionHandler },
                                      queue: .testActionQueue("tests.manager"))
        manager = KeyboardEventManager(settings: settings, permissions: permissions,
                                       detector: detector, dispatcher: dispatcher)
        manager.start()
    }

    override func tearDown() {
        manager.stop()
        destroyScratchDefaults(suiteName)
        super.tearDown()
    }

    private func settle() { dispatcher.queue.drain() }

    // MARK: Suppression

    func testARemappedPressIsSuppressedAndDispatched() {
        settings.actionKind = .forwardDelete

        XCTAssertEqual(detector.send(.ejectKeyDown), .suppress,
                       "The original Eject event must not also reach macOS")
        settle()
        XCTAssertEqual(handlers[.forwardDelete]!.calls.count, 1)
    }

    /// Acceptance test G.
    func testOriginalFunctionPassesTheEventThroughUntouched() {
        settings.actionKind = .original

        XCTAssertEqual(detector.send(.ejectKeyDown), .passThrough)
        settle()
        XCTAssertTrue(handlers.values.allSatisfy { $0.calls.isEmpty },
                      "Original Function must not run any action")
    }

    /// Acceptance test H.
    func testDisabledSwallowsTheEventAndRunsNothing() {
        settings.actionKind = .disabled

        XCTAssertEqual(detector.send(.ejectKeyDown), .suppress)
        settle()
        XCTAssertTrue(handlers.values.allSatisfy { $0.calls.isEmpty })
    }

    func testEveryActionProducesTheExpectedDisposition() {
        let expected: [EjectActionKind: EventDisposition] = [
            .forwardDelete: .suppress,
            .lockScreen: .suppress,
            .screenshot: .suppress,
            .screenshotMenu: .suppress,
            .disabled: .suppress,
            .original: .passThrough,
        ]
        for (kind, disposition) in expected {
            settings.actionKind = kind
            XCTAssertEqual(detector.send(.ejectKeyDown), disposition, "for \(kind)")
            _ = detector.send(.ejectKeyUp)
            settle()
        }
    }

    // MARK: System chords

    func testEveryModifiedPressIsPassedThrough() {
        settings.actionKind = .forwardDelete

        // ⌃⇧⏏ display sleep, ⌥⌘⏏ sleep, ⌃⏏ power dialog, ⌃⌘⏏ restart, ⌃⌥⌘⏏ shut down; then every
        // single modifier, including ⌥ alone, which is not delete-word-forward.
        let chords: [ModifierFlags] = [
            [.control, .shift],
            [.option, .command],
            [.control],
            [.control, .command],
            [.control, .option, .command],
            [.shift],
            [.command],
            [.option],
        ]

        for chord in chords {
            XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: chord), .passThrough,
                           "A press with \(chord.symbol) held must keep its system meaning")
        }
        settle()
        XCTAssertTrue(handlers.values.allSatisfy { $0.calls.isEmpty },
                      "No action may run for a modified press")
    }

    func testAnUnmodifiedPressIsStillRemapped() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: []), .suppress)
    }

    // MARK: The auxiliary event

    func testTheAuxiliaryEventIsSuppressedButNeverRunsAnAction() {
        settings.actionKind = .lockScreen

        XCTAssertEqual(detector.sendAuxiliary(), .suppress)
        settle()
        XCTAssertTrue(handlers[.lockScreen]!.calls.isEmpty,
                      "The subtype-8 pair already fires the action; this must not double it")
    }

    func testTheAuxiliaryEventPassesThroughInOriginalFunction() {
        settings.actionKind = .original
        XCTAssertEqual(detector.sendAuxiliary(), .passThrough)
    }

    func testTheAuxiliaryEventRespectsTheModifierRule() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.sendAuxiliary(modifiers: [.control, .shift]), .passThrough)
    }

    // MARK: Recording

    func testAPressWhileRecordingIsSwallowedAndRunsNothing() {
        settings.actionKind = .lockScreen
        manager.isRecordingShortcut = true

        XCTAssertEqual(detector.send(.ejectKeyDown), .suppress)
        settle()
        XCTAssertTrue(handlers[.lockScreen]!.calls.isEmpty,
                      "Recording a shortcut must not lock the screen")
    }

    func testTheUIIsToldWhenEjectIsPressedWhileRecording() {
        let notified = expectation(description: "recorder notified")
        manager.onEjectPressedDuringRecording = { notified.fulfill() }
        manager.isRecordingShortcut = true

        _ = detector.send(.ejectKeyDown)

        wait(for: [notified], timeout: 2)
    }

    func testNormalBehaviourResumesAfterRecordingEnds() {
        settings.actionKind = .forwardDelete
        manager.isRecordingShortcut = true
        _ = detector.send(.ejectKeyDown)
        manager.isRecordingShortcut = false

        XCTAssertEqual(detector.send(.ejectKeyDown), .suppress)
        settle()
        XCTAssertFalse(handlers[.forwardDelete]!.calls.isEmpty)
    }

    // MARK: Acceptance test F — no restart needed

    func testChangingTheActionTakesEffectOnTheVeryNextPress() {
        settings.actionKind = .forwardDelete
        _ = detector.send(.ejectKeyDown)
        _ = detector.send(.ejectKeyUp)
        settle()
        XCTAssertFalse(handlers[.forwardDelete]!.calls.isEmpty)

        // The user picks Lock Screen. Nothing is restarted.
        settings.actionKind = .lockScreen
        handlers.values.forEach { $0.clear() }

        _ = detector.send(.ejectKeyDown)
        settle()

        XCTAssertFalse(handlers[.lockScreen]!.calls.isEmpty,
                       "The new action must apply immediately, with no relaunch")
        XCTAssertTrue(handlers[.forwardDelete]!.calls.isEmpty,
                      "The old action must not run again")
    }

    func testChangingTheActionReleasesAnythingTheOldHandlerHeld() {
        settings.actionKind = .forwardDelete
        _ = detector.send(.ejectKeyDown)
        settle()

        settings.actionKind = .lockScreen
        settle()

        XCTAssertGreaterThan(handlers[.forwardDelete]!.resetCount, 0,
                             "Switching actions mid-press must not leave a key held down")
    }

    func testClearingTheCustomShortcutFallsBackToDoingNothing() {
        settings.actionKind = .customShortcut
        settings.customShortcut = nil

        XCTAssertEqual(detector.send(.ejectKeyDown), .suppress)
        settle()
        XCTAssertTrue(handlers[.customShortcut]!.calls.isEmpty)
    }

    // MARK: Lifecycle

    func testTheDetectorRunsWhenEnabledAndPermitted() {
        XCTAssertTrue(detector.isRunning)
        XCTAssertEqual(manager.state, .active)
    }

    func testTurningRemappingOffStopsTheDetector() {
        settings.isRemappingEnabled = false
        manager.start()

        XCTAssertFalse(detector.isRunning)
        XCTAssertEqual(manager.state, .inactive(.disabledByUser))
    }

    func testWithoutPermissionTheDetectorDoesNotRun() {
        let denied = PermissionManager(isTrusted: { false }, canCreateEventTap: { false },
                                       promptForAccess: { false }, openURL: { _ in true })
        denied.refresh()

        let detector = FakeEjectKeyDetector()
        let manager = KeyboardEventManager(settings: settings, permissions: denied,
                                           detector: detector, dispatcher: dispatcher)
        manager.start()

        XCTAssertFalse(detector.isRunning)
        XCTAssertEqual(manager.state, .inactive(.permissionMissing))
    }

    func testAFailureToStartIsReportedAndDoesNotCrash() {
        let failing = FakeEjectKeyDetector()
        failing.startError = EventTapError.creationFailed

        let manager = KeyboardEventManager(settings: settings, permissions: permissions,
                                           detector: failing, dispatcher: dispatcher)
        manager.start()

        guard case .failed(let message) = manager.state else {
            return XCTFail("Expected a failed state, got \(manager.state)")
        }
        XCTAssertFalse(message.isEmpty, "The user needs to be told something actionable")
    }

    func testRetryRebuildsTheDetector() {
        let failing = FakeEjectKeyDetector()
        failing.startError = EventTapError.creationFailed

        let manager = KeyboardEventManager(settings: settings, permissions: permissions,
                                           detector: failing, dispatcher: dispatcher)
        manager.start()

        // Whatever was wrong is fixed.
        failing.startError = nil
        manager.retry()

        XCTAssertTrue(failing.isRunning)
        XCTAssertEqual(manager.state, .active)
    }

    func testStoppingLeavesNothingRunning() {
        manager.stop()
        XCTAssertFalse(detector.isRunning)
        XCTAssertEqual(manager.state, .inactive(.notStarted))
    }

    func testStartingTwiceDoesNotStartTheDetectorTwice() {
        manager.start()
        manager.start()
        XCTAssertEqual(detector.startCount, 1, "The tap must be created exactly once")
    }
}

// MARK: - Counting box

final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

final class URLListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var value: [URL] { lock.withLock { storage } }
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
}
