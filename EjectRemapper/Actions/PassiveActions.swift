//
//  PassiveActions.swift
//  EjectRemapper
//
//  The two actions that do nothing.
//

import Foundation

/// Handler for `.original` and `.disabled`.
///
/// Both are decided entirely in the keyboard layer — `.original` passes the event through so macOS
/// performs the Eject key's own function, `.disabled` suppresses it — so by the time anything reaches
/// the action layer there is nothing left to do. It exists so the dispatcher's handler table is total:
/// a missing entry is an error worth logging, while "deliberately nothing" is not.
final class PassiveAction: EjectActionHandler, @unchecked Sendable {
    init() {}
    func execute(action: EjectAction, trigger: ActionTrigger) {}
    func reset() {}
}
