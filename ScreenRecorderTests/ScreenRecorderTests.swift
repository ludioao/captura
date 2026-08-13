import CoreGraphics
import CoreMedia
import CoreVideo
import AVFoundation
import ImageIO
import XCTest

#if canImport(captura)
@testable import captura
#else
@testable import ScreenRecorder
#endif

final class ScreenRecorderTests: XCTestCase {
    func testCaptureTimelineUsesScreenOriginForEverySource() {
        let timeline = CaptureTimeline()
        let origin = CMTime(seconds: 100, preferredTimescale: 1_000)

        XCTAssertNil(timeline.adjustment(for: CMTime(seconds: 99, preferredTimescale: 1_000)))
        timeline.beginIfNeeded(at: origin)

        let camera = timeline.adjustment(for: CMTime(seconds: 101.3, preferredTimescale: 1_000))
        XCTAssertEqual(camera?.origin, origin)
        XCTAssertEqual(camera?.pauseOffset, .zero)
    }

    func testCaptureTimelineAppliesOnePauseOffsetToAudioAndCamera() {
        let timeline = CaptureTimeline()
        timeline.beginIfNeeded(at: CMTime(seconds: 10, preferredTimescale: 1_000))
        timeline.pause(at: CMTime(seconds: 12, preferredTimescale: 1_000))

        XCTAssertNil(timeline.adjustment(for: CMTime(seconds: 12.5, preferredTimescale: 1_000)))

        timeline.resume(at: CMTime(seconds: 15, preferredTimescale: 1_000))
        let screen = timeline.adjustment(for: CMTime(seconds: 16, preferredTimescale: 1_000))
        let camera = timeline.adjustment(for: CMTime(seconds: 16.03, preferredTimescale: 1_000))

        XCTAssertNotNil(screen)
        XCTAssertNotNil(camera)
        XCTAssertEqual(screen!.pauseOffset.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(camera!.pauseOffset.seconds, 3, accuracy: 0.001)
    }

    func testProjectSerializationRoundTrip() throws {
        let project = sampleProject(duration: 12.5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScreenProject.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.media.screen, "media/screen.mov")
        XCTAssertNil(decoded.settings.appearance)
    }

    func testCanvasAppearancePersistsWithProject() throws {
        var project = sampleProject(duration: 8)
        project.settings.appearance = CanvasAppearance(
            backgroundPreset: .ocean,
            customColorHex: "#123456",
            padding: 96,
            cornerRadius: 24,
            shadowStrength: 20,
            showsWindowFrame: false,
            cameraPositionX: 0.25,
            cameraPositionY: 0.35,
            cameraWidth: 0.31,
            cameraHeight: 0.42
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScreenProject.self, from: data)

        XCTAssertEqual(decoded.settings.appearance, project.settings.appearance)
    }

    func testLegacyCanvasAppearanceGetsCameraPlacementDefaults() throws {
        let legacyJSON = Data(#"""
        {
            "backgroundPreset": "midnight",
            "customColorHex": "#123456",
            "padding": 64,
            "cornerRadius": 16,
            "shadowStrength": 12,
            "showsWindowFrame": true
        }
        """#.utf8)

        let appearance = try JSONDecoder().decode(CanvasAppearance.self, from: legacyJSON)

        XCTAssertEqual(appearance.cameraPositionX, 0.82)
        XCTAssertEqual(appearance.cameraPositionY, 0.78)
        XCTAssertEqual(appearance.cameraWidth, 0.24)
        XCTAssertEqual(appearance.cameraHeight, 0.24)
    }

    func testLegacyCameraSizeMigratesToIndependentDimensions() throws {
        let legacyJSON = Data(#"""
        {
            "cameraPositionX": 0.4,
            "cameraPositionY": 0.6,
            "cameraSize": 0.33
        }
        """#.utf8)

        let appearance = try JSONDecoder().decode(CanvasAppearance.self, from: legacyJSON)

        XCTAssertEqual(appearance.cameraWidth, 0.33)
        XCTAssertEqual(appearance.cameraHeight, 0.33)
    }

    func testProjectStoreUpdatePersistsTimelineWithoutTouchingMedia() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = testDirectory.appending(path: "Recent.screenproject", directoryHint: .isDirectory)
        let media = root.appending(path: "media", directoryHint: .isDirectory)
        let metadata = root.appending(path: "metadata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let movie = media.appending(path: "screen.mov")
        let sentinel = Data("source-media-remains-untouched".utf8)
        try sentinel.write(to: movie)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        var project = sampleProject(duration: 12.5)
        project.timeline.clips[0].trimEnd(to: 8)
        project.duration = project.timeline.duration
        let event = InteractionEvent(type: .click, timestamp: 1, normalizedX: 0.5, normalizedY: 0.5)
        let store = ProjectStore()
        try await store.update(project: project, events: [event], at: root)
        let (loaded, events) = try await store.load(from: root)

        XCTAssertEqual(loaded.duration, 8)
        XCTAssertEqual(events, [event])
        XCTAssertEqual(try Data(contentsOf: movie), sentinel)
        let listed = try await store.recentProjects(in: testDirectory)
        XCTAssertTrue(
            listed.contains { $0.projectID == project.id && $0.url.standardizedFileURL == root.standardizedFileURL },
            "Expected \(project.id) at \(root.path); listed: \(listed.map { "\($0.projectID) @ \($0.url.path)" })"
        )
    }

    func testRelativeTimestampAccountsForPause() {
        XCTAssertEqual(RelativeTimebase.timestamp(absoluteTime: 112, origin: 100, pausedDuration: 2.5), 9.5)
        XCTAssertEqual(RelativeTimebase.timestamp(absoluteTime: 99, origin: 100), 0)
    }

    func testCoordinateNormalizationAndClamping() {
        let frame = CGRect(x: 100, y: 200, width: 1000, height: 500)
        XCTAssertEqual(CoordinateNormalizer.normalize(point: CGPoint(x: 600, y: 325), in: frame), CGPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(CoordinateNormalizer.normalize(point: CGPoint(x: 0, y: 900), in: frame), CGPoint(x: 0, y: 1))
    }

    func testTimelineSplitPreservesSourceAndDuration() throws {
        let sourceID = UUID()
        let clip = TimelineClip(id: UUID(), sourceMediaID: sourceID, sourceStart: 10, sourceEnd: 30, timelineStart: 5)
        let halves = try XCTUnwrap(clip.split(at: 13))

        XCTAssertEqual(halves.0.sourceStart, 10)
        XCTAssertEqual(halves.0.sourceEnd, 18)
        XCTAssertEqual(halves.1.sourceStart, 18)
        XCTAssertEqual(halves.1.sourceEnd, 30)
        XCTAssertEqual(halves.0.duration + halves.1.duration, clip.duration)
    }

    func testTimelineTrimAndDuration() {
        var first = TimelineClip(id: UUID(), sourceMediaID: UUID(), sourceStart: 0, sourceEnd: 10, timelineStart: 0)
        first.trimStart(to: 2)
        first.trimEnd(to: 8)
        var timeline = Timeline(clips: [first, TimelineClip(id: UUID(), sourceMediaID: UUID(), sourceStart: 5, sourceEnd: 9, timelineStart: 6)])
        timeline.rippleLayout()

        XCTAssertEqual(first.duration, 6)
        XCTAssertEqual(timeline.clips[1].timelineStart, 6)
        XCTAssertEqual(timeline.duration, 10)
    }

    func testTimelineSpeedChangesDurationAndSplitSourcePosition() throws {
        let clip = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 10, sourceEnd: 30,
            timelineStart: 0, speed: 2
        )
        let halves = try XCTUnwrap(clip.split(at: 4))

        XCTAssertEqual(clip.duration, 10)
        XCTAssertEqual(halves.0.sourceEnd, 18)
        XCTAssertEqual(halves.0.duration, 4)
        XCTAssertEqual(halves.1.timelineStart, 4)
    }

    func testTimelineMapsEditedTimeToSourceAndBack() {
        let clip = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 8, sourceEnd: 18,
            timelineStart: 3, speed: 2
        )
        let timeline = Timeline(clips: [clip])

        XCTAssertEqual(timeline.sourceTime(at: 5), 12)
        XCTAssertEqual(timeline.firstTimelineTime(forSourceTime: 16), 7)
        XCTAssertNil(timeline.sourceTime(at: 1))
    }

    func testRecordingResolutionPreservesNonWidescreenAspect() {
        let output = RecordingResolution.fullHD.dimensions(nativeWidth: 1000, nativeHeight: 1000)
        XCTAssertEqual(output.width, 1080)
        XCTAssertEqual(output.height, 1080)
    }

    func testExternalDeviceDiscoveryHasStableUniqueIDs() {
        let devices = ExternalDeviceCaptureEngine.availableDevices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
    }

    func testDeviceIsASelectableCaptureSource() {
        XCTAssertTrue(CaptureSourceKind.allCases.contains(.device))
    }

    func testCameraKeyframesInterpolateSmoothly() throws {
        let frames = [
            CameraKeyframe(time: 0, centerX: 0.2, centerY: 0.3, scale: 1, easing: .linear),
            CameraKeyframe(time: 2, centerX: 0.8, centerY: 0.7, scale: 2, easing: .linear)
        ]
        let value = try XCTUnwrap(CameraKeyframeInterpolator().value(at: 1, frames: frames))

        XCTAssertEqual(value.centerX, 0.5, accuracy: 0.001)
        XCTAssertEqual(value.centerY, 0.5, accuracy: 0.001)
        XCTAssertEqual(value.scale, 1.5, accuracy: 0.001)
    }

    func testMetalCompositorRendersIOSurfaceBackedFrame() async throws {
        let compositor: MetalFrameCompositor
        do { compositor = try MetalFrameCompositor() }
        catch { throw XCTSkip("Metal unavailable: \(error.localizedDescription)") }
        let source = try makeMetalPixelBuffer(width: 64, height: 36, value: 0x62)
        let output = try await compositor.render(
            source: source,
            at: .zero,
            camera: CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, scale: 1.4, easing: .linear),
            cursor: CursorSample(time: 0, normalizedX: 0.5, normalizedY: 0.5, cursorType: .arrow)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(output), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 36)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(output))
        XCTAssertNotEqual(data.assumingMemoryBound(to: UInt8.self)[0], 0)
    }

    func testLegacyTimelineClipDefaultsToNormalSpeed() throws {
        let id = UUID()
        let mediaID = UUID()
        let data = Data(#"{"id":"\#(id.uuidString)","sourceMediaID":"\#(mediaID.uuidString)","sourceStart":0,"sourceEnd":5,"timelineStart":0}"#.utf8)
        let clip = try JSONDecoder().decode(TimelineClip.self, from: data)

        XCTAssertEqual(clip.speed, 1)
        XCTAssertEqual(clip.duration, 5)
    }

    func testMP4ExporterProducesRequestedCanvas() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mediaDirectory = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = mediaDirectory.appending(path: "screen.mov")
        let destination = directory.appending(path: "export.mp4")
        try await makeTestMovie(at: source, size: CGSize(width: 320, height: 180), frameCount: 30)

        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 320, height: 180)
        project.settings.appearance = .default
        try await MP4ProjectExporter().export(
            project: project,
            packageURL: directory,
            destination: destination,
            settings: .mp4(resolution: CanvasSize(width: 640, height: 360), fps: 30),
            progress: { _ in }
        )

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(duration, 1, accuracy: 0.08)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0, 1_000)
    }

    func testGIFExporterProducesAnimatedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mediaDirectory = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = mediaDirectory.appending(path: "screen.mov")
        let destination = directory.appending(path: "export.gif")
        try await makeTestMovie(at: source, size: CGSize(width: 160, height: 90), frameCount: 15)
        var project = sampleProject(duration: 0.5)
        project.settings.canvas = CanvasSize(width: 160, height: 90)
        project.settings.cursor = .default
        project.captions = [CaptionCue(startTime: 0, endTime: 0.4, text: "Captura")]

        try await GIFExporter().export(
            project: project,
            packageURL: directory,
            destination: destination,
            settings: ExportSettings(
                format: .gif, codec: .h264,
                resolution: CanvasSize(width: 320, height: 180), fps: 5, quality: .high
            ),
            progress: { _ in }
        )

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(imageSource), 2)
    }

    func testProjectStoreImportsExistingMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mov")
        let projects = directory.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try await makeTestMovie(at: source, size: CGSize(width: 320, height: 180), frameCount: 15)

        let store = ProjectStore()
        let packageURL = try await store.importVideo(from: source, in: projects)
        let (project, events) = try await store.load(from: packageURL)

        XCTAssertEqual(project.settings.canvas, CanvasSize(width: 320, height: 180))
        XCTAssertEqual(project.duration, 0.5, accuracy: 0.08)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appending(path: project.media.screen).path))
    }

    func testOverlayRegionsPersistWithoutBreakingProject() throws {
        var project = sampleProject(duration: 5)
        project.overlays = [OverlayRegion(
            startTime: 1, endTime: 4,
            normalizedX: 0.5, normalizedY: 0.5,
            normalizedWidth: 0.3, normalizedHeight: 0.2,
            kind: .privacy
        )]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScreenProject.self, from: data)
        XCTAssertEqual(decoded.overlays, project.overlays)
    }

    func testNearbyClicksAreGroupedIntoOneIntent() {
        let events = [
            InteractionEvent(type: .click, timestamp: 1, normalizedX: 0.4, normalizedY: 0.5),
            InteractionEvent(type: .click, timestamp: 2, normalizedX: 0.45, normalizedY: 0.52)
        ]
        let intents = AutoDirector().makeIntents(from: events, duration: 10)

        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].normalizedTargetX, 0.425, accuracy: 0.0001)
        XCTAssertGreaterThan(intents[0].zoom, 1)
    }

    func testTypingAfterClickExtendsZoomAndGeneratesKeyframes() {
        let events = [
            InteractionEvent(type: .click, timestamp: 1, normalizedX: 0.25, normalizedY: 0.75),
            InteractionEvent(type: .keyActivity, timestamp: 1.5, keyCode: 0, isTextInput: true)
        ]
        let director = AutoDirector()
        let intents = director.makeIntents(from: events, duration: 10)
        let frames = director.makeKeyframes(from: intents, duration: 10)

        XCTAssertEqual(intents.first?.reason, .textInput)
        XCTAssertEqual(intents.first?.endTime, 5)
        XCTAssertTrue(frames.contains { $0.scale > 1 && $0.easing == .spring })
        XCTAssertEqual(frames.last?.scale, 1)
    }

    private func sampleProject(duration: Double) -> ScreenProject {
        let mediaID = UUID()
        return ScreenProject(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: duration,
            media: ProjectMedia(screen: "media/screen.mov"),
            settings: ProjectSettings(
                canvas: CanvasSize(width: 1920, height: 1080),
                sourceDisplay: CanvasSize(width: 2560, height: 1440),
                frameRate: 60,
                codec: .hevc
            ),
            recording: RecordingMetadata(eventsPath: "metadata/events.json", eventCount: 0, droppedVideoFrames: 0),
            cameraKeyframes: [],
            timeline: Timeline(clips: [TimelineClip(id: UUID(), sourceMediaID: mediaID, sourceStart: 0, sourceEnd: duration, timelineStart: 0)])
        )
    }

    private func makeTestMovie(at url: URL, size: CGSize, frameCount: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(
                kCFAllocatorDefault, Int(size.width), Int(size.height),
                kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            guard result == kCVReturnSuccess, let pixelBuffer else {
                throw NSError(domain: "CapturaTests", code: Int(result))
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, frame % 2 == 0 ? 0x36 : 0x86, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "CapturaTests", code: -1)
        }
    }

    private func makeMetalPixelBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "CapturaTests", code: Int(result))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
