//
//  LockScreenAction.swift
//  EjectRemapper
//
//  Lock the screen immediately, the way ⌃⌘Q does.
//

import CoreGraphics
import Foundation
import os

/// One way of locking the screen.
///
/// A chain of strategies rather than a single call, because the primary mechanism is a *private*
/// symbol: it is resolved at runtime and may simply disappear in a future macOS. When it does, the app
/// degrades to the documented ⌃⌘Q chord instead of doing nothing.
protocol LockScreenStrategy: Sendable {
    /// Short identifier used in logs, e.g. "login.framework".
    var name: String { get }
    /// Can this strategy run right now? Must have no side effect whatsoever — in particular it must
    /// never lock the screen to find out.
    func isAvailable() -> Bool
    /// Lock the screen, or throw so the next strategy gets a turn.
    func lock() throws
}

enum LockScreenError: Error, Equatable, LocalizedError {
    /// The strategy's mechanism is not present on this system.
    case unavailable(String)
    /// Refused because the process is running unit tests — locking the screen during a test run would
    /// take the machine away from whoever is at it.
    case suppressedInTests(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            return String(localized: "The \(name) lock mechanism is not available on this Mac.")
        case .suppressedInTests(let name):
            return "Lock strategy \(name) suppressed while running tests."
        }
    }
}

/// Calls `SACLockScreenImmediate` from `login.framework`.
///
/// Verified present on macOS 26.5.2 by resolving — and deliberately never calling — the symbol
/// (TECHNICAL_INVESTIGATION.md §6). It is `@convention(c) () -> Void`: no return value and no error
/// channel (CONTRACT_CORRECTIONS §6), so "success" here only means the call was made. This is the same
/// mechanism Hammerspoon and Caffeine use; it locks immediately regardless of the user's screen-saver
/// and password-grace settings, which `pmset displaysleepnow` and the screen saver do not.
///
/// The framework is `dlopen`ed lazily and never linked, so its removal degrades to the fallback rather
/// than preventing the app from launching.
struct LoginFrameworkLockStrategy: LockScreenStrategy {
    static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    static let symbolName = "SACLockScreenImmediate"

    let name = "login.framework"

    init() {}

    /// Resolves the symbol and throws it away. Resolution alone has no effect.
    func isAvailable() -> Bool {
        Self.resolveSymbol() != nil
    }

    func lock() throws {
        guard !TestEnvironment.isRunningTests else {
            throw LockScreenError.suppressedInTests(name)
        }
        guard let symbol = Self.resolveSymbol() else {
            throw LockScreenError.unavailable(name)
        }
        let lockScreenImmediate = unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
        lockScreenImmediate()
    }

    /// `dlopen` is reference-counted by dyld and the handle is intentionally never closed: the private
    /// framework stays mapped for the life of the process, and unmapping it while a call is in flight
    /// would be far worse than the few pages it costs.
    private static func resolveSymbol() -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
        return dlsym(handle, symbolName)
    }
}

/// Synthesizes ⌃⌘Q, which Apple documents as "Lock your screen".
///
/// There is no `com.apple.symbolichotkeys` entry for Lock Screen — every key in that domain was
/// enumerated during the investigation (12, 28–31, 52, 79–82, 160, 164, 184) and none of them is it —
/// so the chord is a fixed `loginwindow` hot key and must be hard-coded (CONTRACT_CORRECTIONS §7).
///
/// Sent as a complete chord through `KeyboardEventGenerator.press(_:)`, exactly as a person types it,
/// so the modifiers are released afterwards and cannot stay latched for the session.
struct SystemHotKeyLockStrategy: LockScreenStrategy {
    /// `kVK_ANSI_Q`, `Events.h:184`.
    static let qKeyCode: UInt16 = 0x0C
    static let modifiers: ModifierFlags = [.control, .command]

    let name = "⌃⌘Q"
    private let generator: KeyboardEventGenerator
    private let canPostEvents: @Sendable () -> Bool

    init(generator: KeyboardEventGenerator,
         canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() }) {
        self.generator = generator
        self.canPostEvents = canPostEvents
    }

    func isAvailable() -> Bool {
        canPostEvents()
    }

    func lock() throws {
        guard !TestEnvironment.isRunningTests else {
            throw LockScreenError.suppressedInTests(name)
        }
        guard canPostEvents() else {
            throw LockScreenError.unavailable(name)
        }
        generator.press(KeyboardShortcut(keyCode: Self.qKeyCode, modifiers: Self.modifiers))
    }
}

/// Runs the first lock strategy that works.
///
/// Key-down only: locking is not something to repeat, and the dispatcher's one-shot policy already
/// guarantees a single fire per press.
final class LockScreenAction: EjectActionHandler, @unchecked Sendable {
    private let strategies: [any LockScreenStrategy]

    init(strategies: [any LockScreenStrategy]) {
        self.strategies = strategies
    }

    func execute(action: EjectAction, trigger: ActionTrigger) {
        guard trigger == .keyDown else { return }
        for strategy in strategies {
            guard strategy.isAvailable() else {
                Log.actions.debug("Lock strategy \(strategy.name, privacy: .public) unavailable; trying the next one")
                continue
            }
            do {
                try strategy.lock()
                Log.actions.info("Locked the screen via \(strategy.name, privacy: .public)")
                return
            } catch {
                Log.actions.error("Lock strategy \(strategy.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.actions.error("Every lock-screen strategy failed")
    }

    /// Nothing is ever held down by this action.
    func reset() {}
}
