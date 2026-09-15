//
//  ActionSwitchingTests.swift
//  EjectRemapperTests
//
//  Regression tests for switching the Eject action at runtime, written against the bug where
//  selecting Screenshot broke every later action until the app was relaunched.
//
//  The bug lived outside the app's own memory: the window server keeps the modifier flags of the
//  most recently posted keyboard event as the session's modifier state, and stamps them onto the
//  next hardware event. That was measured on macOS 26.5 with a probe that posted ⇧⌘F20 exactly as
//  the screenshot action did and then read CGEventSource.flagsState — ⇧⌘ stayed latched until a
//  flags-changed event released them. `SimulatedSessionPoster` models that one behaviour so the
//  whole press → dispatch → post → next press loop can be exercised without touching the real
//  window server.
//

import CoreGraphics
import XCTest

@testable import EjectRemapper

/// Models the window server rule the bug hinges on: the session's modifier flags become the flags
/// of the most recently posted keyboard event (key down, key up or flags changed).
final class SimulatedSessionPoster: EventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedModifiers: ModifierFlags
    private var storedEvents: [PostedEvent] = []

    /// - Parameter physical: what the user is really holding before anything is posted.
    init(physical: ModifierFlags = []) {
        storedModifiers = physical
    }

    /// The flags a hardware event would be stamped with right now.
    var modifiers: ModifierFlags { lock.withLock { storedModifiers } }
    var events: [PostedEvent] { lock.withLock { storedEvents } }

    func post(_ event: CGEvent) {
        let recorded = PostedEvent(event: event)
        lock.withLock {
            storedEvents.append(recorded)
            storedModifiers = recorded.modifiers
        }
    }

    func clearEvents() {
        lock.withLock { storedEvents = [] }
    }
}

final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

@MainActor
final class ActionSwitchingTests: XCTestCase {

    private var suiteName: String!
    private var settings: AppSettings!
    private var session: SimulatedSessionPoster!
    private var detector: FakeEjectKeyDetector!
    private var dispatcher: ActionDispatcher!
    private var manager: KeyboardEventManager!
    private var lockStrategy: FakeLockScreenStrategy!
    private var launches: LaunchCounter!

