import CoreGraphics
import Foundation

/// Receives Eject presses from a detector and decides, synchronously, what should happen to them.
///
/// Why the delegate returns a value instead of the detector asking a policy object: the answer is
/// needed *inside* the tap callback, before it returns, and there is no opportunity to await
/// anything. Making that a return value forces every implementation to be non-blocking by design.
///
/// `Sendable` because the calls arrive on the detector's own thread, never on the main actor.
protocol EjectKeyDetectorDelegate: AnyObject, Sendable {
    /// Called synchronously on the detector's thread for each subtype-8 Eject event. Must return
    /// immediately — anything slower than a lock read and an enqueue risks the tap being disabled.
    func ejectKeyDetector(
        _ detector: any EjectKeyDetector,
        didDetect event: KeyboardInputEvent,
        modifiers: ModifierFlags
    ) -> EventDisposition

    /// Called for the auxiliary `NX_SUBTYPE_EJECT_KEY` (subtype 10) event that may accompany a
    /// press. It asks only "should this be swallowed too?" and never causes an action to run,
    /// because the subtype-8 down/up pair has already triggered one (CONTRACT_CORRECTIONS §4).
    func ejectKeyDetectorShouldSuppressAuxiliaryEvent(
        _ detector: any EjectKeyDetector,
        modifiers: ModifierFlags
    ) -> EventDisposition

    /// The detector could not start, or died while running.
    func ejectKeyDetector(_ detector: any EjectKeyDetector, didFail error: any Error)
}

extension EjectKeyDetectorDelegate {
    /// Defaults to passing the auxiliary event through: doing nothing is always the safe answer for
    /// an event the app does not understand.
    func ejectKeyDetectorShouldSuppressAuxiliaryEvent(
        _ detector: any EjectKeyDetector,
        modifiers: ModifierFlags
    ) -> EventDisposition {
        .passThrough
    }
}

/// Anything that can tell the app the Eject key was pressed.
///
/// Exists as a protocol purely so the whole layer above it can be tested with a fake that needs no
/// tap, no Accessibility permission and no hardware.
protocol EjectKeyDetector: AnyObject {
    var delegate: (any EjectKeyDetectorDelegate)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

/// The production detector: a `CGEventTap` restricted to `NX_SYSDEFINED` events.
///
/// Why this shape is non-negotiable (TECHNICAL_INVESTIGATION.md §3–§4):
/// - `.cgSessionEventTap` — the only location where a non-root process may run an **active** tap.
/// - `.headInsertEventTap` — the app must see Eject before any other tap can claim it.
/// - `.defaultTap` — a listen-only tap can never suppress, which is the entire point of the app.
/// - mask `1 << 14` — exactly one bit. Keyboard key events are never observed, so typed text is
///   unreadable by this process even in principle.
///
/// `@unchecked Sendable`: the only mutable state is `delegate`, guarded by `lock`.
final class CGEventTapEjectKeyDetector: EjectKeyDetector, @unchecked Sendable {

    private let lock = NSLock()
    private var storedDelegate: (any EjectKeyDetectorDelegate)?
    private var tap: KeyboardEventTap?
    private let location: CGEventTapLocation

    init(location: CGEventTapLocation = .cgSessionEventTap) {
        self.location = location
    }

    var delegate: (any EjectKeyDetectorDelegate)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDelegate
        }
        set {
            lock.lock()
            storedDelegate = newValue
            lock.unlock()
        }
    }

    var isRunning: Bool {
        lock.lock()
        let tap = self.tap
        lock.unlock()
        return tap?.isRunning ?? false
    }

    func start() throws {
        if isRunning { return }

        let tap = KeyboardEventTap(
            eventMask: SystemDefinedEventDecoder.eventMask,
            location: location,
            placement: .headInsertEventTap
        ) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? event
        }
        lock.lock()
        self.tap = tap
        lock.unlock()

        do {
            try tap.start()
        } catch {
            lock.lock()
            self.tap = nil
            lock.unlock()
            delegate?.ejectKeyDetector(self, didFail: error)
            throw error
        }
    }

    func stop() {
        lock.lock()
        let tap = self.tap
        self.tap = nil
        lock.unlock()
        tap?.stop()
    }

    // MARK: - Tap callback (detector thread — keep this cheap)

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Defence in depth: our own generated events are type 10/11 and can never match the mask,
        // but the tag check costs one field read and documents the intent.
        if event.getIntegerValueField(.eventSourceUserData) == GeneratedEventTag.userData {
            return event
        }
        guard type == SystemDefinedEventDecoder.systemDefinedType else { return event }
        guard let delegate else { return event }

        if let (input, modifiers) = SystemDefinedEventDecoder.ejectEvent(event) {
            let disposition = delegate.ejectKeyDetector(self, didDetect: input, modifiers: modifiers)
            return disposition == .suppress ? nil : event
        }

        // Subtype 10 rides along with some presses. Swallow it when the press itself is being
        // swallowed, but never let it trigger an action — that would fire the action twice.
        if SystemDefinedEventDecoder.isAuxiliaryEjectEvent(event) {
            let modifiers = SystemDefinedEventDecoder.modifiers(of: event)
            let disposition = delegate.ejectKeyDetectorShouldSuppressAuxiliaryEvent(self, modifiers: modifiers)
            return disposition == .suppress ? nil : event
        }

        // Every other media key — volume, brightness, play/pause — passes through untouched.
        return event
    }
}
