import Foundation

struct AutoDirector: Sendable {
    var clickZoom = 1.55
    var mergeDistance = 0.12
    var mergeWindow = 2.0
    var clickAnticipation = 0.32
    var keyAnticipation = 0.28
    var returnDelay = 2.5
    var typingReturnDelay = 3.5
    var typingBurstWindow = 1.0

    func makeIntents(from events: [InteractionEvent], duration: Double) -> [CameraIntent] {
        let ordered = events.sorted { $0.timestamp < $1.timestamp }
        let clicks = ordered.filter { $0.type == .click }
        let keys = ordered.filter { $0.type == .keyActivity }
        var consumedKeys = Set<UUID>()
        var intents: [CameraIntent] = []

        for click in clicks where click.timestamp >= 0 {
            guard let target = target(for: click, in: ordered) else { continue }
            let followingKeys = keys.filter {
                $0.timestamp >= click.timestamp && $0.timestamp <= click.timestamp + 1.5
            }
            consumedKeys.formUnion(followingKeys.map(\.id))
            let isTyping = !followingKeys.isEmpty
            let lastActivity = followingKeys.last?.timestamp ?? click.timestamp
            let intent = CameraIntent(
                startTime: max(0, click.timestamp - clickAnticipation),
                focusTime: click.timestamp,
                endTime: min(
                    isTyping ? lastActivity + typingReturnDelay : click.timestamp + returnDelay,
                    duration
                ),
                normalizedTargetX: target.x,
                normalizedTargetY: target.y,
                zoom: clickZoom,
                reason: isTyping ? .textInput : .click,
                priority: isTyping ? 4 : 3
            )
            appendOrMerge(intent, into: &intents)
        }

        let remainingKeys = keys.filter { !consumedKeys.contains($0.id) && $0.timestamp >= 0 }
        var keyIndex = 0
        while keyIndex < remainingKeys.count {
            let first = remainingKeys[keyIndex]
            var last = first
            var nextIndex = keyIndex + 1
            while nextIndex < remainingKeys.count,
                  remainingKeys[nextIndex].timestamp - last.timestamp <= typingBurstWindow {
                last = remainingKeys[nextIndex]
                nextIndex += 1
            }
            if let target = target(for: first, in: ordered) {
                appendOrMerge(CameraIntent(
                    startTime: max(0, first.timestamp - keyAnticipation),
                    focusTime: first.timestamp,
                    endTime: min(last.timestamp + typingReturnDelay, duration),
                    normalizedTargetX: target.x,
                    normalizedTargetY: target.y,
                    zoom: clickZoom,
                    reason: .textInput,
                    priority: 4
                ), into: &intents)
            }
            keyIndex = nextIndex
        }

        return intents.sorted { $0.startTime < $1.startTime }
    }

    func makeKeyframes(from intents: [CameraIntent], duration: Double) -> [CameraKeyframe] {
        var result = [baseFrame(at: 0)]
        let ordered = intents.sorted { $0.startTime < $1.startTime }

        for (index, intent) in ordered.enumerated() {
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].startTime : duration
            let end = min(intent.endTime, max(intent.focusTime, nextStart))
            let exitDuration = min(0.3, max(0.12, (end - intent.focusTime) * 0.2))
            let holdEnd = max(intent.focusTime, end - exitDuration)

            // This duplicate base state is intentional: it prevents interpolation
            // from panning the camera during the idle time before an interaction.
            result.append(baseFrame(at: intent.startTime))
            result.append(CameraKeyframe(
                time: intent.focusTime,
                centerX: intent.normalizedTargetX,
                centerY: intent.normalizedTargetY,
                scale: intent.zoom,
                easing: .easeInOut
            ))
            if holdEnd > intent.focusTime {
                result.append(CameraKeyframe(
                    time: holdEnd,
                    centerX: intent.normalizedTargetX,
                    centerY: intent.normalizedTargetY,
                    scale: intent.zoom,
                    easing: .linear
                ))
            }
            result.append(baseFrame(at: end))
        }

        if result.last?.time != duration { result.append(baseFrame(at: duration)) }
        return result.sorted { $0.time < $1.time }
    }

    private func target(for event: InteractionEvent, in events: [InteractionEvent]) -> CGPoint? {
        if let x = event.normalizedX, let y = event.normalizedY { return CGPoint(x: x, y: y) }
        guard let pointer = events.last(where: {
            $0.timestamp <= event.timestamp && $0.normalizedX != nil && $0.normalizedY != nil &&
            ($0.type == .mouseMove || $0.type == .mouseDown || $0.type == .mouseUp || $0.type == .click)
        }), let x = pointer.normalizedX, let y = pointer.normalizedY else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func appendOrMerge(_ intent: CameraIntent, into intents: inout [CameraIntent]) {
        if let last = intents.last,
           intent.startTime - last.focusTime <= mergeWindow,
           hypot(intent.normalizedTargetX - last.normalizedTargetX,
                 intent.normalizedTargetY - last.normalizedTargetY) <= mergeDistance {
            var merged = last
            merged.endTime = max(last.endTime, intent.endTime)
            merged.normalizedTargetX = (last.normalizedTargetX + intent.normalizedTargetX) / 2
            merged.normalizedTargetY = (last.normalizedTargetY + intent.normalizedTargetY) / 2
            merged.reason = intent.reason == .textInput ? .textInput : last.reason
            merged.priority = max(last.priority, intent.priority)
            intents[intents.count - 1] = merged
        } else {
            intents.append(intent)
        }
    }

    private func baseFrame(at time: Double) -> CameraKeyframe {
        CameraKeyframe(time: time, centerX: 0.5, centerY: 0.5, scale: 1, easing: .easeInOut)
    }
}
