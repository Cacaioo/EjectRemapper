//
//  PermissionManager.swift
//  EjectRemapper
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// Owns the app's view of the Accessibility permission.
///
/// WHY this is more than `AXIsProcessTrusted()`:
///
/// 1. **`AXIsProcessTrusted()` goes stale.** When the user removes the app from System Settings ›
///    Privacy & Security › Accessibility, the TCC answer cached in the running process can keep
///    reporting `true` for a long time. The only reliable revocation probe is to *actually try* to
///    create an active event tap and throw it away again (docs/TECHNICAL_INVESTIGATION.md §8, §9).
/// 2. **The `com.apple.accessibility.api` distributed notification is a hint, not ground truth.**
///    It is not delivered reliably when an app is *removed* from the list, so it is used only to
///    schedule a re-check — never to set the status directly.
/// 3. **Prompting is once per launch.** `AXIsProcessTrustedWithOptions` with
///    `kAXTrustedCheckOptionPrompt` shows a modal system alert. Repeating it would be obnoxious and,
///    on repeat launches, useless — the header notes the prompt is asynchronous and does not affect
///    the return value (`HIServices/AXUIElement.h`).
///
/// Every system call this type makes is injectable so that unit tests never touch TCC, never create
/// a tap and never open System Settings on the developer's live machine.
@MainActor
@Observable
final class PermissionManager {

    // MARK: - Observable state

    /// Current, verified permission state. Starts `.unknown` until the first `refresh()`.
    private(set) var status: AccessibilityStatus = .unknown

    /// `true` once `requestAccess()` has shown the system prompt in this process.
    ///
    /// Exposed so the UI can switch from "Grant Access…" to "Open System Settings…" after the
    /// one prompt this launch is allowed.
    private(set) var hasPromptedThisLaunch = false

    // MARK: - Injected system calls

    private let isTrusted: @Sendable () -> Bool
    private let canCreateEventTap: @Sendable () -> Bool
    private let promptForAccess: @Sendable () -> Bool
    private let openURL: @MainActor (URL) -> Bool

    // MARK: - Monitoring

    private var observers: [any NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var isPollingRequested = false

    /// - Parameters:
    ///   - isTrusted: the cheap, non-prompting TCC check. Defaults to `AXIsProcessTrusted()`.
    ///   - canCreateEventTap: the throwaway-tap probe described above. Defaults to
    ///     ``PermissionManager/eventTapProbeSucceeds()``.
    ///   - promptForAccess: shows the system Accessibility prompt and returns the (possibly stale)
    ///     trusted value. Defaults to `AXIsProcessTrustedWithOptions`.
    ///   - openURL: opens a System Settings deep link. Defaults to `NSWorkspace.shared.open`.
    ///
    /// All four parameters carry defaults, so `PermissionManager()` and
    /// `PermissionManager(isTrusted:)` behave exactly as the architecture contract specifies.
    init(
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        canCreateEventTap: @escaping @Sendable () -> Bool = { PermissionManager.eventTapProbeSucceeds() },
        promptForAccess: @escaping @Sendable () -> Bool = { PermissionManager.showSystemPrompt() },
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.isTrusted = isTrusted
        self.canCreateEventTap = canCreateEventTap
        self.promptForAccess = promptForAccess
        self.openURL = openURL
    }

    // MARK: - Checking

    /// Re-evaluates the permission from scratch.
    ///
    /// `AXIsProcessTrusted()` first because it is free and never prompts; the tap probe only when
    /// it says yes, since a probe can only fail when the cheap check already failed. A trusted
    /// process whose probe fails is the revocation case — it reports `.denied`, which makes
    /// `KeyboardEventManager` tear the tap down instead of leaving a half-dead tap swallowing input.
    func refresh() {
        let trusted = isTrusted()
        let newStatus: AccessibilityStatus = (trusted && canCreateEventTap()) ? .granted : .denied
        guard newStatus != status else { return }
        let previous = status
        status = newStatus
        Log.permissions.notice(
            "Accessibility \(previous.description, privacy: .public) -> \(newStatus.description, privacy: .public) (AXIsProcessTrusted=\(trusted, privacy: .public))"
        )
    }

    /// Shows the system Accessibility prompt — at most once per launch, and never when already
    /// granted.
    ///
    /// The prompt is asynchronous: the return value of `AXIsProcessTrustedWithOptions` is the
    /// *current* trust state, not the user's eventual answer. The real answer arrives later through
    /// `startMonitoring()` / `setPolling(_:)`.
    func requestAccess() {
        guard !hasPromptedThisLaunch else {
            Log.permissions.debug("Accessibility prompt already shown this launch")
            return
        }
        refresh()
        guard status != .granted else { return }
        hasPromptedThisLaunch = true
        Log.permissions.notice("Showing Accessibility prompt")
        _ = promptForAccess()
    }

    /// Opens System Settings on the Accessibility pane.
    ///
    /// macOS 13 renamed the pane and the URL scheme; the pre-Ventura string is kept as a fallback
    /// because `NSWorkspace.open` simply returns `false` for an unhandled URL rather than throwing.
    func openAccessibilitySettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let modern, openURL(modern) { return }
        if let legacy, openURL(legacy) { return }
        Log.permissions.error("Could not open the Accessibility pane in System Settings")
    }

