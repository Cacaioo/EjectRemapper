//
//  EjectAction.swift
//  EjectRemapper
//

import Foundation

/// What the Eject key can be bound to, as a plain enumerable identity.
///
/// WHY this is separate from ``EjectAction``: the UI needs something `CaseIterable` and
/// `Identifiable` to build a radio group from, and the dispatcher needs a stable dictionary key.
/// `EjectAction` carries a payload for one of its cases, which makes it neither. Splitting the
/// *identity* from the *value* keeps both simple, and means adding a new action is a matter of
/// adding one case here, one case there, and one handler — nothing else changes.
enum EjectActionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case forwardDelete
    case lockScreen
    case screenshot
    case screenshotMenu
    case customShortcut
    case original
    case disabled

    var id: String { rawValue }

    /// The label shown in the menu and in Settings.
    var title: String {
        switch self {
        case .forwardDelete: return String(localized: "Forward Delete")
        case .lockScreen: return String(localized: "Lock Screen")
        case .screenshot: return String(localized: "Screenshot")
        case .screenshotMenu: return String(localized: "Screenshot Menu")
        case .customShortcut: return String(localized: "Custom Shortcut")
        case .original: return String(localized: "Original Function")
        case .disabled: return String(localized: "Disabled")
        }
    }

    /// One sentence of plain language, shown under the label. No jargon: a user should never have
    /// to know what an event tap is to choose an option.
    var summary: String {
        switch self {
        case .forwardDelete:
            return String(localized: "Delete the character to the right of the cursor.")
        case .lockScreen:
            return String(localized: "Lock the screen right away.")
        case .screenshot:
            return String(localized: "Capture the whole screen, like ⇧⌘3.")
        case .screenshotMenu:
            return String(localized: "Open the screenshot toolbar, like ⇧⌘5.")
        case .customShortcut:
            return String(localized: "Send a keyboard shortcut you choose.")
        case .original:
            return String(localized: "Leave the key alone and let macOS handle it.")
        case .disabled:
            return String(localized: "Do nothing at all when the key is pressed.")
        }
    }

    /// SF Symbol shown beside the label.
    var symbolName: String {
        switch self {
        case .forwardDelete: return "delete.forward"
        case .lockScreen: return "lock"
        case .screenshot: return "camera"
        case .screenshotMenu: return "camera.on.rectangle"
        case .customShortcut: return "command"
        case .original: return "eject"
        case .disabled: return "nosign"
        }
    }
}

/// What the Eject key does, with the data each choice needs.
///
/// Extensibility is a requirement of the spec: a new action means a new case here, a new
/// ``EjectActionKind``, and a handler registered in `AppState.live()`. Nothing in the tap, the
/// detector or the dispatcher needs to change, because they only ever ask this type the two
/// questions below.
enum EjectAction: Hashable, Sendable, Codable {
    case forwardDelete
    case lockScreen
    case screenshot
    case screenshotMenu
    case customShortcut(KeyboardShortcut)
    case original
    case disabled

    /// The identity of this action, for routing and for the UI.
    var kind: EjectActionKind {
        switch self {
        case .forwardDelete: return .forwardDelete
        case .lockScreen: return .lockScreen
        case .screenshot: return .screenshot
        case .screenshotMenu: return .screenshotMenu
        case .customShortcut: return .customShortcut
        case .original: return .original
        case .disabled: return .disabled
        }
    }

    /// Whether the original Eject event should be swallowed.
    ///
    /// `false` for exactly one case — Original Function — where the event is returned to macOS
    /// untouched. Every other action replaces the key's meaning, so letting the original through
    /// would produce the old behaviour *and* the new one. Note that Disabled also suppresses: that
    /// is the whole point of Disabled, and it is what makes it different from Original Function.
    ///
    /// This does not cover the modifier rule (⌃⇧⏏ and friends) — that is a property of the *press*,
    /// not of the action, and lives in `KeyboardEventManager`.
    var suppressesOriginalEvent: Bool {
        switch self {
        case .original: return false
        default: return true
        }
    }

    /// Whether holding the Eject key should repeat this action.
    ///
    /// Only the two actions that imitate a key make sense to repeat. Locking the screen or opening
    /// the screenshot toolbar forty times because someone leaned on the key does not.
    ///
    /// The hardware never helps here: macOS explicitly excludes the Eject key from auto-repeat
    /// (`IOHIDKeyboardFilter.mm`, `isNotRepeated`), so a held key produces exactly one down and one
    /// up. Repeats are generated by `KeyRepeatTimer`. See `docs/TECHNICAL_INVESTIGATION.md` §3.
    var supportsKeyRepeat: Bool {
        switch self {
        case .forwardDelete, .customShortcut: return true
        default: return false
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case shortcut
    }

    /// Encoded with an explicit discriminator — `{"type": "lockScreen"}`,
    /// `{"type": "customShortcut", "shortcut": {…}}` — rather than with Swift's synthesized
    /// representation.
    ///
    /// WHY: the synthesized form for an enum with associated values is an implementation detail of
    /// the compiler and is keyed by case name in a nested container. Spelling it out means the
    /// stored settings stay readable, stay stable across Swift versions, and can gain new cases
    /// without invalidating old data.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(EjectActionKind.self, forKey: .type)
        switch kind {
        case .forwardDelete: self = .forwardDelete
        case .lockScreen: self = .lockScreen
        case .screenshot: self = .screenshot
        case .screenshotMenu: self = .screenshotMenu
        case .original: self = .original
        case .disabled: self = .disabled
        case .customShortcut:
            let shortcut = try container.decode(KeyboardShortcut.self, forKey: .shortcut)
            self = .customShortcut(shortcut)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        if case .customShortcut(let shortcut) = self {
            try container.encode(shortcut, forKey: .shortcut)
        }
    }
}
