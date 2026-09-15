//
//  ScreenshotMenuAction.swift
//  EjectRemapper
//
//  Open the ⌘⇧5 capture toolbar.
//

import AppKit
import CoreGraphics
import Foundation
import os

/// Opens `/System/Applications/Utilities/Screenshot.app`.
///
/// Apple documents the equivalence directly: "To open the app, press Shift-Command-5. Or find the
/// Screenshot app in the Utilities folder of your Applications folder." The bundle is `LSUIElement`
/// (identifier `com.apple.screenshot.launcher`), so it shows the capture toolbar without a Dock icon.
/// Launching it needs no permission at all, whereas synthesizing hot key 184 needs PostEvent access —
/// hence the launch is primary and the chord is the fallback (TECHNICAL_INVESTIGATION.md §7).
///
/// The capture toolbar itself asks for Screen Recording the first time the user captures, exactly as
/// it does when opened by hand. Key-down only; never repeats.
final class ScreenshotMenuAction: EjectActionHandler, @unchecked Sendable {
    static let screenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
    /// "Screenshot and recording options" in `com.apple.symbolichotkeys` — ⇧⌘5 by default.
    static let fallbackHotKeyID = SymbolicHotKeyReader.screenshotAndRecordingOptions

    /// Launches the app and reports failure (or success) through the completion.
    typealias Launcher = @Sendable (URL, @Sendable @escaping ((any Error)?) -> Void) -> Void // escaping by default in a function type

    private let generator: KeyboardEventGenerator
    private let launch: Launcher
    private let hotKeyProvider: @Sendable (Int) -> SymbolicHotKey
    private let canPostEvents: @Sendable () -> Bool

    /// - Parameter launch: injectable so tests never actually open Screenshot.app.
    init(generator: KeyboardEventGenerator,
         launch: @escaping Launcher = ScreenshotMenuAction.openScreenshotApp,
         hotKeyProvider: @escaping @Sendable (Int) -> SymbolicHotKey = { SymbolicHotKeyReader.hotKey(id: $0) },
         canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() }) {
        self.generator = generator
        self.launch = launch
        self.hotKeyProvider = hotKeyProvider
        self.canPostEvents = canPostEvents
    }

    func execute(action: EjectAction, trigger: ActionTrigger) {
        guard trigger == .keyDown else { return }
        launch(Self.screenshotAppURL) { [weak self] error in
            guard let self, let error else { return }
            Log.actions.error("Could not open Screenshot.app: \(error.localizedDescription, privacy: .public); falling back to the hot key")
            self.postFallbackHotKey()
        }
    }

    /// Nothing is ever held down by this action.
    func reset() {}

    // MARK: - Fallback

    /// Runs on whatever thread `NSWorkspace` calls back on; posting a CGEvent is thread-safe.
    private func postFallbackHotKey() {
        let hotKey = hotKeyProvider(Self.fallbackHotKeyID)
        guard hotKey.isEnabled else {
            Log.actions.error("Screenshot menu hot key \(Self.fallbackHotKeyID, privacy: .public) is disabled; nothing left to try")
            return
        }
        guard canPostEvents() else {
            Log.actions.error("Cannot open the screenshot menu: this app is not allowed to post keyboard events (Accessibility)")
            return
        }
        generator.press(hotKey.shortcut)
    }

    /// Default launcher. Never runs during tests.
    static func openScreenshotApp(at url: URL, completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard !TestEnvironment.isRunningTests else {
            Log.actions.error("Screenshot.app launch suppressed while running tests")
            completion(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            completion(error)
        }
    }
}
