//
//  TestEnvironment.swift
//  EjectRemapper
//
//  Created for the EjectRemapper System layer.
//

import Foundation

/// Detects whether the process is currently hosting an XCTest run.
///
/// WHY this exists: `EjectRemapperTests` is an *app-hosted* XCTest bundle. `xcodebuild test`
/// therefore launches the real `EjectRemapper.app`, which means `@main` runs, the
/// `NSApplicationDelegateAdaptor` is instantiated and `applicationDidFinishLaunching(_:)` fires —
/// all of that on a live, unattended machine. Without this guard a test run would create a real
/// `CGEventTap` at `.cgSessionEventTap`, register a real login item and start suppressing the
/// physical Eject key of whoever is sitting at the Mac. Every side-effecting entry point in the
/// App and System layers checks this flag first.
///
/// The two signals are deliberately redundant:
/// * `XCTestConfigurationFilePath` is set by `xcodebuild`/Xcode in the *host application's*
///   environment before the test bundle is injected, so it is already true in
///   `applicationDidFinishLaunching(_:)` — earlier than the test bundle is loaded.
/// * `NSClassFromString("XCTestCase")` catches the case where the bundle is injected into an
///   already-running process (for example `xctest` attaching to a running host).
enum TestEnvironment {

    /// `true` when this process is running (or is about to run) XCTest.
    ///
    /// Evaluated once and cached: the answer cannot change during the lifetime of the process,
    /// and the value is read from the event-tap thread as well as the main actor.
    static var isRunningTests: Bool { cachedIsRunningTests }

    /// Computed exactly once. `static let` gives us a thread-safe, lazily initialised cache.
    private static let cachedIsRunningTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return false
    }()
}
