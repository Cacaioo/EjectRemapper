//
//  AppSettings.swift
//  EjectRemapper
//

import Foundation
import Observation

/// Everything the user can configure, backed by `UserDefaults`.
///
/// WHY `UserDefaults` and nothing more: there are six values. A database would be absurd, and the
/// spec rules one out explicitly. Every setter writes through immediately — there is no save button
/// and no batching, so a crash can never lose a change, and the settings survive a relaunch, a
/// logout and a restart because that is what `UserDefaults` does.
///
/// WHY `@Observable` rather than `@AppStorage`: the values are read by the keyboard layer, not only
/// by views. `@AppStorage` is a SwiftUI property wrapper that only works inside a view, and these
/// settings have two very different audiences. Views track them through observation, which is
/// asynchronous and perfectly adequate for redrawing a checkbox. The event tap cannot afford that,
/// so it is notified through ``onChange`` in the same turn as the mutation. See that property.
@MainActor
@Observable
final class AppSettings {

    /// Defaults keys. Namespaced so they cannot collide with anything else in the app's domain.
    enum Keys {
        static let remappingEnabled = "settings.remappingEnabled"
        static let actionKind = "settings.actionKind"
        static let customShortcut = "settings.customShortcut"
        static let showMenuBarIcon = "settings.showMenuBarIcon"
        static let hasPromptedForAccessibility = "settings.hasPromptedForAccessibility"
    }

    /// The store. Injectable so tests and previews use a scratch suite rather than the user's real
    /// preferences — a test that flips the user's settings would be a bug in itself.
    private let defaults: UserDefaults

    /// Called **synchronously**, on the main actor, immediately after any setting actually changes.
    ///
    /// WHY this exists alongside `@Observable`: observation is how the *views* stay in step, and it
    /// is asynchronous — `withObservationTracking`'s callback fires before the new value is
    /// readable, so an observer has to hop to a later main-actor turn to read it. That is fine for
    /// redrawing a checkbox and wrong for the event tap, which must never act on a stale
    /// configuration. `KeyboardEventManager` installs itself here so the snapshot the tap reads is
    /// updated in the same turn as the mutation, with no window in between.
    var onChange: (@MainActor () -> Void)?

    /// Records the write and notifies. Every setter ends with this.
    private func didChange() {
        onChange?()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Registering defaults rather than writing them keeps the stored domain empty until the
        // user actually changes something, so `defaults read` shows only real choices.
        defaults.register(defaults: [
            Keys.remappingEnabled: true,
            Keys.showMenuBarIcon: true,
            Keys.hasPromptedForAccessibility: false,
            Keys.actionKind: EjectActionKind.forwardDelete.rawValue,
        ])

        storedRemappingEnabled = defaults.bool(forKey: Keys.remappingEnabled)
        storedShowMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        storedHasPrompted = defaults.bool(forKey: Keys.hasPromptedForAccessibility)
        storedActionKind = Self.readActionKind(from: defaults)
        storedCustomShortcut = Self.readShortcut(from: defaults)
    }

    // MARK: - Backing storage
    //
    // The observable properties below are computed so that every write reaches `UserDefaults`
    // synchronously. The private `stored*` values exist so reads do not hit the defaults system on
    // every access and so `@Observable` has something to track.

    private var storedRemappingEnabled: Bool
    private var storedShowMenuBarIcon: Bool
    private var storedHasPrompted: Bool
    private var storedActionKind: EjectActionKind
    private var storedCustomShortcut: KeyboardShortcut?

    // MARK: - Settings

    /// The master switch. When off, the event tap is stopped entirely and the Eject key behaves
    /// exactly as it did before the app was installed.
    var isRemappingEnabled: Bool {
        get { storedRemappingEnabled }
        set {
            guard storedRemappingEnabled != newValue else { return }
            storedRemappingEnabled = newValue
            defaults.set(newValue, forKey: Keys.remappingEnabled)
            didChange()
        }
    }

    /// Which action the Eject key is bound to.
    var actionKind: EjectActionKind {
        get { storedActionKind }
        set {
            guard storedActionKind != newValue else { return }
            storedActionKind = newValue
            defaults.set(newValue.rawValue, forKey: Keys.actionKind)
            didChange()
        }
    }

    /// The recorded custom shortcut, if any. Stored as JSON, so the shape is
    /// `{"keyCode":8,"modifiers":1048576}` rather than a display string.
    var customShortcut: KeyboardShortcut? {
        get { storedCustomShortcut }
        set {
            guard storedCustomShortcut != newValue else { return }
            storedCustomShortcut = newValue
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.customShortcut)
            } else {
                defaults.removeObject(forKey: Keys.customShortcut)
            }
            didChange()
        }
    }

    /// Whether the menu bar item is shown. With it hidden, re-launching the app from the Finder
    /// opens Settings instead — see `AppState.openSettings()`.
    var showMenuBarIcon: Bool {
        get { storedShowMenuBarIcon }
        set {
            guard storedShowMenuBarIcon != newValue else { return }
            storedShowMenuBarIcon = newValue
            defaults.set(newValue, forKey: Keys.showMenuBarIcon)
            didChange()
        }
    }

    /// Whether the app has already shown the system Accessibility prompt at some point in its life.
    ///
    /// Persisted so a user who declined once is not nagged on every launch; they can still reach
    /// the permission from the popover and from Settings whenever they want it.
    var hasPromptedForAccessibility: Bool {
        get { storedHasPrompted }
        set {
            guard storedHasPrompted != newValue else { return }
            storedHasPrompted = newValue
            defaults.set(newValue, forKey: Keys.hasPromptedForAccessibility)
            didChange()
        }
    }

    // MARK: - Derived

    /// The action the keyboard layer should actually apply.
    ///
    /// This is the single place where "what the user picked" becomes "what happens", and it exists
    /// because of one asymmetry: `.customShortcut` needs a payload that may not be there yet. A
    /// user can select Custom Shortcut and then never record anything. Rather than crash, ignore
    /// the setting, or send a garbage key code, the action degrades to `.disabled` — the Eject key
    /// does nothing, which is the honest and safe reading of "a custom shortcut, but there isn't
    /// one". ``configurationWarning`` tells them so.
    var resolvedAction: EjectAction {
        switch actionKind {
        case .forwardDelete: return .forwardDelete
        case .lockScreen: return .lockScreen
        case .screenshot: return .screenshot
        case .screenshotMenu: return .screenshotMenu
        case .original: return .original
        case .disabled: return .disabled
        case .customShortcut:
            guard let customShortcut else { return .disabled }
            return .customShortcut(customShortcut)
        }
    }

    /// A sentence to show when the configuration is valid but incomplete, or `nil` when all is well.
    var configurationWarning: String? {
        guard actionKind == .customShortcut, customShortcut == nil else { return nil }
        return String(localized: "No shortcut recorded yet — the Eject key does nothing until you record one.")
    }

    // MARK: - Reading

    private static func readActionKind(from defaults: UserDefaults) -> EjectActionKind {
        guard let raw = defaults.string(forKey: Keys.actionKind),
              let kind = EjectActionKind(rawValue: raw)
        else {
            // An unknown value means a downgrade from a future version that had more actions.
            // Falling back to the default is better than refusing to launch.
            return .forwardDelete
        }
        return kind
    }

    private static func readShortcut(from defaults: UserDefaults) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: Keys.customShortcut) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}
