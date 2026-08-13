import Foundation

enum RecorderError: Error, LocalizedError, Sendable, Equatable {
    case permissionDenied(String)
    case displayUnavailable
    case captureFailed(String)
    case encoderInitializationFailed(String)
    case writerFailed(String)
    case insufficientDiskSpace
    case invalidState

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let permission): "Permission denied: \(permission)."
        case .displayUnavailable: "The selected display is no longer available."
        case .captureFailed(let message): "Screen capture failed: \(message)"
        case .encoderInitializationFailed(let message): "Encoder initialization failed: \(message)"
        case .writerFailed(let message): "Media writer failed: \(message)"
        case .insufficientDiskSpace: "There is not enough free disk space to record."
        case .invalidState: "That recording operation is not valid in the current state."
        }
    }
}

enum RecordingState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case finished(URL)
    case failed(RecorderError)
}

struct RecordingMetrics: Sendable, Equatable {
    var capturedFrames = 0
    var encodedFrames = 0
    var droppedFrames = 0
    var averageProcessingMilliseconds = 0.0
    var elapsedSeconds = 0.0
    var eventCount = 0

    var capturedFPS: Double { elapsedSeconds > 0 ? Double(capturedFrames) / elapsedSeconds : 0 }
    var encodedFPS: Double { elapsedSeconds > 0 ? Double(encodedFrames) / elapsedSeconds : 0 }
}
