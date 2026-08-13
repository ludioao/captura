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

struct CameraKeyframeInterpolator: Sendable {
    func value(at time: Double, frames: [CameraKeyframe]) -> CameraKeyframe? {
        let sorted = frames.sorted { $0.time < $1.time }
        guard let nextIndex = sorted.firstIndex(where: { $0.time >= time }) else { return sorted.last }
        guard nextIndex > 0 else { return sorted.first }
        let previous = sorted[nextIndex - 1]
        let next = sorted[nextIndex]
        let span = max(next.time - previous.time, .ulpOfOne)
        var amount = min(max((time - previous.time) / span, 0), 1)
        if next.easing == .easeInOut || next.easing == .spring {
            amount = amount * amount * (3 - 2 * amount)
        }
        return CameraKeyframe(
            time: time,
            centerX: previous.centerX + (next.centerX - previous.centerX) * amount,
            centerY: previous.centerY + (next.centerY - previous.centerY) * amount,
            scale: previous.scale + (next.scale - previous.scale) * amount,
            easing: next.easing
        )
    }
}
