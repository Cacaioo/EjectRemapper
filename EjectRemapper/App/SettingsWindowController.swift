//
//  SettingsWindowController.swift
//  EjectRemapper
//

import AppKit
import Foundation
import SwiftUI

/// Hosts `SettingsView` in a plain AppKit window.
///
/// WHY AppKit instead of SwiftUI's `Settings` scene: this app is `LSUIElement` and its only scene
/// is a `MenuBarExtra`. A `Settings` scene can then only be opened through `SettingsLink` or the
/// private `showSettingsWindow:` selector — the former cannot be triggered from
/// `applicationShouldHandleReopen(_:hasVisibleWindows:)`, and the latter has changed name twice
/// between macOS 12 and 14. The app needs to open Settings from three places (the menu bar item, a
/// reopen, and the "the icon is hidden" recovery path), so it owns the window itself. One
/// deliberate choice, stated here so it is not re-litigated: **there is no `Settings` scene.**
///
/// The window is created on demand — never at launch — because an accessory app must show nothing
/// until the user asks.
@MainActor
final class SettingsWindowController: NSWindowController {

    /// - Parameter appState: injected into the SwiftUI environment for the whole settings tree.
    convenience init(appState: AppState) {
        let hosting = NSHostingController(rootView: SettingsView().environment(appState))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Eject Key Remap Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false      // the controller outlives the window's first close
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        self.init(window: window)
        window.delegate = nil
    }

    /// Brings the window to the front, activating the app first.
    ///
    /// An `.accessory` app is not in the Dock and is not "activated" by a click on its menu bar
    /// item, so without `NSApp.activate()` the window would open behind whatever the user was
    /// using. `activate()` (macOS 14+) replaces the deprecated
    /// `activate(ignoringOtherApps:)`.
    func show() {
        if window == nil { return }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
