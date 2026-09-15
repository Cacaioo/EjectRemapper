//
//  ForwardDeleteAction.swift
//  EjectRemapper
//
//  The default action: turn ⏏ into the Forward Delete key the Magic Keyboard does not have.
//

import Foundation
import os

/// Posts `kVK_ForwardDelete` for as long as the Eject key is held.
///
/// The key code is `0x75` (`kVK_ForwardDelete`, `Events.h:305`). A probe confirmed the synthesized
/// event reads back as key code 117 with characters `U+F728` (`NSDeleteFunctionKey`) and the fn flag
/// set automatically by Core Graphics — so this handler must *not* add fn itself.
///
/// The key is always sent bare. ⌥⌦ and ⌘⌦ cannot be produced from ⏏: every Eject press with ⌘, ⌃, ⌥
/// or ⇧ held is passed through to macOS (`ModifierFlags.passThroughModifiers`), so that the system
/// chords keep working, and this handler never sees it. `KeyboardEventGenerator.baseline(fromSessionFlags:)`
/// relies on the same rule.
///
/// Hold-to-repeat is software (`KeyRepeatTimer`): the hardware never repeats Eject.
final class ForwardDeleteAction: EjectActionHandler, @unchecked Sendable {
    private static let chord = KeyboardShortcut(keyCode: KeyCodes.forwardDelete, modifiers: [])

    private let generator: KeyboardEventGenerator
    private let guardedQueue: ActionQueueGuard
    private let timer: any RepeatTimer

    /// True exactly while Forward Delete is held down.
    private var isHeld = false

    /// - Parameters:
    ///   - generator: builds and posts the events (test doubles capture instead of posting).
    ///   - queue: the dispatcher's action queue.
    ///   - makeTimer: repeat clock factory; the default reads the user's Key Repeat settings, which
    ///     must happen on the main thread — construct handlers during app wiring, not from the queue.
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
                self.press()
            case .keyRepeat:
                // Hardware repeats cannot happen for Eject, and if one ever did the software timer is
                // already driving the repeat — honouring both would double the rate.
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

    private func press() {
        guard !isHeld else { return }   // already down; nothing to do
        isHeld = true
        generator.holdDown(Self.chord)
        timer.start({ [weak self] in
            self?.repeatKey()
        }, onExpire: { [weak self] in
            self?.release()
        })
    }

    private func repeatKey() {
        guard isHeld else { return }
        generator.repeatHeld(Self.chord)
    }

    /// Releases the key and, through the generator, restores the session's modifier state.
    private func release() {
        timer.cancel()
        guard isHeld else { return }
        isHeld = false
        generator.releaseHeld(Self.chord)
    }
}
