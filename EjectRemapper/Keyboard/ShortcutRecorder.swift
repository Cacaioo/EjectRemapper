//
//  ShortcutRecorder.swift
//  EjectRemapper
//

import AppKit
import Foundation
import Observation

/// Captures one keyboard shortcut from the user, then stops listening.
///
/// ## Privacy
///
/// This is the only place in the entire app that observes ordinary key presses, and it is
/// deliberately the narrowest possible window onto them:
///
/// - It uses **local** monitors (`NSEvent.addLocalMonitorForEvents`), which only ever see events
///   delivered to this app's own windows. A global monitor would see every keystroke on the
///   machine; there is no reason for this app to have one, so it does not.
/// - The monitors are installed when the user clicks "Record Shortcut" and removed the instant a
///   shortcut is captured, cancelled or rejected — in `finish(_:)`, which every exit path goes
///   through.
/// - Nothing is written anywhere except the single shortcut the user chose. No key is logged.
///
/// ## Interaction rules
///
/// - Pressing a key with or without modifiers records that combination.
/// - Escape with no modifiers cancels, which is what Escape means everywhere else in macOS.
///   ⌘⎋ or ⌥⎋ record normally, since those are real shortcuts.
/// - ⏏ is rejected with an explanation rather than recorded, because binding Eject to Eject would
///   point the remapper at its own output.
/// - Pressing only modifiers does nothing until a key joins them; the held modifiers are published
///   so the UI can show them building up.
@MainActor
@Observable
final class ShortcutRecorder {

    /// How a recording session ended.
    enum Outcome: Equatable, Sendable {
        /// A usable shortcut was captured.
        case recorded(KeyboardShortcut)
        /// The user pressed Escape, clicked Stop, or the view went away.
        case cancelled
        /// Something was pressed, but it cannot be used. Carries the reason to show.
        case rejected(ShortcutValidationError)
    }

    /// Whether monitors are currently installed.
    private(set) var isRecording = false

    /// The modifiers held right now, for the live display in the recorder box. Empty when idle.
    private(set) var heldModifiers: ModifierFlags = []

    /// The reason the last attempt was refused, shown inline under the box. Cleared on the next
    /// `start()`.
    private(set) var lastRejection: ShortcutValidationError?

    /// The installed monitor tokens.
    ///
    /// Held in a separate reference type rather than in a stored property so that `deinit` — which
    /// is `nonisolated`, because deallocation can happen anywhere — can still reach them. Leaving a
    /// monitor installed after the recorder is gone would mean the app kept watching key presses
    /// with nothing listening, which is exactly the thing this class promises not to do.
    private let tokens = MonitorTokens()

    private var completion: (@MainActor (Outcome) -> Void)?

    init() {}

    deinit {
        tokens.removeAll()
    }

    // MARK: - Session

    /// Begins listening. The completion runs exactly once, on the main actor.
    func start(completion: @escaping @MainActor (Outcome) -> Void) {
        guard !isRecording else { return }

        self.completion = completion
        lastRejection = nil
        heldModifiers = []
        isRecording = true

        // Returning nil from a local monitor swallows the event, so the keystrokes used to record a
        // shortcut do not also reach the UI behind it — no stray text in a field, no menu opening
        // because the user pressed ⌘N while recording.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handleKeyDown(event)
            return nil
        }

        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.heldModifiers = ModifierFlags(nsEventFlags: event.modifierFlags)
            return nil
        }

        // ⏏ arrives as a system-defined event, not a key event, so it needs its own monitor to be
        // recognised and refused rather than silently ignored.
        let systemMonitor = NSEvent.addLocalMonitorForEvents(matching: [.systemDefined]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.subtype.rawValue == SystemDefinedEventDecoder.auxControlButtonsSubtype,
                  let decoded = SystemDefinedEventDecoder.decodeAuxData1(event.data1),
                  decoded.keyType == SystemDefinedEventDecoder.ejectKeyType
            else { return event }

            if decoded.isDown { self.finish(.rejected(.ejectKey)) }
            return nil
        }

        tokens.store([keyMonitor, flagsMonitor, systemMonitor].compactMap { $0 })
    }

    /// Ends the session without recording anything.
    func cancel() {
        guard isRecording else { return }
        finish(.cancelled)
    }

    /// Forgets the inline rejection message, e.g. when the recorder view disappears.
    func clearRejection() {
        lastRejection = nil
    }

    // MARK: - Handling

    private func handleKeyDown(_ event: NSEvent) {
        let modifiers = ModifierFlags(nsEventFlags: event.modifierFlags)

        // Escape alone means "never mind".
        if event.keyCode == KeyCodes.escape, modifiers.isEmpty {
            finish(.cancelled)
            return
        }

        guard let shortcut = Self.shortcut(from: event) else {
            // A modifier-only `keyDown` should not be possible (those arrive as `flagsChanged`),
            // but treating it as the error it would be is cheaper than assuming.
            finish(.rejected(.modifierOnly))
            return
        }

        if let error = ShortcutValidator.validate(shortcut) {
            finish(.rejected(error))
            return
        }

        finish(.recorded(shortcut))
    }

    /// Removes the monitors and reports the outcome. Every exit path goes through here, which is
    /// what guarantees the app stops watching key presses the moment recording ends.
    private func finish(_ outcome: Outcome) {
        tokens.removeAll()
        isRecording = false
        heldModifiers = []

        if case .rejected(let error) = outcome {
            lastRejection = error
        }

        let callback = completion
        completion = nil
        callback?(outcome)
    }

    // MARK: - Pure conversion

    /// Converts a key event into a shortcut. Pure and static, so the conversion rules can be tested
    /// with synthetic `NSEvent`s and no UI at all.
    ///
    /// Returns `nil` for anything that is not a key-down, and for a key-down whose key is itself a
    /// modifier.
    ///
    /// The fn bit is stripped for keys that always carry it: macOS reports the arrows, Home, End,
    /// Page Up/Down, Forward Delete, Help and F1–F20 with fn already set whether or not the user
    /// touched the fn key (`KeyCodes.functionFlagKeys`). Keeping it would store "⌃⌥←" as
    /// "fn ⌃ ⌥ ←" — displayed wrongly, and compared unequal to the same chord recorded elsewhere.
    static func shortcut(from event: NSEvent) -> KeyboardShortcut? {
        guard event.type == .keyDown else { return nil }

        let keyCode = event.keyCode
        guard !KeyCodes.isModifier(keyCode) else { return nil }

        var modifiers = ModifierFlags(nsEventFlags: event.modifierFlags)
        if KeyCodes.functionFlagKeys.contains(keyCode) {
            modifiers.remove(.function)
        }

        return KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
    }
}

/// A tiny, thread-safe holder for `NSEvent` monitor tokens.
///
/// Exists for one reason: `ShortcutRecorder` is `@MainActor`, so its `deinit` is `nonisolated` and
/// cannot read main-actor state. Putting the tokens behind this class lets the recorder guarantee
/// that its monitors are torn down even if it is deallocated mid-session.
///
/// `NSEvent.removeMonitor` is safe to call from any thread with a token obtained on the main thread.
private final class MonitorTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Any] = []

    func store(_ newTokens: [Any]) {
        lock.lock()
        let previous = storage
        storage = newTokens
        lock.unlock()
        for token in previous { NSEvent.removeMonitor(token) }
    }

    func removeAll() {
        lock.lock()
        let previous = storage
        storage = []
        lock.unlock()
        for token in previous { NSEvent.removeMonitor(token) }
    }
}
