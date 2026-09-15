//
//  LoginItemManager.swift
//  EjectRemapper
//

import Foundation
import Observation
import ServiceManagement

/// The subset of `SMAppService` the app actually uses, behind a protocol.
///
/// WHY: `SMAppService.mainApp.register()` writes a real, persistent login item into the user's
/// account. Unit tests run inside the app bundle on a live machine, so they must never reach the
/// real service. Everything side-effecting goes through this seam; tests inject a double.
///
/// `SMAppService.Status` is a plain value enum (`ServiceManagement/SMAppService.h`), so passing it
/// across the seam costs nothing and keeps the status-mapping logic testable.
protocol LoginItemService: Sendable {
    /// Current registration state as reported by the system.
    var status: SMAppService.Status { get }
    /// Registers the main app as a login item. Throws the raw `NSError` from `SMAppService`.
    func register() throws
    /// Removes the login-item registration.
    func unregister() throws
    /// Opens System Settings › General › Login Items.
    func openSystemSettingsLoginItems()
}

/// The real implementation, backed by `SMAppService.mainApp`.
///
/// WHY the `TestEnvironment` guards inside a type that is already injectable: defence in depth.
/// `AppState.live()` is only built outside tests, but a stray `LoginItemManager()` created by a
/// future test would otherwise register a login item on the developer's machine. `register()` and
/// `unregister()` become no-ops under XCTest; `status` stays readable because it is a pure read.
struct MainAppLoginItemService: LoginItemService {

    init() {}

    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws {
        guard !TestEnvironment.isRunningTests else {
            Log.settings.notice("Skipping login-item register(): running under XCTest")
            return
        }
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        guard !TestEnvironment.isRunningTests else {
            Log.settings.notice("Skipping login-item unregister(): running under XCTest")
            return
        }
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettingsLoginItems() {
        guard !TestEnvironment.isRunningTests else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// A service double that reports "not registered" and does nothing.
///
/// Used by `AppState.preview()` so SwiftUI previews and tests can exercise the full object graph
/// without ever touching `ServiceManagement`.
struct InertLoginItemService: LoginItemService {
    private let reported: SMAppService.Status

    init(status: SMAppService.Status = .notRegistered) { self.reported = status }

    var status: SMAppService.Status { reported }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettingsLoginItems() {}
}

/// Owns the "Launch at Login" switch.
///
/// WHY a dedicated type rather than a Bool in `AppSettings`: the truth lives in the system, not in
/// `UserDefaults`. The user can disable the item in System Settings behind the app's back, and
/// moving the app bundle invalidates the recorded path. The manager therefore always re-reads
/// `SMAppService.mainApp.status` instead of caching an intent.
@MainActor
@Observable
final class LoginItemManager {

    /// The four `SMAppService` statuses plus an escape hatch for future/unknown values.
    ///
    /// `requiresApproval` is **not** an error: registration succeeded, but macOS wants the user to
    /// flip the switch in System Settings › General › Login Items. The UI surfaces it as an
    /// actionable state with an "Open Login Items Settings…" button rather than as a failure
    /// (see docs/TECHNICAL_INVESTIGATION.md §9).
    enum Status: Equatable, Sendable {
        /// `SMAppService.Status.enabled` — the app will launch at login.
        case enabled
        /// `SMAppService.Status.notRegistered` — never registered, or unregistered by us.
        case disabled
        /// `SMAppService.Status.requiresApproval` — registered, waiting for the user's approval.
        case requiresApproval
        /// `SMAppService.Status.notFound` — the recorded registration is stale (the user disabled
        /// the item in System Settings, or the bundle moved). Treated as "off"; turning the switch
        /// back on re-registers.
        case notFound
        /// An `SMAppService.Status` value this build does not know about.
        case unavailable
    }

    /// Last value read from the system. Updated only by `refresh()`.
    private(set) var status: Status = .disabled

    /// `true` only for `.enabled`.
    ///
    /// Per docs/TECHNICAL_INVESTIGATION.md §9 the app treats anything other than `.enabled` as
    /// "off", so the toggle reflects reality rather than intent. `.requiresApproval` is reported
    /// separately via `needsApproval` so the UI can explain *why* the switch bounced back.
    var isEnabled: Bool { status == .enabled }

    /// `true` when the item is registered but the user still has to approve it.
    var needsApproval: Bool { status == .requiresApproval }

    private let service: any LoginItemService

    /// - Parameter service: injection seam. Defaults to the real `SMAppService.mainApp`.
    init(service: any LoginItemService = MainAppLoginItemService()) {
        self.service = service
        refresh()
    }

    /// Re-reads the system status. Cheap and side-effect free; safe to call from `onAppear`.
    func refresh() {
        let mapped = Self.map(service.status)
        guard mapped != status else { return }
        status = mapped
        Log.settings.notice("Login item status: \(String(describing: mapped), privacy: .public)")
    }

    /// Turns "Launch at Login" on or off.
    ///
    /// Registration rules (docs/TECHNICAL_INVESTIGATION.md §9):
    /// * `.enabled` → already on, nothing to do.
    /// * `.requiresApproval` → `register()` would throw "Operation not permitted"; the item is
    ///   already registered and only needs the user's approval, so we leave it and let the UI point
    ///   at `openSystemSettings()`.
    /// * `.disabled` / `.notFound` / `.unavailable` → `register()`. `.notFound` in particular means
    ///   the recorded state is **stale** (user-disabled, or the bundle moved), and re-registering is
    ///   exactly the recovery.
    ///
    /// - Throws: the raw `NSError` from `SMAppService`. The status is refreshed before rethrowing so
    ///   the UI never shows a state that disagrees with the system.
    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                switch status {
                case .enabled, .requiresApproval:
                    break
                case .disabled, .notFound, .unavailable:
                    try service.register()
                }
            } else {
                switch status {
                case .enabled, .requiresApproval, .unavailable:
                    try service.unregister()
                case .disabled, .notFound:
                    break
                }
            }
        } catch {
            refresh()
            Log.settings.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        refresh()
    }

    /// Opens System Settings › General › Login Items so the user can approve or remove the item.
    func openSystemSettings() {
        service.openSystemSettingsLoginItems()
    }

    /// Pure mapping, exposed for unit tests.
    static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }
}
