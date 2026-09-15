//
//  CustomShortcutAction.swift
//  EjectRemapper
//
//  Turn ⏏ into any shortcut the user recorded.
//

import Foundation
import os

/// Presses, holds and releases a user-recorded shortcut.
///
/// The full sequence a real chord produces is reproduced (TECHNICAL_INVESTIGATION.md §5):
///
/// ```
/// flagsChanged (modifiers down, fn ⌃ ⌥ ⇧ ⌘ order, flags accumulating)
/// keyDown  (target key, full flags)          ← repeated while held
/// keyUp    (target key, full flags)
/// flagsChanged (modifiers up, reverse order)
/// ```
///
/// `reset()` releasing *both* the key and the modifiers is the single most important behaviour in this
/// file. If the app stopped, lost the key-up, or the user switched actions mid-press while ⌘ was
/// synthesised down, a missing modifier key-up would leave the whole system behaving as if Command
/// were held — every keystroke becoming a menu shortcut. The safety cap in `KeyRepeatTimer` exists for
/// the same reason.
final class CustomShortcutAction: EjectActionHandler, @unchecked Sendable {
    private let generator: KeyboardEventGenerator
    private let guardedQueue: ActionQueueGuard
    private let timer: any RepeatTimer

    /// Non-nil exactly while the shortcut is synthesised down. Stored (rather than re-read from the
    /// action) so the release always matches what was pressed, even if the user edits the shortcut in
    /// Settings mid-press.
    private var heldShortcut: KeyboardShortcut?

    init(generator: KeyboardEventGenerator,
         queue: DispatchQueue,
         makeTimer: @Sendable (DispatchQueue) -> any RepeatTimer = { queue in
             let settings = KeyRepeatTimer.systemRepeatSettings()
             return KeyRepeatTimer(queue: queue, initialDelay: settings.delay, interval: settings.interval)
         }) {
        self.generator = generator
        self.guardedQueue = ActionQueueGuard(queue)
        self.timer = makeTimer(queue)
    }

    func execute(action: EjectAction, trigger: ActionTrigger) {
        guardedQueue.sync {
            switch trigger {
            case .keyDown:
                guard case .customShortcut(let shortcut) = action else {
                    Log.actions.error("CustomShortcutAction received a non-custom action")
                    return
                }
                self.press(shortcut)
            case .keyRepeat:
                // The software timer already drives repeat; see ForwardDeleteAction.
                break
            case .keyUp:
                self.release()
            }
        }
    }

    func reset() {
        guardedQueue.sync { self.release() }
    }

    // MARK: - Action queue only

    private func press(_ shortcut: KeyboardShortcut) {
        guard heldShortcut == nil else { return }
        heldShortcut = shortcut
        generator.holdDown(shortcut)
        timer.start({ [weak self] in
            self?.repeatKey()
        }, onExpire: { [weak self] in
            self?.release()
        })
    }

    private func repeatKey() {
        guard let shortcut = heldShortcut else { return }
        generator.repeatHeld(shortcut)
    }

    private func release() {
        timer.cancel()
        guard let shortcut = heldShortcut else { return }
        heldShortcut = nil
        generator.releaseHeld(shortcut)
    }
}
