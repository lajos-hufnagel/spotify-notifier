# SpotifyNotifier

A small macOS menu bar app: whenever Spotify changes the track, an overlay
appears for 3 seconds in the top right corner of the screen – with artwork,
title and artist. The overlay never steals focus (no click needed, no window
switching).

## Requirements

- macOS 13 or newer
- The Spotify desktop app (`com.spotify.client`)
- A Swift toolchain. The release build was verified with full Xcode.
  If Command Line Tools report a missing `SwiftUIMacros` plugin, select Xcode for the build:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh --no-restart`

## Build & run

```bash
./build_app.sh                 # build release + .app bundle + signature + restart
```

`build_app.sh` stops any running instance and then starts the freshly built app
automatically. That guarantees the new build is always the one that is running –
no forgotten restart. If you only want to build (e.g. for login items or CI)
while the app may keep running:

```bash
./build_app.sh --no-restart
```

Afterwards a ♪ icon sits in the menu bar – the same note as in the app icon
(`music.note`) – and the menu holds the toggle **Active** (see "Pausing") and
**Quit**.

The bundle icon (`Resources/AppIcon.icns`, a `#1DB954` squircle with the same
white note) is packed in automatically – regenerate or adjust it with
`swift make_icon.swift` (see the "App icon" section).

## How it works

- `SpotifyObserver` listens to the system-wide distributed notification
  `com.spotify.client.PlaybackStateChanged`. That is a public channel –
  **no login, no Spotify API, no OAuth**.
- The overlay appears only on a real track change during playback:
  `Player State == "Playing"` **and** a new `Track ID`. Play/pause deliberately
  triggers nothing.
- **Podcasts:** for episodes Spotify delivers a `spotify:episode:…` ID, an
  **empty** `Artist` and the podcast name in the `Album` field. The overlay then
  shows the episode title with the podcast name below it (see
  `Track.secondaryText`); for songs the second line stays the artist as usual.
- `OverlayWindow` shows a borderless `NSPanel` with `.nonactivatingPanel`,
  `level = .floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary` and
  `ignoresMouseEvents = true`. That way the panel never gets focus and is
  visible on every Space.
- Position: top right of the screen **under the pointer** (`targetScreen()`),
  falling back to `NSScreen.main`. macOS pushes the panel below the menu bar of
  that display automatically.
- **Pausing:** `SpotifyObserver.stop()` detaches the observer from the
  distributed notification – while paused, no work happens at all. `start()` is
  idempotent (activating it repeatedly creates no duplicate calls), and
  `lastTrackID` stays remembered across the pause. See "Pausing" for details.

## Marquee for long titles

If a line does not fit into the text area (224 pt), it is no longer truncated
but runs to the left **once**, until its end has been fully visible. Both lines
run independently; short titles stand still as before.

- **Speed:** 40 pt/s, with a 0.8 s hold before and a 0.9 s hold after, so the
  beginning and the end stay readable.
- **The display duration comes from the same measurement:** `MarqueeMetrics`
  measures the text width once through AppKit (`NSString.size(withAttributes:)`)
  and derives from it how long the panel has to stay up. Short titles stay at
  **3 s**, long ones stay exactly as long as their marquee needs, plus 0.2 s of
  buffer – at most **12 s**. Example: "Bohemian Rhapsody (Remastered 2011 Deluxe
  Edition) [Live at Wembley]" is 493 pt wide → 280.7 pt of travel → 7.02 s of
  scrolling → 8.92 s of display duration.
- **Very long titles:** if the maximum window is not enough, both lines run a
  little faster together – better complete and quick than slow and cut off.
- **"Reduce Motion"** (System Settings → Accessibility): then there is no
  marquee, truncation stays as before.
- A soft edge of 12 pt (`OverlayLayout.edgeFade`) fades the letters out instead of
  cutting them off hard – on both sides, but not at the same place. The **right**
  fade lies at the end of the text area and the marquee comes to rest before it
  (tail at 212 of 224 pt). The **left** fade lies *inside* the text area, directly
  behind the head's rest position: it is 0 pt wide while the line stands still
  (otherwise the head would be half transparent) and grows to 12 pt as soon as the
  line runs (`MarqueeMetrics.leftFadeRamp`). So the letters dissolve right at the
  left edge of the text area and nothing is ever drawn left of it – the gap to the
  artwork stays completely empty, in every phase. Lines that fit are never masked:
  they stay flush at the left edge and truncate with an ellipsis.
