//
//  SettingsView.swift
//  EjectRemapper
//

import SwiftUI

/// The Settings window: four tabs, each doing one job.
///
/// The popover already covers the everyday case, so this exists for the things that do not belong
/// in a menu — launch at login, hiding the menu bar icon, the permission explanation in full, and
/// the information someone needs when reporting a problem.
struct SettingsView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            EjectKeySettingsTab()
                .tabItem { Label("Eject Key", systemImage: "eject") }

            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 440)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Launch at Login"), isOn: launchAtLoginBinding)
                    .accessibilityHint(Text("Starts Eject Key Remap automatically when you log in."))

                if appState.loginItems.needsApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusBadge(level: .warning,
                                    message: String(localized: "macOS needs you to allow this in Login Items."))
                        Button(String(localized: "Open Login Items Settings")) {
                            appState.loginItems.openSystemSettings()
                        }
                    }
                }
            }

            Section {
                Toggle(String(localized: "Enable Remapping"), isOn: remappingBinding)
                    .accessibilityHint(Text("Turn off to leave the Eject key exactly as macOS treats it."))

                Toggle(String(localized: "Show Menu Bar Icon"), isOn: menuBarBinding)
                    .accessibilityHint(Text("Hides the eject icon in the menu bar."))

                if !appState.settings.showMenuBarIcon {
                    Text("With the icon hidden, open the app again from the Finder to get back to Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.loginItems.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.loginItems.isEnabled },
            set: { newValue in
                do {
                    try appState.loginItems.setEnabled(newValue)
                } catch {
                    Log.app.error("Could not change the login item: \(String(describing: error), privacy: .public)")
                }
            }
        )
    }

    private var remappingBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.isRemappingEnabled },
            set: { appState.settings.isRemappingEnabled = $0 }
        )
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.showMenuBarIcon },
            set: { appState.settings.showMenuBarIcon = $0 }
        )
    }
}

// MARK: - Eject Key

private struct EjectKeySettingsTab: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When I press ⏏")
                        .font(.headline)
                    Text("Presses with ⌘, ⌃, ⌥ or ⇧ held are never changed, so the built-in shortcuts for sleep, restart and shut down keep working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ActionPicker(selection: actionBinding)

                if appState.settings.actionKind == .customShortcut {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Shortcut")
                            .font(.headline)
                        ShortcutRecorderView()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionBinding: Binding<EjectActionKind> {
        Binding(
            get: { appState.settings.actionKind },
            set: { appState.select($0) }
        )
    }
}

// MARK: - Permissions

private struct PermissionsSettingsTab: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PermissionView()

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why this is needed")
                        .font(.headline)
                    Text("""
                         macOS treats reading and sending keys as a privilege. Without Accessibility \
                         access, no app — including this one — can notice the Eject key or replace \
                         what it does.

                         Eject Key Remap watches for one kind of system event and nothing else. It \
                         never sees ordinary typing, and it stores nothing beyond your settings.
                         """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                StatusBadge(level: keyboardLevel, message: keyboardMessage)
                if case .failed = appState.keyboard.state {
                    Button(String(localized: "Retry")) { appState.keyboard.retry() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var keyboardLevel: StatusBadge.Level {
        switch appState.keyboard.state {
        case .active: return .ok
        case .failed: return .problem
        case .inactive: return .info
        }
    }

    private var keyboardMessage: String {
        switch appState.keyboard.state {
        case .active:
            return String(localized: "Remapping is active.")
        case .failed(let message):
            return message
        case .inactive(.disabledByUser):
            return String(localized: "Remapping is switched off in General.")
        case .inactive(.permissionMissing):
            return String(localized: "Remapping is waiting for Accessibility access.")
        case .inactive(.notStarted):
            return String(localized: "Remapping is not running.")
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppState.preview())
}
