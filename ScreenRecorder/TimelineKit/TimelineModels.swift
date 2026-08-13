import Foundation

struct TimelineClip: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var sourceMediaID: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double

    var duration: Double { max(0, sourceEnd - sourceStart) }

    mutating func trimStart(to sourceTime: Double) {
        sourceStart = min(max(sourceTime, sourceStart), sourceEnd)
    }

    mutating func trimEnd(to sourceTime: Double) {
        sourceEnd = max(min(sourceTime, sourceEnd), sourceStart)
    }

    func split(at timelineTime: Double) -> (TimelineClip, TimelineClip)? {
        let offset = timelineTime - timelineStart
        guard offset > 0, offset < duration else { return nil }
        let splitSourceTime = sourceStart + offset
        let left = TimelineClip(id: id, sourceMediaID: sourceMediaID, sourceStart: sourceStart, sourceEnd: splitSourceTime, timelineStart: timelineStart)
        let right = TimelineClip(id: UUID(), sourceMediaID: sourceMediaID, sourceStart: splitSourceTime, sourceEnd: sourceEnd, timelineStart: timelineTime)
        return (left, right)
    }
}

struct Timeline: Codable, Hashable, Sendable {
    var clips: [TimelineClip]

    var duration: Double {
        clips.map { $0.timelineStart + $0.duration }.max() ?? 0
    }

    mutating func split(clipID: UUID, at timelineTime: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }),
              let halves = clips[index].split(at: timelineTime) else { return }
        clips.replaceSubrange(index...index, with: [halves.0, halves.1])
    }

    mutating func delete(clipID: UUID) {
        clips.removeAll { $0.id == clipID }
        rippleLayout()
    }

    mutating func rippleLayout() {
        var cursor = 0.0
        for index in clips.indices {
            clips[index].timelineStart = cursor
            cursor += clips[index].duration
        }
    }
}