    private let recordedShortcut = KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])

    override func setUp() {
        super.setUp()
        let scratch = makeScratchDefaults("actionSwitching")
        suiteName = scratch.suiteName
        settings = AppSettings(defaults: scratch.defaults)
        settings.customShortcut = recordedShortcut

        let permissions = PermissionManager(isTrusted: { true }, canCreateEventTap: { true },
                                            promptForAccess: { true }, openURL: { _ in true })
        permissions.refresh()

        session = SimulatedSessionPoster()
        let session = self.session!
        let generator = KeyboardEventGenerator(poster: session, physicalModifiers: { session.modifiers })
        let queue = DispatchQueue.testActionQueue("tests.actionSwitching")

        lockStrategy = FakeLockScreenStrategy(name: "fake lock", behaviour: .succeeds)
        launches = LaunchCounter()
        let launches = self.launches!

        let screenshotHotKey = SymbolicHotKey(
            id: 28, isEnabled: true,
            shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.shift, .command]))

        let handlers: [EjectActionKind: any EjectActionHandler] = [
            // The real handlers, wired as in AppState.live(); only true system side effects are doubled.
            .forwardDelete: ForwardDeleteAction(generator: generator, queue: queue,
                                                makeTimer: { _ in ManualRepeatTimer() }),
            .customShortcut: CustomShortcutAction(generator: generator, queue: queue,
                                                  makeTimer: { _ in ManualRepeatTimer() }),
            .lockScreen: LockScreenAction(strategies: [lockStrategy]),
            .screenshot: ScreenshotAction(generator: generator,
                                          hotKeyProvider: { _ in screenshotHotKey },
                                          fallback: {}, canPostEvents: { true }),
            .screenshotMenu: ScreenshotMenuAction(generator: generator,
                                                  launch: { _, completion in
                                                      launches.increment()
                                                      completion(nil)
                                                  },
                                                  canPostEvents: { true }),
            .original: PassiveAction(),
            .disabled: PassiveAction(),
        ]

        // Cooldown 0 so quick successive presses in these tests are never throttled by wall time.
        dispatcher = ActionDispatcher(handlers: handlers, queue: queue, oneShotCooldown: 0)
        detector = FakeEjectKeyDetector()
        manager = KeyboardEventManager(settings: settings, permissions: permissions,
                                       detector: detector, dispatcher: dispatcher)
        manager.start()
    }

    override func tearDown() {
        manager.stop()
        destroyScratchDefaults(suiteName)
        super.tearDown()
    }

    // MARK: Helpers

    private func settle() { dispatcher.queue.drain() }

    /// A physical Eject press. Like real hardware events, both halves are stamped with whatever
    /// modifier flags the session currently holds.
    @discardableResult
    private func pressEject() -> EventDisposition? {
        let down = detector.send(.ejectKeyDown, modifiers: session.modifiers)
        settle()
        _ = detector.send(.ejectKeyUp, modifiers: session.modifiers)
        settle()
        return down
    }

    private func keyDowns(_ keyCode: UInt16, holding modifiers: ModifierFlags = []) -> Int {
        session.events.filter {
            $0.type == .keyDown && $0.keyCode == keyCode && $0.modifiers.isSuperset(of: modifiers)
        }.count
    }

    private func assertSessionIsClean(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(session.modifiers.isEmpty,
                      "\(message) — session still holds \(session.modifiers.symbol)", file: file, line: line)
    }

    // MARK: The reported sequence

    /// Forward Delete → Screenshot → Forward Delete, with no restart in between.
    func testSwitchingAwayFromScreenshotWorksWithoutARestart() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(pressEject(), .suppress)
        XCTAssertEqual(keyDowns(KeyCodes.forwardDelete), 1)

        settings.actionKind = .screenshot
        XCTAssertEqual(pressEject(), .suppress)
        XCTAssertEqual(keyDowns(KeyCodes.ansi3, holding: [.shift, .command]), 1, "The screenshot chord must be sent")
        assertSessionIsClean("Taking a screenshot must not leave its modifiers latched")

        settings.actionKind = .forwardDelete
        session.clearEvents()
        XCTAssertEqual(pressEject(), .suppress,
                       "The next press must reach Forward Delete, not pass through as ⇧⌘⏏")
        XCTAssertEqual(keyDowns(KeyCodes.forwardDelete), 1)
    }

    func testScreenshotCanBeTakenRepeatedly() {
        settings.actionKind = .screenshot
        for press in 1...3 {
            XCTAssertEqual(pressEject(), .suppress, "press \(press)")
        }
        XCTAssertEqual(keyDowns(KeyCodes.ansi3, holding: [.shift, .command]), 3)
    }

    // MARK: Every transition

    /// Every ordered pair of actions, including re-selecting the same one: after using the first,
    /// the second must take effect on its very first press, and nothing may be left latched.
    func testEveryActionWorksAfterEveryOtherAction() {
        let kinds = EjectActionKind.allCases
        for first in kinds {
            for second in kinds {
                settings.actionKind = first
                pressEject()

                settings.actionKind = second
                session.clearEvents()
                let lockBefore = lockStrategy.lockAttempts
                let launchesBefore = launches.value

                let disposition = pressEject()
                let context = "\(first.rawValue) → \(second.rawValue)"

                switch second {
                case .original:
                    XCTAssertEqual(disposition, .passThrough, context)
                case .disabled:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertTrue(session.events.isEmpty, "\(context): Disabled must post nothing")
                case .forwardDelete:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertEqual(keyDowns(KeyCodes.forwardDelete), 1, context)
                case .screenshot:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertEqual(keyDowns(KeyCodes.ansi3, holding: [.shift, .command]), 1, context)
                case .screenshotMenu:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertEqual(launches.value, launchesBefore + 1, context)
                case .lockScreen:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertEqual(lockStrategy.lockAttempts, lockBefore + 1, context)
                case .customShortcut:
                    XCTAssertEqual(disposition, .suppress, context)
                    XCTAssertEqual(keyDowns(recordedShortcut.keyCode, holding: [.command]), 1, context)
                }
                assertSessionIsClean(context)
            }
        }
        XCTAssertEqual(detector.startCount, 1, "Switching actions must never create a second event tap")
    }

    // MARK: Press pairing

    /// A key-up must always reach the handler that received the key-down. If the user touches ⇧
    /// while holding Eject, the key-up arrives carrying ⇧; passing it through would leave Forward
    /// Delete held down, auto-repeating until the safety cap.
    func testAKeyUpCarryingAModifierStillReleasesTheHeldKey() {
        settings.actionKind = .forwardDelete

        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: []), .suppress)
        settle()
        XCTAssertEqual(detector.send(.ejectKeyUp, modifiers: [.shift]), .suppress,
                       "The key-up of a press the app took must also be taken")
        settle()

        let releases = session.events.filter { $0.type == .keyUp && $0.keyCode == KeyCodes.forwardDelete }
        XCTAssertEqual(releases.count, 1, "Forward Delete must be released, not left repeating")
    }

    /// A press that macOS saw go down must also come up through macOS, so the system never sees
    /// half a key press.
    func testAKeyUpOfAPassedThroughPressIsPassedThrough() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: [.control, .shift]), .passThrough)
        XCTAssertEqual(detector.send(.ejectKeyUp, modifiers: []), .passThrough)
        settle()
        XCTAssertTrue(session.events.isEmpty)
    }

    /// Switching action between key-down and key-up: the old handler is released immediately, and
    /// the orphaned key-up is not delivered to the new action.
    func testAKeyUpAfterAnActionSwitchIsNotDeliveredToTheNewAction() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: []), .suppress)
        settle()

        settings.actionKind = .lockScreen
        settle()
        XCTAssertEqual(session.events.filter { $0.type == .keyUp && $0.keyCode == KeyCodes.forwardDelete }.count, 1,
                       "Forward Delete must be released the moment the action changes")

        XCTAssertEqual(detector.send(.ejectKeyUp, modifiers: []), .suppress,
                       "The rest of a press macOS never saw start must not leak through")
        settle()
        XCTAssertEqual(lockStrategy.lockAttempts, 0)

        // And the new action works on the next press.
        XCTAssertEqual(pressEject(), .suppress)
        XCTAssertEqual(lockStrategy.lockAttempts, 1)
    }

    // MARK: Lifecycle of the tap

    /// Turning remapping off while Forward Delete is held: the tap goes away and no key-up will ever
    /// arrive, so the key must be released at once rather than repeating until the safety cap.
    func testDisablingRemappingWhileAKeyIsHeldReleasesIt() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: []), .suppress)
        settle()

        settings.isRemappingEnabled = false
        settle()

        XCTAssertFalse(detector.isRunning)
        XCTAssertEqual(session.events.filter { $0.type == .keyUp && $0.keyCode == KeyCodes.forwardDelete }.count, 1,
                       "Forward Delete must be released the moment the tap stops")
        assertSessionIsClean("Stopping must not leave anything latched")
    }

    /// If a key-up is ever lost, the next key-down releases the stuck press before starting its own.
    func testALostKeyUpIsRecoveredByTheNextPress() {
        settings.actionKind = .forwardDelete
        XCTAssertEqual(detector.send(.ejectKeyDown, modifiers: []), .suppress)
        settle()

        // The key-up never arrives. The next press starts.
        XCTAssertEqual(pressEject(), .suppress)

        let ups = session.events.filter { $0.type == .keyUp && $0.keyCode == KeyCodes.forwardDelete }.count
        XCTAssertEqual(keyDowns(KeyCodes.forwardDelete), 2)
        XCTAssertEqual(ups, 2, "Every Forward Delete that went down must come up")
        assertSessionIsClean("Recovering a lost key-up")
    }
}
