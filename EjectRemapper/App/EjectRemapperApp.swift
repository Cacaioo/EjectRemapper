//
//  EjectRemapperApp.swift
//  EjectRemapper
//

import SwiftUI

/// The app's only SwiftUI scene: a menu bar item.
///
/// WHY `MenuBarExtra` and nothing else:
/// * The app is `LSUIElement` / `.accessory` — it must never show a Dock icon or open a window at
///   launch. A `WindowGroup` would open a window immediately, so there is none.
/// * There is **no `Settings` scene** either. Settings is an AppKit window owned by
///   ``SettingsWindowController``; see that type for the reasoning. That keeps a single code path
///   for "open Settings" usable from the menu, from `applicationShouldHandleReopen` and from the
///   recovery flow when the menu bar icon is hidden.
///
/// `.menuBarExtraStyle(.window)` gives the popover-style panel the design needs (radio group,
/// inline status, buttons); the default `.menu` style only renders `Button`/`Divider`/`Text`.
@main
struct EjectRemapperApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: showMenuBarIcon) {
            MenuBarView()
                .environment(delegate.appState)
        } label: {
            // SF Symbol, so it follows the menu bar's template rendering in light and dark modes
            // and in the reduced-transparency / increased-contrast settings.
            Image(systemName: "eject.fill")
                .accessibilityLabel(Text("Eject Key Remap"))
        }
        .menuBarExtraStyle(.window)
    }

    /// Two-way binding to the persisted "Show Menu Bar Icon" preference.
    ///
    /// `isInserted` is what actually removes the item from the menu bar; hiding it is a supported
    /// state, and the user gets it back by launching the app again (see `AppDelegate`).
    private var showMenuBarIcon: Binding<Bool> {
        Binding(
            get: { delegate.appState.settings.showMenuBarIcon },
            set: { delegate.appState.settings.showMenuBarIcon = $0 }
        )
    }
}
