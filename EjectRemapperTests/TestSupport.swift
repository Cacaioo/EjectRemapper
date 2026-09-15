//
//  TestSupport.swift
//  EjectRemapperTests
//
//  Shared doubles and helpers.
//
//  Ground rule for this whole target: a test may never post an event, create an event tap, lock the
//  screen, launch an app, register a login item, or write to the user's real preferences. The tests
//  are hosted by the app itself, so anything of that sort would happen on the developer's live
//  machine during `xcodebuild test`. Every seam needed to avoid it is here.
//

import AppKit
import CoreGraphics
import Foundation
import XCTest

@testable import EjectRemapper

// MARK: - Deterministic formatting

extension KeyboardShortcutFormatter {
    /// A formatter that always speaks US QWERTY, so assertions do not depend on the keyboard
    /// layout of whoever runs the tests.
    static let fixed = KeyboardShortcutFormatter(labels: USQWERTYKeyLabelProvider())
}

// MARK: - Action doubles

/// Records what it was asked to do instead of doing it.
final class SpyActionHandler: EjectActionHandler, @unchecked Sendable {
    struct Call: Equatable {
        let action: EjectAction
        let trigger: ActionTrigger
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    private var storedResets = 0

    var calls: [Call] { lock.withLock { storedCalls } }
    var resetCount: Int { lock.withLock { storedResets } }
    var triggers: [ActionTrigger] { calls.map(\.trigger) }

    func execute(action: EjectAction, trigger: ActionTrigger) {
        lock.withLock { storedCalls.append(Call(action: action, trigger: trigger)) }
    }

    func reset() {
        lock.withLock { storedResets += 1 }
    }

    func clear() {
        lock.withLock {
            storedCalls = []
            storedResets = 0
        }
    }
}

/// A repeat timer the test drives by hand: nothing fires until `fireOnce()` is called.
final class ManualRepeatTimer: RepeatTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var fireHandler: (@Sendable () -> Void)?
    private var expireHandler: (@Sendable () -> Void)?
    private var storedStarts = 0
    private var storedCancels = 0

    var startCount: Int { lock.withLock { storedStarts } }
    var cancelCount: Int { lock.withLock { storedCancels } }
    var isRunning: Bool { lock.withLock { fireHandler != nil } }

    func start(_ fire: @escaping @Sendable () -> Void, onExpire: @escaping @Sendable () -> Void) {
        lock.withLock {
            fireHandler = fire
            expireHandler = onExpire
            storedStarts += 1
        }
    }

    func cancel() {
        lock.withLock {
            fireHandler = nil
            expireHandler = nil
            storedCancels += 1
        }
    }

    /// Simulates one repeat tick.
    func fireOnce() {
        let handler = lock.withLock { fireHandler }
        handler?()
    }

    /// Simulates the safety cap being reached.
    func expire() {
        let handler = lock.withLock { expireHandler }
        lock.withLock {
            fireHandler = nil
            expireHandler = nil
        }
        handler?()
    }
}

/// A lock strategy that records whether it was consulted, and can pretend to be unavailable or to
/// fail. **The real strategy is never constructed in tests.**
final class FakeLockScreenStrategy: LockScreenStrategy, @unchecked Sendable {
    enum Behaviour {
        case succeeds
        case fails
        case unavailable
    }

    let name: String
    private let behaviour: Behaviour
    /// Named `mutex`, not `lock`, because `lock()` is the protocol requirement below.
    private let mutex = NSLock()
    private var storedAvailabilityChecks = 0
    private var storedLockAttempts = 0

    init(name: String, behaviour: Behaviour) {
        self.name = name
        self.behaviour = behaviour
    }

    var availabilityChecks: Int { mutex.withLock { storedAvailabilityChecks } }
    var lockAttempts: Int { mutex.withLock { storedLockAttempts } }

    func isAvailable() -> Bool {
        mutex.withLock { storedAvailabilityChecks += 1 }
        return behaviour != .unavailable
    }

    func lock() throws {
        mutex.withLock { storedLockAttempts += 1 }
        if behaviour == .fails {
            throw LockScreenError.unavailable(name)
        }
    }
}

/// An `EjectKeyDetector` the test feeds events into.
final class FakeEjectKeyDetector: EjectKeyDetector, @unchecked Sendable {
    weak var delegate: (any EjectKeyDetectorDelegate)?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// When set, `start()` throws it instead of starting.
    var startError: (any Error)?

    func start() throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// Delivers a press to the delegate and returns what the delegate decided.
    func send(_ event: KeyboardInputEvent, modifiers: ModifierFlags = []) -> EventDisposition? {
        delegate?.ejectKeyDetector(self, didDetect: event, modifiers: modifiers)
    }

    /// Delivers the auxiliary subtype-10 event.
    func sendAuxiliary(modifiers: ModifierFlags = []) -> EventDisposition? {
        delegate?.ejectKeyDetectorShouldSuppressAuxiliaryEvent(self, modifiers: modifiers)
    }
}

// MARK: - Preferences

/// A throwaway `UserDefaults` suite, wiped on creation and removed on teardown.
///
/// Tests must never touch `UserDefaults.standard`: that is the user's own configuration.
func makeScratchDefaults(_ name: String = #function) -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "com.cacaioo.EjectRemapper.tests.\(name.replacingOccurrences(of: "()", with: ""))"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

func destroyScratchDefaults(_ suiteName: String) {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    UserDefaults().removePersistentDomain(forName: suiteName)
}

// MARK: - Synthetic events

enum SyntheticEvent {

    /// Builds a `keyDown` `NSEvent` for the recorder tests. Never posted anywhere.
    static func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    static func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// Builds a system-defined media-key `CGEvent`, the shape the tap receives.
    ///
    /// Built in memory through AppKit and converted; it is never posted.
    static func systemDefined(keyType: Int,
                              isDown: Bool,
                              isRepeat: Bool = false,
                              subtype: Int = SystemDefinedEventDecoder.auxControlButtonsSubtype,
                              modifiers: NSEvent.ModifierFlags = []) -> CGEvent? {
        let data1 = SystemDefinedEventDecoder.auxData1(keyType: keyType, isDown: isDown, isRepeat: isRepeat)
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Int16(subtype),
            data1: data1,
            data2: -1
        )?.cgEvent
    }
}

// MARK: - Queue helpers

extension DispatchQueue {
    /// A serial queue for handler tests, matching how the dispatcher configures the real one.
    static func testActionQueue(_ label: String = "tests.actions") -> DispatchQueue {
        DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Blocks until everything already queued has run, so assertions see a settled state.
    func drain() {
        sync {}
    }
}

// MARK: - Generator

extension KeyboardEventGenerator {
    /// A generator for unit tests: posts into `poster` and treats the physical keyboard as holding
    /// `physical`, instead of reading the real HID state of whichever Mac runs the tests.
    convenience init(recording poster: any EventPosting, physical: ModifierFlags = []) {
        self.init(poster: poster, physicalModifiers: { physical })
    }
}