    // MARK: - Monitoring

    /// Starts watching for permission changes and performs an immediate `refresh()`.
    ///
    /// Two sources, both treated as *hints* that trigger a full re-check:
    /// * `com.apple.accessibility.api` on the **distributed** notification centre — posted when the
    ///   Accessibility list changes, but unreliable for removals.
    /// * `NSApplication.didBecomeActiveNotification` — covers the common flow of leaving the app,
    ///   flipping the switch in System Settings and coming back.
    ///
    /// Idempotent: calling it twice does not install duplicate observers.
    func startMonitoring() {
        guard observers.isEmpty else {
            refresh()
            return
        }

        let distributed = DistributedNotificationCenter.default()
        observers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.accessibility.api"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        )

        refresh()
    }

    /// Removes both observers and stops any polling. Idempotent.
    func stopMonitoring() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        setPolling(false)
    }

    /// Enables or disables the 1.5 s fallback poll.
    ///
    /// WHY polling exists at all: neither hint above fires when the user *removes* the app from the
    /// Accessibility list while the app stays frontmost, which is exactly what happens while the
    /// permission screen is open and the user is experimenting. WHY it is opt-in: each tick runs the
    /// tap probe, so it is scoped to "a permission view is on screen" — `onAppear` turns it on,
    /// `onDisappear` turns it off. Nothing else may call this.
    ///
    /// Polling is suppressed entirely under XCTest.
    func setPolling(_ enabled: Bool) {
        guard enabled != isPollingRequested else { return }
        isPollingRequested = enabled

        guard enabled, !TestEnvironment.isRunningTests else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    // MARK: - Default system probes

    /// Creates a real, active event tap, notes whether the system allowed it, and immediately
    /// tears it down.
    ///
    /// This is the **only** reliable revocation probe (docs/TECHNICAL_INVESTIGATION.md §8 and
    /// CONTRACT_CORRECTIONS §9): an active `.defaultTap` at `.cgSessionEventTap` requires the
    /// Accessibility grant, and `CGEvent.tapCreate` returns `nil` without it, whereas
    /// `AXIsProcessTrusted()` can stay `true` after the grant is taken away.
    ///
    /// Safety notes, because this runs on a live machine:
    /// * The mask is `1 << 14` only — `NX_SYSDEFINED` (IOLLEvent.h), the same mask
    ///   `SystemDefinedEventDecoder.eventMask` uses. Ordinary key events are never tapped.
    /// * `tapCreate` returns an *enabled* tap that has no run-loop source, so it is disabled before
    ///   being invalidated. Without that, media-key events could stall until the tap timed out.
    /// * The callback passes every event straight through and is never actually reached.
    /// * Under XCTest the probe short-circuits to `true` and creates nothing at all.
    nonisolated static func eventTapProbeSucceeds() -> Bool {
        guard !TestEnvironment.isRunningTests else { return true }

        let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << 14,
            callback: callback,
            userInfo: nil
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        return true
    }

    /// Calls `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
    ///
    /// Suppressed under XCTest — a modal system alert in the middle of `xcodebuild test` would hang
    /// an unattended run. The non-prompting check stands in for it there.
    nonisolated static func showSystemPrompt() -> Bool {
        guard !TestEnvironment.isRunningTests else { return AXIsProcessTrusted() }
        let options: [String: Any] = [promptOptionKey: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// The literal value of `kAXTrustedCheckOptionPrompt`.
    ///
    /// WHY spelled out rather than read from the constant: `kAXTrustedCheckOptionPrompt` is imported
    /// as a mutable global `Unmanaged<CFString>`, which Swift 6 rightly refuses to let a `nonisolated`
    /// function touch. The underlying value is a documented, stable API string, so using it directly
    /// is both safe and honest — and this is the one place it appears.
    private nonisolated static let promptOptionKey = "AXTrustedCheckOptionPrompt"
}
