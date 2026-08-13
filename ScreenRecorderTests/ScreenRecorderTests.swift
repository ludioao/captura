import CoreGraphics
import XCTest

#if canImport(captura)
@testable import captura
#else
@testable import ScreenRecorder
#endif

final class ScreenRecorderTests: XCTestCase {
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
}
