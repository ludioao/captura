import Foundation

enum InteractionEventType: String, Codable, Sendable {
    case mouseMove
    case mouseDown
    case mouseUp
    case click
    case scroll
    case keyActivity
    case windowFocus
}

enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

struct AccessibilityElementSnapshot: Codable, Hashable, Sendable {
    var role: String?
    var title: String?
    var frame: CGRect?
    var applicationName: String?
    var bundleIdentifier: String?
}

struct InteractionEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var type: InteractionEventType
    var timestamp: Double
    var x: Double? = nil
    var y: Double? = nil
    var normalizedX: Double? = nil
    var normalizedY: Double? = nil
    var button: MouseButton? = nil
    var scrollDeltaX: Double? = nil
    var scrollDeltaY: Double? = nil
    var keyCode: Int? = nil
    var isTextInput: Bool? = nil
    var windowTitle: String? = nil
    var applicationName: String? = nil
    var accessibility: AccessibilityElementSnapshot? = nil
}

enum CursorType: String, Codable, Sendable {
    case arrow, pointingHand, iBeam, crosshair, unknown
}

struct CursorSample: Codable, Hashable, Sendable {
    var time: Double
    var normalizedX: Double
    var normalizedY: Double
    var cursorType: CursorType
}

enum CoordinateNormalizer {
    static func normalize(point: CGPoint, in displayFrame: CGRect) -> CGPoint {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .zero }
        let x = (point.x - displayFrame.minX) / displayFrame.width
        // CGEvent coordinates and ScreenCaptureKit display coordinates are top-left based.
        let y = (point.y - displayFrame.minY) / displayFrame.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

enum RelativeTimebase {
    static func timestamp(absoluteTime: Double, origin: Double, pausedDuration: Double = 0) -> Double {
        max(0, absoluteTime - origin - pausedDuration)
    }
}
