//
//  KeyboardEventManager.swift
//  EjectRemapper
//

import Foundation
import Observation
import os

/// The configuration the event tap reads, reduced to the two facts it needs.
///
/// This is the only thing that crosses from the main actor to the tap thread. Keeping it tiny and
/// `Sendable` is what allows the crossing to be a lock read of a value type rather than a message
/// send — the callback must not wait for anything, least of all the main thread.
struct ActiveConfiguration: Equatable, Sendable {
    /// What the Eject key is bound to right now.
    var action: EjectAction
    /// Whether the shortcut recorder is open, in which case presses are swallowed rather than acted on.
    var isRecording: Bool
}

/// Owns the detector, decides what happens to each Eject press, and keeps the whole thing in step
/// with the user's settings and the Accessibility permission.
///
/// ## The thread story
///
/// This class is `@MainActor` because the UI observes it. The decision path is not: it runs on the
/// tap's own thread, inside a callback that must return in microseconds. Those two facts are
/// reconciled by ``DispositionBridge`` — a small `Sendable` object that holds the configuration in
/// an `OSAllocatedUnfairLock` and the dispatcher, and conforms to `EjectKeyDetectorDelegate`.
///
/// The main actor *writes* the snapshot when the settings change; the tap thread *reads* it when a
/// key arrives. Neither ever waits for the other, and the tap never holds a reference to anything
/// main-actor-isolated.
///
/// ## Staleness
///
/// The spec requires that changing the action takes effect on the next press with no restart. That
/// is why nothing is cached inside the detector or the tap: the snapshot is re-published by
/// `withObservationTracking` the moment `AppSettings` changes, so the very next press reads the new
/// value.
@MainActor
@Observable
final class KeyboardEventManager {

    /// Why remapping is not currently running.
    enum InactiveReason: Equatable, Sendable {
        /// `start()` has not been called, or `stop()` has.
        case notStarted
        /// The user switched remapping off.
        case disabledByUser
        /// Accessibility access is missing, so an active tap cannot exist.
        case permissionMissing
    }

    /// What the keyboard layer is doing.
    enum State: Equatable, Sendable {
        case inactive(InactiveReason)
        case active
        /// The tap could not be created or died. Carries a sentence for the UI, and the user can retry.
        case failed(String)
    }

    private(set) var state: State = .inactive(.notStarted)

    /// Raised while the shortcut recorder is open.
    ///
    /// Setting it pushes a new snapshot immediately, so a press that lands a millisecond later is
    /// already suppressed. Without this, opening the recorder and pressing ⏏ would fire whatever
    /// action is currently configured — locking the screen mid-recording, for instance.
    var isRecordingShortcut: Bool = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            publishConfiguration()
        }
    }

    /// Called on the main actor when ⏏ is pressed while recording, so the UI can react.
    var onEjectPressedDuringRecording: (@MainActor () -> Void)?

    /// When the last Eject press was seen. Diagnostics only — no key data, just a timestamp, so the
    /// About pane can show that the tap is alive.
    private(set) var lastEjectDetectedAt: Date?

    // MARK: - Collaborators

    private let settings: AppSettings
    private let permissions: PermissionManager
    private let detector: any EjectKeyDetector
    private let bridge: DispositionBridge

    /// Set once observation tracking is armed, so it is not armed twice.
    private var isObserving = false

    init(
        settings: AppSettings,
        permissions: PermissionManager,
        detector: any EjectKeyDetector,
        dispatcher: ActionDispatcher
    ) {
        self.settings = settings
        self.permissions = permissions
        self.detector = detector
        self.bridge = DispositionBridge(
            configuration: ActiveConfiguration(action: settings.resolvedAction, isRecording: false),
            dispatcher: dispatcher
        )

        bridge.onRecordingPress = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.onEjectPressedDuringRecording?()
            }
        }
        bridge.onDetection = { [weak self] in
            Task { @MainActor in
                self?.lastEjectDetectedAt = Date()
            }
        }
        bridge.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.handleDetectorFailure(message)
            }
        }

        detector.delegate = bridge

        // Synchronous, in the same main-actor turn as the mutation. This is what guarantees the
        // spec's "changing the action takes effect on the next press, with no restart" — the tap
        // can never read a configuration the user has already replaced. Observation (below) stays
        // as the backstop for the permission status, which changes outside the app entirely.
        settings.onChange = { [weak self] in
            self?.reconcile()
        }
    }

    /// Re-publishes the snapshot and brings the detector into line with the current settings.
    private func reconcile() {
        publishConfiguration()
        start()
    }

    // MARK: - Lifecycle

    /// Starts remapping if it should be running, stops it if it should not.
    ///
    /// Safe to call repeatedly: it is the single place that reconciles "what the user wants and what
    /// macOS allows" with "what the detector is doing", and every change funnels back through it.
    func start() {
        armObservationIfNeeded()
        publishConfiguration()

        guard settings.isRemappingEnabled else {
            stopDetector(reason: .disabledByUser)
            return
        }
        guard permissions.status == .granted else {
            stopDetector(reason: .permissionMissing)
            return
        }
        guard !detector.isRunning else {
            state = .active
            return
        }

        do {
            try detector.start()
            state = .active
            Log.tap.notice("Event tap started")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The Eject key could not be captured.")
            state = .failed(message)
            Log.tap.error("Event tap failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops remapping and restores the keyboard to its normal behaviour.
    func stop() {
        detector.stop()
        bridge.releaseAll()
        state = .inactive(.notStarted)
        Log.tap.notice("Event tap stopped")
    }

    /// Tears the tap down and builds it again.
    ///
    /// This is the correct response to a tap failure and to permission being re-granted: after a
    /// revocation the existing port is effectively dead, so re-enabling it is not enough — it has to
    /// be re-created (`docs/TECHNICAL_INVESTIGATION.md` §8).
    func retry() {
        detector.stop()
        bridge.releaseAll()
        permissions.refresh()
        start()
    }

    private func stopDetector(reason: InactiveReason) {
        if detector.isRunning {
            detector.stop()
            bridge.releaseAll()
            Log.tap.notice("Event tap stopped")
        }
        state = .inactive(reason)
    }

    private func handleDetectorFailure(_ message: String) {
        detector.stop()
        bridge.releaseAll()
        state = .failed(message)
        Log.tap.error("Event tap failed: \(message, privacy: .public)")
    }

    // MARK: - Configuration

    /// Copies the current settings into the snapshot the tap thread reads.
    private func publishConfiguration() {
        bridge.update(ActiveConfiguration(
            action: settings.resolvedAction,
            isRecording: isRecordingShortcut
        ))
    }

    /// Watches the settings and the permission, re-arming itself after every change.
    ///
    /// `withObservationTracking` fires once per change, so the continuation has to re-register. The
    /// hop through `Task { @MainActor }` is required because `onChange` runs synchronously inside
    /// the mutation.
    private func armObservationIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        observeChanges()
    }

    private func observeChanges() {
        withObservationTracking {
            _ = settings.resolvedAction
            _ = settings.isRemappingEnabled
            _ = permissions.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.publishConfiguration()
                self.start()
                self.observeChanges()
            }
        }
    }
}

