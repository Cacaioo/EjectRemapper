# Eject Key Remap

A small macOS menu bar utility that gives the physical Eject key (⏏) on an Apple Magic Keyboard
something useful to do.

On a Mac with no optical drive the Eject key does nothing. This app lets you turn it into Forward
Delete, a screen lock, a screenshot, the screenshot toolbar, or any keyboard shortcut you like.

```
Eject ⏏  →  Forward Delete
Eject ⏏  →  Lock Screen
Eject ⏏  →  Screenshot
Eject ⏏  →  Screenshot Menu
Eject ⏏  →  ⌘ C   (or any shortcut you record)
```

---

## Requirements

- **macOS 14 (Sonoma) or later.** Built and tested on macOS 26.
- **A keyboard with a physical Eject key.** That means an Apple Magic Keyboard from 2015 or 2017
  (A1644, A1843) or an older Apple wired or wireless keyboard. See
  [Supported keyboards](#supported-keyboards) — Magic Keyboards with a Lock key or Touch ID are **not**
  supported, and the app tells you so instead of failing silently.
- **Accessibility permission.** The app cannot see or change the Eject key without it.

## Installation

1. Build the app (see [Building](#building)) or copy `EjectRemapper.app` to `/Applications`.
2. Launch it. An eject symbol appears in the menu bar. There is no Dock icon and no window.
3. macOS asks for Accessibility access. Click **Open System Settings**, find **Eject Key Remap** in
   the list and switch it on.
4. Click the menu bar icon and pick what the Eject key should do.

That is the whole setup. The choice takes effect on your very next press — nothing needs restarting.

## Permissions

**Accessibility** is required, and it is the only permission the app asks for.

macOS treats the ability to intercept a key and to send a key as privileged, and gates both behind
Accessibility. Without it the app still runs and its interface still works, but remapping is inactive
and the menu bar popover says so.

Two actions may ask for something extra, and only if you use them:

| Action | Extra permission | When |
|---|---|---|
| Screenshot | None normally | The app asks the system to take the screenshot, exactly as if you had pressed ⌘⇧3, so the system does the capturing. Only the fallback path, used if you have disabled the ⌘⇧3 shortcut, needs Screen Recording. |
| Screenshot Menu | None | Opens the built-in Screenshot app. That app asks for Screen Recording the first time you capture, exactly as it does when you open it yourself. |

The app makes no network connections of any kind.

## Usage

Click the menu bar icon and choose one of:

**Forward Delete** — deletes the character to the right of the cursor, like the ⌦ key on a full-size
keyboard. Hold the Eject key to repeat, at the speed set in your own Keyboard settings. It deletes
one character at a time only: holding ⌥ or ⌘ does not turn it into delete-word or delete-to-end-of-line,
because Eject presses with a modifier held are left to macOS (see below).

**Lock Screen** — locks immediately and shows the login window.

**Screenshot** — captures the whole screen, exactly like ⌘⇧3. Same save location, same file format,
same floating thumbnail, same shutter sound, because the system does the work.

**Screenshot Menu** — opens the screenshot toolbar, exactly like ⌘⇧5, with the capture modes, the
timer and the save-location options.

**Custom Shortcut** — sends any shortcut you record. See below.

**Original Function** — the app stops interfering. The Eject key does whatever macOS normally does
with it, which on a Mac without an optical drive is nothing.

**Disabled** — the key is swallowed and nothing happens at all. Useful if you keep hitting it by
accident.

### System shortcuts are never intercepted

The Eject key's built-in system chords keep working no matter which action you choose:

| Shortcut | What it does |
|---|---|
| ⌃⇧⏏ | Put the displays to sleep |
| ⌥⌘⏏ | Put the Mac to sleep |
| ⌃⏏ | Show the restart / sleep / shut down dialog |
| ⌃⌘⏏ | Force restart |
| ⌃⌥⌘⏏ | Quit all apps and shut down |

The app only ever acts on an Eject press with **no** modifier held. Anything with ⌘, ⌃, ⌥ or ⇧ is
passed straight through to macOS untouched. This is deliberate: those chords are how some people
restart a wedged Mac, and a remapper that ate them would be dangerous.

## Custom shortcuts

1. Choose **Custom Shortcut**.
2. Click **Record Shortcut**.
3. Press the combination you want, for example ⌘C or ⌘⇧4 or ⌃⌥←.

The shortcut appears using the usual macOS symbols. You never type key names and you never see key
codes. Press Escape to cancel, or click **Clear** to remove the shortcut.

Shortcuts are shown in Apple's canonical order — fn, ⌃, ⌥, ⇧, ⌘ — so what you record as ⌘⇧4 is
displayed as **⇧ ⌘ 4**, which is how System Settings writes it too.

Some combinations are refused, with an explanation:

- A shortcut needs a real key, not only modifiers.
- The Eject key itself cannot be its own shortcut.
- A few keys cannot be reproduced reliably by macOS and are rejected rather than saved and broken.

Holding the Eject key repeats the shortcut, matching what holding the real chord would do.

## Launch at Login

Settings → General → **Launch at Login**. This uses the modern macOS login item API, so the app shows
up under **System Settings → General → Login Items** where you can also turn it off.

If macOS says the item needs approval, the app gives you a button that opens that settings pane
directly. If you move the app to a different folder, toggle the switch off and on again so macOS learns
the new location.

## Troubleshooting

**The Eject key does nothing after I granted Accessibility.**
Quit and relaunch the app. macOS sometimes only applies a new grant to a fresh process.

**It worked, then stopped after I rebuilt the app.**
This is the most common confusion when building from source. macOS identifies an app by its code
signature. A locally built app signed "to run locally" gets a brand new identity on every build, so
your old Accessibility grant no longer matches it — but the row stays visible in System Settings, so
it looks like it should still work. Either sign with a stable developer certificate, or reset the
grant between builds:

```bash
tccutil reset Accessibility com.cacaioo.EjectRemapper
```

**The menu bar icon is gone.**
If you turned it off in Settings, open the app again from Finder and its Settings window appears.

**I have a Magic Keyboard but the app says it is unsupported.**
Magic Keyboards from 2021 onward replaced the Eject key with either a Lock key or Touch ID. macOS
handles both of those itself and never passes them to apps, so there is nothing for this app to remap.
See below.

**Holding the key does not repeat.**
Lock Screen, Screenshot and Screenshot Menu deliberately fire once per press. Only Forward Delete and
custom shortcuts repeat.

**Nothing happens and the popover shows an error.**
Click **Retry**. If it persists, check that Accessibility is still enabled, then relaunch.

## Supported keyboards

| Keyboard | Key at the top right | Works |
|---|---|---|
| Magic Keyboard (2015, A1644) | Eject ⏏ | Yes — this is the reference device |
| Magic Keyboard with Numeric Keypad (2017, A1843) | Eject ⏏ | Yes |
| Apple Keyboard (wired, A1243) | Eject ⏏ | Yes |
| Apple Wireless Keyboard (A1255, A1314) | Eject ⏏ | Yes |
| Magic Keyboard (2021, A2450) and USB-C (2024, A3203) | Lock 🔒 | No |
| Magic Keyboard with Touch ID (A2449, A2520, A3118, A3119) | Touch ID | No |
| Built-in MacBook keyboard | Touch ID or power | No — there is no Eject key |

Any third-party keyboard that reports a real Eject key works too. The app detects this by reading what
each connected keyboard says it can do, which needs no permission at all and never opens the device.

The Lock key and the Touch ID key are consumed by macOS itself before any app can see them, so no
user-space app can remap them. This is a limit of macOS, not of this app.

## Technical architecture

The app watches for exactly one kind of system event and nothing else.

```
Magic Keyboard
      │  HID Consumer page 0x0C, usage 0xB8 (Eject)
      ▼
macOS HID event system
      │  NX_SYSDEFINED event, subtype 8, key type 14
      ▼
KeyboardEventTap        event tap, mask = system-defined events only
      ▼
EjectKeyDetector        decodes the event into "eject down" / "eject up"
      ▼
KeyboardEventManager    decides: pass through, or suppress and act
      ▼
ActionDispatcher        runs the action off the event callback
      ├── Forward Delete       synthesized key event
      ├── Lock Screen          system lock call
      ├── Screenshot           your own ⌘⇧3 shortcut, sent to the system
      ├── Screenshot Menu      opens the built-in Screenshot app
      ├── Custom Shortcut      synthesized modifiers + key
      ├── Original Function    event passed through untouched
      └── Disabled             event swallowed
```

When an action is configured, the original Eject event is **suppressed** so you never get both the
old behaviour and the new one. In Original Function mode the event is returned unchanged.

Full detail, with the evidence behind every decision, is in
[docs/TECHNICAL_INVESTIGATION.md](docs/TECHNICAL_INVESTIGATION.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Security and privacy

**This app is not a keylogger and cannot become one by accident.**

- The event tap is registered for **system-defined events only**. Key presses, typed characters and
  text fields are not part of that category, so the app never receives them. This is enforced by the
  operating system, not by a filter in the code.
- The only key the app reacts to is Eject. Every other system event is passed through untouched.
- The shortcut recorder is the one place the app reads ordinary key presses. It listens only while its
  window is open and only to the app's own window, and it stops the moment you finish recording.
- Nothing is stored except your settings: the selected action, your custom shortcut as a key code and
  modifier mask, and three switches. There is no history and no log of anything you pressed.
- The diagnostic log records events like "tap started" and "action changed". It never records key data.
- No network access. No analytics. No telemetry.

## Building

Requires Xcode 16 or later.

```bash
Scripts/build.sh            # Debug build
Scripts/build.sh Release    # Release build
Scripts/build.sh Release universal
Scripts/test.sh             # Unit tests
```

Or open `EjectRemapper.xcodeproj` and press ⌘R.

The built app is at `build/Build/Products/Debug/EjectRemapper.app`.

Signing, notarization and distribution are covered in
[docs/BUILD_AND_SIGNING.md](docs/BUILD_AND_SIGNING.md).

## Limitations

- **Accessibility permission is mandatory.** macOS provides no way to intercept a key without it, and
  the app does not try to work around that.
- **Magic Keyboards from 2021 onward cannot be supported.** Their Lock and Touch ID keys are handled
  inside macOS and never reach apps.
- **The app cannot be sandboxed.** Sending key events is blocked inside the App Sandbox with no
  entitlement to re-enable it, which also means the app cannot be distributed on the Mac App Store.
- **Lock Screen uses a private system function.** It is looked up at runtime, so if a future macOS
  removes it the app falls back to sending ⌃⌘Q rather than breaking.
- **Screenshot follows your own shortcut.** If you have disabled or changed ⌘⇧3, the app follows what
  you configured.
- **System Eject chords are never remappable**, by design.
- **Holding Eject does not repeat in hardware.** macOS excludes the Eject key from auto-repeat, so the
  app generates the repeats itself, timed to your own Key Repeat setting.
- **A locally signed build loses its Accessibility grant on every rebuild.** See Troubleshooting.

## License and credits

Built as a study of how macOS delivers media keys to user space. The investigation drew on Apple's
open-source IOHIDFamily, Apple's developer documentation and forums, and prior art from Ejectulate,
PowerKey, SPMediaKeyTap, Hammerspoon and Karabiner-Elements — all credited with links in
[docs/TECHNICAL_INVESTIGATION.md](docs/TECHNICAL_INVESTIGATION.md).
