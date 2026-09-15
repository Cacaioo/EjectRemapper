//
//  AccessibilityStatus.swift
//  EjectRemapper
//

import Foundation

/// Three-state model of the app's Accessibility (TCC) grant.
///
/// WHY three states and not a `Bool`: at launch the answer is genuinely not known yet — the first
/// `AXIsProcessTrusted()` call has not run, and the app must not draw a red "Permission denied"
/// banner during that window. `unknown` also covers the moment right after a `refresh()` is
/// scheduled but has not completed, which is what the permission UI uses to stay quiet instead of
/// flickering.
///
/// Note that "granted" here means *verified usable*, not merely "the system says we are trusted":
/// `PermissionManager` combines `AXIsProcessTrusted()` with a throwaway event-tap probe, because
/// `AXIsProcessTrusted()` keeps returning `true` for a process whose access has already been
/// revoked (docs/TECHNICAL_INVESTIGATION.md §8).
enum AccessibilityStatus: Equatable, Sendable {
    /// Trusted *and* a test tap could be created — remapping can run.
    case granted
    /// Not trusted, or a test tap was refused. Remapping cannot run.
    case denied
    /// Not determined yet (before the first `refresh()`).
    case unknown

    /// Convenience for call sites that only care whether the tap can run.
    var isGranted: Bool { self == .granted }
}

extension AccessibilityStatus: CustomStringConvertible {
    /// Stable, non-localised text for the unified log. User-facing strings live in the UI layer.
    var description: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "unknown"
        }
    }
}
