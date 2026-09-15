//
//  AboutView.swift
//  EjectRemapper
//

import SwiftUI

/// The About tab: version, compatibility, and what is actually plugged in.
///
/// The connected-keyboard list earns its place: "it doesn't work" and "my keyboard has no Eject
/// key" look identical from the user's side, and this is where they can see which one it is
/// without anyone having to run a command.
struct AboutView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identity
                Divider()
                compatibility
                Divider()
                supportedKeyboards
                Divider()
                credit
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { appState.refreshCompatibility() }
    }

    // MARK: - Sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Eject Key Remap")
                .font(.title3.weight(.semibold))
            Text("Version \(Self.version) (\(Self.build))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Gives the Eject ⏏ key on an Apple keyboard something useful to do.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Mac")
                .font(.headline)

            LabeledContent(String(localized: "Requires")) {
                Text("macOS 14 or later")
            }
            LabeledContent(String(localized: "Running")) {
                Text(Self.systemVersion)
            }

            Text("Connected keyboards")
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)

            switch appState.compatibility {
            case .supported(let keyboard):
                keyboardRow(keyboard)
            case .unsupported(let reason, let keyboards):
                ForEach(keyboards, id: \.self) { keyboardRow($0) }
                StatusBadge(level: .warning, message: reason)
            case .noKeyboardFound:
                StatusBadge(level: .warning, message: String(localized: "No keyboard was found."))
            case .unknown:
                StatusBadge(level: .info, message: String(localized: "Keyboards haven't been checked yet."))
            }
        }
    }

    private func keyboardRow(_ keyboard: HIDKeyboardInfo) -> some View {
        StatusBadge(
            level: keyboard.declaresEjectUsage ? .ok : .info,
            message: keyboard.declaresEjectUsage
                ? String(localized: "\(keyboard.name) — has an Eject key")
                : String(localized: "\(keyboard.name) — no Eject key")
        )
    }

    private var supportedKeyboards: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Supported keyboards")
                .font(.headline)
            Text("""
                 Apple keyboards with a physical Eject ⏏ key: the Magic Keyboard from 2015 and 2017, \
                 and older wired and wireless Apple keyboards. Other keyboards that report a real \
                 Eject key work too.

                 Magic Keyboards made from 2021 onwards replaced the Eject key with a Lock key or \
                 Touch ID. macOS handles both of those itself and never passes them to apps, so they \
                 can't be remapped by any app.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The author credit, with a link to the author's GitHub page.
    ///
    /// Built from an `AttributedString` rather than from Markdown in a `Text` literal so the link
    /// keeps working when the sentence is translated: a localiser can move "Cacaio" anywhere in the
    /// line, and the range is located by name at runtime. The flag is written as its own `Text` so
    /// VoiceOver reads the sentence rather than spelling out a regional indicator pair.
    private var credit: some View {
        HStack(spacing: 4) {
            // Left as its own element on purpose: SwiftUI exposes the link inside an
            // `AttributedString` as a real accessibility link, so VoiceOver can announce it and
            // activate it. Combining the children into one element would read the sentence but
            // throw that away.
            Text(Self.creditLine)
                .tint(.accentColor)
            Text(verbatim: "🇧🇷")
                .accessibilityLabel(Text("Brazilian flag"))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // Internal rather than private so the link wiring can be unit-tested: if the range lookup ever
    // fails, the credit would still render but silently stop being clickable.
    static let authorName = "Cacaio"
    static let authorURL = URL(string: "https://github.com/Cacaioo")!

    static var creditLine: AttributedString {
        var line = AttributedString(String(localized: "Made by \(authorName) in Brazil"))
        if let range = line.range(of: authorName) {
            line[range].link = authorURL
            line[range].underlineStyle = .single
        }
        return line
    }

    // MARK: - Bundle values

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

#Preview("About") {
    AboutView()
        .environment(AppState.preview())
        .frame(width: 420, height: 460)
}
