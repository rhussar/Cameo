# Cameo

Record a demo the way Dan Fessler's TrellisWM launch video was made: a full-resolution
screen recording with a background-removed cutout of you floating in a corner, and your
voice as the audio track. Everything runs locally on Apple frameworks (ScreenCaptureKit,
AVFoundation, Vision, CoreImage). No models to download, no cloud.

## App (easiest)

```bash
scripts/build-app.sh
```

This installs `~/Applications/Cameo.app` (the app was called DemoRec before; the CLI is still `demorec`). Open it, click a corner of the preview to choose
where you appear, drag the slider to set your size, and hit **Start Recording**. After a
3-second countdown the window shrinks to a small floating pill (hidden from the recording).
Click **Stop** and the app makes the video, then offers **Play** and **Show in Finder**.
Videos go side by side in `~/Movies/DemoRec/`, named like macOS's own screen recordings
(`Cameo 2026-10-15 at 20.27.42.mp4`). The raw screen, camera and pointer recordings are kept in
`~/Library/Application Support/DemoRec/Recordings/` only while the video is being made, then
deleted; if making the video fails they stay there, so the recording isn't lost.

The size menu picks the video's frame: Original, YouTube 4K or 1440p (16:9), X 1080p (16:9), or
LinkedIn 1080p (16:9), square (1:1) or portrait (4:5). When your screen is a different shape
(e.g. ultrawide), it's fitted inside the frame over a blurred copy of itself. **Look** has colour
presets (Natural, Bright, Warm, Cool, Vivid, Mono) and brightness / contrast / colour / warmth
sliders for you; the preview updates live. The CLI takes the same as `--format` and `--look`.

**Scene** picks the whole look at once: *Classic* (flat screen, you cut out in a corner), *Studio* (a tilted
card over a blurred copy of the screen), *Showcase* (a straight padded card on the Petal wallpaper, you in a
portrait glass tile), *Desk* (the same on Dune with a landscape tile) and *Night* (Aurora). Under the presets
are the three choices they're made of: **Screen** flat, card or tilted (tilted gets a tilt slider); **Background**
a blurred copy of the screen, one of nine wallpapers (Dune, Lagoon, Horizon, Petal, Night Petal,
Aurora, Ember, Silk, Slate), a **Colour** of your own with a texture slider from smooth to grainy, or a picture
of your own (**Picture…**, with a soften toggle); and **You** as a cutout or a **glass tile** (portrait, square or landscape) that shows the
whole camera picture in a rounded frosted frame with a bright rim and a soft shadow. A glass tile skips
person segmentation, so it's also the lightest on the Mac. The background only shows where the screen
doesn't fill the frame, so picking one for a flat screen puts the screen on a card. The CLI has the same
as `--scene`, `--background`, `--presenter`, `--tile` and `--card`.

**Crop** (the crop button next to the screen picker) shows only part of what you record, handy on a big
or ultrawide monitor. The preview switches to the whole screen with a box over it: drag the box to move it
(it snaps to the edges and the middle), drag a corner to resize it, then **Done**. With a fixed video shape
(e.g. YouTube 16:9) the box keeps that shape so the crop fills the video; with Original size the video takes
the box's shape. Each screen remembers its own crop; **Whole Screen** clears it. Zoom works inside the crop.

**Zoom** is yours to call: press **⌃⌥Z** and the screen zooms in on the pointer and follows it,
press it again and it zooms back out. Click the **Zoom ⌃⌥Z** button to pick a different shortcut (it
needs ⌘, ⌃ or ⌥, or can be an F-key on its own). Try it on the setup preview, which zooms live; while
recording, the magnifier in the stop pill shows whether you're zoomed in. Only the screen zooms, not
you. (The CLI can also zoom on its own on clicks and pauses; see `--zoom`.)

## Build (CLI)

```bash
swift build -c release
```

The binary is at `.build/release/demorec`. Optionally put it on your PATH:

```bash
ln -sf "$PWD/.build/release/demorec" /opt/homebrew/bin/demorec
```

## Permissions

Run it from Terminal (or iTerm). macOS will prompt for **Screen Recording**, **Camera**
and **Microphone** for that terminal app the first time. If a prompt was dismissed, enable
the terminal app under System Settings > Privacy & Security.

## Workflow

```bash
demorec devices                    # list displays, cameras, mics
demorec record                     # Ctrl-C to stop
demorec composite ~/Movies/DemoRec/<timestamp>
open ~/Movies/DemoRec/<timestamp>/final.mp4
```

