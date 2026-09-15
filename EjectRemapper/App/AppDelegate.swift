//
//  AppDelegate.swift
//  EjectRemapper
//

import AppKit
import Foundation

/// The AppKit half of the app: activation policy, reopen handling, teardown — and, above all, the
/// XCTest guard.
///
/// ## WHY the XCTest guard is critical
/// `EjectRemapperTests` is hosted by this very application, so `xcodebuild test` launches
/// `EjectRemapper.app` for real. `@main` runs, this delegate is instantiated and
/// `applicationDidFinishLaunching(_:)` fires *before* a single test does. An unguarded delegate
/// would therefore create a live `CGEventTap` at `.cgSessionEventTap`, start suppressing the Eject
/// key and possibly register a login item — on the developer's machine, every time the test suite
/// runs. Hence: under `TestEnvironment.isRunningTests` the delegate builds the inert
/// ``AppState/preview()`` graph and never calls `start()`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The instance SwiftUI's `@NSApplicationDelegateAdaptor` created, for the rare non-SwiftUI
    /// call site (menu actions, `NSApp.delegate` round trips).
    private(set) static var shared: AppDelegate?

    /// The one and only application graph.
    ///
    /// DEVIATION from the contract, deliberately: the contract says the state is "created in
    /// `applicationDidFinishLaunching`". It is created in `init()` instead, because SwiftUI may
    /// evaluate the `MenuBarExtra` scene body before `applicationDidFinishLaunching(_:)` runs and
    /// the scene needs a non-optional `AppState` to put in the environment. Construction is inert
    /// either way — `AppState.live()` only allocates objects; nothing observes, taps or registers
    /// until `start()`, which still happens in `applicationDidFinishLaunching(_:)` and still only
    /// outside tests.
    let appState: AppState

    override init() {
        if TestEnvironment.isRunningTests {
            appState = AppState.preview()
        } else {
            appState = AppState.live()
        }
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `LSUIElement` is already YES in the Info.plist, but set the policy explicitly as well:
        // the plist value can be overridden by a stale launch cache, and a Dock icon appearing for
        // a menu-bar utility is a visible bug.
        //
        // `.accessory` and NOT `.prohibited`: Apple DTS is explicit that `.prohibited` breaks event
        // taps (the process is not a full UI session participant), which is the one thing this app
        // cannot lose. `.accessory` gives the same "no Dock icon, no menu bar" result while keeping
        // the app able to activate and show its Settings window.
        NSApp.setActivationPolicy(.accessory)

        guard !TestEnvironment.isRunningTests else {
            Log.app.notice("Launched as an XCTest host — event tap, prompts and login item are disabled")
            return
        }

        Log.app.notice("EjectRemapper launched")
        appState.start()
    }

    // MARK: - Reopen

    /// Reopening the app (double-clicking it in Finder, or `open -a`) shows Settings.
    ///
    /// WHY: "Show Menu Bar Icon" can be turned off, and then the app has no visible UI at all. The
    /// documented recovery is to launch the app again — which produces exactly this callback,
    /// because the process is already running. Returning `false` tells AppKit not to try to
    /// un-hide or create windows on its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !TestEnvironment.isRunningTests else { return false }
        appState.openSettings()
        return false
    }

    // MARK: - Termination

    /// A menu-bar utility has no windows, so closing one must never quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !TestEnvironment.isRunningTests else { return }
        // Tearing the tap down explicitly matters: a tap abandoned by a dying process can leave the
        // keyboard misbehaving until the Mach port is reaped.
        appState.stop()
        Log.app.notice("EjectRemapper terminating")
    }

    /// Opts into secure state restoration; without it macOS logs a warning on every launch.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
