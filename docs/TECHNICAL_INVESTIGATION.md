# Technical Investigation — Eject Key Remap

Phase 1 of the engineering specification. Every claim below is either **verified** on the development
machine (macOS 26.5.2 build 25F84, Apple silicon, Xcode 26.6, Apple Magic Keyboard A1644 over
Bluetooth) with the command or header citation given, or explicitly marked **unverified** with the
reason. Sections 3–10 follow the spec's *Decision / Alternatives / Reason / Compatibility /
Limitations* format.

Investigation artefacts (probe sources, decoded HID descriptors, fetched Apple sources) were produced
in a scratch directory and are not part of the repository; the evidence is quoted inline here.

---

## 1. Summary of decisions

| Area | Decision | Permission needed | Confidence |
|---|---|---|---|
| Eject key detection | `CGEventTap` at `.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, mask `1 << 14` (`NX_SYSDEFINED`) | Accessibility | High |
| Event decoding | `NSEvent(cgEvent:)` → subtype 8 (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`), `data1` bit layout | — | High |
| Suppression | Return `nil` from the tap callback | Accessibility | High |
| Modified Eject (⌃⇧⏏, ⌥⌘⏏, ⌃⌘⏏, ⌃⌥⌘⏏, ⌃⏏) | Never intercepted — always passed through | — | High |
| Key repeat | Software timer; hardware Eject never repeats | — | High |
| Forward Delete | Synthesized `CGEvent` virtual key `0x75`, posted to `.cghidEventTap` | Accessibility / PostEvent | High |
| Custom shortcut | Synthesized modifier `flagsChanged` + key down/up, posted to `.cghidEventTap` | Accessibility / PostEvent | High |
| Lock Screen | `SACLockScreenImmediate` from `login.framework`, resolved by `dlsym` at runtime; fallback ⌃⌘Q | none / PostEvent for fallback | High |
| Screenshot | Synthesize the user's configured symbolic hot key 28 (⌘⇧3); fallback `/usr/sbin/screencapture -x -p` | PostEvent / Screen Recording for fallback | High |
| Screenshot Menu | `NSWorkspace` opens `/System/Applications/Utilities/Screenshot.app`; fallback hot key 184 (⌘⇧5) | none / PostEvent for fallback | High |
| Keyboard compatibility | Parse each HID device's report descriptor for Consumer page `0x0C` usage `0xB8` without opening the device | none | High |
| Accessibility permission | `AXIsProcessTrusted`, prompt once per launch, System Settings deep link, test-tap health probe | — | High |
| Launch at Login | `SMAppService.mainApp` | user approval in Login Items | High |
| App Sandbox | **Off** — posting events is impossible inside the sandbox | — | High |
| Hardened Runtime | On (honoured in Release; Xcode disables it for ad-hoc Debug builds) | — | Verified |
| Deployment target | macOS 14.0 | — | See §12 |

---

## 2. Environment and hardware observed

```
macOS 26.5.2 (25F84), arm64
Xcode 26.6 (17F113) — not xcode-selected; Command Line Tools SDK 26.5 active
security find-identity -v -p codesigning  ->  0 valid identities found   (ad-hoc signing only)
defaults read -g KeyRepeat -> 5 ;  InitialKeyRepeat -> 25
```

Connected keyboard, from `system_profiler SPBluetoothDataType` and `ioreg -l -w0`:

```
MagicKeyboard   VendorID 0x004C (76)   ProductID 0x0267 (615)   firmware 2.0.6 (VersionNumber 518)
Transport Bluetooth   Manufacturer "Apple Inc."   KeyboardLanguage "U.S."
```

That is the **A1644 Magic Keyboard (2015)**, which has a physical Eject key. `bluetoothd` (pid 163)
publishes it as four `IOHIDUserDevice`s; the keyboard one (`PrimaryUsagePage 0x01 / Usage 0x06`) is
driven by `AppleHIDKeyboardEventDriverV2`, whose `IOHIDEventServiceUserClient` is owned by
WindowServer (pid 173).

---

## 3. Eject key exposure

**Decision.** Treat the Eject key as a HID **Consumer page (0x0C) usage 0xB8** key that macOS
delivers to user space as an `NX_SYSDEFINED` (CGEvent type 14) event with subtype 8 and key type 14.

**Evidence — the report descriptor.** The keyboard interface's 182-byte report descriptor was read
from the IORegistry (`ReportDescriptor` property, no device open, no permission) and decoded. Report
ID 1 contains, after the 8 modifier bits, the reserved byte, the LED output and the 6-key rollover
array:

