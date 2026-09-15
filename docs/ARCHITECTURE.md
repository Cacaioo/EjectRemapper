# Architecture

How Eject Key Remap is put together, and why each piece is where it is. The evidence behind the
low-level choices is in [TECHNICAL_INVESTIGATION.md](TECHNICAL_INVESTIGATION.md); this document is
about structure.

---

## The shape of the problem

Three constraints drive the whole design.

**The Eject key is not an ordinary key.** It arrives as a system-defined event carrying a media-key
payload, not as a key event with a virtual key code. Nothing in the app can treat it as "just another
key", and the code that decodes it has to be isolated so the rest of the app never needs to know.

**The interception point is a real-time callback.** The tap callback runs on a dedicated thread inside
the window server's event path. Blocking it, or taking a lock the main thread holds, stalls the user's
input. Everything in that callback must be bounded and fast.

**Every interesting action is a side effect on the user's machine.** Locking the screen, taking a
screenshot and sending key events cannot be exercised in tests. If those calls are scattered through
the code, the app becomes untestable. They are therefore all funnelled through narrow protocols with
test doubles.

## Layers

```
                       ┌──────────────────────────────────────────┐
   main actor          │  UI (SwiftUI)   AppState   AppSettings    │
                       └───────────────┬──────────────────────────┘
                                       │  observation, snapshot update
                       ┌───────────────▼──────────────────────────┐
   main actor          │  KeyboardEventManager                    │
                       │  PermissionManager  LoginItemManager     │
                       └───────────────┬──────────────────────────┘
                                       │  lock-protected snapshot
   ────────────────────────────────────┼───────────────────────────── thread boundary
                                       │
                       ┌───────────────▼──────────────────────────┐
   tap thread          │  CGEventTapEjectKeyDetector              │
                       │  KeyboardEventTap · SystemDefinedDecoder │
                       └───────────────┬──────────────────────────┘
                                       │  enqueue, never block
                       ┌───────────────▼──────────────────────────┐
   action queue        │  ActionDispatcher → handlers             │
                       │  KeyboardEventGenerator → EventPosting   │
                       └──────────────────────────────────────────┘
```

Three execution contexts, with one rule each:

- **The main actor** owns all state the user can see and change. Nothing here runs in the event path.
- **The tap thread** owns the event tap and its run loop. It reads a snapshot under a lock, decides
  pass-through or suppress, and enqueues. It never touches the main actor and never calls a handler
  directly.
- **The action queue** is a serial queue where handlers run. Posting events, launching apps and
  locking the screen all happen here, off the event path.

The snapshot is the crossing point. When the user changes the action, the main actor writes a new
`ActiveConfiguration` into a lock; the next press reads it. No message passing, no cached configuration
inside the tap, and no possibility of the tap waiting on the main thread.

That write happens **synchronously**, in the same main-actor turn as the change. This is worth stating
because the obvious implementation gets it wrong. SwiftUI's observation is the natural way to watch a
settings object, but its callback fires *before* the new value is readable, so an observer has to defer
to a later turn to read it. Views can afford that; the event tap cannot, because between the deferral
and the read there is a window in which a key press would be handled with the configuration the user
has just replaced. The settings object therefore notifies the keyboard layer directly, and observation
is kept only as the backstop for the Accessibility permission, which changes outside the app entirely
and is asynchronous by nature.

## The path of one key press

```
⏏ pressed
  → macOS delivers NX_SYSDEFINED, subtype 8, key type 14
  → KeyboardEventTap callback (tap thread)
      is this one of our own generated events?   → pass through
      SystemDefinedEventDecoder.decode           → not an eject event? pass through
  → EjectKeyDetector translates to .ejectKeyDown / .ejectKeyUp + modifiers
  → KeyboardEventManager's bridge reads the snapshot and decides:
      recording a shortcut?           → suppress, tell the UI
      ⌘ ⌃ ⌥ or ⇧ held?                → pass through (system chords stay native)
      action == .original             → pass through
      action == .disabled             → suppress
      otherwise                       → enqueue on the action queue, suppress
  → ActionDispatcher applies the repeat and debounce policy
  → the handler for that action runs
```

The decision to suppress is made before the action runs and independently of whether it succeeds. That
keeps the tap's behaviour predictable: for a given configuration, the same press always produces the
same disposition.

## Key decisions

Each decision below follows the specification's Decision / Alternatives / Reason / Compatibility /
Limitations format. The supporting evidence is in the investigation document.

