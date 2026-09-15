//
//  ScreenshotAction.swift
//  EjectRemapper
//
//  Take a screenshot exactly as if the user had pressed their own screenshot shortcut.
//

import CoreGraphics
import Foundation
import os

/// Synthesizes the user's configured "Save picture of screen as a file" chord.
///
/// Symbolic hot key **28** is that command; on a stock system it is ⇧⌘3 (verified live: `keyCode 0x14`,
/// `mods 0x120000`, TECHNICAL_INVESTIGATION.md §7). Posting the user's *own* chord — rather than
/// capturing the screen ourselves — means the result is identical to pressing it by hand: same save
/// location, same file format, same floating thumbnail, same shutter sound, and no Screen Recording
/// permission for this app, which would otherwise be an extra TCC prompt for a capability the app does
/// not need.
///
/// The chord is sent with `KeyboardEventGenerator.press(_:)`, the modifier keys pressed and released
/// exactly as a person types it. An earlier version sent a flags-only key tap, which left ⇧⌘ latched
/// for the whole session and stopped every later Eject press from working
/// (TECHNICAL_INVESTIGATION.md §5, "Modifier state is session-wide").
///
/// If the user has disabled hot key 28 the app falls back to `/usr/sbin/screencapture -x -p` (`-x` =
/// no sound, `-p` = "use the default settings for capture", per the man page). That path *does* make
/// this app the responsible process for Screen Recording, which is why it is only a fallback.
final class ScreenshotAction: EjectActionHandler, @unchecked Sendable {
    /// "Save picture of screen as a file" in `com.apple.symbolichotkeys`.
    static let hotKeyID = SymbolicHotKeyReader.saveScreenAsFile

    private let generator: KeyboardEventGenerator
    private let hotKeyProvider: @Sendable (Int) -> SymbolicHotKey
    private let fallback: @Sendable () -> Void
    private let canPostEvents: @Sendable () -> Bool

    /// - Parameters:
    ///   - hotKeyProvider: reads the user's configured chord; injectable so tests are deterministic.
    ///   - fallback: runs when the hot key is disabled. Injectable so tests never spawn a process.
    ///   - canPostEvents: `CGPreflightPostEventAccess` — posting without it silently does nothing,
    ///     which would look like the app is broken, so it is checked and logged instead.
    init(generator: KeyboardEventGenerator,
         hotKeyProvider: @escaping @Sendable (Int) -> SymbolicHotKey = { SymbolicHotKeyReader.hotKey(id: $0) },
         fallback: @escaping @Sendable () -> Void = ScreenshotAction.runScreenCaptureTool,
         canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() }) {
        self.generator = generator
        self.hotKeyProvider = hotKeyProvider
        self.fallback = fallback
        self.canPostEvents = canPostEvents
    }

    func execute(action: EjectAction, trigger: ActionTrigger) {
        guard trigger == .keyDown else { return }

        let hotKey = hotKeyProvider(Self.hotKeyID)
        guard hotKey.isEnabled else {
            Log.actions.info("Screenshot hot key \(Self.hotKeyID, privacy: .public) is disabled; using screencapture")
            fallback()
            return
        }
        guard canPostEvents() else {
            Log.actions.error("Cannot take a screenshot: this app is not allowed to post keyboard events (Accessibility)")
            return
        }
        generator.press(hotKey.shortcut)
    }

    /// Nothing is ever held down by this action.
    func reset() {}

    /// Default fallback: `/usr/sbin/screencapture -x -p`, fire-and-forget.
    ///
    /// Never runs during tests — spawning a capture on a live, unattended machine is exactly the kind
    /// of side effect the test suite must not have.
    static func runScreenCaptureTool() {
        guard !TestEnvironment.isRunningTests else {
            Log.actions.error("screencapture fallback suppressed while running tests")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-p"]
        do {
            try process.run()
        } catch {
            Log.actions.error("screencapture failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }
}
