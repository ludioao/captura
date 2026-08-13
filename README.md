# captura

`captura` is a native macOS screen recorder and non-destructive editing foundation built with Swift 6, SwiftUI, ScreenCaptureKit, AVFoundation, CoreMedia, and VideoToolbox. It targets Apple Silicon first and macOS 15 or newer.

The generated master brand icon is stored at [`Brand/captura-logo-master.png`](Brand/captura-logo-master.png), with production macOS sizes in the app asset catalog.

## Current status

The repository contains the first end-to-end implementation: choose a display or individual window, select a resolution and frame rate, record ScreenCaptureKit video at 30 or 60 FPS, optionally mux system and selected-microphone audio, and optionally record a selected webcam as a separate hardware-encoded HEVC source. Interaction metadata is collected independently and everything is saved in a versioned Finder-recognized `.screenproject` package. The home screen includes a recent-project library. While recording, an always-on-top controller remains available across Spaces. Opening or stopping into a project launches both the editor and an automatic floating preview with synchronized screen and webcam playback.

The source frame path does not convert frames through `NSImage`, `CGImage`, encoded image data, PNG, or JPEG. `CMSampleBuffer`s flow from ScreenCaptureKit to `AVAssetWriterInput`, whose encoder specification requires hardware acceleration.

Runtime screen capture must be exercised from a signed app with macOS Screen Recording permission. CI/unit tests deliberately do not invoke the privacy-protected capture API.

## Requirements and build

- macOS 15+
- Apple Silicon recommended
- Xcode 26.2+ (the project uses Swift 6 strict concurrency)

Open `ScreenRecorder.xcodeproj`, select the `ScreenRecorder` scheme, configure a Development Team if desired, and run the macOS target. Command-line verification:

```sh
xcodebuild -project ScreenRecorder.xcodeproj \
  -scheme ScreenRecorder \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/captura-derived \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild test -project ScreenRecorder.xcodeproj \
  -scheme ScreenRecorder \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/captura-derived \
  CODE_SIGNING_ALLOWED=NO
```

`swift test` is also supported for model tests through `Package.swift`.

For local builds, use `scripts/install-local.sh`. It builds Release, signs with the installed Apple Development identity, installs to `/Applications/captura.app`, and verifies the signature without launching the app. Pass `--launch` only when an interactive test is explicitly wanted. Do not install privacy-sensitive builds with `CODE_SIGNING_ALLOWED=NO` alone or replace this step with ad-hoc signing: macOS TCC may treat each binary hash as a different app and request permissions repeatedly.

## Permissions

- **Screen Recording** is required. It is requested only through the explicit **Grant Access** action; captura does not prompt automatically on every launch. macOS may require relaunching after the first grant.
- **Camera** is requested only when webcam capture is enabled.
- **Accessibility** is optional. It enables richer global input/window metadata and control snapshots on clicks. Capture degrades to available coordinate metadata when it is absent.
- **Microphone** is optional. The selected input is captured through ScreenCaptureKit on the same media clock as screen and system audio.

The app sandbox is currently disabled because global event taps and freely created Finder project packages need a deliberate sandbox/temporary-exception design before distribution.

## Source layout

```text
ScreenRecorder/
├── App/             SwiftUI lifecycle, home, recorder controller, editor
├── RecorderKit/     ScreenCaptureKit, AVAssetWriter, lifecycle, configuration
├── InteractionKit/ event tap, 60 Hz mouse coalescing, AX snapshots, models
├── ProjectKit/      versioned Codable model and .screenproject persistence
├── DirectorKit/     deterministic camera intents and keyframes
├── TimelineKit/     immutable-source clip/range editing model
├── RenderKit/       zero-copy compositor and cursor interfaces
├── ExportKit/       H.264/HEVC MP4 and animated GIF composition
└── Shared/          OSLog and permission abstractions
```

Detailed design: [architecture](docs/ARCHITECTURE.md), [recording pipeline](docs/RECORDING_PIPELINE.md), [project format](docs/PROJECT_FORMAT.md), [Auto Director](docs/AUTO_DIRECTOR.md), [timeline](docs/TIMELINE.md), [performance](docs/PERFORMANCE.md), and the [v1 engineering roadmap](docs/ROADMAP.md).

## Intentionally not implemented yet

The feature-parity plan is tracked in [`ROADMAP.md`](ROADMAP.md).

- Editable webcam position/keyframes and Metal composition (capture and basic editor overlay are implemented)
- Metal preview/compositing implementation (the interface exists; preview currently uses AVPlayer)
- Cursor asset capture and rendered cursor replacement
- Undo and continuous autosave (explicit editor save is implemented)
- Metal custom compositor for effect-level preview/export parity
- Full pause-aware audio validation under device changes
- Thumbnails and real audio waveform analysis
- App Store sandbox/document-type registration and production signing

The exact next step is the Metal compositor for pixel-identical preview/export,
followed by transcript generation, privacy masks, device capture and reusable presets.
