# captura

`captura` is a native macOS screen recorder and non-destructive editing foundation built with Swift 6, SwiftUI, ScreenCaptureKit, AVFoundation, CoreMedia, and VideoToolbox. It targets Apple Silicon first and macOS 15 or newer.

## Current status

The repository contains the first end-to-end implementation: choose a display and resolution, record ScreenCaptureKit video at 30 or 60 FPS, optionally mux system audio, require a hardware HEVC encoder, collect interaction metadata independently, and save a versioned `.screenproject`. Stopping opens the package in an AVPlayer-based editor with a canvas timeline, playhead, interaction markers, camera zoom regions, and model-level trim/split operations.

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

## Permissions

- **Screen Recording** is required. The app requests it when recording starts; macOS may require relaunching after the first grant.
- **Accessibility** is optional. It enables richer global input/window metadata and control snapshots on clicks. Capture degrades to available coordinate metadata when it is absent.
- **Microphone** usage text and audio-input entitlement are present, but microphone capture is intentionally disabled in this milestone.

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
├── ExportKit/       exporter contracts and GIF placeholder
└── Shared/          OSLog and permission abstractions
```

Detailed design: [architecture](docs/ARCHITECTURE.md), [recording pipeline](docs/RECORDING_PIPELINE.md), [project format](docs/PROJECT_FORMAT.md), [Auto Director](docs/AUTO_DIRECTOR.md), [timeline](docs/TIMELINE.md), and [performance](docs/PERFORMANCE.md).

## Intentionally not implemented yet

- Microphone and webcam tracks
- Metal preview/compositing implementation (the interface exists; preview currently uses AVPlayer)
- Cursor asset capture and rendered cursor replacement
- Persisting editor mutations/autosave
- MP4 render/export and GIF encoding
- Full pause-aware audio validation under device changes
- Thumbnails and real audio waveform analysis
- App Store sandbox/document-type registration and production signing

The exact next step is to add an independent microphone capture/writer track with a shared host-time clock, then validate drift, pause/resume, and device changes alongside ScreenCaptureKit system audio.