```
Usage Page (0x0C Consumer); Report Size 1; Report Count 1; Usage (0xB8 Eject);
Logical 0..1; Input (Data,Var,Abs)          <- Eject: one dedicated bit in report ID 1
Usage Page (0xFF AppleVendor); Usage (0x03 = Fn); Report Size 7; Input (Data,Var,Abs)
```

So Eject is a real key, not an Fn-layer alias of F12. The driver agrees: its
`SupportedKeyboardUsagePairs` array contains `(0x0C << 32) | 0xB8`, and its `Keyboard.Elements`
list holds `{UsagePage 12, Usage 184, ReportID 1, ReportSize 1, ElementCookie 285}`. Its
`FnFunctionUsageMap` maps F12 to Consumer `0xE9` (Volume Up), confirming F12 is not an Eject alias
on this model.

**Evidence — the delivery path.** `bluetoothd` → `IOHIDUserDevice` → `IOHIDInterface` →
`AppleHIDKeyboardEventDriverV2` → HID event system (`IOHIDKeyboardFilter.plugin`, then the
`IOHIDNXEventTranslator*` plugins) → `IOHIDSystem` → WindowServer → the CGEventTap chain → apps.

**Evidence — the `data1` encoding.** From Apple's own last open-source translator
(`IOHIDFamily-503.215.2`, `IOHIDSystem/IOHIDSystem.cpp:4977`):

```c
outData.compound.subType   = NX_SUBTYPE_AUX_CONTROL_BUTTONS;          /* 8 */
outData.compound.misc.L[0] = (flavor << 16) | (eventType << 8) | repeat;
```

with `flavor = NX_KEYTYPE_EJECT = 14` (`ev_keymap.h:71`), `eventType = NX_KEYDOWN = 10` /
`NX_KEYUP = 11` (`IOLLEvent.h:106-107`), `NX_SYSDEFINED = 14` (`IOLLEvent.h:113`),
`NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8` (`IOLLEvent.h:186`). Apple's own decoder
(`tools/IOHIDNXEventDescription.c`) and three independent consumers (Hammerspoon, SPMediaKeyTap,
Ejectulate) use the same masks. Therefore:

```
key down   data1 = 0x000E0A00
key up     data1 = 0x000E0B00
keyType    (data1 >> 16) & 0xFFFF
keyState   (data1 >>  8) & 0xFF      0x0A = down, 0x0B = up
repeat      data1 & 1
```

A round-trip probe confirmed the bridge: an `NSEvent.otherEvent(with: .systemDefined, subtype: 8,
data1: 0xE0A00, …)` converted to a `CGEvent` reports `type.rawValue == 14`, and converting back with
`NSEvent(cgEvent:)` returns subtype 8 and the same `data1`.

**Eject delay.** `IOHIDKeyboardFilter.mm:64` defines `kEjectKeyDelayMS 0`, and this machine reports
`"EjectDelay" = 0` in all 125 `HIDEventServiceProperties` dictionaries and in `IOHIDSystem`'s
`HIDParameters`. So the key is delivered immediately. When the delay is non-zero the filter withholds
the key-down and cancels both events if the key is released early — the historical source of "laggy
Eject". `HIDF12EjectDelay = 250` is a separate legacy knob for keyboards where F12 doubled as Eject.
**The app never changes these values.**

**Key repeat.** `IOHIDKeyboardFilter.mm:1353-1372` (`isNotRepeated`) excludes Consumer Play, **Eject**,
PlayOrPause, Menu, Power and Sleep from auto-repeat, and `processKeyRepeats` returns early for them.
The legacy kernel path agrees (`IOHIKeyboard.cpp:602-608`). **Holding Eject produces exactly one down
and one up event; the repeat bit is never set.** Hold-to-repeat must therefore be generated in
software — this corrected an early assumption in the investigation.

**Alternatives.**
- `IOHIDManager` with `IOHIDDeviceOpen` and input-value callbacks: needs Input Monitoring, cannot stop
  propagation without `kIOHIDOptionsTypeSeizeDevice` (which hijacks the entire keyboard), and would
  duplicate Apple's Fn-map, eject-delay and repeat logic.
- `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)`: observe-only. `NSEvent.h:541` states
  "you cannot modify or otherwise prevent the event from being delivered".
