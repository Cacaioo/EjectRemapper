//
//  ActionPicker.swift
//  EjectRemapper
//

import SwiftUI

/// The radio group of the seven things the Eject key can do.
///
/// Built by hand rather than with `Picker(.radioGroup)` because each row carries an icon and a line
/// of explanation, which a `Picker` cannot render. The keyboard and VoiceOver behaviour a real radio
/// group would give for free is therefore restored explicitly: the group is one accessibility
/// container, each row reports `.isButton` with a selected trait, and the whole list is reachable by
/// Tab.
struct ActionPicker: View {

    @Binding var selection: EjectActionKind

    /// Shows the one-line explanation under each label. The popover turns this off to stay compact;
    /// Settings leaves it on.
    var showsSummaries = true

    var body: some View {
        VStack(alignment: .leading, spacing: showsSummaries ? 8 : 2) {
            ForEach(EjectActionKind.allCases) { kind in
                row(for: kind)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Eject key action"))
    }

    private func row(for kind: EjectActionKind) -> some View {
        let isSelected = selection == kind

        return Button {
            selection = kind
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbolName)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(kind.title)
                            .foregroundStyle(.primary)
                    }
                    if showsSummaries {
                        Text(kind.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.title))
        .accessibilityHint(Text(kind.summary))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Action picker") {
    @Previewable @State var selection: EjectActionKind = .forwardDelete
    return ActionPicker(selection: $selection)
        .frame(width: 300)
        .padding()
}
