import CoreGraphics
import Foundation

/// The single choke point through which the app injects events into macOS.
///
/// Why this protocol exists at all: `CGEvent.post` is the one call in the codebase with a global,
/// irreversible side effect on a live machine. Isolating it behind a protocol means every unit test
/// — and every future refactor — can exercise the full generation path without a single real
/// keystroke ever reaching the system.
protocol EventPosting: Sendable {
    func post(_ event: CGEvent)
}

/// Production poster.
///
/// `.cghidEventTap` is deliberate and load-bearing: it is the point at which HID events enter the
/// window server, and it is the only posting location at which the system's own hot keys (the
/// screenshot chords ⌘⇧3 / ⌘⇧5) actually fire. Note the asymmetry with the *tap*, which must sit at
/// `.cgSessionEventTap` — CONTRACT_CORRECTIONS §1, TECHNICAL_INVESTIGATION.md §5.
struct HIDEventPoster: EventPosting {
    func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }
}

/// A flattened, comparable record of one posted event.
///
/// The generator's output is a *sequence* — modifier down, key down, key up, modifier up — and the
/// interesting property of that sequence is its exact order and the flags carried at each step.
/// Capturing value types makes that sequence assertable with a plain `XCTAssertEqual`.
struct PostedEvent: Equatable, Sendable {
    let type: CGEventType
    let keyCode: UInt16
    let modifiers: ModifierFlags
    let isAutorepeat: Bool
    let userData: Int64

    init(type: CGEventType, keyCode: UInt16, modifiers: ModifierFlags, isAutorepeat: Bool, userData: Int64) {
        self.type = type
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isAutorepeat = isAutorepeat
        self.userData = userData
    }

    /// Snapshots the fields the app controls. Anything CoreGraphics fills in for us is ignored,
    /// except through `modifiers`, which is masked to the device-independent bits.
    init(event: CGEvent) {
        self.type = event.type
        self.keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        self.modifiers = ModifierFlags(cgEventFlags: event.flags)
        self.isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        self.userData = event.getIntegerValueField(.eventSourceUserData)
    }
}

/// Test double: records what *would* have been posted and posts nothing.
///
/// `@unchecked Sendable` — the array is guarded by `lock`, because actions run on the dispatcher's
/// serial queue while assertions run on the test thread.
final class RecordingEventPoster: EventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PostedEvent] = []

    init() {}

    /// Everything posted so far, in order. Read-only by design: only ``post(_:)`` appends.
    var events: [PostedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func post(_ event: CGEvent) {
        let recorded = PostedEvent(event: event)
        lock.lock()
        storage.append(recorded)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

/// The marker stamped on every event the app generates.
///
/// `0x454A4354` is ASCII "EJCT". It is set on the private `CGEventSource` (so every event the source
/// creates inherits it) *and* explicitly on each event. The event tap checks it before decoding, so
/// the app can never react to its own output — and other tools can identify our events if they care.
/// See TECHNICAL_INVESTIGATION.md §4 "Recursion prevention".
enum GeneratedEventTag {
    static let userData: Int64 = 0x454A_4354
}
