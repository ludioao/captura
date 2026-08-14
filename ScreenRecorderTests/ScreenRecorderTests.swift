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

    func testLegacyAudioSettingsGainProcessingDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectAudioSettings.self, from: Data(#"{"systemVolume":0.8}"#.utf8))

        XCTAssertEqual(settings.systemVolume, 0.8)
        XCTAssertFalse(settings.voiceEnhancement)
        XCTAssertFalse(settings.noiseReduction)
        XCTAssertFalse(settings.clickSounds)
    }

    func testCapturaPresetRoundTripsAsShareableJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Tutorial.capturapreset")
        let preset = CapturaPreset(
            name: "Tutorial",
            appearance: .default,
            audio: ProjectAudioSettings(voiceEnhancement: true, noiseReduction: true, clickSounds: true),
            cursor: .default,
            export: .mp4(resolution: CanvasSize(width: 1920, height: 1080), fps: 60),
            brandKit: BrandKit(name: "Captura", primaryHex: "#6610F2", secondaryHex: "#B96CFF")
        )

        try CapturaPresetStore.export(preset, to: url)
        let decoded = try CapturaPresetStore.importPreset(from: url)

        XCTAssertEqual(decoded, preset)
    }

    func testAdvancedEditorFeaturesPersistInProject() throws {
        var project = sampleProject(duration: 12)
        let textID = UUID()
        project.brandKit = BrandKit(name: "Acme", primaryHex: "#112233", secondaryHex: "#445566")
        project.audioAssets = [ProjectAudioAsset(
            name: "Theme", assetPath: "assets/audio/theme.m4a", startTime: 1, duration: 8
        )]
        project.textOverlays = [TextOverlay(
            id: textID, text: "Launch", startTime: 2, endTime: 6,
            fontName: "Avenir Next", letterSpacing: 1.5, entrance: .slideUp, exit: .fade
        )]
        project.visualKeyframes = [VisualPropertyKeyframe(
            elementID: textID, elementKind: .text, property: .positionX, time: 3, value: 0.65
        )]
        project.layoutSegments = [LayoutSegment(startTime: 4, endTime: 7, layout: .sideBySide)]

        let decoded = try JSONDecoder().decode(ScreenProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.audioAssets?.first?.fadeOut, 0.8)
        XCTAssertEqual(decoded.layoutSegments?.first?.layout, .sideBySide)
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
        XCTAssertEqual(appearance.cameraShadow, 0)
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

    func testWebcamFocusSegmentExpandsHoldsAndReturns() {
        let appearance = CanvasAppearance.default
        let interpolator = WebcamLayoutInterpolator()
        let frames = interpolator.focusSegment(
            at: 2,
            duration: 4,
            frames: [],
            fallback: appearance,
            projectDuration: 10
        )

        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.first?.time, 2)
        XCTAssertEqual(frames.last?.time, 6)
        XCTAssertEqual(interpolator.value(at: 3, frames: frames, fallback: appearance).width, 0.92, accuracy: 0.001)
        XCTAssertEqual(interpolator.value(at: 6, frames: frames, fallback: appearance).width, appearance.cameraWidth, accuracy: 0.001)
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

    func testCursorDoesNotDriftAcrossIdleGap() throws {
        let samples = [
            CursorSample(time: 1, normalizedX: 0.2, normalizedY: 0.3, cursorType: .arrow),
            CursorSample(time: 5, normalizedX: 0.8, normalizedY: 0.7, cursorType: .arrow)
        ]

        let idle = try XCTUnwrap(CursorInterpolator().sample(at: 3, from: samples))
        let arrived = try XCTUnwrap(CursorInterpolator().sample(at: 5, from: samples))

        XCTAssertEqual(idle.normalizedX, 0.2, accuracy: 0.001)
        XCTAssertEqual(idle.normalizedY, 0.3, accuracy: 0.001)
        XCTAssertEqual(arrived.normalizedX, 0.8, accuracy: 0.001)
        XCTAssertEqual(arrived.normalizedY, 0.7, accuracy: 0.001)
    }

    func testCursorStillSmoothsConsecutiveMovementSamples() throws {
        let samples = [
            CursorSample(time: 1, normalizedX: 0.2, normalizedY: 0.3, cursorType: .arrow),
            CursorSample(time: 1.1, normalizedX: 0.8, normalizedY: 0.7, cursorType: .arrow)
        ]

        let moving = try XCTUnwrap(CursorInterpolator().sample(at: 1.05, from: samples))
        XCTAssertEqual(moving.normalizedX, 0.5, accuracy: 0.001)
        XCTAssertEqual(moving.normalizedY, 0.5, accuracy: 0.001)
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

    func testTimelineContextEditUsesCurrentPlayheadExactly() throws {
        let editTime = TimelineEditPosition.playhead(10, within: 0...30)
        XCTAssertEqual(editTime, 10, accuracy: 0.000_001)

        let clip = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 0, sourceEnd: 30, timelineStart: 0
        )
        let halves = try XCTUnwrap(clip.split(at: editTime))
        XCTAssertEqual(halves.0.duration, 10, accuracy: 0.000_001)
        XCTAssertEqual(halves.1.timelineStart, 10, accuracy: 0.000_001)
    }

    func testSmartEditDetectsAndRemovesSilentPause() {
        let ranges = SmartEditAnalyzer.silentRanges(
            waveform: [0.8, 0.7, 0, 0, 0, 0, 0.9, 0.8],
            duration: 8,
            threshold: 0.1,
            minimumDuration: 2,
            preserveEdge: 0
        )
        XCTAssertEqual(ranges, [2...6])

        var timeline = Timeline(clips: [TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 0, sourceEnd: 8, timelineStart: 0
        )])
        timeline.remove(timeRanges: ranges)
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.duration, 4, accuracy: 0.000_001)
        XCTAssertEqual(timeline.clips[1].sourceStart, 6, accuracy: 0.000_001)
    }

    func testDemoFlowStartsOnCameraThenMovesToChosenFocus() throws {
        let plan = DemoFlowDirector.makePlan(
            duration: 20,
            introDuration: 5,
            destination: .pictureInPicture,
            appearance: .default,
            focusTarget: CGPoint(x: 0.8, y: 0.25),
            sourceCutTime: 7,
            destinationCameraFrame: CGRect(x: 0.08, y: 0.12, width: 0.3, height: 0.22)
        )
        XCTAssertEqual(plan.layouts.map(\.layout), [.cameraOnly, .pictureInPicture])
        XCTAssertEqual(plan.layouts[0].endTime, 5)
        XCTAssertEqual(try XCTUnwrap(plan.webcamKeyframes.first).time, 0, accuracy: 0.001)
        let landing = try XCTUnwrap(plan.webcamKeyframes.last)
        XCTAssertEqual(landing.time, 5.45, accuracy: 0.001)
        XCTAssertEqual(landing.positionX, 0.23, accuracy: 0.001)
        XCTAssertEqual(landing.positionY, 0.23, accuracy: 0.001)
        XCTAssertEqual(landing.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(landing.height, 0.22, accuracy: 0.001)
        let focus = try XCTUnwrap(plan.cameraKeyframes.last)
        XCTAssertEqual(focus.centerX, 0.8, accuracy: 0.001)
        XCTAssertEqual(focus.centerY, 0.25, accuracy: 0.001)
        XCTAssertEqual(focus.scale, 1.45, accuracy: 0.001)
    }

    func testSplitMovesExistingTransitionToTrailingClip() throws {
        let clip = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 0, sourceEnd: 10,
            timelineStart: 0, transitionOut: ClipTransition(kind: .flash, duration: 0.6)
        )
        let halves = try XCTUnwrap(clip.split(at: 4))
        XCTAssertNil(halves.0.transitionOut)
        XCTAssertEqual(halves.1.transitionOut, ClipTransition(kind: .flash, duration: 0.6))
    }

    func testTimelineTransitionPeaksAtCutAndStopsOutsideWindow() throws {
        let first = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 0, sourceEnd: 4,
            timelineStart: 0, transitionOut: ClipTransition(kind: .fade, duration: 0.8)
        )
        let second = TimelineClip(
            id: UUID(), sourceMediaID: UUID(), sourceStart: 4, sourceEnd: 8,
            timelineStart: 4
        )
        let timeline = Timeline(clips: [first, second])
        XCTAssertEqual(try XCTUnwrap(timeline.activeTransition(at: 4)).intensity, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.activeTransition(at: 3.8)).intensity, 0.5, accuracy: 0.001)
        XCTAssertNil(timeline.activeTransition(at: 3.5))
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

    func testTimelineDeletesExactlyTheRequestedClipAtEveryPosition() {
        let sourceID = UUID()
        let clips = (0..<3).map { index in
            TimelineClip(
                id: UUID(), sourceMediaID: sourceID,
                sourceStart: Double(index * 2), sourceEnd: Double(index * 2 + 2),
                timelineStart: Double(index * 2)
            )
        }

        for targetIndex in clips.indices {
            var timeline = Timeline(clips: clips)
            let targetID = clips[targetIndex].id

            XCTAssertTrue(timeline.delete(clipID: targetID))
            XCTAssertFalse(timeline.clips.contains { $0.id == targetID })
            XCTAssertEqual(timeline.clips.map(\.id), clips.map(\.id).filter { $0 != targetID })
            XCTAssertEqual(timeline.clips.map(\.timelineStart), [0, 2])
        }

        var unchanged = Timeline(clips: clips)
        XCTAssertFalse(unchanged.delete(clipID: UUID()))
        XCTAssertEqual(unchanged.clips.map(\.id), clips.map(\.id))
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

    func testTimelineInsertsImportedClipAtMouseTimeAndSplitsUnderlyingClip() {
        let originalMediaID = UUID()
        let importedMediaID = UUID()
        var timeline = Timeline(clips: [
            TimelineClip(
                id: UUID(), sourceMediaID: originalMediaID,
                sourceStart: 0, sourceEnd: 10, timelineStart: 0
            )
        ])
        let imported = TimelineClip(
            id: UUID(), sourceMediaID: importedMediaID,
            sourceStart: 0, sourceEnd: 3, timelineStart: 4,
            layout: VideoClipLayout(positionX: 0.5, positionY: 0.5, scale: 0.7, opacity: 1, contentMode: .fit)
        )

        timeline.insert(imported, at: 4)

        XCTAssertEqual(timeline.clips.count, 3)
        XCTAssertEqual(timeline.clips.map(\.sourceMediaID), [originalMediaID, importedMediaID, originalMediaID])
        XCTAssertEqual(timeline.clips[0].sourceEnd, 4, accuracy: 0.001)
        XCTAssertEqual(timeline.clips[1].timelineStart, 4, accuracy: 0.001)
        XCTAssertEqual(timeline.clips[2].sourceStart, 4, accuracy: 0.001)
        XCTAssertEqual(timeline.duration, 13, accuracy: 0.001)
    }

    func testImportedVideoAndClipLayoutPersistWithProject() throws {
        var project = sampleProject(duration: 5)
        let media = ProjectVideoAsset(
            id: UUID(), path: "assets/video/demo.mov", name: "Demo",
            duration: 2, width: 1080, height: 1920, rotationQuarterTurns: 1
        )
        project.videoAssets = [media]
        project.timeline.clips[0].layout = VideoClipLayout(
            positionX: 0.35, positionY: 0.62, scale: 1.4, opacity: 0.8, contentMode: .fill
        )

        let decoded = try JSONDecoder().decode(ScreenProject.self, from: JSONEncoder().encode(project))

        XCTAssertEqual(decoded.videoAssets, [media])
        XCTAssertEqual(decoded.timeline.clips[0].layout, project.timeline.clips[0].layout)
    }

    func testVideoTemplateGeneratorProducesPlayableMovie() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "captura-template-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let template = try XCTUnwrap(VideoTemplateDescriptor.library.first { $0.id == "chapter" })

        try await VideoTemplateGenerator.generate(
            template: template,
            title: "Chapter One",
            subtitle: "A generated scene",
            canvas: CanvasSize(width: 320, height: 180),
            outputURL: url,
            frameRate: 10
        )

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(duration, template.duration, accuracy: 0.12)
    }

    func testRecordingResolutionPreservesNonWidescreenAspect() {
        let output = RecordingResolution.fullHD.dimensions(nativeWidth: 1000, nativeHeight: 1000)
        XCTAssertEqual(output.width, 1080)
        XCTAssertEqual(output.height, 1080)
    }

    func testCapturePixelGeometryUsesSelectedDisplayScale() {
        let retina = CapturePixelGeometry.dimensions(
            for: CGSize(width: 1512, height: 982),
            pointPixelScale: 2
        )
        let external = CapturePixelGeometry.dimensions(
            for: CGSize(width: 2560, height: 1440),
            pointPixelScale: 1
        )

        XCTAssertEqual(retina.width, 3024)
        XCTAssertEqual(retina.height, 1964)
        XCTAssertEqual(external.width, 2560)
        XCTAssertEqual(external.height, 1440)
    }

    func testCapturePixelGeometryProducesEncoderSafeEvenDimensions() {
        let output = CapturePixelGeometry.dimensions(
            for: CGSize(width: 1001, height: 777),
            pointPixelScale: 1.5
        )

        XCTAssertEqual(output.width % 2, 0)
        XCTAssertEqual(output.height % 2, 0)
        XCTAssertEqual(output.width, 1502)
        XCTAssertEqual(output.height, 1166)
    }

    func testMacWindowChromeUsesNativeLikeProportions() {
        let windowWidth = 1_200.0
        let titlebarHeight = windowWidth * MacWindowChromeMetrics.titlebarToWindowWidth
        let lightDiameter = titlebarHeight * MacWindowChromeMetrics.trafficLightToTitlebarHeight

        XCTAssertEqual(titlebarHeight, 31.2, accuracy: 0.001)
        XCTAssertEqual(lightDiameter, 9.984, accuracy: 0.001)
        XCTAssertLessThan(lightDiameter, titlebarHeight * 0.35)
    }

    func testAreaSelectionLocksAspectAndStaysInsideCanvas() {
        let canvas = CGSize(width: 1600, height: 900)
        let selection = AreaSelectionGeometry.normalizedRect(
            start: CGPoint(x: 1500, y: 800),
            current: CGPoint(x: 200, y: 100),
            canvasSize: canvas,
            aspectRatio: 16 / 9
        )

        XCTAssertGreaterThan(selection.width, 0)
        XCTAssertGreaterThan(selection.height, 0)
        XCTAssertGreaterThanOrEqual(selection.minX, 0)
        XCTAssertGreaterThanOrEqual(selection.minY, 0)
        XCTAssertLessThanOrEqual(selection.maxX, 1)
        XCTAssertLessThanOrEqual(selection.maxY, 1)
        let pixelAspect = (selection.width * canvas.width) / (selection.height * canvas.height)
        XCTAssertEqual(pixelAspect, 16 / 9, accuracy: 0.001)
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

    func testMetalProjectRendererComposesCanvasCameraAndPrivacyBlur() throws {
        let source = try makeMetalPixelBuffer(width: 96, height: 54, value: 0x68)
        let camera = try makeMetalPixelBuffer(width: 48, height: 48, value: 0xD2)
        let destination = try makeMetalPixelBuffer(width: 192, height: 108, value: 0)
        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 96, height: 54)
        project.settings.appearance = .default
        project.overlays = [OverlayRegion(
            startTime: 0, endTime: 1,
            normalizedX: 0.5, normalizedY: 0.5,
            normalizedWidth: 0.3, normalizedHeight: 0.3,
            kind: .privacy
        )]
        let geometry = ExportGeometry(
            outputSize: CGSize(width: 192, height: 108),
            sourceSize: project.settings.canvas,
            appearance: .default
        )
        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            screenTrackID: 1,
            cameraTrackID: 2,
            project: project,
            events: [],
            geometry: geometry
        )

        try MetalProjectRenderer().render(
            source: source,
            camera: camera,
            destination: destination,
            compositionTime: CMTime(seconds: 0.5, preferredTimescale: 600),
            instruction: instruction
        )

        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt8.self)
        XCTAssertNotEqual(bytes[0], bytes[CVPixelBufferGetBytesPerRow(destination) * 54 + 96 * 4])
    }

    func testMetalProjectRendererFocusesWebcamAtKeyframe() throws {
        let source = try makeMetalPixelBuffer(width: 96, height: 54, value: 0x42)
        let camera = try makeMetalPixelBuffer(width: 48, height: 48, value: 0xD4)
        let destination = try makeMetalPixelBuffer(width: 192, height: 108, value: 0)
        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 96, height: 54)
        project.settings.appearance = .default
        project.webcamKeyframes = [.focused(at: 0)]
        let geometry = ExportGeometry(
            outputSize: CGSize(width: 192, height: 108),
            sourceSize: project.settings.canvas,
            appearance: .default
        )
        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            screenTrackID: 1,
            cameraTrackID: 2,
            project: project,
            events: [],
            geometry: geometry
        )

        try MetalProjectRenderer().render(
            source: source,
            camera: camera,
            destination: destination,
            compositionTime: CMTime(seconds: 0.5, preferredTimescale: 600),
            instruction: instruction
        )

        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt8.self)
        let center = CVPixelBufferGetBytesPerRow(destination) * 54 + 96 * 4
        XCTAssertEqual(bytes[center], 0xD4, accuracy: 2)
    }

    func testMetalProjectRendererCompositesBrandingImage() throws {
        let source = try makeMetalPixelBuffer(width: 96, height: 54, value: 0x22)
        let destination = try makeMetalPixelBuffer(width: 192, height: 108, value: 0)
        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 96, height: 54)
        project.settings.appearance = .default
        let branding = BrandingOverlay(
            name: "Logo", assetPath: "assets/branding/logo.png",
            startTime: 0, endTime: 1,
            normalizedX: 0.5, normalizedY: 0.5,
            normalizedWidth: 0.35, normalizedHeight: 0.35,
            opacity: 1, cornerRadius: 0, contentMode: .fill
        )
        project.brandingOverlays = [branding]
        let geometry = ExportGeometry(
            outputSize: CGSize(width: 192, height: 108),
            sourceSize: project.settings.canvas,
            appearance: .default
        )
        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            screenTrackID: 1,
            cameraTrackID: nil,
            project: project,
            events: [],
            geometry: geometry,
            brandingImages: [branding.id: try makeSolidImage(red: 1, green: 0, blue: 0)]
        )

        try MetalProjectRenderer().render(
            source: source,
            camera: nil,
            destination: destination,
            compositionTime: CMTime(seconds: 0.5, preferredTimescale: 600),
            instruction: instruction
        )

        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt8.self)
        let center = CVPixelBufferGetBytesPerRow(destination) * 54 + 96 * 4
        XCTAssertGreaterThan(bytes[center + 2], 220)
        XCTAssertLessThan(bytes[center], 20)
    }

    func testMetalProjectRendererCompositesTimedText() throws {
        let source = try makeMetalPixelBuffer(width: 96, height: 54, value: 0x22)
        let destination = try makeMetalPixelBuffer(width: 192, height: 108, value: 0)
        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 96, height: 54)
        project.settings.appearance = .default
        project.textOverlays = [TextOverlay(
            text: "Title",
            startTime: 0,
            endTime: 1,
            normalizedWidth: 0.6,
            backgroundHex: "#FF0000",
            backgroundOpacity: 1,
            trackID: TimelineTrack.defaultTextID
        )]
        let geometry = ExportGeometry(
            outputSize: CGSize(width: 192, height: 108),
            sourceSize: project.settings.canvas,
            appearance: .default
        )
        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            screenTrackID: 1,
            cameraTrackID: nil,
            project: project,
            events: [],
            geometry: geometry
        )

        try MetalProjectRenderer().render(
            source: source,
            camera: nil,
            destination: destination,
            compositionTime: CMTime(seconds: 0.5, preferredTimescale: 600),
            instruction: instruction
        )

        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt8.self)
        let center = CVPixelBufferGetBytesPerRow(destination) * 54 + 96 * 4
        XCTAssertGreaterThan(bytes[center + 2], 220)
        XCTAssertLessThan(bytes[center], 40)
    }

    func testMutedOverlayTrackIsNotRenderedByMetalCompositor() throws {
        let source = try makeMetalPixelBuffer(width: 96, height: 54, value: 0x22)
        let destination = try makeMetalPixelBuffer(width: 192, height: 108, value: 0)
        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 96, height: 54)
        project.settings.appearance = .default
        let branding = BrandingOverlay(
            name: "Logo", assetPath: "assets/branding/logo.png",
            startTime: 0, endTime: 1,
            normalizedX: 0.5, normalizedY: 0.5,
            normalizedWidth: 0.35, normalizedHeight: 0.35,
            opacity: 1, cornerRadius: 0, contentMode: .fill,
            trackID: TimelineTrack.defaultOverlayID
        )
        project.brandingOverlays = [branding]
        var mutedTrack = TimelineTrack.defaultOverlay
        mutedTrack.isMuted = true
        project.timelineTracks = [mutedTrack]
        let geometry = ExportGeometry(
            outputSize: CGSize(width: 192, height: 108),
            sourceSize: project.settings.canvas,
            appearance: .default
        )
        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            screenTrackID: 1, cameraTrackID: nil,
            project: project, events: [], geometry: geometry,
            brandingImages: [branding.id: try makeSolidImage(red: 1, green: 0, blue: 0)]
        )
        try MetalProjectRenderer().render(
            source: source, camera: nil, destination: destination,
            compositionTime: CMTime(seconds: 0.5, preferredTimescale: 600), instruction: instruction
        )
        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt8.self)
        let center = CVPixelBufferGetBytesPerRow(destination) * 54 + 96 * 4
        XCTAssertLessThan(bytes[center + 2], 100)
    }

    @MainActor
    func testMetalPreviewUsesSharedVideoCompositor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let media = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.makeTestMovie(
            at: media.appending(path: "screen.mov"),
            size: CGSize(width: 160, height: 90),
            frameCount: 15
        )
        var project = sampleProject(duration: 0.5)
        project.settings.canvas = CanvasSize(width: 160, height: 90)

        let item = try await MetalPreviewCompositionBuilder.makePlayerItem(
            project: project,
            packageURL: directory,
            events: []
        )

        let compositorClass = try XCTUnwrap(item.videoComposition?.customVideoCompositorClass)
        XCTAssertEqual(ObjectIdentifier(compositorClass), ObjectIdentifier(MetalProjectVideoCompositor.self))
        XCTAssertTrue(item.videoComposition?.instructions.first is CapturaVideoInstruction)
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
        let metadataDirectory = directory.appending(path: "metadata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = mediaDirectory.appending(path: "screen.mov")
        let destination = directory.appending(path: "export.mp4")
        try await Self.makeTestMovie(at: source, size: CGSize(width: 320, height: 180), frameCount: 30)

        var project = sampleProject(duration: 1)
        project.settings.canvas = CanvasSize(width: 320, height: 180)
        project.settings.appearance = .default
        project.settings.audio = ProjectAudioSettings(clickSounds: true, clickVolume: 0.7)
        let click = InteractionEvent(type: .click, timestamp: 0.35, normalizedX: 0.5, normalizedY: 0.5)
        try JSONEncoder().encode([click]).write(to: metadataDirectory.appending(path: "events.json"))
        try await MP4ProjectExporter().export(
            project: project,
            packageURL: directory,
            destination: destination,
            settings: .mp4(resolution: CanvasSize(width: 640, height: 360), fps: 30),
            progress: { _ in }
        )

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(duration, 1, accuracy: 0.08)
        XCTAssertFalse(audioTracks.isEmpty)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0, 1_000)
    }

    func testVoiceProcessingTapCanBeCreated() throws {
        _ = try VoiceProcessingAudioTap.make(voiceEnhancement: true, noiseReduction: true)
    }

    func testGIFExporterProducesAnimatedImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mediaDirectory = directory.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = mediaDirectory.appending(path: "screen.mov")
        let destination = directory.appending(path: "export.gif")
        try await Self.makeTestMovie(at: source, size: CGSize(width: 160, height: 90), frameCount: 15)
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
        try await Self.makeTestMovie(at: source, size: CGSize(width: 320, height: 180), frameCount: 15)

        let store = ProjectStore()
        let packageURL = try await store.importVideo(from: source, in: projects)
        let (project, events) = try await store.load(from: packageURL)

        XCTAssertEqual(project.settings.canvas, CanvasSize(width: 320, height: 180))
        XCTAssertEqual(project.duration, 0.5, accuracy: 0.08)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appending(path: project.media.screen).path))
    }

    func testProjectStoreRecoversInterruptedRecordingManifest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore()
        let package = try await store.createPackage(in: directory)
        try await Self.makeTestMovie(at: package.screenMediaURL, size: CGSize(width: 320, height: 180), frameCount: 15)
        try await store.writeRecoveryManifest(
            RecordingRecoveryManifest(
                createdAt: Date(),
                canvas: CanvasSize(width: 320, height: 180),
                sourceDisplay: CanvasSize(width: 320, height: 180),
                frameRate: 30,
                codec: .h264,
                hasWebcam: false
            ),
            to: package
        )

        let recovered = await store.recoverInterruptedRecordings(in: directory)
        let (project, events) = try await store.load(from: package.rootURL)

        XCTAssertEqual(
            recovered.map { $0.resolvingSymlinksInPath() },
            [package.rootURL.resolvingSymlinksInPath()]
        )
        XCTAssertEqual(project.settings.canvas, CanvasSize(width: 320, height: 180))
        XCTAssertEqual(project.duration, 0.5, accuracy: 0.08)
        XCTAssertTrue(events.isEmpty)
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

    func testBrandingOverlayPersistsWithProject() throws {
        var project = sampleProject(duration: 12)
        let overlayTrack = TimelineTrack(id: UUID(), name: "Client Brand", kind: .overlay, isLocked: true)
        project.timelineTracks = [overlayTrack]
        project.brandingOverlays = [BrandingOverlay(
            name: "Acme logo",
            assetPath: "assets/branding/logo.png",
            startTime: 1,
            endTime: 9,
            normalizedX: 0.82,
            normalizedY: 0.84,
            normalizedWidth: 0.2,
            normalizedHeight: 0.12,
            opacity: 0.72,
            cornerRadius: 0.1,
            contentMode: .fit,
            trackID: overlayTrack.id
        )]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScreenProject.self, from: data)
        XCTAssertEqual(decoded.brandingOverlays, project.brandingOverlays)
        XCTAssertEqual(decoded.timelineTracks, project.timelineTracks)
    }

    func testTextOverlayPersistsWithProject() throws {
        var project = sampleProject(duration: 8)
        project.textOverlays = [TextOverlay(
            text: "Launch day",
            startTime: 1.5,
            endTime: 4.5,
            normalizedX: 0.5,
            normalizedY: 0.8,
            normalizedWidth: 0.72,
            fontSize: 72,
            weight: .bold,
            alignment: .center,
            foregroundHex: "#FFFFFF",
            backgroundHex: "#111318",
            backgroundOpacity: 0.75,
            trackID: TimelineTrack.defaultTextID
        )]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScreenProject.self, from: data)

        XCTAssertEqual(decoded.textOverlays, project.textOverlays)
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

    func testAutoDirectorIgnoresPointerMotionAndWindowChanges() {
        let events = [
            InteractionEvent(type: .mouseMove, timestamp: 1, normalizedX: 0.1, normalizedY: 0.2),
            InteractionEvent(type: .windowFocus, timestamp: 2, applicationName: "Notes"),
            InteractionEvent(type: .scroll, timestamp: 3, normalizedX: 0.4, normalizedY: 0.5)
        ]
        XCTAssertTrue(AutoDirector().makeIntents(from: events, duration: 10).isEmpty)
    }

    func testAutoDirectorAnticipatesClickWithoutDriftingBeforeIt() throws {
        let director = AutoDirector()
        let events = [
            InteractionEvent(type: .click, timestamp: 5, normalizedX: 0.8, normalizedY: 0.25)
        ]
        let intent = try XCTUnwrap(director.makeIntents(from: events, duration: 10).first)
        XCTAssertEqual(intent.startTime, 4.68, accuracy: 0.001)
        XCTAssertEqual(intent.focusTime, 5, accuracy: 0.001)

        let frames = director.makeKeyframes(from: [intent], duration: 10)
        let idle = try XCTUnwrap(CameraKeyframeInterpolator().value(at: 4, frames: frames))
        let anticipation = try XCTUnwrap(CameraKeyframeInterpolator().value(at: intent.startTime, frames: frames))
        let focused = try XCTUnwrap(CameraKeyframeInterpolator().value(at: intent.focusTime, frames: frames))
        XCTAssertEqual(idle.centerX, 0.5, accuracy: 0.001)
        XCTAssertEqual(idle.scale, 1, accuracy: 0.001)
        XCTAssertEqual(anticipation.centerX, 0.5, accuracy: 0.001)
        XCTAssertEqual(focused.centerX, 0.8, accuracy: 0.001)
        XCTAssertEqual(focused.centerY, 0.25, accuracy: 0.001)
        XCTAssertEqual(focused.scale, director.clickZoom, accuracy: 0.001)
    }

    func testAutoDirectorGroupsTypingAndUsesLatestPointerPosition() throws {
        let events = [
            InteractionEvent(type: .mouseMove, timestamp: 2, normalizedX: 0.22, normalizedY: 0.74),
            InteractionEvent(type: .keyActivity, timestamp: 3, keyCode: 0, isTextInput: true),
            InteractionEvent(type: .keyActivity, timestamp: 3.4, keyCode: 1, isTextInput: true),
            InteractionEvent(type: .keyActivity, timestamp: 3.9, keyCode: 2, isTextInput: true)
        ]
        let intents = AutoDirector().makeIntents(from: events, duration: 10)
        XCTAssertEqual(intents.count, 1)
        let intent = try XCTUnwrap(intents.first)
        XCTAssertEqual(intent.reason, .textInput)
        XCTAssertEqual(intent.focusTime, 3, accuracy: 0.001)
        XCTAssertEqual(intent.endTime, 7.4, accuracy: 0.001)
        XCTAssertEqual(intent.normalizedTargetX, 0.22, accuracy: 0.001)
        XCTAssertEqual(intent.normalizedTargetY, 0.74, accuracy: 0.001)
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
        XCTAssertTrue(frames.contains { $0.scale > 1 && $0.easing == .easeInOut })
        XCTAssertEqual(frames.last?.scale, 1)
    }

    func testSideBySideGeometrySupportsHorizontalRatioGapAndOrder() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let configuration = SideBySideConfiguration(
            orientation: .horizontal, screenFraction: 0.6, gap: 0.1, screenFirst: false
        )
        let result = PresenterLayoutGeometry.resolve(
            layout: .sideBySide,
            container: container,
            baseVideoRect: container,
            baseCameraRect: .zero,
            videoAspect: 2,
            videoContentMode: .fit,
            sideBySide: configuration
        )

        XCTAssertEqual(result.cameraRect, CGRect(x: 0, y: 0, width: 360, height: 500))
        XCTAssertEqual(result.videoRect.minX, 460, accuracy: 0.001)
        XCTAssertEqual(result.videoRect.width, 540, accuracy: 0.001)
        XCTAssertEqual(result.videoRect.height, 270, accuracy: 0.001)
        XCTAssertEqual(result.videoRect.midY, container.midY, accuracy: 0.001)
    }

    func testSideBySideGeometrySupportsVerticalSplit() {
        let container = CGRect(x: 0, y: 0, width: 600, height: 900)
        let result = PresenterLayoutGeometry.resolve(
            layout: .sideBySide,
            container: container,
            baseVideoRect: container,
            baseCameraRect: .zero,
            videoAspect: 1,
            videoContentMode: .fill,
            sideBySide: SideBySideConfiguration(
                orientation: .vertical, screenFraction: 0.4, gap: 0.05, screenFirst: true
            )
        )

        XCTAssertEqual(result.videoRect, CGRect(x: 0, y: 0, width: 600, height: 342))
        XCTAssertEqual(result.cameraRect, CGRect(x: 0, y: 387, width: 600, height: 513))
    }

    func testPresenterLayoutInterpolationMovesAndFadesGeometry() {
        let start = ResolvedPresenterLayout(
            videoRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            cameraRect: CGRect(x: 80, y: 80, width: 20, height: 20),
            videoOpacity: 1,
            cameraOpacity: 0
        )
        let end = ResolvedPresenterLayout(
            videoRect: CGRect(x: 50, y: 50, width: 50, height: 50),
            cameraRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            videoOpacity: 0,
            cameraOpacity: 1
        )
        let result = PresenterLayoutGeometry.interpolate(from: start, to: end, progress: 0.5)

        XCTAssertEqual(result.videoRect, CGRect(x: 25, y: 25, width: 75, height: 75))
        XCTAssertEqual(result.cameraRect, CGRect(x: 40, y: 40, width: 60, height: 60))
        XCTAssertEqual(result.videoOpacity, 0.5)
        XCTAssertEqual(result.cameraOpacity, 0.5)
    }

    func testLegacyLayoutSegmentDecodesWithoutSplitConfiguration() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","startTime":0,"endTime":4,"layout":"sideBySide","transitionDuration":0.35}
        """.data(using: .utf8)!
        let segment = try JSONDecoder().decode(LayoutSegment.self, from: json)
        XCTAssertNil(segment.sideBySide)
    }

    func testDemoFlowPersistsSideBySideConfiguration() throws {
        let configuration = SideBySideConfiguration(
            orientation: .vertical, screenFraction: 0.58, gap: 0.04, screenFirst: false
        )
        let plan = DemoFlowDirector.makePlan(
            duration: 12,
            introDuration: 3,
            destination: .sideBySide,
            appearance: .default,
            focusTarget: CGPoint(x: 0.5, y: 0.5),
            sourceCutTime: 3,
            sideBySideConfiguration: configuration
        )
        XCTAssertEqual(try XCTUnwrap(plan.layouts.last?.sideBySide), configuration)
    }

    func testTimelineRetimerKeepsTimedLayersAligned() throws {
        var project = sampleProject(duration: 20)
        project.captions = [CaptionCue(startTime: 2, endTime: 14, text: "Narration")]
        project.textOverlays = [TextOverlay(text: "Title", startTime: 1, endTime: 16)]
        project.layoutSegments = [LayoutSegment(startTime: 0, endTime: 20, layout: .sideBySide)]
        project.audioAssets = [ProjectAudioAsset(
            name: "Music", assetPath: "media/music.m4a", startTime: 0, duration: 20
        )]

        ProjectTimelineRetimer.apply(to: &project, removing: [5...10])

        XCTAssertEqual(project.duration, 15, accuracy: 0.001)
        XCTAssertEqual(project.captions?.map(\.startTime), [2, 5])
        XCTAssertEqual(project.captions?.map(\.endTime), [5, 9])
        XCTAssertEqual(project.textOverlays?.count, 2)
        XCTAssertEqual(project.layoutSegments?.map(\.endTime), [5, 15])
        XCTAssertEqual(project.audioAssets?.map(\.sourceStart), [0, 10])
        XCTAssertEqual(project.audioAssets?.map(\.duration), [5, 10])
    }

    func testMusicDuckingMergesNearbyNarration() {
        let cues = [
            CaptionCue(startTime: 1, endTime: 2, text: "A"),
            CaptionCue(startTime: 2.1, endTime: 3, text: "B"),
            CaptionCue(startTime: 5, endTime: 6, text: "C")
        ]
        XCTAssertEqual(MusicAudioMix.mergedNarration(cues), [1...3, 5...6])
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

    private static func makeTestMovie(at url: URL, size: CGSize, frameCount: Int) async throws {
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

    private func makeSolidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "CapturaTests", code: -2) }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else { throw NSError(domain: "CapturaTests", code: -3) }
        return image
    }
}
