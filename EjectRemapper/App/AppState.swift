//
//  AppState.swift
//  EjectRemapper
//

import AppKit
import Foundation
import Observation

/// The composition root: one object that owns every long-lived subsystem and hands them to SwiftUI.
///
/// WHY a single root rather than `@StateObject`s scattered across views: the keyboard layer must
/// keep running while no window exists (this is a menu-bar-only app), and the event tap must be
/// created exactly once. Putting the graph in one main-actor object means the views are pure
/// projections of it, and `preview()` can swap in an inert graph without the views knowing.
///
/// Two factories, and only two:
/// * ``live()`` builds the real graph — a `CGEventTapEjectKeyDetector`, real action handlers and the
///   real `SMAppService` login item. It creates objects but starts nothing; `start()` does that.
/// * ``preview()`` builds a graph with no system side effects whatsoever, for SwiftUI previews and
///   for tests that need a plausible `AppState`.
@MainActor
@Observable
final class AppState {

    // MARK: - Subsystems

    let settings: AppSettings
    let permissions: PermissionManager
    let keyboard: KeyboardEventManager
    let loginItems: LoginItemManager
    let recorder: ShortcutRecorder

    /// What `KeyboardCompatibility` last said about the attached keyboards.
    ///
    /// Read-only enumeration (`IOHIDManagerCopyDevices`, devices never opened), so it is safe to
    /// refresh whenever a settings pane appears.
    private(set) var compatibility: CompatibilityAssessment

    // MARK: - Private

    /// `false` for the `preview()` graph. Guards everything that reaches outside the process.
    private let isLive: Bool

    /// Created lazily the first time Settings is opened — the app must not own a window at launch.
    private var settingsWindowController: SettingsWindowController?

    private init(
        settings: AppSettings,
        permissions: PermissionManager,
        keyboard: KeyboardEventManager,
        loginItems: LoginItemManager,
        recorder: ShortcutRecorder,
        compatibility: CompatibilityAssessment,
        isLive: Bool
    ) {
        self.settings = settings
        self.permissions = permissions
        self.keyboard = keyboard
        self.loginItems = loginItems
        self.recorder = recorder
        self.compatibility = compatibility
        self.isLive = isLive

        // A physical Eject press that arrives while the shortcut recorder is open is suppressed by
        // the keyboard layer rather than dispatched. The recorder's own local NSEvent monitor
        // normally reports it as `.rejected(.ejectKey)`; this callback is the backstop for the case
        // where the tap sees it first, and simply ends the recording session.
        keyboard.onEjectPressedDuringRecording = { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.recorder.cancel()
        }
    }

    // MARK: - Factories

    /// Builds the real object graph. Creates no taps, registers nothing and shows no UI —
    /// `start()` is what brings the app to life.
    static func live() -> AppState {
        let settings = AppSettings()
        let permissions = PermissionManager()
        let loginItems = LoginItemManager()

        // One serial queue shared by the dispatcher and every handler, so a key-repeat timer and
        // the dispatch that cancels it can never interleave.
        let queue = DispatchQueue(label: "com.cacaioo.EjectRemapper.actions", qos: .userInteractive)
        let generator = KeyboardEventGenerator()

        let handlers: [EjectActionKind: any EjectActionHandler] = [
            .forwardDelete: ForwardDeleteAction(generator: generator, queue: queue),
            .customShortcut: CustomShortcutAction(generator: generator, queue: queue),
            .lockScreen: LockScreenAction(strategies: [
                LoginFrameworkLockStrategy(),
                SystemHotKeyLockStrategy(generator: generator),
            ]),
            .screenshot: ScreenshotAction(generator: generator),
            .screenshotMenu: ScreenshotMenuAction(generator: generator),
            .original: PassiveAction(),
            .disabled: PassiveAction(),
        ]

        let dispatcher = ActionDispatcher(handlers: handlers, queue: queue)
        let detector = CGEventTapEjectKeyDetector()
        let keyboard = KeyboardEventManager(
            settings: settings,
            permissions: permissions,
            detector: detector,
            dispatcher: dispatcher
        )

        let compatibility = KeyboardCompatibility.assess()
        Log.compatibility.notice("Keyboard compatibility: \(String(describing: compatibility), privacy: .public)")

        return AppState(
            settings: settings,
            permissions: permissions,
            keyboard: keyboard,
            loginItems: loginItems,
            recorder: ShortcutRecorder(),
            compatibility: compatibility,
            isLive: true
        )
    }