// MARK: - The thread crossing

/// Holds the configuration the tap thread reads and turns each half of an Eject press into a
/// disposition.
///
/// Deliberately *not* main-actor-isolated and deliberately not holding a reference to anything that
/// is. Everything it needs is either immutable (the dispatcher) or behind a lock, so the tap callback
/// can do its whole job without touching Swift concurrency.
///
/// `OSAllocatedUnfairLock` rather than `NSLock`: it is the lock Apple recommends for exactly this
/// shape of problem — very short critical sections, contended rarely, on a real-time-ish thread.
/// Dispatching inside the lock is allowed because `dispatch` only enqueues; it never blocks.
private final class DispositionBridge: EjectKeyDetectorDelegate, @unchecked Sendable {

    /// What became of the Eject press that is currently down. Decided once, on its key-down, and
    /// then applied to every other half of that press.
    ///
    /// WHY a press is tracked rather than each event judged on its own: judging independently gives
    /// the halves of one press different answers whenever something changes between them — a
    /// modifier is touched, or the action is switched. A key-up passed through after its key-down was
    /// taken leaves a handler holding a key down; a key-up taken after its key-down was passed through
    /// hands macOS half a press. Both were possible before this type tracked presses.
    private enum Press: Equatable, Sendable {
        /// No Eject press is down, as far as the app knows.
        case none
        /// The key-down went to macOS, so the rest of the press does too.
        case passedThrough
        /// The key-down was taken. `handler` is the action it was delivered to, or `nil` when it was
        /// swallowed without one (Disabled, recording) or when that action has since been released
        /// because the user switched actions mid-press.
        case taken(handler: EjectAction?)
    }

    private struct State: Sendable {
        var configuration: ActiveConfiguration
        var press: Press = .none
    }

    /// The outcome of the rules for a new press.
    private struct Decision: Sendable {
        let disposition: EventDisposition
        let press: Press
        let isRecording: Bool
    }

    private let state: OSAllocatedUnfairLock<State>
    private let dispatcher: ActionDispatcher

    /// Called when a press arrives while the recorder is open.
    var onRecordingPress: (@Sendable () -> Void)?
    /// Called on every recognised Eject press, for the diagnostics timestamp.
    var onDetection: (@Sendable () -> Void)?
    /// Called when the detector reports a failure.
    var onFailure: (@Sendable (String) -> Void)?

