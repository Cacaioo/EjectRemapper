//
//  ActionTests.swift
//  EjectRemapperTests
//
//  Routing, the repeat and one-shot policy, and each handler's event sequence.
//

import CoreGraphics
import XCTest

@testable import EjectRemapper

// MARK: - Routing and policy

final class ActionDispatcherTests: XCTestCase {

    private var handlers: [EjectActionKind: SpyActionHandler]!
    private var dispatcher: ActionDispatcher!
    private var clock: TimeInterval = 0

    override func setUp() {
        super.setUp()
        clock = 0
        handlers = Dictionary(uniqueKeysWithValues: EjectActionKind.allCases.map { ($0, SpyActionHandler()) })

        let erased = handlers.mapValues { $0 as any EjectActionHandler }
        dispatcher = ActionDispatcher(
            handlers: erased,
            queue: .testActionQueue(),
            oneShotCooldown: 0.3,
            now: { [clockBox] in clockBox.value }
        )
    }

    /// The injected clock has to be readable from the action queue, so it lives in a box.
    private let clockBox = ClockBox()

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: TimeInterval = 0
        var value: TimeInterval {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private func spy(_ kind: EjectActionKind) -> SpyActionHandler { handlers[kind]! }

    private func settle() { dispatcher.queue.drain() }

    // MARK: Routing

    func testEachActionReachesItsOwnHandler() {
        let actions: [EjectAction] = [
            .forwardDelete, .lockScreen, .screenshot, .screenshotMenu,
            .customShortcut(KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command])),
            .original, .disabled,
        ]

        for action in actions {
            dispatcher.dispatch(.ejectKeyDown, action: action)
            settle()
            XCTAssertEqual(spy(action.kind).calls.count, 1, "\(action.kind) should have been called once")

            // And nothing else was touched.
            for other in EjectActionKind.allCases where other != action.kind {
                XCTAssertTrue(spy(other).calls.isEmpty, "\(other) should not have run for \(action.kind)")
            }

            handlers.values.forEach { $0.clear() }
            dispatcher.dispatch(.ejectKeyUp, action: action)
            settle()
            handlers.values.forEach { $0.clear() }
        }
    }

    func testInputEventsMapToTheRightTriggers() {
        dispatcher.dispatch(.ejectKeyDown, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyRepeat, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyUp, action: .forwardDelete)
        settle()
        XCTAssertEqual(spy(.forwardDelete).triggers, [.keyDown, .keyRepeat, .keyUp])
    }

    // MARK: One-shot policy

    func testAOneShotActionIgnoresRepeats() {
        dispatcher.dispatch(.ejectKeyDown, action: .lockScreen)
        dispatcher.dispatch(.ejectKeyRepeat, action: .lockScreen)
        dispatcher.dispatch(.ejectKeyRepeat, action: .lockScreen)
        settle()

        let downs = spy(.lockScreen).calls.filter { $0.trigger == .keyDown }
        XCTAssertEqual(downs.count, 1, "Holding the key must lock the screen exactly once")
        XCTAssertTrue(spy(.lockScreen).triggers.allSatisfy { $0 != .keyRepeat })
    }

    func testASecondKeyDownWhileStillHeldIsIgnored() {
        dispatcher.dispatch(.ejectKeyDown, action: .screenshot)
        dispatcher.dispatch(.ejectKeyDown, action: .screenshot)
        settle()
        XCTAssertEqual(spy(.screenshot).calls.filter { $0.trigger == .keyDown }.count, 1)
    }

    func testAOneShotActionRefiresAfterTheCooldown() {
        dispatcher.dispatch(.ejectKeyDown, action: .screenshot)
        dispatcher.dispatch(.ejectKeyUp, action: .screenshot)
        settle()

        // Immediately again: still inside the cooldown, so it is ignored.
        clockBox.value = 0.1
        dispatcher.dispatch(.ejectKeyDown, action: .screenshot)
        dispatcher.dispatch(.ejectKeyUp, action: .screenshot)
        settle()
        XCTAssertEqual(spy(.screenshot).calls.filter { $0.trigger == .keyDown }.count, 1,
                       "A press inside the cooldown must not fire again")

        // Well past the cooldown: it fires.
        clockBox.value = 1.0
        dispatcher.dispatch(.ejectKeyDown, action: .screenshot)
        settle()
        XCTAssertEqual(spy(.screenshot).calls.filter { $0.trigger == .keyDown }.count, 2)
    }

    // MARK: Repeating actions

    func testARepeatingActionSeesEveryTrigger() {
        dispatcher.dispatch(.ejectKeyDown, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyRepeat, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyRepeat, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyUp, action: .forwardDelete)
        settle()
        XCTAssertEqual(spy(.forwardDelete).triggers, [.keyDown, .keyRepeat, .keyRepeat, .keyUp])
    }

    func testARepeatingActionIsNotSubjectToTheCooldown() {
        dispatcher.dispatch(.ejectKeyDown, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyUp, action: .forwardDelete)
        dispatcher.dispatch(.ejectKeyDown, action: .forwardDelete)
        settle()
        XCTAssertEqual(spy(.forwardDelete).calls.filter { $0.trigger == .keyDown }.count, 2,
                       "Typing quickly must not be throttled")
    }

    // MARK: Changing action mid-press

    func testChangingTheActionWhileTheKeyIsHeldReleasesThePreviousHandler() {
        dispatcher.dispatch(.ejectKeyDown, action: .forwardDelete)
        settle()
        XCTAssertEqual(spy(.forwardDelete).resetCount, 0)

        // The user switches to Lock Screen before letting go.
        dispatcher.dispatch(.ejectKeyUp, action: .lockScreen)
        settle()
        XCTAssertEqual(spy(.forwardDelete).resetCount, 1,
                       "The forward-delete key must be released, not left held down")
    }

    func testResetReachesEveryHandler() {
        dispatcher.reset()
        settle()
        for kind in EjectActionKind.allCases {
            XCTAssertEqual(spy(kind).resetCount, 1)
        }
    }
}

