//
//  KeyRepeatTimer.swift
//  EjectRemapper
//
//  Software key repeat, because the hardware never repeats Eject.
//

import AppKit
import Foundation
import os

/// The repeat clock an action uses while the Eject key is held.
///
/// Exists as a protocol purely so tests can drive `ForwardDeleteAction` / `CustomShortcutAction`
/// deterministically without a real `DispatchSourceTimer` — nothing in the app substitutes it.
protocol RepeatTimer: AnyObject, Sendable {
    /// Begin repeating. `fire` runs after the initial delay and then every interval; `onExpire` runs
    /// once if the safety cap is reached, after which the timer has already cancelled itself.
    func start(_ fire: @escaping @Sendable () -> Void, onExpire: @escaping @Sendable () -> Void)
    /// Stop repeating. Idempotent, safe from the timer's own handler.
    func cancel()
}

/// Generates hold-to-repeat for actions that should behave like a real key.
///
/// Holding the Eject key produces exactly one key-down and one key-up: `IOHIDKeyboardFilter.mm:1353-1372`
/// (`isNotRepeated`) excludes Consumer/Eject from auto-repeat and the legacy kernel path agrees
/// (`IOHIKeyboard.cpp:602-608`). So repeat has to be synthesised. The cadence comes from
/// `NSEvent.keyRepeatDelay` / `NSEvent.keyRepeatInterval` so that holding ⏏ feels exactly like holding
/// the key the user remapped it to.
///
/// The `maxDuration` cap is the important safety property: the only thing that stops the repeat is the
/// Eject key-up, and a key-up can be lost (tap disabled by timeout, app suspended, session switch). A
/// lost key-up without the cap would leave Forward Delete — or worse, ⌘ — held down forever.
final class KeyRepeatTimer: RepeatTimer, @unchecked Sendable {
    private let guardedQueue: ActionQueueGuard
    private let initialDelay: TimeInterval
    private let interval: TimeInterval
    private let maxDuration: TimeInterval

    /// Both sources live on the action queue, so all state below is queue-confined.
    private var repeatSource: DispatchSourceTimer?
    private var expirySource: DispatchSourceTimer?

    /// - Parameters:
    ///   - queue: the dispatcher's serial action queue; every callback is delivered on it.
    ///   - initialDelay: seconds before the first repeat (`NSEvent.keyRepeatDelay`).
    ///   - interval: seconds between repeats (`NSEvent.keyRepeatInterval`).
    ///   - maxDuration: hard cap after which the key is force-released. 10 s is far longer than any
    ///     deliberate hold and far shorter than "forever".
    init(queue: DispatchQueue,
         initialDelay: TimeInterval,
         interval: TimeInterval,
         maxDuration: TimeInterval = 10) {
        self.guardedQueue = ActionQueueGuard(queue)
        self.initialDelay = max(0, initialDelay)
        self.interval = max(0.001, interval)
        self.maxDuration = maxDuration
    }

    func start(_ fire: @escaping @Sendable () -> Void, onExpire: @escaping @Sendable () -> Void) {
        guardedQueue.sync {
            self.cancelLocked()

            let repeater = DispatchSource.makeTimerSource(queue: self.guardedQueue.queue)
            repeater.schedule(deadline: .now() + self.initialDelay,
                              repeating: self.interval,
                              leeway: .milliseconds(2))
            repeater.setEventHandler(handler: fire)
            self.repeatSource = repeater

            let expiry = DispatchSource.makeTimerSource(queue: self.guardedQueue.queue)
            expiry.schedule(deadline: .now() + self.maxDuration, leeway: .milliseconds(50))
            expiry.setEventHandler { [weak self] in
                guard let self else { return }
                self.cancelLocked()
                Log.actions.error("Key repeat hit the \(self.maxDuration, privacy: .public) s safety cap; force-releasing")
                onExpire()
            }
            self.expirySource = expiry

            // Sources are created running and are never suspended, so cancelling one can never trap.
            repeater.resume()
            expiry.resume()
        }
    }

    func cancel() {
        guardedQueue.sync { self.cancelLocked() }
    }

    /// Must be called on the action queue.
    private func cancelLocked() {
        repeatSource?.cancel()
        repeatSource = nil
        expirySource?.cancel()
        expirySource = nil
    }

    deinit {
        repeatSource?.cancel()
        expirySource?.cancel()
    }

    // MARK: - System settings

    /// Measured on the development machine; used when the cache has never been primed from the main
    /// thread. Both are the user's preference value divided by 60 (AppKit's tick is 1/60 s, not 15 ms)
    /// — see TECHNICAL_INVESTIGATION.md §5 and CONTRACT_CORRECTIONS §3.
    static let fallbackDelay: TimeInterval = 0.4167
    static let fallbackInterval: TimeInterval = 0.0833

    private static let cache = OSAllocatedUnfairLock<(delay: TimeInterval, interval: TimeInterval)?>(initialState: nil)

    /// The user's Key Repeat settings.
    ///
    /// `NSEvent.keyRepeatDelay` / `keyRepeatInterval` are AppKit state and must be read on the main
    /// thread — never from the action queue. This reads them the first time it is called on the main
    /// thread and caches the result; called from anywhere else it returns the cache, or the measured
    /// defaults if nobody primed it. Call `primeSystemRepeatSettings()` once at launch.
    static func systemRepeatSettings() -> (delay: TimeInterval, interval: TimeInterval) {
        if let cached = cache.withLock({ $0 }) { return cached }
        guard Thread.isMainThread else { return (fallbackDelay, fallbackInterval) }
        return MainActor.assumeIsolated { primeSystemRepeatSettings() }
    }

    /// Read the settings from AppKit and cache them. Safe to call repeatedly.
    @MainActor
    @discardableResult
    static func primeSystemRepeatSettings() -> (delay: TimeInterval, interval: TimeInterval) {
        let settings = (delay: NSEvent.keyRepeatDelay, interval: NSEvent.keyRepeatInterval)
        cache.withLock { $0 = settings }
        return settings
    }
}
