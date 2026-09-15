# Building, signing and distributing Eject Key Remap

## Requirements

- macOS 14 or later to run the app; macOS 14 SDK or later to build it.
- Xcode 16 or later. The project uses `objectVersion 77` with synchronized folder groups, so every
  file under `EjectRemapper/` and `EjectRemapperTests/` is compiled automatically and nothing is
  listed individually in the project file. Adding a Swift file means creating it; there is no project
  file to edit.
- No code-signing certificate is needed to build and run locally.

## Building

```bash
Scripts/build.sh                    # Debug, active architecture
Scripts/build.sh Release            # Release, active architecture
Scripts/build.sh Release universal  # Release, Intel + Apple silicon
Scripts/test.sh                     # Unit tests
```

The scripts locate Xcode themselves. If `xcode-select` points at the Command Line Tools, they fall
back to `/Applications/Xcode.app` and then to `/Volumes/Macintosh_SSD/Applications/Xcode.app`. To
point them somewhere else, set `DEVELOPER_DIR` before running.

The equivalent raw commands:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
           -destination 'platform=macOS' -derivedDataPath build build
xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
           -destination 'platform=macOS' -derivedDataPath build test
```

Products land in `build/Build/Products/<Configuration>/EjectRemapper.app`.

A universal Release binary needs `-destination 'generic/platform=macOS'`. The plain `platform=macOS`
destination builds only the architecture you are running on.

## Build settings that matter

| Setting | Value | Why |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | 14.0 | `@Observable` needs 14.0; everything else is older |
| `SWIFT_VERSION` | 6.0 | Strict concurrency; the code compiles cleanly under it |
| `INFOPLIST_KEY_LSUIElement` | YES | Menu bar app: no Dock icon, no window at launch |
| `ENABLE_APP_SANDBOX` | NO | Sending key events is blocked inside the sandbox with no entitlement to re-enable it |
| `ENABLE_HARDENED_RUNTIME` | YES | Required for notarization |
| `CODE_SIGN_IDENTITY` | `-` | Ad-hoc by default so the project builds with no certificate |
| `CODE_SIGN_STYLE` | Manual | Avoids Xcode trying to fetch a team's provisioning profile |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.cacaioo.EjectRemapper` | Keep it stable: permissions are recorded against it |

There is **no entitlements file**, and that is correct. Event taps and event posting are gated by the
privacy system, not by hardened-runtime entitlements, so no `com.apple.security.*` key is needed once
the sandbox is off.

## Local testing with an ad-hoc signature

An ad-hoc build runs fine on the machine that built it. There is one sharp edge, and it will bite you.

macOS identifies an app for privacy purposes by its code signature. An ad-hoc signature is tied to the
exact bytes of that build, so **every rebuild produces a different identity**. The consequence is
specific and confusing: your app keeps appearing in System Settings → Privacy & Security →
Accessibility with its switch on, while the system answers "not allowed" when the app asks. Remapping
silently stops working and nothing explains why.

Three ways to deal with it, in increasing order of comfort:

**Reset the grant after each rebuild.**

```bash
tccutil reset Accessibility com.cacaioo.EjectRemapper
```

Then launch and grant again.

**Remove and re-add the app by hand** in System Settings, using the minus and plus buttons.

**Use a stable signing identity**, which is the real fix. Any of these works:

- An Apple Development certificate from a paid or free Apple Developer account.
- A self-signed code-signing certificate made in Keychain Access → Certificate Assistant → Create a
  Certificate, with type "Code Signing".

Then build with it:

```bash
xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
           -destination 'platform=macOS' -derivedDataPath build \
           CODE_SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" \
           DEVELOPMENT_TEAM=YOURTEAMID build
```

The identity stays the same across rebuilds, so the permission sticks.

To see what a build was signed with:

```bash
codesign -dv --verbose=2 build/Build/Products/Release/EjectRemapper.app
```

`Signature=adhoc` and `flags=0x2(adhoc)` mean an ad-hoc Debug build. A Release ad-hoc build reports
`flags=0x10002(adhoc,runtime)` because the hardened runtime applies there.

One quirk worth knowing: Xcode prints `note: Disabling hardened runtime with ad-hoc codesigning` for
Debug builds and turns the setting off for that configuration. Leave it alone. Forcing
`OTHER_CODE_SIGN_FLAGS="--options runtime"` onto a Debug build makes the unit-test host crash before
it can connect to the test manager.

## Distribution

The Mac App Store is not an option. The app cannot be sandboxed, and it uses a private system function
to lock the screen. Direct distribution with Developer ID is the path.

**1. Sign with Developer ID and the hardened runtime.**

```bash
xcodebuild -project EjectRemapper.xcodeproj -scheme EjectRemapper \
           -configuration Release -destination 'generic/platform=macOS' \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
           DEVELOPMENT_TEAM=TEAMID build
```

Verify:

```bash
codesign --verify --deep --strict --verbose=2 build/Build/Products/Release/EjectRemapper.app
codesign -dv --verbose=4 build/Build/Products/Release/EjectRemapper.app   # expect flags=0x10000(runtime)
```

**2. Package it.** A zip is enough for notarization; a signed disk image is nicer to ship.

```bash
ditto -c -k --keepParent build/Build/Products/Release/EjectRemapper.app EjectRemapper.zip
```

**3. Notarize.** Store credentials once, then submit.

```bash
xcrun notarytool store-credentials "EjectRemapperNotary" \
      --apple-id you@example.com --team-id TEAMID --password app-specific-password

xcrun notarytool submit EjectRemapper.zip --keychain-profile "EjectRemapperNotary" --wait
```

If it is rejected, read the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile "EjectRemapperNotary"
```

**4. Staple**, so the app validates without a network round trip.

```bash
xcrun stapler staple build/Build/Products/Release/EjectRemapper.app
xcrun stapler validate build/Build/Products/Release/EjectRemapper.app
spctl --assess --type execute --verbose build/Build/Products/Release/EjectRemapper.app
```

Re-zip the stapled app for distribution.

## Keeping users' permissions across updates

Keep the **bundle identifier** and the **signing certificate** stable. Both are part of how macOS
recognises the app. Change either and every user has to grant Accessibility again, without any
explanation from the system. If you must change the bundle identifier, say so in the release notes.

## Unit tests

`Scripts/test.sh` runs them. Points worth knowing:

- The tests are hosted by the app, so `xcodebuild test` launches `EjectRemapper.app` for a second or
  two and its menu bar item flashes into view. That is normal for host-based unit tests.
- The app checks whether it is running under the test harness and skips creating its live object
  graph, so **no event tap is created and no permission is requested during tests**.
- No test sends an event, locks the screen, takes a screenshot, registers a login item or writes to
  your real preferences. Every side effect sits behind a protocol with a test double.
- Tests need no permissions at all, so they run correctly in a terminal or in continuous integration.
