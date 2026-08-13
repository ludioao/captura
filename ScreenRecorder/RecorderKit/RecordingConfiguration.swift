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
        case .fullHD: aspectFit(nativeWidth: nativeWidth, nativeHeight: nativeHeight, maxWidth: 1920, maxHeight: 1080)
        case .quadHD: aspectFit(nativeWidth: nativeWidth, nativeHeight: nativeHeight, maxWidth: 2560, maxHeight: 1440)
        case .native: (nativeWidth, nativeHeight)
        }
    }

    private func aspectFit(nativeWidth: Int, nativeHeight: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let scale = min(Double(maxWidth) / Double(max(nativeWidth, 1)), Double(maxHeight) / Double(max(nativeHeight, 1)))
        let width = max(2, Int(Double(nativeWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(nativeHeight) * scale) / 2 * 2)
        return (width, height)
    }
}

struct RecordingConfiguration: Sendable {
    var displayID: CGDirectDisplayID
    var windowID: CGWindowID? = nil
    var normalizedCropRect: CGRect? = nil
    var externalDeviceID: String? = nil
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
    case area = "Area"
    case device = "Device"
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

struct ExternalDeviceChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}
