import CoreGraphics
import Foundation
import os

/// Builds and posts synthetic keyboard events.
///
/// ## The invariant this type exists to keep
///
/// **Every sequence of synthesized events ends with the session's modifier state exactly as the
/// user's real keyboard has it.**
///
/// The operating system does not guarantee this, and a private event source does not isolate it.
/// Measured on macOS 26.5 (docs/TECHNICAL_INVESTIGATION.md §5, "Modifier state is session-wide"):
/// after posting a key down and a key up that both carry ⇧⌘ as flags, `CGEventSource.flagsState`
/// reports ⇧⌘ held for the whole login session, and the physical key presses that follow arrive
/// stamped with ⇧⌘. The latch outlives the process that posted the events. Only a later
/// flags-changed event clears it.
///
/// That was the cause of a real bug. The Screenshot action sent ⇧⌘3 as a flags-only key tap; every
/// later Eject press then looked like ⇧⌘⏏, and the rule that modified Eject presses belong to macOS
/// passed them all straight through. No action worked again until something released the modifiers.
///
/// The invariant is kept structurally, so no caller can forget it:
/// - There is no way to post a key whose modifier flags are not released afterwards. ``press(_:)``
///   sends a complete, balanced chord. ``holdDown(_:)`` starts one that only ``releaseHeld(_:)``
///   finishes.
/// - Each sequence records the physical modifiers when it starts and, when it ends, returns the
///   session to exactly those. That covers flags Core Graphics adds on its own, such as fn on
///   navigation keys, and flags the user really is holding, such as Caps Lock.
///
/// `@unchecked Sendable`: the event source and poster are immutable references, and the only mutable
/// state, the sequence in progress, is behind an `OSAllocatedUnfairLock`. The lock matters because
/// most calls come from the action queue, but the Screenshot Menu fallback runs on whichever thread
/// `NSWorkspace` completes on.
final class KeyboardEventGenerator: @unchecked Sendable {

    /// The key used to carry a flags-only resynchronisation event at the end of a sequence, when
    /// releasing the chord's own modifiers did not already restore the session.
    ///
    /// Control, because it is neither a toggle (unlike Caps Lock, whose key code flips the lock) nor
    /// the Globe key (whose key code can open the emoji picker or start dictation). The probe that
    /// established the latch cleared it with exactly this event. If the user is physically holding
    /// Control, the next candidate is used so the event never claims a held key was released.
    private static let resyncCandidates: [ModifierFlags] = [.control, .option, .shift, .command]

    private let poster: any EventPosting

    /// Tags every event this app creates, so the event tap and other tools can tell them apart from
    /// hardware events.
    private let source: CGEventSource?

    /// Reads the modifiers the hardware is really holding.
    private let physicalModifiers: @Sendable () -> ModifierFlags

    /// A synthesized sequence that has started and not yet been restored.
    private struct Sequence {
        /// The physical modifiers when the sequence began. This is what the session returns to.
        let baseline: ModifierFlags
        /// The modifiers the session holds now: the flags of the most recently posted event.
        var session: ModifierFlags
    }

    private let sequence = OSAllocatedUnfairLock<Sequence?>(initialState: nil)

    /// - Parameters:
    ///   - poster: where events go. Tests pass a recorder.
    ///   - physicalModifiers: reads the modifiers the user is really holding when a sequence starts.
    ///     The default applies ``baseline(fromSessionFlags:)`` to the HID system state.
    init(poster: any EventPosting = HIDEventPoster(),
         physicalModifiers: @escaping @Sendable () -> ModifierFlags = {
             KeyboardEventGenerator.baseline(fromSessionFlags: CGEventSource.flagsState(.hidSystemState))
         }) {
        self.poster = poster
        self.physicalModifiers = physicalModifiers
        let source = CGEventSource(stateID: .privateState)
        // Every event created from this source inherits the tag; it is also stamped per event
        // below, because a few CG paths rebuild events without preserving source user data.
        source?.userData = GeneratedEventTag.userData
        self.source = source
    }

    /// The modifiers a sequence restores the session to, derived from a reading of the session's flags.
    ///
    /// ⌘, ⌃, ⌥ and ⇧ are always excluded, and that is exact rather than approximate. An action only
    /// runs for an Eject press made without them, because every press with one held is passed through
    /// to macOS (`ModifierFlags.passThroughModifiers`). So when a sequence starts, none of them is
    /// physically held, and any the reading shows can only be this app's own chord.
    ///
    /// The reading can be stale. On macOS 26.5, a read taken straight after posting a flags change still
    /// showed the previous flags in 20 of 20 attempts (docs/TECHNICAL_INVESTIGATION.md §5). Without the
    /// mask, a sequence that starts right after another, as when a lost key-up is recovered, could record
    /// half of a ⇧⌘ chord as the user's baseline and restore the session to it. fn and Caps Lock are kept:
    /// the user can genuinely hold fn or have Caps Lock on.
    static func baseline(fromSessionFlags flags: CGEventFlags) -> ModifierFlags {
        ModifierFlags(cgEventFlags: flags).subtracting(.passThroughModifiers)
    }

    // MARK: - Complete chords

