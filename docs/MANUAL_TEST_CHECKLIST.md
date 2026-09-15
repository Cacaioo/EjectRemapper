# Manual test checklist

The unit tests cover everything that can be checked without a keyboard and without touching the
system. This checklist covers everything else. Each item needs a person pressing a real Eject key on a
real Mac.

Before starting: build the app, launch it, grant Accessibility, and confirm the menu bar icon appears.
If you rebuild at any point during testing, re-read the ad-hoc signing note in
`docs/BUILD_AND_SIGNING.md` — a rebuild silently invalidates the permission.

Record the result of each item as pass, fail or not run, along with the macOS version and the keyboard
model. Nothing here is optional: the acceptance criteria in the specification map directly onto
sections 1 through 8.

## 0. Baseline

| # | Check | Expected |
|---|---|---|
| 0.1 | Launch the app | Menu bar icon appears, no Dock icon, no window |
| 0.2 | Open the popover | Current action is shown and selected |
| 0.3 | About tab | Version, macOS compatibility, and the connected keyboard listed by name |
| 0.4 | Quit and relaunch | The selected action is remembered |

## 1. Forward Delete — acceptance test A

Set the action to Forward Delete, then in each app place the cursor before a character and press ⏏.

| # | App | Expected |
|---|---|---|
| 1.1 | TextEdit | The character to the right is deleted |
| 1.2 | Notes | Same |
| 1.3 | Safari, in a text field | Same |
| 1.4 | Finder, renaming a file | Same |
| 1.5 | Terminal | Same |
| 1.6 | Xcode | Same |
| 1.7 | One third-party app of your choice | Same |
| 1.8 | Hold ⏏ in TextEdit | Characters delete repeatedly, at your own key repeat speed, and stop on release |
| 1.9 | Hold ⌥ and press ⏏ | Nothing is deleted: a modified press goes to macOS (see section 8) |
| 1.10 | Press ⏏ rapidly ten times | Ten deletions, none missed, none doubled |

## 2. Lock Screen — acceptance test B

Set the action to Lock Screen. Have your password ready.

| # | Check | Expected |
|---|---|---|
| 2.1 | Press ⏏ from the Finder | The Mac locks immediately and shows the login window |
| 2.2 | Press ⏏ from Safari | Same |
| 2.3 | Press ⏏ from a text editor | Same |
| 2.4 | Press ⏏ from a full-screen app | Same |
| 2.5 | Hold ⏏ for three seconds | Locks exactly once, not repeatedly |
| 2.6 | Unlock, then press ⏏ again | Locks again |

## 3. Screenshot — acceptance test C

| # | Check | Expected |
|---|---|---|
| 3.1 | Press ⏏ | Shutter sound, floating thumbnail, file saved where your screenshots normally go |
| 3.2 | Compare with pressing ⌘⇧3 by hand | Identical result: same location, same format, same naming |
| 3.3 | Hold ⏏ | Exactly one screenshot |
| 3.4 | Change the screenshot format in the Screenshot app, press ⏏ | The new format is used |

## 4. Screenshot Menu — acceptance test D

| # | Check | Expected |
|---|---|---|
| 4.1 | Press ⏏ | The screenshot toolbar appears at the bottom of the screen |
| 4.2 | Compare with ⌘⇧5 by hand | The same toolbar, with the same options |
| 4.3 | Take a capture from the toolbar | Works normally |
| 4.4 | Hold ⏏ | The toolbar opens once |

## 5. Custom Shortcut — acceptance test E

| # | Check | Expected |
|---|---|---|
| 5.1 | Record ⌘C, select some text, press ⏏, then paste | The text is pasted |
| 5.2 | Record ⌘⇧4, press ⏏ | The selection crosshair appears |
| 5.3 | Record ⌥Delete in a text field, press ⏏ | The previous word is deleted |
| 5.4 | Record ⌃⌥←, press ⏏ | Whatever that shortcut does in the active app |
| 5.5 | Record ⌘⌥⇧K | Displayed as ⌥ ⇧ ⌘ K |
| 5.6 | Press only ⇧ while recording | Nothing is recorded; the shortcut stays unset |
| 5.7 | Press ⏏ while recording | Rejected with a message saying the Eject key cannot be used |
| 5.8 | Press Escape while recording | Recording cancels, the previous shortcut is kept |
| 5.9 | Click Clear | The shortcut is removed and the popover explains the key does nothing until one is recorded |
| 5.10 | Hold ⏏ with ⌘C recorded | The shortcut repeats while held |
| 5.11 | Record a shortcut, quit, relaunch | The shortcut is still there |

## 6. Configuration change — acceptance test F

| # | Check | Expected |
|---|---|---|
| 6.1 | With Forward Delete active, switch to Lock Screen and press ⏏ **without relaunching** | The Mac locks |
| 6.2 | Switch back to Forward Delete and press ⏏ | Forward delete happens |
| 6.3 | Switch actions while holding ⏏ down | No key is left stuck; release behaves normally |
| 6.4 | Turn Enable Remapping off, press ⏏ | Nothing happens; the key behaves as it did before the app |
| 6.5 | Turn it back on, press ⏏ | The configured action runs |
| 6.6 | Select Screenshot and press ⏏, then select Forward Delete and press ⏏ | Forward Delete works straight away, with no relaunch |
| 6.7 | With Screenshot selected, press ⏏ three times a few seconds apart | Three screenshots |
| 6.8 | After taking a screenshot with ⏏, type a few letters | They type normally, not as ⇧⌘ shortcuts |
| 6.9 | Hold ⏏ with Forward Delete selected, tap ⇧, then release ⏏ | Deleting stops the moment ⏏ is released |