// MARK: - Forward Delete

final class ForwardDeleteActionTests: XCTestCase {

    private var poster: RecordingEventPoster!
    private var timer: ManualRepeatTimer!
    private var action: ForwardDeleteAction!
    private var queue: DispatchQueue!

    override func setUp() {
        super.setUp()
        poster = RecordingEventPoster()
        timer = ManualRepeatTimer()
        queue = .testActionQueue("tests.forwardDelete")

        let generator = KeyboardEventGenerator(recording: poster)
        let heldTimer = timer!
        action = ForwardDeleteAction(
            generator: generator,
            queue: queue,
            makeTimer: { _ in heldTimer }
        )
    }

    func testKeyDownPressesForwardDeleteAndStartsRepeating() throws {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()

        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.type, .keyDown)
        XCTAssertEqual(event.keyCode, KeyCodes.forwardDelete)
        XCTAssertFalse(event.isAutorepeat)
        XCTAssertEqual(timer.startCount, 1, "Hold-to-repeat has to be generated in software")
    }

    func testTheTimerProducesAutorepeatMarkedPresses() throws {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        poster.reset()

        timer.fireOnce()
        queue.drain()

        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.type, .keyDown)
        XCTAssertEqual(event.keyCode, KeyCodes.forwardDelete)
        XCTAssertTrue(event.isAutorepeat)
    }

    func testKeyUpReleasesTheKeyAndStopsTheTimer() throws {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        poster.reset()

        action.execute(action: .forwardDelete, trigger: .keyUp)
        queue.drain()

        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.type, .keyUp)
        XCTAssertEqual(event.keyCode, KeyCodes.forwardDelete)
        XCTAssertGreaterThanOrEqual(timer.cancelCount, 1)
    }

    /// A modified ⏏ never reaches this action (it is passed through to macOS), so there is nothing to
    /// carry over: the whole press, repeats included, is a bare ⌦.
    func testForwardDeleteIsSentWithoutModifiers() {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        timer.fireOnce()
        queue.drain()
        action.execute(action: .forwardDelete, trigger: .keyUp)
        queue.drain()

        let keyEvents = poster.events.filter { $0.type != .flagsChanged }
        XCTAssertEqual(keyEvents.map(\.type), [.keyDown, .keyDown, .keyUp])
        XCTAssertTrue(keyEvents.allSatisfy { $0.modifiers.isDisjoint(with: .passThroughModifiers) },
                      "⌦ must never go out with ⌘, ⌃, ⌥ or ⇧")
        XCTAssertFalse(poster.events.contains(where: { $0.type == .flagsChanged && !$0.modifiers.isEmpty }),
                       "No modifier key may be pressed for Forward Delete")
    }

    func testResetReleasesAHeldKey() throws {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        poster.reset()

        action.reset()
        queue.drain()

        XCTAssertEqual(try XCTUnwrap(poster.events.first).type, .keyUp,
                       "A key left down would keep deleting forever")
    }

    func testResetWithNothingHeldPostsNothing() {
        action.reset()
        queue.drain()
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testTheSafetyCapReleasesTheKey() throws {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        poster.reset()

        timer.expire()
        queue.drain()

        XCTAssertEqual(try XCTUnwrap(poster.events.first).type, .keyUp,
                       "A lost key-up must not leave the key held down forever")
    }
}

