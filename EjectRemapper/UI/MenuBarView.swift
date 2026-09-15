//
//  MenuBarView.swift
//  EjectRemapper
//

import SwiftUI

/// The popover behind the menu bar icon — the app's main interface.
///
/// Everything the user needs day to day is here: what the Eject key does, whether it is working,
/// and the way out to Settings. The shortcut controls appear only when Custom Shortcut is selected,
/// as the spec requires, so the panel stays short for the six other actions.
///
/// The status area shows at most one thing, in order of how much it matters: a broken tap, a
/// missing permission, an unsupported keyboard, an incomplete configuration, then — only if none of
/// those apply — a quiet confirmation that remapping is on.
struct MenuBarView: View {

    @Environment(AppState.self) private var appState

    private static let width: CGFloat = 320

    var body: some View {
        @Bindable var settings = appState.settings

        VStack(alignment: .leading, spacing: 12) {
            header

            ActionPicker(selection: actionBinding, showsSummaries: false)

            if appState.settings.actionKind == .customShortcut {
                Divider()
                customShortcutSection
            }

            Divider()
            status

            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .onAppear { appState.refreshCompatibility() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Eject Key")
                .font(.headline)
            Text("When I press ⏏:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var customShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Shortcut")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ShortcutRecorderView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch statusContent {
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                StatusBadge(level: .problem, message: message)
                Button(String(localized: "Retry")) { appState.keyboard.retry() }
            }
        case .permission:
            PermissionView(isCompact: true)
        case .badge(let level, let message):
            StatusBadge(level: level, message: message)
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Settings…")) { appState.openSettings() }
            Spacer()
            Button(String(localized: "Quit")) { appState.quit() }
        }
    }

    // MARK: - Status selection

    private enum StatusContent {
        case failure(String)
        case permission
        case badge(StatusBadge.Level, String)
    }

    /// Picks the single most important thing to say. Showing four warnings at once would mean the
    /// user reads none of them.
    private var statusContent: StatusContent {
        if case .failed(let message) = appState.keyboard.state {
            return .failure(message)
        }
        if appState.permissions.status != .granted {
            return .permission
        }
        if case .unsupported(let reason, _) = appState.compatibility {
            return .badge(.warning, reason)
        }
        if case .noKeyboardFound = appState.compatibility {
            return .badge(.warning, String(localized: "No keyboard with an Eject ⏏ key is connected."))
        }
        if let warning = appState.settings.configurationWarning {
            return .badge(.warning, warning)
        }
        if case .inactive(.disabledByUser) = appState.keyboard.state {
            return .badge(.info, String(localized: "Remapping is switched off in Settings."))
        }
        if case .active = appState.keyboard.state {
            return .badge(.ok, String(localized: "Remapping is active."))
        }
        return .badge(.info, String(localized: "Remapping is not running."))
    }

    private var actionBinding: Binding<EjectActionKind> {
        Binding(
            get: { appState.settings.actionKind },
            set: { appState.select($0) }
        )
    }
}

#Preview("Menu bar popover") {
    MenuBarView()
        .environment(AppState.preview())
}
