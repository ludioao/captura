# Captura product roadmap

Captura aims for feature parity with the core workflows of products such as Screen Studio while remaining a distinct, native macOS application. We will reproduce useful behavior and interaction patterns, not proprietary branding, assets, code, or exact visual identity.

Reference reviewed: <https://screen.studio/> and its public changelog on 2026-08-13.

## Product principles

- Native Swift 6, SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, VideoToolbox, Core Media and Metal.
- Apple Silicon first and macOS 15 minimum.
- Screen, audio, microphone, webcam and interaction metadata share one host-clock timeline.
- Recording stays low-copy; visual effects are rendered non-destructively during preview and export.
- Every project remains locally editable and recoverable as a versioned `.screenproject` package.
- Local processing is preferred for media, speech and sensitive metadata.

## Current foundation

- Display and individual-window recording at 30 or 60 FPS.
- HEVC hardware encoding with system audio and selected microphone tracks.
- Separate HEVC webcam capture, live floating preview and synchronized playback.
- Cursor, click, typing and active-window metadata.
- Automatic zoom intent/keyframe generation.
- Project packages, recent projects, ripple delete, trim, split, per-clip speed and persisted canvas settings.
- Backgrounds, spacing, shadow, macOS window chrome and adjustable webcam layout.
- Shared capture clock and synchronized screen/webcam transport.
- H.264/HEVC MP4 export with canvas, window chrome, camera, audio and common aspect-ratio presets.
- Animated GIF export, real audio waveform, per-source mix controls, editable captions and rendered cursor/click effects.
- Automatic/manual zoom playback and export, debounced autosave and export disk-space preflight.
- Display, window and interactive area capture plus MOV/MP4 import into editable projects.
- Timed privacy masks/highlights and explicit on-device transcript generation.

## M1 — Complete the shippable editor

Outcome: a user records, edits and exports a polished MP4 without leaving Captura.

- Metal-backed compositor for background, padding, shadow, window chrome, crop and webcam.
- [x] H.264 and HEVC MP4 export with source, 1080p and 4K presets.
- [x] Real timeline split, ripple delete, start/end trim and per-slice speed controls.
- [x] Horizontal 16:9, square 1:1, portrait 9:16 and social 4:5 output.
- [x] Export status, cancellation and actionable failures.
- [x] Continuous export progress and disk-space preflight.
- [ ] Metal compositor and pixel-perfect preview parity for every effect.
- Quick export using the last successful settings.

Acceptance:

- Exported video matches the editor preview frame-for-frame for canvas and webcam layout.
- Audio, webcam and screen remain within one frame of the shared timeline after pause/resume.
- A ten-minute 4K source exports without unbounded memory growth.

## M2 — Signature automatic motion

Outcome: raw recordings automatically become easy-to-follow demos.

- [x] Automatic zoom playback/export and manual add/remove at the playhead.
- [ ] Drag-editable zoom ranges and easing handles on the timeline.
- Spring/easing-based camera motion with safe framing for portrait output.
- [x] Smoothed cursor path, post-recording cursor sizing and static-cursor hiding.
- High-resolution replacement for known macOS cursor types.
- [x] Click ripple/circle effects.
- [ ] Optional click sound effects.
- Cursor-aware webcam avoidance.

Acceptance:

- Zooms follow click and typing intent without cutting off the focused target.
- Cursor rendering is stable at 60 FPS and independent of the recorded cursor.
- Camera and cursor motion are deterministic between preview and export.

## M3 — Audio, captions and teaching tools

Outcome: tutorials sound clean and remain understandable without audio.

- [x] Per-source mute and volume controls with visible waveforms.
- Voice normalization and local noise reduction.
- Stereo microphone support and channel routing.
- [x] Manual editable subtitle track with preview/export rendering.
- [x] On-device transcript generation requested explicitly from the captions inspector.
- Keyboard shortcut overlays with per-range visibility.
- Optional background music and ducking.

Acceptance:

- Exported channel levels match the editor preview.
- Captions stay aligned after cuts and speed changes.
- Audio processing never changes project source media.

## M4 — Advanced composition and reuse

Outcome: users can create branded, reusable templates and more complex demos.

- Presets for canvas, camera, cursor, zoom and export settings.
- Import/export of shareable preset files.
- Dynamic webcam layouts: hidden, picture-in-picture and fullscreen ranges.
- [x] Timed privacy and highlight masks for sensitive or important areas.
- [ ] True Gaussian blur masks in the Metal compositor.
- Custom cursor packs and additional macOS/device frames.
- [x] Import existing MOV/MP4 files into a project.
- [x] GIF export with scale, FPS, quality and infinite loop.

## M5 — Capture and distribution expansion

Outcome: Captura covers device demos and fast sharing workflows.

- Connected iPhone/iPad capture with device model and orientation metadata.
- iPhone/iPad frames and colors.
- [x] Area capture with interactive preview guides.
- [ ] Optional aspect locking while selecting the area.
- Batch export and copy exported media/current frame to clipboard.
- Optional shareable links behind a separate, privacy-explicit service boundary.
- Crash-safe recording recovery and autosave snapshots.

## Not in scope for feature parity

- Copying Screen Studio's name, icons, wallpapers, cursor assets, device artwork or visual identity.
- Depending on Screen Studio project formats or private APIs.
- Requiring a cloud account for local recording, editing or export.

## Immediate execution order

1. Metal compositor and pixel-perfect preview/export parity.
2. Aspect-aware crop and editable automatic zoom ranges.
3. Cursor replacement, smoothing and click effects.
4. Audio controls, real waveform and captions.
5. GIF, presets, masks and connected-device capture.