// MARK: - Custom shortcut

final class CustomShortcutActionTests: XCTestCase {

    private var poster: RecordingEventPoster!
    private var timer: ManualRepeatTimer!
    private var action: CustomShortcutAction!
    private var queue: DispatchQueue!

    private let shortcut = KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift])

    override func setUp() {
        super.setUp()
        poster = RecordingEventPoster()
        timer = ManualRepeatTimer()
        queue = .testActionQueue("tests.customShortcut")

        let generator = KeyboardEventGenerator(recording: poster)
        let heldTimer = timer!
        action = CustomShortcutAction(generator: generator, queue: queue, makeTimer: { _ in heldTimer })
    }

    func testKeyDownPressesTheModifiersThenTheKey() {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()

        let events = poster.events
        XCTAssertEqual(events.count, 3, "⇧ down, ⌘ down, 4 down — the key is not released yet")
        XCTAssertEqual(events[0].keyCode, KeyCodes.shift)
        XCTAssertEqual(events[1].keyCode, KeyCodes.command)
        XCTAssertEqual(events[2].keyCode, KeyCodes.ansi4)
        XCTAssertEqual(events[2].type, .keyDown)
        XCTAssertTrue(events[2].modifiers.contains(.command))
        XCTAssertTrue(events[2].modifiers.contains(.shift))
    }

    func testKeyUpReleasesTheKeyThenTheModifiers() {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()
        poster.reset()

        action.execute(action: .customShortcut(shortcut), trigger: .keyUp)
        queue.drain()

        let events = poster.events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].type, .keyUp)
        XCTAssertEqual(events[0].keyCode, KeyCodes.ansi4)
        XCTAssertEqual(events[1].keyCode, KeyCodes.command)
        XCTAssertEqual(events[2].keyCode, KeyCodes.shift)
    }

    func testRepeatsRepressTheKeyWithTheSameChord() throws {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()
        poster.reset()

        timer.fireOnce()
        queue.drain()

        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.keyCode, KeyCodes.ansi4)
        XCTAssertTrue(event.isAutorepeat)
        XCTAssertTrue(event.modifiers.contains(.command))
    }

    func testResetReleasesBothTheKeyAndItsModifiers() {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()
        poster.reset()

        action.reset()
        queue.drain()

        let released = poster.events.map(\.keyCode)
        XCTAssertTrue(released.contains(KeyCodes.ansi4))
        XCTAssertTrue(released.contains(KeyCodes.command), "A stuck ⌘ would be the worst possible bug")
        XCTAssertTrue(released.contains(KeyCodes.shift))
    }

    func testTheShortcutThatWasPressedIsTheOneReleased() {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()
        poster.reset()

        // The user edits the shortcut in Settings while the key is still held.
        let edited = KeyboardShortcut(keyCode: KeyCodes.ansiZ, modifiers: [.control])
        action.execute(action: .customShortcut(edited), trigger: .keyUp)
        queue.drain()

        let released = poster.events.map(\.keyCode)
        XCTAssertTrue(released.contains(KeyCodes.ansi4), "The key that went down must be the key that comes up")
        XCTAssertFalse(released.contains(KeyCodes.ansiZ))
    }

    func testAKeyDownWithoutAShortcutPayloadDoesNothing() {
        action.execute(action: .forwardDelete, trigger: .keyDown)
        queue.drain()
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testTheSafetyCapReleasesTheChord() {
        action.execute(action: .customShortcut(shortcut), trigger: .keyDown)
        queue.drain()
        poster.reset()

        timer.expire()
        queue.drain()

        XCTAssertTrue(poster.events.map(\.keyCode).contains(KeyCodes.command))
    }
}