- The marquee restarts on every presentation (`presentation` counter in the
  view). Without that counter SwiftUI would reuse the same view for A → B → A
  and not replay the animation.
- The animation is a **one-shot** `withAnimation` – no `repeatForever`, no
  `TimelineView(.animation)`. Hidden panels stay in memory after `orderOut` and
  must not keep computing then.

## Pausing

Via the menu bar icon → **Active** the app can be paused without quitting it:

- **Paused:** no more listening to Spotify, hence no overlay – not even on a
  track change. The menu bar icon becomes the struck-through note
  (`music.note.slash`) and dims as well, the menu reads "SpotifyNotifier paused"
  and the check mark next to "Active" is gone. An overlay that is visible right
  now disappears immediately instead of staying until the end of its display
  duration.
- **Active again:** a click on "Active" sets the check mark, the icon looks
  normal again, and the next track change shows an overlay again.

The state is deliberately memory-only: after a restart the app is always active
(otherwise "why is nothing showing up?" turns into a long hunt for a cause). The
last reported track stays remembered across a pause, so the track that is
currently playing is **not** shown a second time after resuming – only the next
change shows something again.

## Artwork

The current Spotify version no longer sends an artwork URL in the notification
payload (only `Has Artwork = 1`). `ArtworkProvider` therefore fetches the image
in three steps:

1. The `Artwork` field from the notification – in case a Spotify version does
   deliver it (supports `https://…`, `file://…` and `spotify:image:<hash>`).
2. **AppleScript**: `tell application "Spotify" to artwork url of current track`
   → exact artwork from `i.scdn.co`. The first time, macOS shows the dialog
   "SpotifyNotifier wants to control Spotify". Clicking **OK** allows it for
   good; declining is fine as well (see step 3).
   As a safety net the result is only accepted when title and artist match the
   reported song – so a quick change can never show the wrong artwork.
3. **iTunes Search API** (no login, no key): search for artist + title, hits are
   compared tolerantly and the 100×100 artwork is upscaled to 600×600. This
   happens silently, without any prompt. If that fails as well, the music note
   placeholder stays.

For podcast episodes the artwork is cached by episode ID only, not by show name:
every episode has artwork of its own, and a shared show key would briefly show
the artwork of the previous episode.

Note: the AppleScript step is attempted once per app launch only. If the
Automation dialog is declined, the app remembers that and does not ask again on
every track change – the iTunes fallback simply takes over.

## App icon

