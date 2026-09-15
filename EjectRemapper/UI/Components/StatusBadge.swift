//
//  StatusBadge.swift
//  EjectRemapper
//

import SwiftUI

/// A one-line status message with an icon.
///
/// WHY the icon is not optional: the spec requires that status is never conveyed by colour alone.
/// A red dot and a green dot are indistinguishable to a large number of people and invisible to a
/// screen reader. Every level here pairs a distinct SF Symbol with distinct text, so the colour is
/// the third signal rather than the only one.
struct StatusBadge: View {

    enum Level {
        case ok
        case warning
        case problem
        case info

        var symbolName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .problem: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .ok: return .green
            case .warning: return .orange
            case .problem: return .red
            case .info: return .secondary
            }
        }

        /// Read before the message by VoiceOver, so the severity survives without the colour.
        var spokenPrefix: String {
            switch self {
            case .ok: return String(localized: "OK")
            case .warning: return String(localized: "Warning")
            case .problem: return String(localized: "Problem")
            case .info: return String(localized: "Information")
            }
        }
    }

    let level: Level
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: level.symbolName)
                .foregroundStyle(level.tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(level == .ok ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(level.spokenPrefix). \(message)"))
    }
}

#Preview("Status badges") {
    VStack(alignment: .leading, spacing: 10) {
        StatusBadge(level: .ok, message: "Remapping is active.")
        StatusBadge(level: .warning, message: "No shortcut recorded yet — the Eject key does nothing until you record one.")
        StatusBadge(level: .problem, message: "The Eject key could not be captured.")
        StatusBadge(level: .info, message: "Built-in Mac keyboards don't have an Eject key.")
    }
    .frame(width: 300)
    .padding()
}
