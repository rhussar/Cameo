# DemoRec

Record a demo the way Dan Fessler's TrellisWM launch video was made: a full-resolution
screen recording with a background-removed cutout of you floating in a corner, and your
voice as the audio track. Everything runs locally on Apple frameworks (ScreenCaptureKit,
AVFoundation, Vision, CoreImage). No models to download, no cloud.

## App (easiest)

```bash
scripts/build-app.sh
```

This installs `~/Applications/DemoRec.app`. Open it, click a corner of the preview to choose
where you appear, drag the slider to set your size, and hit **Start Recording**. After a
3-second countdown the window shrinks to a small floating pill (hidden from the recording).
Click **Stop** and the app makes `final.mp4`, then offers **Play** and **Show in Finder**.
Recordings go to `~/Movies/DemoRec/<timestamp>/`.

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
so the files line up at t = 0 without any manual offset.

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
| `--output <file>` | `final.mp4` in the session folder | output path |

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
