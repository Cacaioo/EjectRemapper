//
//  ActionDispatcher.swift
//  EjectRemapper
//
//  Routes a detected Eject press to the handler for the configured action, and owns the
//  one-shot / repeat policy so no individual handler has to.
//

import Foundation
import os

/// The single entry point from the keyboard layer into the action layer.
///
/// The event tap callback has a hard latency budget (macOS disables a tap that takes too long —
/// `kCGEventTapDisabledByTimeout`), so `dispatch(_:action:)` does nothing but enqueue onto a serial
/// `.userInteractive` queue. Everything after that — timers, posted events, `Process`, `NSWorkspace` —
/// happens on that one queue, which is also what makes the handlers' state safe without locks.
///
/// The dispatcher owns the press policy because it is the only object that sees *every* trigger:
///
/// * Actions that support repeat (Forward Delete, Custom Shortcut) get every trigger forwarded.
/// * One-shot actions (Lock Screen, Screenshot, Screenshot Menu) fire on key-down only. A second
///   key-down while the key is still held is ignored, hardware repeats are ignored, and a short
///   cooldown swallows a duplicate down that some keyboards emit alongside the subtype-10 event
///   (TECHNICAL_INVESTIGATION.md §3) — locking the screen twice or firing two screenshots is exactly
///   the kind of double-fire users notice.
/// * If the user changes the action while the key is held, the *previous* handler is reset first, so a
///   key or modifier posted by the old handler can never be left stuck down.
final class ActionDispatcher: EjectActionHandler, @unchecked Sendable {
    private let handlers: [EjectActionKind: any EjectActionHandler]
    private let guardedQueue: ActionQueueGuard
    private let oneShotCooldown: TimeInterval
    private let now: @Sendable () -> TimeInterval

    /// Queue-confined state.
    private var heldKind: EjectActionKind?
    private var lastOneShotFire: [EjectActionKind: TimeInterval] = [:]

    /// - Parameters:
    ///   - handlers: one handler per action kind. A missing kind is simply ignored (logged once).
    ///   - queue: serial, `.userInteractive` — key remapping is the definition of user-interactive work.
    ///   - oneShotCooldown: minimum seconds between two fires of the same one-shot action.
    ///   - now: monotonic clock, injectable for tests. `systemUptime` is monotonic and unaffected by
    ///     clock changes, unlike `Date()`.
    init(handlers: [EjectActionKind: any EjectActionHandler],
         queue: DispatchQueue = DispatchQueue(label: "com.cacaioo.EjectRemapper.actions", qos: .userInteractive),
         oneShotCooldown: TimeInterval = 0.3,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.handlers = handlers
        self.guardedQueue = ActionQueueGuard(queue)
        self.oneShotCooldown = oneShotCooldown
        self.now = now
    }

    /// The queue every handler must use for its own timers and state.
    var queue: DispatchQueue { guardedQueue.queue }

    /// Called from the event tap thread. Never blocks.
    func dispatch(_ event: KeyboardInputEvent, action: EjectAction) {
        let trigger: ActionTrigger
        switch event {
        case .ejectKeyDown: trigger = .keyDown
        case .ejectKeyRepeat: trigger = .keyRepeat
        case .ejectKeyUp: trigger = .keyUp
        }
        guardedQueue.enqueue { [self] in
            applyPolicy(action: action, trigger: trigger)
        }
    }

    /// Runs the policy synchronously on the action queue (inline when already there).
    ///
    /// Tests call this directly; `KeyboardEventManager` always goes through `dispatch(_:action:)`.
    func execute(action: EjectAction, trigger: ActionTrigger) {
        guardedQueue.sync { self.applyPolicy(action: action, trigger: trigger) }
    }

    /// Release everything. Called when the tap stops, the app quits, or permission is lost.
    func reset() {
        guardedQueue.sync {
            for handler in self.handlers.values { handler.reset() }
            self.heldKind = nil
            self.lastOneShotFire.removeAll()
        }
    }

    // MARK: - Policy (action queue only)

    private func applyPolicy(action: EjectAction, trigger: ActionTrigger) {
        let kind = action.kind

        // The action changed while the key was held: let the old handler let go first.
        if let held = heldKind, held != kind {
            handlers[held]?.reset()
            heldKind = nil
        }

        guard let handler = handlers[kind] else {
            Log.actions.error("No handler registered for action kind \(kind.rawValue, privacy: .public)")
            return
        }

        if action.supportsKeyRepeat {
            switch trigger {
            case .keyDown:
                heldKind = kind
            case .keyRepeat:
                break
            case .keyUp:
                if heldKind == kind { heldKind = nil }
            }
            handler.execute(action: action, trigger: trigger)
            return
        }

        switch trigger {
        case .keyRepeat:
            // One-shot actions never repeat, no matter where the repeat came from.
            return
        case .keyUp:
            if heldKind == kind { heldKind = nil }
            // Forwarded so a handler can clean up; the one-shot handlers ignore it.
            handler.execute(action: action, trigger: .keyUp)
        case .keyDown:
            guard heldKind != kind else { return }          // still held from the previous down
            let timestamp = now()
            if let last = lastOneShotFire[kind], timestamp - last < oneShotCooldown {
                Log.actions.debug("Ignoring \(kind.rawValue, privacy: .public) within cooldown")
                heldKind = kind
                return
            }
            heldKind = kind
            lastOneShotFire[kind] = timestamp
            handler.execute(action: action, trigger: .keyDown)
        }
    }
}