`record` writes `screen.mov` (native Retina pixels, HEVC) and `camera.mov` (1080p H.264 +
AAC mic) into a timestamped folder. Both writers start from the same host-clock timestamp,
so the files line up at t = 0 without any manual offset. It also writes `cursor.json`: the pointer
position (~60 times a second) and clicks, on the same clock, which `composite` uses for zooming.

`composite` cuts you out of every camera frame with Vision's person segmentation, places
the cutout over the screen frame, and writes `final.mp4` with the mic audio passed through.

### record options

| flag | default | meaning |
|---|---|---|
| `--camera <substring>` | `Dell` | camera name to match; falls back to FaceTime HD |
| `--display <id>` | main | display ID from `demorec devices` |
| `--fps <n>` | 30 | capture rate for both files |
| `--out <dir>` | `~/Movies/DemoRec` | where session folders go |

### composite options

| flag | default | meaning |
|---|---|---|
| `--corner` | `bottom-right` | `bottom-right`, `bottom-left`, `top-right`, `top-left` |
| `--scale` | `0.35` | cutout height as a fraction of screen height |
| `--margin` | `24` | distance from the edges, in output pixels |
| `--feather` | `2` | mask edge softness (blur sigma); `0` for a hard edge |
| `--mirror` | off | flip the camera horizontally |
| `--quality` | `accurate` | segmentation quality: `fast`, `balanced`, `accurate` |
| `--output-height` | native | downscale output, e.g. `1440` for a 5K display |
| `--no-mask` | off | overlay the whole camera frame (debugging / picture-in-picture) |
| `--crop <x,y,w,h>` | whole screen | show only part of the screen, as fractions from the top-left, e.g. `0.25,0,0.5,1` |
| `--output <file>` | `final.mp4` in the session folder | output path |
| `--zoom` | `subtle` | zooming on its own: `off`, `subtle`, `normal`, `strong` (zooms from the app's shortcut happen at every setting) |
| `--zoom-level` | by `--zoom` | how far zooms go in: 1.4 subtle, 1.6 normal, 1.8 strong |
| `--no-zoom` | off | never zoom, ignoring `cursor.json` |

By default the screen is staged like the reference video: a rounded, slightly tilted card with a
drop shadow, floating over a zoomed and blurred copy of the same screen content. Fractions are
relative to the output frame height.

| flag | default | meaning |
|---|---|---|
| `--scene` | – | a whole look at once: classic, studio, showcase, desk, night (the flags below override its parts) |
| `--background` | screen | screen (a blurred copy of it), a wallpaper (dune, lagoon, horizon, petal, night-petal, aurora, ember, silk, slate), a colour like `#5a6a80`, or the path of a picture |
| `--texture` | `0.03` | grain on a colour background, 0 (smooth) to 0.12 (grainy) |
| `--background-blur` | `0.012` | blur for a background picture, 0 = sharp |
| `--presenter` | cutout | cutout, or glass (the whole camera picture in a glass tile; no segmentation) |
| `--tile` | portrait | glass tile shape: portrait, square, landscape |
| `--card` | off | straight padded card, no tilt |
| `--flat` | off | plain full-frame screen, no staging |
| `--inset` | `0.88` | card height as a fraction of the frame |
| `--card-x` | `0.47` | horizontal position of the card centre, 0-1 |
| `--tilt` | `4` | degrees of rotation about the vertical axis; positive brings the left edge closer |
| `--radius` | `0.012` | corner radius |
| `--bg-blur` | `0.03` | backdrop blur sigma |
| `--bg-zoom` | `1.2` | backdrop zoom |
| `--bg-dim` | `0.35` | backdrop darkening, 0-1 |
| `--shadow` | `0.6` | drop shadow opacity, 0 disables |

Tips: `--quality accurate` is roughly real time on Apple silicon; use `fast` for a quick
preview. Good lighting and a plain background behind you make the mask noticeably cleaner.

## Layout

```
Sources/DemoRecApp/            SwiftUI app (setup preview, recording pill, progress)
Sources/demorec/DemoRec.swift   CLI (devices / record / composite)
Sources/DemoRecKit/             shared recording + compositing code
  Config.swift                  Layout, Corner, MaskQuality
  Record/Clock.swift            shared T0
  Record/ScreenRecorder.swift   ScreenCaptureKit -> screen.mov
  Record/CameraRecorder.swift   AVCaptureSession (camera + mic) -> camera.mov
  Composite/PersonMasker.swift  Vision person segmentation
  Composite/Compositor.swift    CoreImage cutout + placement
  Composite/Transcoder.swift    reads both files, renders on a fixed clock, writes final.mp4
```

The recorders emit `CMSampleBuffer`s and the compositor takes `CIImage`s, so a live
compositing menu-bar app (phase 2) can feed the same `PersonMasker` + `Compositor` per
frame into a single writer instead of two files.
