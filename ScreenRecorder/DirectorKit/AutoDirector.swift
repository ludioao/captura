import Foundation

struct AutoDirector: Sendable {
    var clickZoom = 1.55
    var mergeDistance = 0.12
    var mergeWindow = 2.0
    var returnDelay = 2.5

    func makeIntents(from events: [InteractionEvent], duration: Double) -> [CameraIntent] {
        let relevant = events.filter { $0.type == .click || $0.type == .windowFocus }
        var intents: [CameraIntent] = []

        for event in relevant {
            guard event.timestamp >= 0 else { continue }
            if event.type == .windowFocus {
                intents.append(CameraIntent(
                    startTime: event.timestamp,
                    focusTime: event.timestamp + 0.2,
                    endTime: min(event.timestamp + 0.65, duration),
                    normalizedTargetX: 0.5,
                    normalizedTargetY: 0.5,
                    zoom: 1,
                    reason: .windowChange,
                    priority: 2
                ))
                continue
            }

            guard let x = event.normalizedX, let y = event.normalizedY else { continue }
            let textActivity = events.contains {
                $0.type == .keyActivity && $0.timestamp >= event.timestamp && $0.timestamp <= event.timestamp + 1.5
            }
            let end = min(event.timestamp + (textActivity ? 4.0 : returnDelay), duration)
            let newIntent = CameraIntent(
                startTime: max(0, event.timestamp - 0.2),
                focusTime: event.timestamp + 0.25,
                endTime: end,
                normalizedTargetX: x,
                normalizedTargetY: y,
                zoom: clickZoom,
                reason: textActivity ? .textInput : .click,
                priority: textActivity ? 4 : 3
            )

            if let last = intents.last,
               last.reason != .windowChange,
               newIntent.startTime - last.focusTime <= mergeWindow,
               hypot(newIntent.normalizedTargetX - last.normalizedTargetX,
                     newIntent.normalizedTargetY - last.normalizedTargetY) <= mergeDistance {
                var merged = last
                merged.endTime = max(last.endTime, newIntent.endTime)
                merged.normalizedTargetX = (last.normalizedTargetX + newIntent.normalizedTargetX) / 2
                merged.normalizedTargetY = (last.normalizedTargetY + newIntent.normalizedTargetY) / 2
                merged.reason = newIntent.reason == .textInput ? .textInput : last.reason
                merged.priority = max(last.priority, newIntent.priority)
                intents[intents.count - 1] = merged
            } else {
                intents.append(newIntent)
            }
        }
        return intents
    }

    func makeKeyframes(from intents: [CameraIntent], duration: Double) -> [CameraKeyframe] {
        var result = [CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, scale: 1, easing: .easeInOut)]
        for intent in intents {
            if intent.reason == .windowChange {
                result.append(CameraKeyframe(time: intent.startTime, centerX: 0.5, centerY: 0.5, scale: 1, easing: .easeInOut))
                continue
            }
            result.append(CameraKeyframe(time: intent.startTime, centerX: intent.normalizedTargetX, centerY: intent.normalizedTargetY, scale: 1, easing: .easeInOut))
            result.append(CameraKeyframe(time: intent.focusTime, centerX: intent.normalizedTargetX, centerY: intent.normalizedTargetY, scale: intent.zoom, easing: .spring))
            result.append(CameraKeyframe(time: intent.endTime, centerX: intent.normalizedTargetX, centerY: intent.normalizedTargetY, scale: 1, easing: .easeInOut))
        }
        if result.last?.time != duration {
            result.append(CameraKeyframe(time: duration, centerX: 0.5, centerY: 0.5, scale: 1, easing: .easeInOut))
        }
        return result.sorted { $0.time < $1.time }
    }
}
