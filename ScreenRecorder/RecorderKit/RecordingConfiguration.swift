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

enum AreaAspectLock: String, CaseIterable, Sendable {
    case free = "Free"
    case landscape = "16:9"
    case square = "1:1"
    case portrait = "9:16"

    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .landscape: 16 / 9
        case .square: 1
        case .portrait: 9 / 16
        }
    }
}

enum AreaSelectionGeometry {
    static func normalizedRect(
        start: CGPoint,
        current: CGPoint,
        canvasSize: CGSize,
        aspectRatio: CGFloat?
    ) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }

        let origin = CGPoint(
            x: min(max(start.x, 0), canvasSize.width),
            y: min(max(start.y, 0), canvasSize.height)
        )
        let target = CGPoint(
            x: min(max(current.x, 0), canvasSize.width),
            y: min(max(current.y, 0), canvasSize.height)
        )
        let directionX: CGFloat = target.x < origin.x ? -1 : 1
        let directionY: CGFloat = target.y < origin.y ? -1 : 1
        var width = max(abs(target.x - origin.x), 2)
        var height = max(abs(target.y - origin.y), 2)

        if let aspectRatio {
            if width / height > aspectRatio {
                height = width / aspectRatio
            } else {
                width = height * aspectRatio
            }

            let availableWidth = directionX > 0 ? canvasSize.width - origin.x : origin.x
            let availableHeight = directionY > 0 ? canvasSize.height - origin.y : origin.y
            let scale = min(1, availableWidth / width, availableHeight / height)
            width *= max(scale, 0)
            height *= max(scale, 0)
        }

        width = min(width, directionX > 0 ? canvasSize.width - origin.x : origin.x)
        height = min(height, directionY > 0 ? canvasSize.height - origin.y : origin.y)
        let x = directionX > 0 ? origin.x : origin.x - width
        let y = directionY > 0 ? origin.y : origin.y - height

        return CGRect(
            x: x / canvasSize.width,
            y: y / canvasSize.height,
            width: width / canvasSize.width,
            height: height / canvasSize.height
        )
    }
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
