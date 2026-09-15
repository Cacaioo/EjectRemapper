//
//  PermissionView.swift
//  EjectRemapper
//

import SwiftUI

/// Explains the Accessibility requirement and offers the two ways to satisfy it.
///
/// The wording avoids every technical term the spec rules out of the main interface: no "event
/// tap", no "TCC", no "CGEvent". A user needs to know one thing — macOS will not let an app touch
/// the Eject key without permission — and needs one button that takes them there.
///
/// While this view is on screen it asks `PermissionManager` to poll, because the user is about to
/// leave for System Settings and come back, and the distributed notification is not reliable enough
/// to be the only signal. Polling stops the moment the view disappears.
struct PermissionView: View {

    @Environment(AppState.self) private var appState

    /// The popover uses the compact form: one status line and one button, no heading.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            if !isCompact {
                Text("Accessibility Access")
                    .font(.headline)
            }

            StatusBadge(level: level, message: message)

            if appState.permissions.status != .granted {
                HStack(spacing: 8) {
                    Button(String(localized: "Open Accessibility Settings")) {
                        appState.permissions.openAccessibilitySettings()
                    }
                    .accessibilityHint(Text("Opens System Settings so you can switch on access for this app."))

                    if !appState.permissions.hasPromptedThisLaunch {
                        Button(String(localized: "Ask Again")) {
                            appState.permissions.requestAccess()
                        }
                        .accessibilityHint(Text("Shows the system permission alert."))
                    }
                }

                if !isCompact {
                    Text("After switching it on, remapping starts straight away — there's no need to relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { appState.permissions.setPolling(true) }
        .onDisappear { appState.permissions.setPolling(false) }
    }

    private var level: StatusBadge.Level {
        switch appState.permissions.status {
        case .granted: return .ok
        case .denied: return .problem
        case .unknown: return .info
        }
    }

    private var message: String {
        switch appState.permissions.status {
        case .granted:
            return String(localized: "Eject Key Remap has the access it needs.")
        case .denied:
            return String(localized: "Eject Key Remap needs Accessibility access to change what the Eject key does.")
        case .unknown:
            return String(localized: "Checking whether Eject Key Remap has Accessibility access…")
        }
    }
}

#Preview("Permission") {
    PermissionView()
        .environment(AppState.preview())
        .frame(width: 340)
        .padding()
}