- Tap at `kCGHIDEventTap` with an active tap: `CGEvent.h:269-270` restricts that location to root.
- A Karabiner-style DriverKit virtual HID device: most powerful, but requires a system extension and
  is far beyond the scope of a small utility.

**Reason.** The session-level event tap is the only user-space layer that can both *see* and *consume*
the key, it is transport-independent, and it inherits all of Apple's HID processing for free.

**Compatibility.** Verified on macOS 26.5.2 with the A1644. The `NX_SYSDEFINED` encoding has been
stable since Mac OS X 10.x and is used unchanged by long-lived third-party projects.

**Limitations.**
- An active tap requires Accessibility. A listen-only tap can detect but never suppress, and is itself
  gated by Input Monitoring (see §4).
- A press may also surface as an `NX_SUBTYPE_EJECT_KEY` (subtype 10) event in addition to the subtype-8
  pair — the PowerKey project handles all three. This app swallows subtype 10 as well when remapping.
  Not observed directly here (no key could be pressed on the unattended machine).
- Karabiner-style virtual HID drivers sit below this layer and would rewrite the key first.

---

## 4. Event interception and suppression

**Decision.** One `CGEventTap`, created with

```swift
CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                  options: .defaultTap, eventsOfInterest: 1 << 14,
                  callback: trampoline, userInfo: Unmanaged.passUnretained(self).toOpaque())
```

serviced by a dedicated `Thread` running its own `CFRunLoop`. The callback returns the original event
to pass it through and `nil` to suppress it.

**The mask is exactly `1 << 14`.** The app never observes keyboard key events, so it cannot read typed
text even in principle. This is the single most important privacy property of the design.

**Permission model** (verified by probe plus Apple DTS statements):

