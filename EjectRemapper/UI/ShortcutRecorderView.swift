//
//  ShortcutRecorderView.swift
//  EjectRemapper
//

import SwiftUI

/// The record-a-shortcut control: a framed box that shows the current shortcut, or listens for a
/// new one.
///
/// The interaction the spec asks for is "click Record, then press the keys" — the user never types
/// a shortcut as text. The box therefore has three states and says which one it is in:
///
/// * **Idle with a shortcut** — the key caps, plus Record and Clear.
/// * **Idle with none** — "No shortcut recorded", plus Record.
/// * **Recording** — "Press a shortcut", with the modifiers appearing live as they are held.
///
/// The view is also responsible for raising and lowering
/// `KeyboardEventManager.isRecordingShortcut`, including when it disappears while still recording —
/// otherwise a user who closes Settings mid-recording would leave the Eject key suppressed.
struct ShortcutRecorderView: View {

    @Environment(AppState.self) private var appState

    private let formatter = KeyboardShortcutFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            recorderBox

            HStack(spacing: 8) {
                Button(appState.recorder.isRecording
                       ? String(localized: "Stop")
                       : String(localized: "Record Shortcut")) {
                    if appState.recorder.isRecording {
                        appState.cancelRecordingShortcut()
                    } else {
                        appState.beginRecordingShortcut()
                    }
                }
                .accessibilityHint(Text("Listens for the next key combination you press."))

                Button(String(localized: "Clear")) {
                    appState.clearShortcut()
                }
                .disabled(appState.settings.customShortcut == nil || appState.recorder.isRecording)
                .accessibilityHint(Text("Removes the recorded shortcut."))
            }

            if let rejection = appState.recorder.lastRejection {
                StatusBadge(level: .warning, message: rejection.localizedDescription)
            } else if let warning = warningForCurrentShortcut {
                StatusBadge(level: .info, message: warning)
            }
        }
        .onDisappear {
            // Leaving the view while recording would strand the suppression flag.
            appState.cancelRecordingShortcut()
            appState.recorder.clearRejection()
        }
    }

    // MARK: - The box

    @ViewBuilder
    private var recorderBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    appState.recorder.isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: appState.recorder.isRecording ? 2 : 1
                )
            content
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Shortcut recorder"))
        .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var content: some View {
        if appState.recorder.isRecording {
            VStack(spacing: 6) {
                Text("Press a shortcut")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !appState.recorder.heldModifiers.isEmpty {
                    Text(appState.recorder.heldModifiers.ordered.map(\.symbol).joined(separator: " "))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                } else {
                    Text("⎋ to cancel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if let shortcut = appState.settings.customShortcut {
            ShortcutBadge(shortcut: shortcut, formatter: formatter)
        } else {
            Text("No shortcut recorded")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text

    private var accessibilityValue: String {
        if appState.recorder.isRecording {
            let held = appState.recorder.heldModifiers
            return held.isEmpty
                ? String(localized: "Recording. Press a shortcut, or press Escape to cancel.")
                : String(localized: "Recording. Holding \(held.spokenName).")
        }
        if let shortcut = appState.settings.customShortcut {
            return formatter.spokenDescription(for: shortcut)
        }
        return String(localized: "No shortcut recorded")
    }

    private var warningForCurrentShortcut: String? {
        guard !appState.recorder.isRecording, let shortcut = appState.settings.customShortcut else { return nil }
        return ShortcutValidator.warnings(for: shortcut).first
    }
}

#Preview("Recorder") {
    ShortcutRecorderView()
        .environment(AppState.preview())
        .frame(width: 300)
        .padding()
}