    /// Builds a graph that cannot touch the system.
    ///
    /// Every seam is filled with a double: an inert detector (no tap), a `RecordingEventPoster`
    /// (events are collected, never posted), an inert lock-screen strategy, `PassiveAction` in place
    /// of the screenshot handlers (which would otherwise launch Screenshot.app), an inert login-item
    /// service, and permission closures that answer from memory. Settings live in a scratch
    /// `UserDefaults` suite that is wiped on creation, so previews never disturb the real app's
    /// preferences.
    static func preview() -> AppState {
        let suiteName = "com.cacaioo.EjectRemapper.preview"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionManager(
            isTrusted: { true },
            canCreateEventTap: { true },
            promptForAccess: { true },
            openURL: { _ in true }
        )
        let loginItems = LoginItemManager(service: InertLoginItemService())

        let queue = DispatchQueue(label: "com.cacaioo.EjectRemapper.actions.preview", qos: .utility)
        let generator = KeyboardEventGenerator(poster: RecordingEventPoster())

        let handlers: [EjectActionKind: any EjectActionHandler] = [
            .forwardDelete: ForwardDeleteAction(generator: generator, queue: queue),
            .customShortcut: CustomShortcutAction(generator: generator, queue: queue),
            .lockScreen: LockScreenAction(strategies: [InertLockScreenStrategy()]),
            .screenshot: PassiveAction(),
            .screenshotMenu: PassiveAction(),
            .original: PassiveAction(),
            .disabled: PassiveAction(),
        ]

        let dispatcher = ActionDispatcher(handlers: handlers, queue: queue)
        let keyboard = KeyboardEventManager(
            settings: settings,
            permissions: permissions,
            detector: InertEjectKeyDetector(),
            dispatcher: dispatcher
        )

        return AppState(
            settings: settings,
            permissions: permissions,
            keyboard: keyboard,
            loginItems: loginItems,
            recorder: ShortcutRecorder(),
            compatibility: .unknown,
            isLive: false
        )
    }

    // MARK: - Lifecycle

    /// Brings the app to life: permission monitoring, the event tap, and — at most once, ever —
    /// the Accessibility prompt.
    ///
    /// The prompt is gated three ways: only when the permission is not already granted, only when
    /// `AppSettings.hasPromptedForAccessibility` is still false (persisted, so a second launch never
    /// prompts again), and only once per process (`PermissionManager` enforces that itself). The
    /// flag is written *before* prompting so a crash inside the system alert cannot produce a loop.
    func start() {
        permissions.startMonitoring()
        loginItems.refresh()
        keyboard.start()

        guard permissions.status != .granted, !settings.hasPromptedForAccessibility else { return }
        settings.hasPromptedForAccessibility = true
        permissions.requestAccess()
    }

    /// Tears everything down. Called from `applicationWillTerminate(_:)`.
    ///
    /// Stopping the tap explicitly matters: a tap left behind in a dying process is the classic way
    /// to leave the user's keyboard half-broken until the port is reaped.
    func stop() {
        keyboard.stop()
        permissions.stopMonitoring()
    }

    // MARK: - Intents

    /// Changes the action bound to the Eject key. Takes effect on the next press, no restart.
    func select(_ kind: EjectActionKind) {
        guard settings.actionKind != kind else { return }
        settings.actionKind = kind
        Log.settings.notice("Eject action changed to \(kind.rawValue, privacy: .public)")
    }

    /// Starts a shortcut recording session.
    ///
    /// `keyboard.isRecordingShortcut` is raised for the whole session so a physical Eject press is
    /// suppressed instead of firing the current action while the user is recording.
    func beginRecordingShortcut() {
        guard !recorder.isRecording else { return }
        keyboard.isRecordingShortcut = true
        recorder.start { [weak self] outcome in
            guard let self else { return }
            self.keyboard.isRecordingShortcut = false
            if case .recorded(let shortcut) = outcome {
                self.settings.customShortcut = shortcut
                Log.settings.notice("Custom shortcut recorded")   // never the shortcut itself
            }
        }
    }

    /// Cancels an in-flight recording session and lowers the suppression flag.
    func cancelRecordingShortcut() {
        guard recorder.isRecording else { return }
        recorder.cancel()
        keyboard.isRecordingShortcut = false
    }

    /// Forgets the recorded custom shortcut. `AppSettings.resolvedAction` then falls back to
    /// `.disabled`, which is the safe state — the Eject key does nothing rather than something
    /// unexpected.
    func clearShortcut() {
        settings.customShortcut = nil
    }

    /// Re-runs the keyboard compatibility assessment (read-only HID enumeration).
    func refreshCompatibility() {
        guard isLive else { return }
        compatibility = KeyboardCompatibility.assess()
    }

    /// Shows the Settings window, creating it on first use.
    ///
    /// This is also the escape hatch for "Show Menu Bar Icon" being off: re-launching the app from
    /// Finder produces `applicationShouldHandleReopen(_:hasVisibleWindows:)`, which lands here.
    func openSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(appState: self)
        settingsWindowController = controller
        controller.show()
    }

    /// Quits. `applicationWillTerminate(_:)` does the teardown.
    func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Inert doubles for preview()

/// An `EjectKeyDetector` that never creates a tap and never reports an event.
///
/// Used by ``AppState/preview()`` so that SwiftUI previews and tests can run the whole graph,
/// including `KeyboardEventManager.start()`, without a single system call.
final class InertEjectKeyDetector: EjectKeyDetector, @unchecked Sendable {
    weak var delegate: (any EjectKeyDetectorDelegate)?
    private(set) var isRunning = false

    init() {}

    func start() throws { isRunning = true }
    func stop() { isRunning = false }
}

/// A `LockScreenStrategy` that reports itself available and then does nothing.
///
/// WHY it exists: locking the screen of a live, unattended development machine is unrecoverable
/// from a test. The real strategies are never constructed in ``AppState/preview()``.
struct InertLockScreenStrategy: LockScreenStrategy {
    init() {}
    var name: String { "Inert (preview)" }
    func isAvailable() -> Bool { true }
    func lock() throws {}
}