| Need | TCC service | Evidence |
|---|---|---|
| Active (`.defaultTap`) tap | Accessibility | `.defaultTap` returned `nil` in the untrusted probe; `CGEvent.h:272-278` |
| Listen-only tap | Input Monitoring | Created but **never enabled**: `CGGetEventTapList` showed `enabled=false` after `tapEnable(true)` |
| `CGEvent.post` | PostEvent (shown in the UI under Accessibility) | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`, `CGEvent.h:405-408` |

A listen-only keyboard tap is refused outright (`tapCreate` → `nil`), and a mixed mask is silently
trimmed rather than rejected — so a non-nil tap is not proof of a working tap. The app therefore
checks `CGEvent.tapIsEnabled` after creation, not just the return value.

**Suppression policy.**

| Situation | Tap returns |
|---|---|
| Action is *Original Function* | the event, unmodified |
| Action is *Disabled* | `nil` (event consumed, nothing happens) |
| Any other action | `nil`, and the action is dispatched off the callback thread |
| Eject with ⌘, ⌃, ⌥ or ⇧ held | the event, unmodified — **always** |
| Shortcut recorder is open | `nil` (so a stray Eject press cannot fire the old action) |
| Not an Eject event | the event, unmodified — other media keys are never touched |

The modifier rule keeps every documented system chord working: ⌃⇧⏏ (display sleep), ⌥⌘⏏ (sleep),
⌃⏏ (power dialog), ⌃⌘⏏ (restart), ⌃⌥⌘⏏ (shut down). Those actions are performed by `loginwindow`
*after* the tap chain, so a tap that swallowed the event would silently break them. The same policy is
used by Ejectulate and is recommended by the Hammerspoon community.

**Callback discipline.** The callback decodes the event, reads a lock-protected configuration snapshot,
and enqueues the action on a serial queue. It never touches the main actor, never allocates beyond the
`NSEvent` bridge, and never blocks. The bridge costs about 17.8 µs per call, measured over 10,000
iterations; at most two events arrive per key press.

**Recovery.** `kCGEventTapDisabledByTimeout` (0xFFFFFFFE) and `kCGEventTapDisabledByUserInput`
(0xFFFFFFFF) are handled inside the callback by calling `CGEvent.tapEnable(tap:enable:true)`.

**Recursion prevention.** Generated events come from a `CGEventSource(stateID: .privateState)` whose
`userData` is set to `0x454A4354` ("EJCT"); that value is inherited by every event the source creates,
and is also set explicitly on each event. The tap additionally checks the tag before decoding. Because
the mask only covers type 14 and every generated event is type 10/11, a generated event cannot reach
the callback at all — the tag is defence in depth and lets other tools identify our events.

---

## 5. Event generation

**Decision.** A single `KeyboardEventGenerator` owns one private `CGEventSource` and builds all events;
the actual `post` call sits behind an `EventPosting` protocol so tests capture instead of post.
Events are posted to `.cghidEventTap`, the point where HID events enter the window server — this is
what makes the system's own hot keys (the screenshot chords) fire.

**Forward Delete.** Virtual key `0x75` (`kVK_ForwardDelete`, `Events.h:305`). A probe confirmed the
synthesized event reads back as `keyCode 117`, characters `U+F728` (`NSDeleteFunctionKey`), with the
fn flag set automatically by Core Graphics. It is always sent without modifiers: a press with ⌘, ⌃, ⌥
or ⇧ held is passed through to macOS (§4), so ⌥⌦ and ⌘⌦ cannot be produced from ⏏.

**Custom shortcut.** The sequence is

```
flagsChanged (modifier down, in fn ⌃ ⌥ ⇧ ⌘ order, flags accumulating)
keyDown  (target key, full flags)
keyUp    (target key, full flags)
flagsChanged (modifier up, reverse order, flags decreasing to none)
```

Caps Lock is applied as a flag only; its key is never pressed, because pressing it would toggle the
real Caps Lock state.

**Modifier mapping.** `CGEventFlags` and `NSEvent.ModifierFlags` share raw values — verified
numerically for all eight bits:

| Modifier | Raw value | Virtual key |
|---|---|---|
| Caps Lock ⇪ | `0x010000` | `0x39` |
| Shift ⇧ | `0x020000` | `0x38` |
| Control ⌃ | `0x040000` | `0x3B` |
| Option ⌥ | `0x080000` | `0x3A` |
| Command ⌘ | `0x100000` | `0x37` |
| Function fn | `0x800000` | `0x3F` |

so `CGEventFlags(rawValue: UInt64(nsFlags.rawValue))` is lossless. Header evidence:
`CGEventTypes.h:84-98`, `IOLLEvent.h:241-248`, `NSEvent.h:168-178`.

**Key repeat policy.**

| Action | Repeat |
|---|---|
| Forward Delete | Yes — software timer |
| Custom Shortcut | Yes — software timer, matching what holding the real chord would do |
| Lock Screen, Screenshot, Screenshot Menu | No — one-shot, guarded by held-state tracking and a cooldown |
| Original Function, Disabled | Not applicable |

Because the hardware never repeats Eject (§3), a `DispatchSourceTimer` on the action queue drives the
repeats, using `NSEvent.keyRepeatDelay` and `NSEvent.keyRepeatInterval` so the feel matches the user's
own Key Repeat settings. On this machine those read 0.4167 s and 0.0833 s, which is the preference
value divided by 60 — AppKit's tick is 1/60 s, not 15 ms. A 10-second safety cap force-releases the
key if a key-up is ever lost.

### Modifier state is session-wide

This was found after release, while fixing a bug where choosing Screenshot stopped every later
action from working until the app was relaunched.

Posting a keyboard event changes the modifier state of the whole login session, not just of that
event. The window server takes the flags of the most recently posted key down, key up or
flags-changed event as the session's current modifiers, and stamps them onto the physical key
presses that follow. A private event source does not isolate this.

Measured on macOS 26.5.2 by posting a harmless ⇧⌘F20 the way the Screenshot action had posted ⇧⌘3,
as a key down and a key up carrying the flags, then reading `CGEventSource.flagsState`:

| Step | Session modifiers |
|---|---|
| Before | none |
| After key down and key up carrying ⇧⌘ | ⇧⌘ |
| After the posting process exited | still ⇧⌘ |
| After one flags-changed event with no flags | none |

Core Graphics also adds the fn flag on its own to Forward Delete, Help, Home, End, Page Up, Page Down,
the four arrows and F1–F19. That was checked in memory, with nothing posted. A plain synthesized
Forward Delete therefore leaves fn set in the same way.

For this app the consequence was specific. The Eject key arrived stamped with ⇧⌘, the rule that
modified Eject presses belong to macOS passed it straight through, and nothing selected afterwards
could run. Quitting the app did not clear it. Relaunching most likely appeared to help because a real
modifier key was pressed along the way, which releases the flags.

**Decision.** The event generator guarantees that every synthesized sequence ends with the session's
modifiers equal to the physical modifiers read when the sequence began. System hot keys are sent as
complete chords, with the modifier keys pressed and released exactly as a person types them, instead
of as a flags-only key tap. Any flag still left over, such as fn, is cleared with one flags-changed
event on the Control key code. It is never sent on the Caps Lock key code, which would toggle Caps Lock,
or on the Globe key code, which can open the emoji picker. The generator's interface no longer offers
any way to post a modifier without releasing it.

Two further measurements shaped the implementation.

- **Synthesized fn really does latch.** A plain F19 key down and key up, the shape the old Forward
  Delete path used, left fn set for the session.
- **A reading taken right after posting is stale.** Straight after posting ⇧⌘ as flags, the session
  still showed no modifiers in 20 of 20 attempts; readings taken after a brief settle were correct.
  So the baseline a sequence records must not trust a reading that could still contain this app's
  own unfinished chord. It excludes ⌘, ⌃, ⌥ and ⇧, none of which can be physically held when an action
  runs, because presses with them are passed through to macOS.

The app's real `KeyboardEventGenerator` was then driven against the window server with harmless keys.
A ⇧⌘ chord, a bare key that Core Graphics stamps with fn, and a held and repeated ⌥ chord each left the
session's modifiers exactly as they were before.

---

## 6. Lock Screen

**Decision.** Resolve `SACLockScreenImmediate` from `/System/Library/PrivateFrameworks/login.framework/login`
at runtime with `dlopen` + `dlsym`, cast to `@convention(c) () -> Void`, and call it. If the symbol
cannot be resolved, fall back to synthesizing ⌃⌘Q.

**Verified on this OS** (resolve only — the function was deliberately never called):

```
dlopen OK: /System/Library/PrivateFrameworks/login.framework/login
  SACLockScreenImmediate : present
  SACSwitchToLoginWindow : present
  SACScreenSaverStartNow : present
  SACLockScreen          : ABSENT