// MARK: - Lock screen

final class LockScreenActionTests: XCTestCase {

    func testTheFirstAvailableStrategyIsUsed() {
        let primary = FakeLockScreenStrategy(name: "primary", behaviour: .succeeds)
        let fallback = FakeLockScreenStrategy(name: "fallback", behaviour: .succeeds)
        let action = LockScreenAction(strategies: [primary, fallback])

        action.execute(action: .lockScreen, trigger: .keyDown)

        XCTAssertEqual(primary.lockAttempts, 1)
        XCTAssertEqual(fallback.lockAttempts, 0, "The fallback must not run when the primary works")
    }

    func testAnUnavailableStrategyIsSkipped() {
        let primary = FakeLockScreenStrategy(name: "primary", behaviour: .unavailable)
        let fallback = FakeLockScreenStrategy(name: "fallback", behaviour: .succeeds)
        let action = LockScreenAction(strategies: [primary, fallback])

        action.execute(action: .lockScreen, trigger: .keyDown)

        XCTAssertEqual(primary.lockAttempts, 0)
        XCTAssertEqual(fallback.lockAttempts, 1)
    }

    func testAFailingStrategyFallsThrough() {
        let primary = FakeLockScreenStrategy(name: "primary", behaviour: .fails)
        let fallback = FakeLockScreenStrategy(name: "fallback", behaviour: .succeeds)
        let action = LockScreenAction(strategies: [primary, fallback])

        action.execute(action: .lockScreen, trigger: .keyDown)

        XCTAssertEqual(primary.lockAttempts, 1)
        XCTAssertEqual(fallback.lockAttempts, 1)
    }

    func testEveryStrategyFailingDoesNotCrash() {
        let action = LockScreenAction(strategies: [
            FakeLockScreenStrategy(name: "a", behaviour: .fails),
            FakeLockScreenStrategy(name: "b", behaviour: .unavailable),
        ])
        action.execute(action: .lockScreen, trigger: .keyDown)   // must simply log
    }

    func testOnlyKeyDownLocks() {
        let strategy = FakeLockScreenStrategy(name: "only", behaviour: .succeeds)
        let action = LockScreenAction(strategies: [strategy])

        action.execute(action: .lockScreen, trigger: .keyRepeat)
        action.execute(action: .lockScreen, trigger: .keyUp)

        XCTAssertEqual(strategy.lockAttempts, 0, "Holding or releasing the key must never lock")
    }

    func testTheRealStrategyCanReportAvailabilityWithoutLocking() {
        // Resolving the symbol is safe; calling it is not, and this test never calls it.
        let strategy = LoginFrameworkLockStrategy()
        _ = strategy.isAvailable()
        XCTAssertEqual(strategy.name.isEmpty, false)
    }
}

// MARK: - Screenshots

final class ScreenshotActionTests: XCTestCase {

