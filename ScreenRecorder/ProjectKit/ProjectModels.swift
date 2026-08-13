import Foundation

struct CanvasSize: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
}

struct ProjectMedia: Codable, Hashable, Sendable {
    var screen: String
    var microphone: String? = nil
    var systemAudio: String? = nil
}

struct ProjectSettings: Codable, Hashable, Sendable {
    var canvas: CanvasSize
    var sourceDisplay: CanvasSize
    var frameRate: Int
    var codec: VideoCodec
}

struct RecordingMetadata: Codable, Hashable, Sendable {
    var eventsPath: String
    var eventCount: Int
    var droppedVideoFrames: Int
}

struct ScreenProject: Codable, Identifiable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var id: UUID
    var createdAt: Date
    var duration: Double
    var media: ProjectMedia
    var settings: ProjectSettings
    var recording: RecordingMetadata
    var cameraKeyframes: [CameraKeyframe]
    var timeline: Timeline
}