CoreGraphics CGSLockScreen : ABSENT
```

**Alternatives.**
- `SACSwitchToLoginWindow`: fast-user-switches to the login window. Different behaviour, leaves the
  session running behind a user picker. Rejected.
- Synthesized ⌃⌘Q: documented by Apple as "Lock your screen". There is **no**
  `com.apple.symbolichotkeys` entry for it (every key in the domain was enumerated: 12, 28–31, 52,
  79–82, 160, 164, 184), so it is a fixed `loginwindow` hot key and the chord must be hard-coded.
  Kept as the fallback.
- `pmset displaysleepnow` or the screen saver: these only lock if the user has set "require password
  immediately", which is not the case on this machine (`sysadminctl -screenLock status` reports a
  300 s grace period). Rejected as unreliable.
- `CGSession -suspend`: the binary no longer exists on modern macOS. Verified absent.
- AppleScript or Accessibility driving the Apple menu: slow, locale-fragile, needs more permission.
  Not implemented.

**Reason.** `SACLockScreenImmediate` is what Hammerspoon and Caffeine use, it locks immediately and
independently of screen-saver and password-grace settings, and it is a single call with no UI
automation. The spec ranks a native mechanism above UI automation and above a simulated shortcut.

**Compatibility.** Present on macOS 26.5.2. Widely reported working from 10.13 onward. Resolved at
runtime, never linked, so its disappearance in a future release degrades to the fallback rather than
preventing the app from launching.

**Limitations.** It is a private symbol, undocumented, and returns `void` — there is no success code.
The app logs the attempt and relies on the fallback chain. An app using it cannot be distributed on
the Mac App Store. The lock is attempted only on key-down, never on repeat.

---

## 7. Screenshot and Screenshot Menu

### Screenshot (full screen)

**Decision.** Read the user's configured symbolic hot key **28** ("Save picture of screen as a file")
and synthesize exactly that chord at `.cghidEventTap`, letting `screencaptureui` do the capture.

**Verified reading of the live preferences:**

```
id  28 : enabled=true  keyCode=0x14  unicode=51 ('3')  mods=0x120000  ->  ⇧⌘3
id  30 : enabled=true  keyCode=0x15                    mods=0x120000  ->  ⇧⌘4
id 184 : enabled=true  keyCode=0x17                    mods=0x120000  ->  ⇧⌘5
```

The `parameters` array is `[unicode character, virtual key code, modifier mask]`, and the modifier mask
uses the Cocoa device-independent bits (shift `1<<17`, control `1<<18`, option `1<<19`, command
`1<<20`), **not** the Carbon bits. `0x120000 = 0x100000 | 0x20000` = ⌘ + ⇧. If the entry is missing or
disabled the app falls back to the built-in default.

**Alternatives.** `/usr/sbin/screencapture -p` honours the user's own settings (the man page states
"-p Screen capture will use the default settings for capture"), but it makes *this app* the responsible
process for the Screen Recording permission, which means an extra TCC prompt for a capability the app
does not otherwise need. It is kept as the fallback, invoked as `screencapture -x -p`. ScreenCaptureKit
was rejected outright: it would mean re-implementing the capture engine, the save location, the format,
the thumbnail and the shutter sound, which the specification forbids.

**Reason.** Synthesizing the chord gives a result identical to the user pressing it: same save
location, same format, same floating thumbnail, same sound, and no additional permission beyond the
PostEvent access the app already needs.

**Limitations.** Requires PostEvent access. If the user has disabled or remapped hot key 28, the app
follows whatever they configured, which is the correct behaviour. One-shot only.

### Screenshot Menu (the ⌘⇧5 interface)

**Decision.** Launch `/System/Applications/Utilities/Screenshot.app` through
`NSWorkspace.openApplication(at:configuration:)` with `activates = true`.

**Verified:** the bundle exists, its identifier is `com.apple.screenshot.launcher`, and it is
`LSUIElement`, so it shows the capture toolbar without a Dock icon. Apple's own documentation states
the equivalence: "To open the app, press Shift-Command-5. Or find the Screenshot app in the Utilities
folder of your Applications folder."

**Alternatives.** Synthesizing hot key 184 works and is used as the fallback if the launch fails.
`screencapture -i -U` would require Screen Recording. The toolbar is never re-implemented.

**Limitations.** The toolbar itself asks for Screen Recording the first time the user captures,
exactly as it does when opened by hand. One-shot only.

---

## 8. Accessibility permission

**Decision.** `PermissionManager` owns a three-state model (`granted` / `denied` / `unknown`) and
combines four signals:

1. `AXIsProcessTrusted()` — never prompts.
2. `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` — prompts, at most once per
   launch, and only at a user-initiated moment. The header notes that "prompting occurs asynchronously
   and does not affect the return value".
3. The `com.apple.accessibility.api` distributed notification, treated as a hint to re-check rather
   than as ground truth, because it is not delivered reliably when an app is removed from the list.
4. A cheap **test tap** probe: create a tap, check it, invalidate it immediately. This is the only
   reliable way to detect revocation, because `AXIsProcessTrusted()` can keep returning `true` for a
   process whose access has already been taken away.

The app re-checks on activation, and polls at 1.5 s **only** while a permission view is on screen.

**System Settings deep link.** `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`
for macOS 13 and later, with the legacy `com.apple.preference.security?Privacy_Accessibility` string as
a fallback.

**Revocation while running.** The tap stops delivering events and the callback starts receiving
`tapDisabledByTimeout`. Forum reports on Sonoma and later describe input being swallowed in this state,
so the app tears the tap down rather than leaving it in place: `stop()` disables, invalidates and stops
the run loop, restoring normal keyboard behaviour. After a re-grant the tap is **re-created**, not just
re-enabled. *Partly unverified* — TCC state could not be changed safely on the development machine.

**Ad-hoc signing caveat.** Apple DTS is explicit that ad-hoc signed code "does not include a stable
designated requirement, and thus macOS is unable to tell that version N+1 of your app is the same code
as version N". Every rebuild therefore invalidates the grant *silently*: the row stays visible in
System Settings while the check returns denied. The fix is either a stable signing identity or
`tccutil reset Accessibility com.cacaioo.EjectRemapper` between rebuilds. This is documented in the
README's troubleshooting section because it is the single most confusing failure mode for a developer.

---

## 9. Launch at Login

**Decision.** `SMAppService.mainApp` with `register()` / `unregister()`, and
`SMAppService.openSystemSettingsLoginItems()` when the status is `.requiresApproval`.

The four statuses are `notRegistered`, `enabled`, `requiresApproval` and `notFound`. `.requiresApproval`
is not an error: registration succeeded but the user must enable the item in System Settings. A user
who disables the item afterwards makes the status report `.notFound`, so the app treats anything other
than `.enabled` as "off" and re-registers when the user turns the switch back on. Moving the app bundle
invalidates the recorded path, so the app re-registers when it finds a stale state.

The header notes that apps using `SMAppService` must be code signed; ad-hoc signing satisfies this
locally. The app is `LSUIElement`, so a login launch shows only the menu bar item, never a window.

`SMAppServiceErrorDomain`, the symbol marked `API_AVAILABLE(macos(15.0))` in the SDK header, is a newer
dedicated error domain and is not used — the app reports errors through the generic `NSError` it gets
back, so it keeps working on macOS 14.

---

## 10. App Sandbox, code signing, notarization

**App Sandbox is off.** Apple's App Sandbox design guide lists "use of accessibility APIs in assistive
apps" among the activities forbidden inside the sandbox, and `CGEvent.post` is silently blocked there
with no entitlement to re-enable it. Since the app must both run an active tap and post events, the
sandbox is incompatible. This is a documented, deliberate choice, not a shortcut.

**Hardened Runtime is on**, with no `com.apple.security.*` entitlements: event taps and event posting
are gated by TCC, not by hardened-runtime entitlements, so no exception is needed. Xcode prints
"Disabling hardened runtime with ad-hoc codesigning" for Debug builds and honours the setting in
Release. Forcing `--options runtime` in Debug makes the test host crash before it can connect to
`testmanagerd`, so it is deliberately not forced.

**Signing.** The development machine has no identities, so builds are ad-hoc (`CODE_SIGN_IDENTITY = "-"`).
The app builds and runs locally this way. For distribution: sign with Developer ID, keep hardened
runtime on, notarize with `notarytool`, staple with `stapler`. The Mac App Store is not an option
because of the private lock-screen symbol and the missing sandbox. Full instructions are in
`docs/BUILD_AND_SIGNING.md`.

---

## 11. Hardware compatibility

| Model | Year | Product ID | Key at top right | HID usage | Supported |
|---|---|---|---|---|---|
| A1644 Magic Keyboard | 2015 | `0x0267` | Eject ⏏ | Consumer `0xB8` | **Yes — verified on this machine** |
| A1843 Magic Keyboard with Numeric Keypad | 2017 | `0x026C` | Eject ⏏ | Consumer `0xB8` | Yes (high confidence) |
| A1243 Apple Keyboard (wired) | 2007 | `0x0220`–`0x0222` | Eject ⏏ | Consumer `0xB8` | Yes (high confidence) |
| A1255 / A1314 Apple Wireless Keyboard | 2007–2011 | `0x022C`–`0x022E`, `0x0239`–`0x023B`, `0x0255`–`0x0257` | Eject ⏏ | Consumer `0xB8` | Yes (medium-high confidence) |
| A2450 Magic Keyboard | 2021 | `0x029C` | Lock 🔒 | Consumer `0x19E` | **No** |
| A3203 Magic Keyboard (USB-C) | 2024 | `0x0320` | Lock 🔒 | Consumer `0x19E` | **No** |
| A2449 / A2520 Magic Keyboard with Touch ID | 2021 | `0x029A`, `0x029F` | Touch ID | Consumer `0x40` (Menu) | **No** |
| A3118 / A3119 Magic Keyboard with Touch ID (USB-C) | 2024 | `0x0321`, `0x0322` | Touch ID | Consumer `0x40` | **No** |
| Built-in MacBook keyboards | — | — | Touch ID / power | — | **No** — no Eject key |

Product IDs come from the Linux `hid-ids.h` driver table; the Lock and Touch ID usages come from
Karabiner-Elements' source and issue tracker. The Lock key is handled by macOS itself and there is no
`NX_KEYTYPE` for it — `ev_keymap.h` ends at 23 with `NX_NUMSPECIALKEYS` 24 — and multiple reports say
it never appears in event viewers, so it cannot be intercepted by an event tap. The Touch ID key is
likewise consumed by the system on external keyboards. Both are reported to the user as unsupported
rather than silently doing nothing.

**Detection**, performed without any permission and without opening a device: enumerate with
`IOHIDManagerCopyDevices` (never `IOHIDManagerOpen`), read each device's `ReportDescriptor`, and walk
the HID items looking for usage `0xB8` while the current usage page is `0x0C`. This works with Input
Monitoring denied and triggers no prompt — verified, with `IOHIDCheckAccess` unchanged before and
after. Element enumeration via `IOHIDDeviceCopyMatchingElements` does **not** work without Input
Monitoring and is deliberately not used. Third-party keyboards that declare Consumer Eject are
therefore supported automatically.

---

## 12. Deployment target

**macOS 14.0 (Sonoma).** Everything the app needs exists there: `SMAppService.mainApp` (13.0),
`MenuBarExtra` (13.0), the Observation framework's `@Observable` (14.0),
`CGPreflightPostEventAccess` (10.15), `NSWorkspace.openApplication` (10.15) and the modern System
Settings URL scheme (13.0). Choosing 14.0 rather than 13.0 buys `@Observable`, which removes a large
amount of `ObservableObject` boilerplate, and covers the three most recent major releases. Nothing
deprecated is used: `CGWindowListCreateImage` and friends are avoided entirely because the app never
captures the screen itself.

---

## 13. Xcode project facts

Proven by building and testing a template before any application code was written:

- `objectVersion = 77` with `PBXFileSystemSynchronizedRootGroup` works with `xcodebuild` 26.6. Files
  are discovered from the folder; nothing is listed individually in the project file.
- `SWIFT_VERSION = 6.0` compiles cleanly with zero warnings.
- XCTest and Swift Testing coexist in one test bundle; both were reported passing.
- `xcodebuild ... build` and `xcodebuild ... test` both succeed from the command line with a shared
  scheme. No extra flags are needed.
- A universal Release binary needs `-destination 'generic/platform=macOS'`; `platform=macOS` builds the
  active architecture only.

---

## 14. What only a human can verify

The development machine was unattended throughout, so no key was ever pressed and no side-effectful
action was run. The following require a person at the keyboard, and are listed in
`docs/MANUAL_TEST_CHECKLIST.md`:

1. That a real hardware Eject press produces `NX_SYSDEFINED` subtype 8 with `data1 = 0x000E0A00`, and
   whether a subtype 10 event accompanies it.
2. That returning `nil` from the tap actually suppresses the system's own Eject handling.
3. That the system chords ⌃⇧⏏, ⌥⌘⏏, ⌃⌘⏏ still work while the app is running.
4. That granting Accessibility alone is enough to post events, or whether PostEvent is prompted
   separately.
5. That the synthesized ⌘⇧3 chord fires the system screenshot.
6. That `SACLockScreenImmediate` locks the screen on macOS 26.5.
7. Behaviour when Accessibility is revoked while the app is running.
8. Behaviour on a keyboard other than the A1644.

---

## 15. Sources

Apple headers in the macOS 26.5 SDK: `IOKit/hidsystem/IOLLEvent.h`, `IOKit/hidsystem/ev_keymap.h`,
`IOKit/hid/IOHIDUsageTables.h`, `IOKit/hid/IOHIDProperties.h`, `IOKit/hid/IOHIDKeys.h`,
`IOKit/hidsystem/IOHIDLib.h`, `CoreGraphics/CGEvent.h`, `CoreGraphics/CGEventTypes.h`,
`Carbon/HIToolbox/Events.h`, `AppKit/NSEvent.h`, `AppKit/NSWorkspace.h`, `AppKit/NSApplication.h`,
`ServiceManagement/SMAppService.h`, `HIServices/AXUIElement.h`.

Apple open source: <https://github.com/apple-oss-distributions/IOHIDFamily> —
`IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm`, `IOHIDSystem/IOHIDSystem.cpp`,
`IOHIDSystem/IOHIKeyboard.cpp`, `IOHIDSystem/IOHIDKeyboardEventDevice.cpp`,
`IOHIDEventSystemPlugIns/IOHIDNXEventTranslatorServiceFilter.cpp`, `tools/IOHIDNXEventDescription.c`.

Apple documentation and support: <https://support.apple.com/en-us/102650> (Mac keyboard shortcuts),
<https://support.apple.com/en-us/102646> (Take a screenshot on Mac),
<https://support.apple.com/guide/mac-help/lock-the-screen-of-your-mac-mchl8e8b6a34/mac>,
<https://developer.apple.com/library/archive/technotes/tn2450/_index.html>,
<https://developer.apple.com/documentation/servicemanagement/smappservice>.

Apple Developer Forums: threads 122492, 735204, 744440, 789896, 805245, 760186, 758554, 795739.

Third-party prior art: <https://github.com/nolanw/Ejectulate>, <https://github.com/pkamb/PowerKey>,
<https://github.com/nevyn/SPMediaKeyTap>, <https://github.com/Hammerspoon/hammerspoon>,
<https://github.com/pqrs-org/Karabiner-Elements>, <https://github.com/pqrs-org/cpp-hid>,
<https://weblog.rogueamoeba.com/2007/09/29/apple-keyboard-media-key-event-handling/>,
<https://github.com/torvalds/linux/blob/master/drivers/hid/hid-ids.h>.