    /// Sends a complete chord the way a person types it: modifier keys down, key down, key up,
    /// modifier keys up. The session's modifier state is restored before this returns.
    ///
    /// Used both for custom shortcuts and for the system hot keys (⇧⌘3, ⇧⌘5, ⌃⌘Q). A person pressing
    /// a system hot key produces exactly these events, so the window server recognises them the same
    /// way.
    func press(_ shortcut: KeyboardShortcut) {
        holdDown(shortcut)
        releaseHeld(shortcut)
    }

    // MARK: - Held chords

    /// Starts a chord that stays down until ``releaseHeld(_:)``: modifier keys down, then key down.
    ///
    /// For actions that repeat while the Eject key is held. If a previous held chord was never
    /// released, it is restored first rather than left latched.
    func holdDown(_ shortcut: KeyboardShortcut) {
        if hasOpenSequence {
            Log.actions.error("A synthesized key was still held when a new one started; restoring modifier state first")
            restoreSession()
        }
        beginSequence()
        modifiersDown(shortcut.modifiers)
        postKeyEvent(keyCode: shortcut.keyCode, keyDown: true, modifiers: shortcut.modifiers, isRepeat: false)
    }

    /// Repeats the key of a held chord, marked as an auto-repeat.
    func repeatHeld(_ shortcut: KeyboardShortcut) {
        postKeyEvent(keyCode: shortcut.keyCode, keyDown: true, modifiers: shortcut.modifiers, isRepeat: true)
    }

    /// Ends a held chord: key up, modifier keys up, then the session's modifier state is restored.
    func releaseHeld(_ shortcut: KeyboardShortcut) {
        postKeyEvent(keyCode: shortcut.keyCode, keyDown: false, modifiers: shortcut.modifiers, isRepeat: false)
        modifiersUp(shortcut.modifiers)
        restoreSession()
    }

    // MARK: - Sequence state

    private var hasOpenSequence: Bool {
        sequence.withLock { $0 != nil }
    }

    private func beginSequence() {
        let baseline = physicalModifiers()
        sequence.withLock { $0 = Sequence(baseline: baseline, session: baseline) }
    }

    /// Records the flags of an event that was just posted as the session's modifier state, which is
    /// the window server behaviour measured on macOS 26.5.
    private func recordPosted(_ flags: CGEventFlags) {
        let modifiers = ModifierFlags(cgEventFlags: flags)
        sequence.withLock { $0?.session = modifiers }
    }

    /// Closes the open sequence, posting one flags-changed event if the session does not already
    /// match the baseline.
    ///
    /// In the common case, a chord whose modifier keys were just released with no modifiers
    /// physically held, the session already matches and nothing extra is posted.
    private func restoreSession() {
        let closed = sequence.withLock { state -> Sequence? in
            defer { state = nil }
            return state
        }
        guard let closed, closed.session != closed.baseline else { return }

        let carrier = Self.resyncCandidates.first { !closed.baseline.contains($0) } ?? .control
        guard let keyCode = carrier.keyCode else { return }
        postFlagsChanged(keyCode: keyCode, modifiers: closed.baseline)
    }

    // MARK: - Modifier keys

    /// Emits one `flagsChanged` per modifier, in canonical order (fn ⌃ ⌥ ⇧ ⌘), with the flag set
    /// accumulating as it goes — exactly what a human pressing the chord produces.
    ///
    /// Caps Lock is **never** pressed as a key: its virtual key toggles the real Caps Lock state,
    /// which would outlive the shortcut. It is carried as a flag only
    /// (TECHNICAL_INVESTIGATION.md §5 "Custom shortcut").
    private func modifiersDown(_ modifiers: ModifierFlags) {
        var cumulative: ModifierFlags = []
        for modifier in modifiers.ordered {
            cumulative.insert(modifier)
            guard modifier != .capsLock, let keyCode = modifier.keyCode else { continue }
            postFlagsChanged(keyCode: keyCode, modifiers: cumulative)
        }
    }

    /// The exact reverse of ``modifiersDown(_:)``: releases in reverse canonical order with the flag
    /// set decreasing to empty.
    private func modifiersUp(_ modifiers: ModifierFlags) {
        var remaining = modifiers
        for modifier in modifiers.ordered.reversed() {
            remaining.remove(modifier)
            guard modifier != .capsLock, let keyCode = modifier.keyCode else { continue }
            postFlagsChanged(keyCode: keyCode, modifiers: remaining)
        }
    }

    // MARK: - Construction

    private func postKeyEvent(keyCode: UInt16, keyDown: Bool, modifiers: ModifierFlags, isRepeat: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else {
            Log.actions.error("Failed to create keyboard event for key code \(keyCode, privacy: .public)")
            return
        }
        // Union, never assignment: CoreGraphics sets the fn bit automatically for the keys that need
        // it (arrows, forward delete, F-keys), and overwriting the flags would drop it.
        event.flags = event.flags.union(modifiers.cgEventFlags)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: GeneratedEventTag.userData)
        poster.post(event)
        recordPosted(event.flags)
    }

    private func postFlagsChanged(keyCode: UInt16, modifiers: ModifierFlags) {
        // There is no `CGEvent(flagsChangedEventSource:)`. The documented idiom is to build a key
        // event and retype it; the virtual key code identifies which modifier moved.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            Log.actions.error("Failed to create flagsChanged event for key code \(keyCode, privacy: .public)")
            return
        }
        event.type = .flagsChanged
        event.flags = modifiers.cgEventFlags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: GeneratedEventTag.userData)
        poster.post(event)
        recordPosted(event.flags)
    }
}
