import Foundation

enum CameraIntentReason: String, Codable, Sendable {
    case click
    case textInput
    case windowChange
    case navigation
    case manual
}

struct CameraIntent: Codable, Hashable, Sendable {
    var startTime: Double
    var focusTime: Double
    var endTime: Double
    var normalizedTargetX: Double
    var normalizedTargetY: Double
    var zoom: Double
    var reason: CameraIntentReason
    var priority: Int
}

enum CameraEasing: String, Codable, Sendable {
    case linear
    case easeInOut
    case spring
}

struct CameraKeyframe: Codable, Hashable, Sendable {
    var time: Double
    var centerX: Double
    var centerY: Double
    var scale: Double
    var easing: CameraEasing
}
