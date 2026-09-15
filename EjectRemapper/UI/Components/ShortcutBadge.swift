//
//  ShortcutBadge.swift
//  EjectRemapper
//

import SwiftUI

/// Draws a keyboard shortcut as a row of key caps.
///
/// Two things matter here and both are accessibility requirements rather than decoration:
///
/// - The symbols are rendered from ``KeyboardShortcutFormatter``, never from a stored string, so
///   the display follows the user's keyboard layout and Apple's modifier order.
/// - The whole badge is one accessibility element whose value is the *spoken* form ("Shift Command
///   4"). Left to itself, VoiceOver would read the glyphs individually and say nothing useful.
struct ShortcutBadge: View {

    let shortcut: KeyboardShortcut

    /// Defaults to the live keyboard layout; previews and tests can pass a fixed provider.
    var formatter = KeyboardShortcutFormatter()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(formatter.symbols(for: shortcut).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Shortcut", comment: "Accessibility label for the key cap display"))
        .accessibilityValue(Text(formatter.spokenDescription(for: shortcut)))
    }
}

#Preview("Shortcut badges") {
    VStack(alignment: .leading, spacing: 10) {
        ShortcutBadge(shortcut: KeyboardShortcut(keyCode: KeyCodes.ansiC, modifiers: [.command]),
                      formatter: KeyboardShortcutFormatter(labels: USQWERTYKeyLabelProvider()))
        ShortcutBadge(shortcut: KeyboardShortcut(keyCode: KeyCodes.ansi4, modifiers: [.command, .shift]),
                      formatter: KeyboardShortcutFormatter(labels: USQWERTYKeyLabelProvider()))
        ShortcutBadge(shortcut: KeyboardShortcut(keyCode: KeyCodes.delete, modifiers: [.option]),
                      formatter: KeyboardShortcutFormatter(labels: USQWERTYKeyLabelProvider()))
        ShortcutBadge(shortcut: KeyboardShortcut(keyCode: KeyCodes.leftArrow, modifiers: [.control, .option]),
                      formatter: KeyboardShortcutFormatter(labels: USQWERTYKeyLabelProvider()))
    }
    .padding()
}