## 7. Original Function and Disabled — acceptance tests G and H

| # | Check | Expected |
|---|---|---|
| 7.1 | Set Original Function, press ⏏ | macOS's own behaviour, which on a Mac with no optical drive is nothing |
| 7.2 | Set Original Function with a disc inserted, press ⏏ | The disc ejects |
| 7.3 | Set Disabled, press ⏏ | Nothing at all, consistently, every time |
| 7.4 | Set Disabled, hold ⏏ | Still nothing |

## 8. System chords — must never be intercepted

Test these with the action set to **Forward Delete**, so any interception would be obvious. Save your
work first: two of these restart or shut down the Mac.

| # | Check | Expected |
|---|---|---|
| 8.1 | ⌃⇧⏏ | The displays sleep. No forward delete happens |
| 8.2 | ⌥⌘⏏ | The Mac sleeps |
| 8.3 | ⌃⏏ | The restart / sleep / shut down dialog appears. Press Escape |
| 8.4 | ⌃⌘⏏ | The Mac restarts. Optional — only if you are willing |
| 8.5 | ⌃⌥⌘⏏ | The Mac shuts down. Optional |

## 9. Permission failures

| # | Check | Expected |
|---|---|---|
| 9.1 | Launch with Accessibility never granted | App runs, popover explains that access is needed, remapping inactive, no crash |
| 9.2 | Click Open Accessibility Settings | The correct System Settings pane opens |
| 9.3 | Grant permission while the app is running | The popover updates and remapping starts, no relaunch needed |
| 9.4 | Revoke permission while the app is running | The app stays alive, the popover says remapping is inactive, the keyboard behaves normally, no crash and no input freeze |
| 9.5 | Re-grant after revoking | Remapping resumes |
| 9.6 | Press ⏏ while permission is missing | Normal macOS behaviour; the app does not interfere |

## 10. Hardware

| # | Check | Expected |
|---|---|---|
| 10.1 | Disconnect the Magic Keyboard | The app reports that no keyboard with an Eject key is connected |
| 10.2 | Reconnect it | The notice clears |
| 10.3 | On a Magic Keyboard with Touch ID or a Lock key | A clear message explaining that macOS handles that key itself, no crash |
| 10.4 | On a MacBook's built-in keyboard alone | A clear message that there is no Eject key |
| 10.5 | With an external keyboard connected alongside the built-in one | The external one is detected and works |

## 11. Launch at Login and lifecycle

| # | Check | Expected |
|---|---|---|
| 11.1 | Turn Launch at Login on | The app appears under System Settings → General → Login Items |
| 11.2 | Log out and back in | The app starts, menu bar icon only, no window, remapping active |
| 11.3 | Restart the Mac | Same |
| 11.4 | Turn Launch at Login off | The item disappears from Login Items |
| 11.5 | Move the app to another folder and toggle the switch | The login item points at the new location |
| 11.6 | Turn off Show Menu Bar Icon | The icon disappears |
| 11.7 | With the icon hidden, open the app from Finder | The Settings window appears |
| 11.8 | Quit from the popover | The app exits and the Eject key returns to normal behaviour immediately |

## 12. Performance

| # | Check | Expected |
|---|---|---|
| 12.1 | Leave the app idle for an hour, then check Activity Monitor | Effectively zero CPU |
| 12.2 | Memory footprint | A few tens of megabytes, stable over time |
| 12.3 | Press ⏏ with Forward Delete set | No perceptible delay before the character disappears |
| 12.4 | Type normally for a few minutes | No dropped or delayed keystrokes |
| 12.5 | Leave it running overnight | Still working in the morning, no growth in memory |

## 13. Accessibility of the app itself

| # | Check | Expected |
|---|---|---|
| 13.1 | Turn on VoiceOver and open the popover | Every control is announced with a meaningful name |
| 13.2 | Navigate the action list with VoiceOver | Each action is announced and selectable |
| 13.3 | Reach the shortcut badge with VoiceOver | Announced in words, for example "Shift Command 4", not as symbols |
| 13.4 | Use the recorder with VoiceOver | Its state and result are announced |
| 13.5 | Navigate Settings with Tab only | Every control is reachable |
| 13.6 | Look at the status indicators | Each pairs an icon with text; none relies on colour alone |
| 13.7 | Turn on Increase Contrast and Reduce Motion | Layout stays legible and calm |

## 14. Observations to report back

These were flagged during the technical investigation as things only a human at the keyboard could
confirm. Note what you actually see:

1. Does a real Eject press produce one event pair, or is there an extra event alongside it?
2. Does suppressing the event fully prevent macOS's own Eject handling?
3. Did granting Accessibility alone allow sending events, or did macOS ask separately?
4. Does the synthesized ⌘⇧3 really fire the system screenshot?
5. Does the lock call still work on your macOS version?
6. What exactly happens when Accessibility is revoked while the app is running?
