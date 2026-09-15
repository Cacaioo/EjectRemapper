//
//  Log.swift
//  EjectRemapper
//

import os

/// Unified-logging channels for the app.
///
/// WHY a central enum: this app observes a global event tap, so what it writes to the system log
/// is a privacy question, not a formatting question. Funnelling every `Logger` through one type
/// makes the complete set of categories auditable at a glance, and gives reviewers a single place
/// to check the rule below.
///
/// # PRIVACY RULE — READ BEFORE ADDING A LOG STATEMENT
/// **Keystrokes and typed text are NEVER logged.** Not the key code, not the character, not the
/// modifier combination of a keystroke that merely passed through the tap, not the contents of any
/// `CGEvent`. The tap's mask is `1 << 14` (`NX_SYSDEFINED`, IOLLEvent.h) so the app never even sees
/// normal key events — and the Eject key events it does see are logged only as "an eject key event
/// happened", with no payload.
///
/// The contract's exhaustive list of loggable events is:
/// * tap started / stopped / re-enabled
/// * permission status changed
/// * eject key detected (a bare fact plus, at most, a Bool for "had modifiers")
/// * action changed (the `EjectActionKind` only — never the recorded custom shortcut)
/// * action failed
/// * unsupported keyboard detected
///
/// Anything not on that list does not get logged. User-recorded shortcuts, clipboard content and
/// window/app names are all out of scope.
enum Log {

    /// Matches the bundle identifier so `log stream --predicate 'subsystem == "com.cacaioo.EjectRemapper"'`
    /// picks up everything the app emits.
    static let subsystem = "com.cacaioo.EjectRemapper"

    /// App lifecycle: launch, activation policy, settings window, termination.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Event tap lifecycle: created, started, stopped, auto re-enabled after
    /// `kCGEventTapDisabledByTimeout` / `ByUserInput`. Never event payloads.
    static let tap = Logger(subsystem: subsystem, category: "tap")

    /// Action dispatch: which `EjectActionKind` ran, and failures. Never the keys it generated.
    static let actions = Logger(subsystem: subsystem, category: "actions")

    /// Accessibility permission transitions and the results of the test-tap probe.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    /// Settings changes (kind only) and login-item registration state.
    static let settings = Logger(subsystem: subsystem, category: "settings")

    /// Keyboard compatibility assessment (model names / product IDs of connected keyboards).
    static let compatibility = Logger(subsystem: subsystem, category: "compatibility")
}
