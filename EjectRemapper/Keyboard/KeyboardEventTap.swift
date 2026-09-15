import CoreGraphics
import Foundation

/// Why `start()` could not bring a tap up.
///
/// These are the only three failures worth distinguishing to a user: "macOS refused to give us a
/// tap" (almost always Accessibility), "we got a tap but could not service it", and "we got a tap
/// that is not actually alive". The third is not paranoia — see ``EventTapError/tapNotEnabled``.
enum EventTapError: Error, Equatable, LocalizedError {
    /// `CGEvent.tapCreate` returned `nil`. Accessibility permission is missing, or the requested
    /// tap location is unavailable to this process (`CGEvent.h:272-278`).
    case creationFailed

    /// The Mach port could not be turned into a run-loop source.
    case runLoopSourceFailed

    /// `tapCreate` returned a port but `CGEvent.tapIsEnabled` reported `false` afterwards.
    ///
    /// A non-nil tap is **not** proof of a working tap: a listen-only keyboard tap is created and
    /// then silently never enabled, and a mixed mask is trimmed rather than rejected
    /// (TECHNICAL_INVESTIGATION.md §4, CONTRACT_CORRECTIONS §9). Without this check the app would
    /// report itself active while swallowing nothing.
    case tapNotEnabled

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return String(localized: "macOS refused to create the event tap. Grant Accessibility access and try again.")
        case .runLoopSourceFailed:
            return String(localized: "The event tap could not be attached to its run loop.")
        case .tapNotEnabled:
            return String(localized: "The event tap was created but macOS did not enable it. Accessibility access may have been revoked.")
        }
    }
}

/// The C callback the kernel calls. It is a file-private free function on purpose: a
/// `CGEventTapCallBack` is a bare C function pointer, so it can capture **nothing**. The owning
/// object travels through `userInfo` as an unmanaged pointer instead (CONTRACT_CORRECTIONS §12).
private func ejectRemapperEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

/// Owns one `CGEventTap` and the dedicated thread that services it.
///
/// Why a dedicated `Thread` with its own `CFRunLoop` rather than the main run loop: the tap callback
/// runs synchronously inside the window server's event delivery path. If it were serviced by the
/// main run loop, any main-thread work — a SwiftUI layout pass, a menu tracking loop, a modal — would
/// stall every Eject press and, past the timeout, make macOS disable the tap outright. A private run
/// loop that does nothing else keeps the callback's latency bounded by our own code.
///
/// `@unchecked Sendable` because the mutable state below is guarded by `lock`, which the compiler
/// cannot verify.
final class KeyboardEventTap: @unchecked Sendable {

    /// Returns the event to pass it through, or `nil` to consume it. Must complete in microseconds:
    /// it runs on the event delivery path, and exceeding the system timeout disables the tap.
    typealias Handler = @Sendable (_ type: CGEventType, _ event: CGEvent) -> CGEvent?

    private let eventMask: CGEventMask
    private let location: CGEventTapLocation
    private let placement: CGEventTapPlacement
    private let handler: Handler

    private let lock = NSLock()
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var running = false
    private var reenabledHandler: (@Sendable (_ reason: CGEventType) -> Void)?

    /// - Parameters:
    ///   - location: `.cgSessionEventTap`. An **active** tap at `.cghidEventTap` requires root
    ///     (`CGEvent.h:269-270`), so the session tap is the only usable location for a normal app —
    ///     CONTRACT_CORRECTIONS §1. Generated events, by contrast, are *posted* to `.cghidEventTap`.
    ///   - placement: `.headInsertEventTap` so the app sees Eject before anything else can claim it.
    init(
        eventMask: CGEventMask,
        location: CGEventTapLocation = .cgSessionEventTap,
        placement: CGEventTapPlacement = .headInsertEventTap,
        handler: @escaping Handler
    ) {
        self.eventMask = eventMask
        self.location = location
        self.placement = placement
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Fired after the tap was automatically re-enabled following
    /// `kCGEventTapDisabledByTimeout` / `kCGEventTapDisabledByUserInput`. Diagnostics only — the
    /// re-enable itself has already happened by the time this runs.
    var onReenabled: (@Sendable (_ reason: CGEventType) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return reenabledHandler
        }
        set {
            lock.lock()
            reenabledHandler = newValue
            lock.unlock()
        }
    }

    // MARK: - Lifecycle

    /// Creates the tap on a fresh thread and blocks until that thread has either armed it or failed.
    ///
    /// Blocking is intentional: callers need a synchronous yes/no so the UI can show a real state
    /// instead of an optimistic one. The wait is bounded by two `CGEvent` calls.
    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        let outcome = StartOutcome()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                outcome.set(.creationFailed)
                ready.signal()
                return
            }
            self.runTapThread(outcome: outcome, ready: ready)
        }
        thread.name = "com.cacaioo.EjectRemapper.EventTap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024

        lock.lock()
        self.thread = thread
        lock.unlock()

        thread.start()
        ready.wait()

        if let error = outcome.error {
            stop()
            throw error
        }

        lock.lock()
        running = true
        lock.unlock()
        Log.tap.info("Event tap started (mask 0x\(String(self.eventMask, radix: 16), privacy: .public))")
    }

    /// Disables, invalidates and tears down the tap. Idempotent, and safe to call from any thread.
    ///
    /// Order matters: the tap is disabled *first* so that the keyboard is back to its normal
    /// behaviour before anything else is released. A tap that is invalidated while still enabled has
    /// been reported to swallow input on recent macOS releases
    /// (TECHNICAL_INVESTIGATION.md §8 "Revocation while running").
    func stop() {
        lock.lock()
        let port = machPort
        let source = runLoopSource
        let loop = runLoop
        machPort = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        let wasRunning = running
        running = false
        lock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source, let loop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        if wasRunning {
            Log.tap.info("Event tap stopped")
        }
    }

    // MARK: - Tap thread

    private func runTapThread(outcome: StartOutcome, ready: DispatchSemaphore) {
        guard let port = CGEvent.tapCreate(
            tap: location,
            place: placement,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: ejectRemapperEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            outcome.set(.creationFailed)
            ready.signal()
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            outcome.set(.runLoopSourceFailed)
            ready.signal()
            return
        }

        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        // A non-nil tap is not a healthy tap: verify it actually came up before claiming success.
        guard CGEvent.tapIsEnabled(tap: port) else {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
            outcome.set(.tapNotEnabled)
            ready.signal()
            return
        }

        lock.lock()
        machPort = port
        runLoopSource = source
        runLoop = loop
        lock.unlock()

        ready.signal()
        CFRunLoopRun()
    }

    // MARK: - Callback

    /// Called from the C trampoline on the tap thread. Nothing here may block or allocate heavily.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(reason: type)
            return Unmanaged.passUnretained(event)
        }
        guard let result = handler(type, event) else { return nil }
        return Unmanaged.passUnretained(result)
    }

    private func reenable(reason: CGEventType) {
        lock.lock()
        let port = machPort
        let notify = reenabledHandler
        lock.unlock()

        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        Log.tap.notice("Event tap re-enabled after disable reason \(reason.rawValue, privacy: .public)")
        notify?(reason)
    }
}

/// A one-shot, lock-protected box for the tap thread's start result.
///
/// Needed because the result crosses from the tap thread back to the caller through a semaphore,
/// which the compiler cannot reason about.
private final class StartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EventTapError?

    func set(_ error: EventTapError) {
        lock.lock()
        storage = error
        lock.unlock()
    }

    var error: EventTapError? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
