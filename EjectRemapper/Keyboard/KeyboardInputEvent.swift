import Foundation

/// What the Eject key just did, expressed independently of the Core Graphics / IOKit encoding.
///
/// Why a dedicated type instead of passing `CGEvent` around: everything above the event tap
/// (the manager, the dispatcher, the action handlers, and every unit test) must be able to reason
/// about a key press without a live event tap, without Accessibility permission, and without
/// CoreGraphics at all. This enum is the seam that makes the whole app testable.
///
/// `ejectKeyRepeat` exists for completeness of the trigger vocabulary but is **never produced by the
/// hardware**: `IOHIDKeyboardFilter.mm:1353-1372` (`isNotRepeated`) excludes Consumer Eject from auto
/// repeat, so holding the key yields exactly one down and one up. Hold-to-repeat is generated in
/// software by `KeyRepeatTimer` (TECHNICAL_INVESTIGATION.md §3 "Key repeat", CONTRACT_CORRECTIONS §2).
enum KeyboardInputEvent: Equatable, Sendable {
    case ejectKeyDown
    case ejectKeyRepeat
    case ejectKeyUp
}

/// What the event tap should do with the `CGEvent` it is currently holding.
///
/// Why an enum rather than a `Bool`: the tap callback returns `nil` to consume an event, and a bare
/// boolean at that call site reads ambiguously in both directions. Naming the two outcomes makes the
/// suppression policy in `KeyboardEventManager` readable as prose.
enum EventDisposition: Equatable, Sendable {
    /// Return the original event from the tap — the system keeps its native behaviour.
    case passThrough
    /// Return `nil` from the tap — the system never sees the event.
    case suppress
}
