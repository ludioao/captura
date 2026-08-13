import CoreGraphics
import Foundation

enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case hevc
    case h264

    var displayName: String { rawValue.uppercased() }
}

enum RecordingResolution: String, Codable, CaseIterable, Sendable {
    case fullHD
    case quadHD
    case native

    var displayName: String {
        switch self {
        case .fullHD: "1920 × 1080"
        case .quadHD: "2560 × 1440"
        case .native: "Native"
        }
    }

    func dimensions(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .fullHD: (1920, 1080)
        case .quadHD: (2560, 1440)
        case .native: (nativeWidth, nativeHeight)
        }
    }
}

struct RecordingConfiguration: Sendable {
    var displayID: CGDirectDisplayID
    var resolution: RecordingResolution = .native
    var frameRate: Int = 60
    var codec: VideoCodec = .hevc
    var captureSystemAudio = true
    var captureMicrophone = false
    var captureCursorInVideo = false
}

struct DisplayChoice: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}