![The app icon: a white note on a flat #1DB954 squircle](Resources/AppIcon.png)

The bundle icon lives in the repo as `Resources/AppIcon.icns` and is copied to
`Contents/Resources/` by `build_app.sh`; it is wired up through
`CFBundleIconFile` in `Resources/Info.plist`. `Resources/AppIcon.png` is the very
same icon at 256 px, written by the same run – that is the form this README can
show, because GitHub and most editors do not render an `.icns`.

A flat green squircle with the white note `♪` – **one** green and nothing else:
`#1DB954`. The note is the SF Symbol `music.note`, so exactly the one the menu bar
shows (see below). Deliberately no gradient, so there is no second green tone in
it (and no dithering noise in the small sizes). The green is stored unchanged:
the script draws into an explicit sRGB context on purpose, because a wide-gamut
display colour space would write different numbers (P3 turned `#1DB954` into
`#11C267`).

Regenerate or adjust it:

```bash
swift make_icon.swift     # writes Resources/AppIcon.icns (+ AppIcon.png)
./build_app.sh            # build the bundle with the new icon (restarts the app)
```

Every size is drawn fresh from vector paths – never upscaled. The small ones
(16, 32, 64, 128 px and their @2x variants) are rendered 8× larger and scaled
down again, which is what gives them clean edges; 256, 512 and 1024 px are drawn
straight at the target resolution. 1024 px (512x512@2x) is the largest bitmap an
`.icns` can hold – that is as sharp as the bundle can get.

Colours, margin and note size sit at the top of `make_icon.swift`
(`backgroundGreen`, `noteColor`, `nativeSize`, `supersample`, the shape fractions
in `renderIcon`). If Finder still shows the old symbol:
`touch build/SpotifyNotifier.app` or run `killall Finder` once.

The **menu bar** icon is independent of that: it comes from `main.swift` and is
the SF Symbol `music.note` – the same note the app icon shows – as a template
image, so it adapts to light/dark mode automatically. For a custom menu bar icon
simply replace `button.image` there with your own `NSImage` (with
`isTemplate = true`).

## Start automatically at login (optional)

System Settings → General → Login Items → "+" → add
`build/SpotifyNotifier.app`.

## Project structure

```
Sources/SpotifyNotifier/
  main.swift              AppDelegate, menu bar item + active toggle
  SpotifyObserver.swift   Track model + listening to the Spotify notification
  ArtworkProvider.swift   Artwork resolution (notification → AppleScript → iTunes)
  OverlayWindow.swift     Panel, SwiftUI view, positioning, hiding
  MarqueeMetrics.swift    Text measurement: marquee + panel display duration
Resources/Info.plist      LSUIElement = true (menu bar only, no Dock icon)
Resources/AppIcon.icns    Bundle icon (generated by make_icon.swift)
Resources/AppIcon.png     The same icon as PNG – what this README shows
make_icon.swift           Generates the app icon (squircle + note → .icns/.png)
build_app.sh              Build + bundle + icon + signature (+ app restart)
docs/publishing.md        Checklist for a public release (Developer ID, notarisation)
```

## Tests / pitfalls

- **Rebuild ⇒ new dialog.** The app is ad-hoc signed, so every build carries a
  new signature. That is why macOS may show the Automation dialog again after a
  rebuild. To be rid of it for good you need a Developer certificate instead of
  the ad-hoc signature – `docs/publishing.md` is the checklist for that
  (Developer ID, Hardened Runtime, notarisation).
- **Verify the overlay:** `CGWindowListCopyWindowInfo` shows the panel as a
  window of `SpotifyNotifier` at level 3 (floating). Play/pause must not trigger
  it, a track change must. While paused, no panel may show up there at all.
- **Verify the marquee:** a screen capture of the panel shows whether the title
  line really moves (column profile of the dark pixels, 40 pt/s to the left) –
  and whether a short title stands still. Cut that profile by line (title rows
  vs. artist rows), otherwise the non-scrolling second line covers the first one.
  Capture **during the leading hold** as well: the head must rest at the left edge
  of the text area (first ink at 84...85 pt, depending on the glyph's side bearing)
  and be as dark as the middle of the text – and the second line below must start at
  the very same column. Left of that column nothing may be dark at any time: the gap
  to the artwork (72...83 pt) stays at 255 in every phase, because the exit fade lies
  inside the text area and only grows while the line runs. During the run the letters
  therefore dissolve over the first 12 pt behind the rest position (measured: almost
  paper at 84 pt, about two thirds ink at 88 pt, full ink from 96 pt on). Capture
  **after** the movement has ended too: the tail must rest before the right fade
  (212 of 224 pt) and be as dark there as the middle of the text; inside the fade
  it would be measurably lighter. The display duration always sits a little above
  the computed value: 0.35 s of fading plus the trailing lag of timer and
  WindowServer (roughly +0.7 s at 3 s, roughly +1 s at 8.9 s).
- **Measure the marquee:** the width comes from AppKit
  (`NSString.size(withAttributes:)`), the display from SwiftUI. That is why both
  fonts sit right next to each other in `MarqueeMetrics.Style` – if one of them
  drifts, the text runs too far or stops too early. An overflow of up to 2 pt
  counts as "fits", because the two measurements differ slightly.
- **Artwork missing entirely:** is Spotify running? Is the network reachable?
  For local files (which often yield no artwork in the search) the placeholder
  stays.


## Development approach

Personal project developed with AI assistance. I defined requirements, guided implementation, reviewed results and iterated through practical testing.
