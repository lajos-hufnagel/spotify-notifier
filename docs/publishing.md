# Publishing SpotifyNotifier

Everything here is about handing the app to **other** people. For local use none of
it is needed – `./build_app.sh` stays ad-hoc signed and keeps working as before.

## Why the current build cannot be shipped yet

`build_app.sh` signs ad-hoc (`codesign --force --deep --sign -`, without
entitlements). Measured on the current bundle:

- `spctl -a -vvv -t exec build/SpotifyNotifier.app` → **rejected**
- `codesign -dv …` → `flags=0x2(adhoc)`, `TeamIdentifier=not set`

For a download that means two things:

- **Gatekeeper refuses it.** The file carries the quarantine flag and an ad-hoc
  signature offers nothing to check it against. The user would have to work around
  it (right-click → Open, or `xattr -dr com.apple.quarantine`).
- **Permissions do not survive an update.** Every rebuild produces a different
  signature, and macOS ties granted permissions to the signature – that is exactly
  why the Automation dialog ("SpotifyNotifier wants to control Spotify") comes back
  after every rebuild (README, "Tests / pitfalls"). Published, that would happen
  after every update.

A Developer ID signature plus notarisation removes both.

## What this app needs in particular

- **AppleEvents entitlement.** The exact artwork comes from Spotify through
  AppleScript (`SpotifyScriptRunner`, `NSAppleScript` **inside** the app process –
  measured 94–106 ms against 315–374 ms for the `/usr/bin/osascript` subprocess it
  replaced). Under Hardened Runtime an app may only send AppleEvents with
  `com.apple.security.automation.apple-events`. `NSAppleEventsUsageDescription` is
  already in `Resources/Info.plist`, but that is only the wording of the dialog.
  Without the entitlement the AppleScript step fails silently, every overlay falls
  back to the iTunes search and now and then shows the wrong artwork. This is the
  first thing to test after signing.
- **Developer ID, not the App Store.** The sandbox does not allow AppleEvents to
  another app without a temporary exception, so an App Store version would need a
  different artwork source. Everything below is the Developer ID path.
- **`LSUIElement = true`** (menu bar only, no Dock icon) is unproblematic for
  notarisation.
- **Architecture.** `swift build -c release` builds for the machine it runs on
  (`arm64` here). The one-step universal build needs full Xcode: with the Command
  Line Tools alone,
  `swift build -c release --arch arm64 --arch x86_64` stops with
  `error: xcbuild executable at '/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild' does not exist or is not executable`
  (measured). Per architecture it works without Xcode, and the two binaries can be
  joined (verified):

  ```bash
  swift build -c release --arch arm64    # → .build/arm64-apple-macosx/release/
  swift build -c release --arch x86_64   # → .build/x86_64-apple-macosx/release/
  lipo -create -output SpotifyNotifier \
    .build/arm64-apple-macosx/release/SpotifyNotifier \
    .build/x86_64-apple-macosx/release/SpotifyNotifier
  lipo -info SpotifyNotifier             # → x86_64 arm64
  ```

  The bundle holds a single binary, so `lipo` is all it takes. Otherwise ship Apple
  Silicon only and say so on the release page – an arm64 binary cannot run on an
  Intel Mac (Rosetta translates the other way round).

## 1. Settle the identity before the first release

In `Resources/Info.plist`:

- `CFBundleIdentifier` is `com.local.spotifynotifier`. The `local.` prefix says "not
  for distribution", and macOS keys the Automation grant on the bundle ID – so it
  should be final **before** the first release, otherwise every user has to grant
  again after the change. Take something you control, e.g.
  `de.<yourname>.spotifynotifier`.
- `CFBundleShortVersionString` (marketing version, `1.0`) and `CFBundleVersion`
  (build number, must grow with every submission) need care per release.

## 2. Certificate and credentials

- Apple Developer Program membership. Then a **Developer ID Application**
  certificate – created in the developer portal (only the account holder can) and
  installed into the login keychain. There is nothing to sign with yet on this
  machine: `security find-identity -v -p codesigning` → `0 valid identities found`.
- Credentials for the notary service, stored once:

  ```bash
  xcrun notarytool store-credentials "spotifynotifier" \
    --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"
  ```

  The password is an app-specific password from appleid.apple.com, not the Apple ID
  password.

## 3. Entitlements file

New file `Resources/SpotifyNotifier.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- The AppleScript query for the current track (SpotifyScriptRunner). -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

## 4. Signing in `build_app.sh`

Replace the ad-hoc line (`codesign --force --deep --sign - "$APP_BUNDLE"`) with a
Developer ID path and keep ad-hoc as the default for local builds:

```bash
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "==> Signing (Developer ID, hardened runtime)…"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/SpotifyNotifier.entitlements \
    --sign "$DEVELOPER_ID_APP" "$APP_BUNDLE"
else
  echo "==> Signing (ad-hoc)…"
  codesign --force --sign - "$APP_BUNDLE"
fi
```

- `--options runtime` is the Hardened Runtime, required for notarisation.
- `--timestamp` embeds a trusted timestamp (needs the network).
- `--deep` is dropped: the bundle contains no nested code and Apple deprecated it.
- Usage: `DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" ./build_app.sh`

## 5. Notarise and staple

Order matters: sign → pack → notarise → staple → pack what you upload.

```bash
ditto -c -k --keepParent build/SpotifyNotifier.app build/SpotifyNotifier.zip
xcrun notarytool submit build/SpotifyNotifier.zip --keychain-profile spotifynotifier --wait
xcrun stapler staple build/SpotifyNotifier.app
xcrun stapler validate build/SpotifyNotifier.app
```

If it is rejected, `xcrun notarytool log <submission-id> --keychain-profile
spotifynotifier` prints the reason – usually a missing entitlement or an unsigned
nested binary.

## 6. Release

- `git tag -a v1.0.0 -m "SpotifyNotifier 1.0.0"`, push the tag, then a GitHub
  Release with a `.zip`/`.dmg` built from the **stapled** app.
- A `.dmg` can be notarised and stapled as well (`xcrun stapler staple
  SpotifyNotifier.dmg`) – nicer to install, but the `.zip` is enough.
- Optional: a Homebrew cask takes care of updates.
- Say the minimum system on the release page: `LSMinimumSystemVersion` is 13.0.

## 7. Verification before it goes online

```bash
codesign -dv --verbose=4 build/SpotifyNotifier.app   # Authority=Developer ID Application: …, TeamIdentifier=…, flags=0x10000(runtime)
codesign --verify --strict --verbose=2 build/SpotifyNotifier.app
codesign -d --entitlements - build/SpotifyNotifier.app   # must list the AppleEvents entitlement
spctl -a -vvv -t exec build/SpotifyNotifier.app          # accepted, source=Notarized Developer ID
stapler validate build/SpotifyNotifier.app
```

Then the only test that really counts: download it on a Mac that has never seen the
app (or a fresh VM) and check that

- it starts with a double-click – no right-click trick,
- the Automation dialog appears **once** and the artwork really comes from Spotify
  (not from the iTunes fallback; a track whose artwork is unusual shows the
  difference),
- the grant survives an update: install the next version over it and no dialog
  appears again.

## 8. Worth doing for the first release

- A "Download" section in the README plus a screenshot of the overlay.
- The Automation dialog appears right at start (`ArtworkProvider.warmUp()`), so the
  release notes should say what it is for.
- `CHANGELOG.md` or at least GitHub release notes – the app has no update check of
  its own.