    func testItSendsTheUsersConfiguredChord() throws {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let hotKey = SymbolicHotKey(id: 28, isEnabled: true,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.command, .shift]))

        let action = ScreenshotAction(
            generator: generator,
            hotKeyProvider: { _ in hotKey },
            fallback: { XCTFail("The fallback must not run when the hot key is enabled") },
            canPostEvents: { true }
        )

        action.execute(action: .screenshot, trigger: .keyDown)

        let events = poster.events
        let keyDown = try XCTUnwrap(events.first(where: { $0.type == .keyDown }))
        XCTAssertEqual(keyDown.keyCode, KeyCodes.ansi3)
        XCTAssertTrue(keyDown.modifiers.isSuperset(of: [.command, .shift]))
        XCTAssertEqual(events.last?.modifiers, [],
                       "The chord's modifiers must be released, or every later Eject press arrives as ⇧⌘⏏")
    }

    func testItFollowsARemappedShortcut() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        // The user moved screenshots to ⌃⌥4.
        let hotKey = SymbolicHotKey(id: 28, isEnabled: true,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.control, .option]))

        let action = ScreenshotAction(generator: generator, hotKeyProvider: { _ in hotKey },
                                      fallback: {}, canPostEvents: { true })
        action.execute(action: .screenshot, trigger: .keyDown)

        let keyDown = poster.events.first(where: { $0.type == .keyDown })
        XCTAssertEqual(keyDown?.keyCode, KeyCodes.ansi4)
        XCTAssertTrue(keyDown?.modifiers.contains(.control) ?? false)
    }

    func testADisabledHotKeyUsesTheFallback() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let hotKey = SymbolicHotKey(id: 28, isEnabled: false,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.command, .shift]))

        let fellBack = FlagBox()
        let action = ScreenshotAction(generator: generator, hotKeyProvider: { _ in hotKey },
                                      fallback: { fellBack.value = true }, canPostEvents: { true })
        action.execute(action: .screenshot, trigger: .keyDown)

        XCTAssertTrue(fellBack.value)
        XCTAssertTrue(poster.events.isEmpty)
    }

    func testNothingIsPostedWithoutPermission() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let hotKey = SymbolicHotKey(id: 28, isEnabled: true,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.command, .shift]))

        let action = ScreenshotAction(generator: generator, hotKeyProvider: { _ in hotKey },
                                      fallback: {}, canPostEvents: { false })
        action.execute(action: .screenshot, trigger: .keyDown)

        XCTAssertTrue(poster.events.isEmpty, "Posting without permission silently does nothing; log instead")
    }

    func testOnlyKeyDownTakesAScreenshot() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let hotKey = SymbolicHotKey(id: 28, isEnabled: true,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi3, modifiers: [.command, .shift]))

        let action = ScreenshotAction(generator: generator, hotKeyProvider: { _ in hotKey },
                                      fallback: {}, canPostEvents: { true })
        action.execute(action: .screenshot, trigger: .keyRepeat)
        action.execute(action: .screenshot, trigger: .keyUp)

        XCTAssertTrue(poster.events.isEmpty)
    }
}

final class ScreenshotMenuActionTests: XCTestCase {

    func testItLaunchesTheScreenshotApp() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let launched = URLBox()

        let action = ScreenshotMenuAction(
            generator: generator,
            launch: { url, completion in
                launched.value = url
                completion(nil)
            }
        )
        action.execute(action: EjectAction.screenshotMenu, trigger: ActionTrigger.keyDown)

        XCTAssertEqual(launched.value, ScreenshotMenuAction.screenshotAppURL)
        XCTAssertTrue(poster.events.isEmpty, "No hot key is needed when the app launches")
    }

    func testAFailedLaunchFallsBackToTheHotKey() {
        let poster = RecordingEventPoster()
        let generator = KeyboardEventGenerator(recording: poster)
        let hotKey = SymbolicHotKey(id: 184, isEnabled: true,
                                    shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi5, modifiers: [.command, .shift]))

        let action = ScreenshotMenuAction(
            generator: generator,
            launch: { _, completion in
                completion(CocoaError(.fileNoSuchFile))
            },
            hotKeyProvider: { _ in hotKey },
            canPostEvents: { true }
        )
        action.execute(action: EjectAction.screenshotMenu, trigger: ActionTrigger.keyDown)

        XCTAssertEqual(poster.events.first(where: { $0.type == .keyDown })?.keyCode, KeyCodes.ansi5)
    }

    func testOnlyKeyDownOpensTheToolbar() {
        let launched = URLBox()
        let action = ScreenshotMenuAction(
            generator: KeyboardEventGenerator(recording: RecordingEventPoster()),
            launch: { url, completion in
                launched.value = url
                completion(nil)
            }
        )
        action.execute(action: EjectAction.screenshotMenu, trigger: ActionTrigger.keyRepeat)
        action.execute(action: EjectAction.screenshotMenu, trigger: ActionTrigger.keyUp)

        XCTAssertNil(launched.value)
    }
}

// MARK: - Passive

final class PassiveActionTests: XCTestCase {
    func testItDoesNothingAtAll() {
        let action = PassiveAction()
        action.execute(action: .original, trigger: .keyDown)
        action.execute(action: .disabled, trigger: .keyUp)
        action.reset()
    }
}

// MARK: - Small boxes for capturing from @Sendable closures

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?
    var value: URL? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