    init(configuration: ActiveConfiguration, dispatcher: ActionDispatcher) {
        self.state = OSAllocatedUnfairLock(initialState: State(configuration: configuration))
        self.dispatcher = dispatcher
    }

    /// Publishes a new configuration.
    ///
    /// When the action changes, the previous action is fully released before this returns, and a
    /// press that is still down is detached from it. Its key-up is then swallowed, so macOS never
    /// sees half a press, but it is delivered to no one — least of all the new action.
    func update(_ new: ActiveConfiguration) {
        let actionChanged = state.withLock { state -> Bool in
            let changed = state.configuration.action.kind != new.action.kind
            state.configuration = new
            if changed, case .taken = state.press {
                state.press = .taken(handler: nil)
            }
            return changed
        }
        if actionChanged {
            dispatcher.reset()
        }
    }

    /// Forgets any press in progress and releases every handler.
    ///
    /// For when the tap stops: no key-up is ever going to arrive, so waiting for one would leave a
    /// synthesized key held down.
    func releaseAll() {
        state.withLock { $0.press = .none }
        dispatcher.reset()
    }

    // MARK: - EjectKeyDetectorDelegate

    func ejectKeyDetector(
        _ detector: any EjectKeyDetector,
        didDetect event: KeyboardInputEvent,
        modifiers: ModifierFlags
    ) -> EventDisposition {
        onDetection?()

        let dispatcher = self.dispatcher
        let (disposition, pressedWhileRecording) = state.withLock { state -> (EventDisposition, Bool) in
            switch event {
            case .ejectKeyDown:
                // A key-down while a taken press is still open means its key-up was lost, for
                // example while the tap was briefly disabled. Release it before starting anew.
                if case .taken(let handler?) = state.press {
                    dispatcher.dispatch(.ejectKeyUp, action: handler)
                }
                let decision = Self.decide(modifiers: modifiers, configuration: state.configuration)
                state.press = decision.press
                if case .taken(let handler?) = decision.press {
                    dispatcher.dispatch(.ejectKeyDown, action: handler)
                }
                return (decision.disposition, decision.isRecording)

            case .ejectKeyRepeat:
                guard case .taken(let handler) = state.press else { return (.passThrough, false) }
                if let handler {
                    dispatcher.dispatch(.ejectKeyRepeat, action: handler)
                }
                return (.suppress, false)

            case .ejectKeyUp:
                let press = state.press
                state.press = .none
                guard case .taken(let handler) = press else { return (.passThrough, false) }
                if let handler {
                    dispatcher.dispatch(.ejectKeyUp, action: handler)
                }
                return (.suppress, false)
            }
        }

        if pressedWhileRecording {
            onRecordingPress?()
        }
        return disposition
    }

    func ejectKeyDetectorShouldSuppressAuxiliaryEvent(
        _ detector: any EjectKeyDetector,
        modifiers: ModifierFlags
    ) -> EventDisposition {
        // Never runs an action: the subtype-8 pair already does (CONTRACT_CORRECTIONS §4).
        state.withLock { state in
            switch state.press {
            case .taken:
                return .suppress
            case .passedThrough:
                return .passThrough
            case .none:
                // It may arrive before its key-down, so apply the rules that key-down will get.
                return Self.decide(modifiers: modifiers, configuration: state.configuration).disposition
            }
        }
    }

    func ejectKeyDetector(_ detector: any EjectKeyDetector, didFail error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "The Eject key could not be captured.")
        onFailure?(message)
    }

    // MARK: - Rules

    /// Decides what a new press means. Pure, so the same rules serve key-downs and auxiliary events.
    private static func decide(modifiers: ModifierFlags, configuration: ActiveConfiguration) -> Decision {
        // 1. Recording. Swallow the press so it cannot fire the old action; the UI is told.
        if configuration.isRecording {
            return Decision(disposition: .suppress, press: .taken(handler: nil), isRecording: true)
        }

        // 2. System chords. ⌃⇧⏏, ⌥⌘⏏, ⌃⏏, ⌃⌘⏏ and ⌃⌥⌘⏏ are how people sleep, restart and shut down a
        //    Mac. loginwindow handles them *after* this tap, so swallowing the event would silently
        //    break them. Nothing is ever remapped while a modifier is held.
        if !modifiers.isDisjoint(with: .passThroughModifiers) {
            return Decision(disposition: .passThrough, press: .passedThrough, isRecording: false)
        }

        // 3. The configured action.
        let action = configuration.action
        guard action.suppressesOriginalEvent else {
            // Original Function.
            return Decision(disposition: .passThrough, press: .passedThrough, isRecording: false)
        }
        guard action.kind != .disabled else {
            // Disabled: swallowed, nothing runs.
            return Decision(disposition: .suppress, press: .taken(handler: nil), isRecording: false)
        }
        return Decision(disposition: .suppress, press: .taken(handler: action), isRecording: false)
    }
}
