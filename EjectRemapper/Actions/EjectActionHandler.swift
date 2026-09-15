//
//  EjectActionHandler.swift
//  EjectRemapper
//
//  The vocabulary shared by every action in this layer.
//

import Foundation

/// Why a handler is being run.
///
/// The Eject key is *not* a normal key: `IOHIDKeyboardFilter.mm:1353-1372` (`isNotRepeated`) excludes
/// Consumer/Eject from auto-repeat, so the hardware emits exactly one down and one up — the repeat bit
/// is never set (TECHNICAL_INVESTIGATION.md §3, CONTRACT_CORRECTIONS §2). `.keyRepeat` therefore exists
/// only so the layer can stay honest if a future keyboard or a virtual HID driver ever does repeat;
/// hold-to-repeat in this app is generated in software by `KeyRepeatTimer`.
enum ActionTrigger: Equatable, Sendable {
    case keyDown
    case keyRepeat
    case keyUp
}

/// Something that can be done when the user presses the Eject key.
///
/// Handlers are reference types because most of them hold release state (a key that is physically
/// "down" from the system's point of view until we post its key-up). They are `Sendable` because the
/// dispatcher hands them between the tap thread and its own serial queue; in practice every handler
/// confines its mutable state to that one queue (see `ActionQueueGuard`).
protocol EjectActionHandler: AnyObject, Sendable {
    /// Perform the action. Must return quickly — it runs on the dispatcher's `.userInteractive` queue.
    func execute(action: EjectAction, trigger: ActionTrigger)

    /// Release anything still held (posted key-downs, running timers). Must be idempotent.
    ///
    /// This is the safety valve of the whole layer: a lost key-up, a configuration change mid-press or
    /// an app shutdown must never leave a modifier stuck down for the user.
    func reset()
}

extension EjectActionHandler {
    /// Convenience for one-shot callers and tests.
    func execute(action: EjectAction) {
        execute(action: action, trigger: .keyDown)
    }
}

/// Tags a serial queue so code can tell whether it is *already* running on it.
///
/// Every handler in this layer must mutate its state on the dispatcher's action queue. Callers,
/// however, come from three places: the dispatcher (already on the queue), a `DispatchSourceTimer`
/// (also on the queue) and tests (an arbitrary thread). A plain `queue.sync` would deadlock in the
/// first two cases, so the guard uses a queue-specific key — the standard `dispatch_get_specific`
/// idiom — to run inline when it is already on the queue and to hop otherwise.
///
/// Each guard allocates its own key, so several guards may safely mark the same queue.
final class ActionQueueGuard: @unchecked Sendable {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    init(_ queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: key, value: 1)
    }

    /// True when the calling thread is executing a block on the guarded queue.
    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: key) == 1
    }

    /// Run `body` on the queue, inline if we are already there.
    func sync(_ body: () -> Void) {
        if isCurrent {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    /// Always enqueue — used by the event tap, which must never block.
    func enqueue(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }
}
