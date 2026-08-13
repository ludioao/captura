import Foundation

struct CanvasSize: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
}

struct ProjectMedia: Codable, Hashable, Sendable {
    var screen: String
    var microphone: String? = nil
    var systemAudio: String? = nil
    var camera: String? = nil
}

enum CanvasBackgroundPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case studio
    case midnight
    case ocean
    case sunset
    case graphite
    case custom

    var displayName: String {
        switch self {
        case .studio: "Studio"
        case .midnight: "Midnight"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        case .custom: "Custom"
        }
    }
}

struct CanvasAppearance: Codable, Hashable, Sendable {
    var backgroundPreset: CanvasBackgroundPreset = .studio
    var customColorHex = "#6C5CE7"
    var padding = 72.0
    var cornerRadius = 18.0
    var shadowStrength = 18.0
    var showsWindowFrame = true
    var cameraPositionX = 0.82
    var cameraPositionY = 0.78
    var cameraWidth = 0.24
    var cameraHeight = 0.24

    static let `default` = CanvasAppearance()
}

extension CanvasAppearance {
    private enum CodingKeys: String, CodingKey {
        case backgroundPreset
        case customColorHex
        case padding
        case cornerRadius
        case shadowStrength
        case showsWindowFrame
        case cameraPositionX
        case cameraPositionY
        case cameraWidth
        case cameraHeight
        // Kept as a decoding/encoding bridge for projects created by earlier builds.
        case cameraSize
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backgroundPreset = try values.decodeIfPresent(CanvasBackgroundPreset.self, forKey: .backgroundPreset) ?? .studio
        customColorHex = try values.decodeIfPresent(String.self, forKey: .customColorHex) ?? "#6C5CE7"
        padding = try values.decodeIfPresent(Double.self, forKey: .padding) ?? 72
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 18
        shadowStrength = try values.decodeIfPresent(Double.self, forKey: .shadowStrength) ?? 18
        showsWindowFrame = try values.decodeIfPresent(Bool.self, forKey: .showsWindowFrame) ?? true
        cameraPositionX = try values.decodeIfPresent(Double.self, forKey: .cameraPositionX) ?? 0.82
        cameraPositionY = try values.decodeIfPresent(Double.self, forKey: .cameraPositionY) ?? 0.78
        let legacyCameraSize = try values.decodeIfPresent(Double.self, forKey: .cameraSize)
        cameraWidth = try values.decodeIfPresent(Double.self, forKey: .cameraWidth) ?? legacyCameraSize ?? 0.24
        cameraHeight = try values.decodeIfPresent(Double.self, forKey: .cameraHeight) ?? legacyCameraSize ?? 0.24
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backgroundPreset, forKey: .backgroundPreset)
        try values.encode(customColorHex, forKey: .customColorHex)
        try values.encode(padding, forKey: .padding)
        try values.encode(cornerRadius, forKey: .cornerRadius)
        try values.encode(shadowStrength, forKey: .shadowStrength)
        try values.encode(showsWindowFrame, forKey: .showsWindowFrame)
        try values.encode(cameraPositionX, forKey: .cameraPositionX)
        try values.encode(cameraPositionY, forKey: .cameraPositionY)
        try values.encode(cameraWidth, forKey: .cameraWidth)
        try values.encode(cameraHeight, forKey: .cameraHeight)
        try values.encode(cameraWidth, forKey: .cameraSize)
    }
}

struct ProjectSettings: Codable, Hashable, Sendable {
    var canvas: CanvasSize
    var sourceDisplay: CanvasSize
    var frameRate: Int
    var codec: VideoCodec
    /// Optional so projects created before canvas styling continue to decode.
    var appearance: CanvasAppearance? = nil
    /// Optional fields keep projects from earlier builds source-compatible.
    var audio: ProjectAudioSettings? = nil
    var cursor: CursorAppearance? = nil
}

struct ProjectAudioSettings: Codable, Hashable, Sendable {
    var systemVolume = 1.0
    var microphoneVolume = 1.0
    var systemMuted = false
    var microphoneMuted = false
    var voiceEnhancement = false
    var noiseReduction = false
    var clickSounds = false
    var clickVolume = 0.55

    static let `default` = ProjectAudioSettings()

    private enum CodingKeys: String, CodingKey {
        case systemVolume, microphoneVolume, systemMuted, microphoneMuted
        case voiceEnhancement, noiseReduction, clickSounds, clickVolume
    }

    init(
        systemVolume: Double = 1,
        microphoneVolume: Double = 1,
        systemMuted: Bool = false,
        microphoneMuted: Bool = false,
        voiceEnhancement: Bool = false,
        noiseReduction: Bool = false,
        clickSounds: Bool = false,
        clickVolume: Double = 0.55
    ) {
        self.systemVolume = systemVolume
        self.microphoneVolume = microphoneVolume
        self.systemMuted = systemMuted
        self.microphoneMuted = microphoneMuted
        self.voiceEnhancement = voiceEnhancement
        self.noiseReduction = noiseReduction
        self.clickSounds = clickSounds
        self.clickVolume = clickVolume
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        systemVolume = try values.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1
        microphoneVolume = try values.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1
        systemMuted = try values.decodeIfPresent(Bool.self, forKey: .systemMuted) ?? false
        microphoneMuted = try values.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? false
        voiceEnhancement = try values.decodeIfPresent(Bool.self, forKey: .voiceEnhancement) ?? false
        noiseReduction = try values.decodeIfPresent(Bool.self, forKey: .noiseReduction) ?? false
        clickSounds = try values.decodeIfPresent(Bool.self, forKey: .clickSounds) ?? false
        clickVolume = try values.decodeIfPresent(Double.self, forKey: .clickVolume) ?? 0.55
    }
}

struct CursorAppearance: Codable, Hashable, Sendable {
    var isVisible = true
    var size = 1.0
    var smoothing = 0.35
    var hidesWhenIdle = true
    var clickEffect = true

    static let `default` = CursorAppearance()
}

struct CaptionCue: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var text: String
}

enum OverlayRegionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case privacy
    case highlight
}

struct OverlayRegion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
    var kind: OverlayRegionKind
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
    var captions: [CaptionCue]? = nil
    var overlays: [OverlayRegion]? = nil
}

struct CapturaPreset: Codable, Identifiable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = currentFormatVersion
    var id = UUID()
    var name: String
    var appearance: CanvasAppearance
    var audio: ProjectAudioSettings
    var cursor: CursorAppearance
    var export: ExportSettings?
}

struct RecordingRecoveryManifest: Codable, Hashable, Sendable {
    var createdAt: Date
    var canvas: CanvasSize
    var sourceDisplay: CanvasSize
    var frameRate: Int
    var codec: VideoCodec
    var hasWebcam: Bool
}

struct RecentProject: Identifiable, Hashable, Sendable {
    var id: UUID { projectID }
    let projectID: UUID
    let url: URL
    let name: String
    let createdAt: Date
    let duration: Double
    let canvas: CanvasSize
    let hasWebcam: Bool
    let eventCount: Int
}
