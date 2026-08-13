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
    var windowID: CGWindowID? = nil
    var resolution: RecordingResolution = .native
    var frameRate: Int = 60
    var codec: VideoCodec = .hevc
    var captureSystemAudio = true
    var captureMicrophone = false
    var microphoneDeviceID: String? = nil
    var captureWebcam = false
    var webcamDeviceID: String? = nil
    var captureCursorInVideo = false
}

enum CaptureSourceKind: String, CaseIterable, Sendable {
    case display = "Display"
    case window = "Window"
}

struct DisplayChoice: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

struct WindowChoice: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let width: Int
    let height: Int

    var displayName: String {
        title.isEmpty ? applicationName : "\(applicationName) — \(title)"
    }
}

struct MicrophoneChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct CameraChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}