### Detecting the Eject key

**Decision.** A single `CGEventTap` at the session level, head-inserted, active, with the event mask
set to system-defined events only, decoded with `NSEvent(cgEvent:)`.

**Alternatives.** Opening the keyboard through `IOHIDManager` would need Input Monitoring and could
only stop the key by seizing the whole keyboard. A global `NSEvent` monitor can watch but never
suppress. A DriverKit virtual keyboard, the Karabiner approach, would mean shipping a system extension.

**Reason.** The tap is the only user-space layer that can both see the key and consume it, and it
inherits Apple's own Fn mapping, eject-delay handling and key-repeat suppression for free.

**Compatibility.** Verified on macOS 26 with a 2015 Magic Keyboard. The event encoding has been stable
for many major releases and is relied upon by several long-lived third-party projects.

**Limitations.** Needs Accessibility. The tap can be disabled by the window server and must be
re-enabled. A virtual-HID remapper installed on the same Mac would see the key first.

### Suppressing the original event

**Decision.** Return `nil` from the callback for every action except Original Function.

**Alternatives.** Letting the event through and hoping macOS ignores it, which would give both the old
behaviour and the new one on any Mac where the key does something.

**Reason.** The specification requires that the mapped action replaces the original, not that it is
added to it.

**Limitations.** Suppression is all or nothing per event. This is why modified Eject presses are
excluded from interception entirely rather than filtered afterwards.

### Never intercepting modified presses

**Decision.** Any Eject press with ⌘, ⌃, ⌥ or ⇧ held is passed through untouched, in every mode.

**Alternatives.** Intercepting everything and re-synthesizing the system behaviour, which would mean
re-implementing sleep, restart and shut down.

**Reason.** Those chords are how people put a Mac to sleep and how they force a restart. Silently
eating them would be a safety problem, not just a bug. The same policy is used by prior art.

**Limitations.** Modified Eject presses cannot be remapped. This is a deliberate trade.

### Generating events

**Decision.** One `KeyboardEventGenerator` owning a private event source, with the actual post call
behind an `EventPosting` protocol. Events are posted at the HID entry point so system hot keys fire.

**Alternatives.** Building events ad hoc in each handler, which would duplicate the tagging and flag
logic and leave no place to intercept for tests.

**Reason.** One place to get the modifier order, the auto-repeat flag and the source tagging right, and
one seam where tests capture instead of post.

**Limitations.** Posting needs permission, and macOS may refuse events from an unsigned process.

### Preventing recursion

**Decision.** Generated events carry a tag in the event source's user data, inherited by every event
from that source, and the tap checks it.

**Reason.** Defence in depth. The tap's mask covers only system-defined events while generated events
are key events, so they cannot reach the callback in the first place. The tag guards against a future
change widening the mask, and lets other tools recognise our events.

### Leaving the keyboard as it was found

**Decision.** Every synthesized sequence ends by restoring the session's modifier flags to what the
user is physically holding. An Eject press is treated as one unit from its key-down to its key-up.

**Alternatives.** Relying on a private event source to keep synthesized modifiers separate from the
real keyboard, which was the original design.

**Reason.** That does not work. Posted events set the modifier state of the whole session, as measured
on macOS 26.5. The original flags-only screenshot chord left ⇧⌘ held, so every later Eject press
looked like ⇧⌘⏏ and was passed through to macOS. Deciding a key-down and its key-up separately had a
related flaw: a modifier touched mid-press could send the two halves different ways, leaving a
synthesized key held down. Each problem is fixed in the layer that owns it. The generator owns the
modifier state it disturbs, and the disposition bridge owns the pairing of a press.

**Limitations.** If the user presses or releases a real modifier while a synthesized key is held, the
restore targets the modifiers read when the press began. The next real modifier change corrects it.

### Key repeat

**Decision.** Software repeat, driven by a timer on the action queue, at the user's own key repeat
speed, only for Forward Delete and custom shortcuts.

**Alternatives.** Relying on the hardware's own repeat events.

**Reason.** There are none. macOS explicitly excludes the Eject key from auto-repeat, so a held key
produces exactly one down and one up. Software repeat is the only way to offer hold-to-repeat at all.

**Limitations.** The repeat is a good imitation, not the real thing. A ten-second safety cap releases
the key if a key-up is ever lost, so nothing can wedge.

### One-shot actions

**Decision.** Lock Screen, Screenshot and Screenshot Menu run on key-down only, are ignored while the
key is held, and are guarded by a short cooldown.

**Reason.** Locking the screen twice is harmless; taking forty screenshots because someone leaned on
the key is not.

### Locking the screen

**Decision.** Resolve the system's lock function at runtime and call it; fall back to sending ⌃⌘Q.

**Alternatives.** Sleeping the display, starting the screen saver, or driving the Apple menu. The
first two only lock if the user has configured a password prompt with no grace period, which is not
the default. The third is slow and breaks in other languages.

**Reason.** It locks immediately and unconditionally, which is what the user asked for. The
specification ranks a native mechanism above UI automation and above a simulated shortcut.

**Limitations.** The function is private and returns nothing, so success cannot be confirmed directly.
Resolving it at runtime means a future macOS that removes it degrades to the fallback instead of
preventing the app from launching. Its use also rules out the Mac App Store.

### Taking a screenshot

**Decision.** Read the user's own screenshot shortcut from their preferences and send exactly that
chord, letting the system's screenshot service do the work.

**Alternatives.** Running the `screencapture` tool, which works but makes this app responsible for the
Screen Recording permission. Using ScreenCaptureKit, which would mean writing a capture engine, a file
namer and a thumbnail presenter — precisely what the specification forbids.

**Reason.** The result is indistinguishable from pressing the shortcut by hand, and it costs no extra
permission. The command-line tool remains as a fallback.

**Limitations.** If the user disabled that shortcut, the app follows the fallback path, which does need
Screen Recording.

### Opening the screenshot toolbar

**Decision.** Launch the system's Screenshot app, which Apple documents as the equivalent of the
shortcut. Fall back to sending the shortcut if the launch fails.

**Reason.** Deterministic, needs no permission from this app, and cannot be affected by the user having
remapped the chord.

### Detecting which keyboard is attached

**Decision.** Enumerate HID devices without opening them and parse each device's own description of
itself, looking for a declared Eject capability.

**Alternatives.** Asking the device for its elements, which needs Input Monitoring; or matching on
product IDs alone, which would miss third-party keyboards.

**Reason.** It needs no permission at all, shows no prompt, and is accurate: a keyboard either declares
the capability or it does not. Product IDs are used only to explain *why* a specific unsupported
keyboard is unsupported.

**Limitations.** A keyboard that declares the capability but whose key macOS consumes internally would
be reported as supported. No such device is known.

### Settings

**Decision.** `UserDefaults` through an observable wrapper, written synchronously, with the store
injectable for tests.

**Reason.** A handful of small values. A database would be absurd, and the specification rules one out.

**Limitations.** The custom shortcut is stored as encoded data rather than as plain keys, so it is not
hand-editable in the defaults file. That is the point: the internal representation is a key code and a
modifier mask, never a display string, so it survives a change of keyboard layout or language.

## Testability

Each seam exists so that a specific side effect can be replaced in tests:

| Protocol | Real implementation | Test double |
|---|---|---|
| `EventPosting` | posts to the window server | records events in an array |
| `EjectKeyDetector` | the event tap | a fake that feeds events on demand |
| `LockScreenStrategy` | the system lock call | a fake that records that it was asked |
| `EjectActionHandler` | the real handlers | spies that record their calls |
| `KeyLabelProvider` | the current keyboard layout | a fixed US QWERTY table |
| `UserDefaults` | the user's preferences | a private, disposable suite |
| `LoginItemService` | the real login item registry | an inert double that registers nothing |
| `RepeatTimer` | a dispatch timer | a timer the test ticks by hand |

The pure logic — decoding the event payload, formatting a shortcut, validating one, parsing a HID
description, deciding the disposition for a configuration — is all in free functions and value types
with no dependencies, which is where most of the test coverage sits.

The app also detects when it is running under the test harness and refuses to build its live object
graph, because the unit tests are hosted by the app itself. Without that check, running the tests would
start a real event tap.

## What is deliberately not here

- No general remapping framework. One key, seven actions.
- No key logging of any kind. The event mask makes it structurally impossible.
- No polling loops and no high-frequency timers. The only timer is the repeat timer, which runs only
  while a key is held, plus a slow permission poll that runs only while a permission screen is visible.
- No network code.
- No database.
- No support for the Lock and Touch ID keys on newer Magic Keyboards, because macOS consumes them
  before any app can see them.
