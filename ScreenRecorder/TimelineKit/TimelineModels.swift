import Foundation

struct TimelineClip: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var sourceMediaID: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double
    var speed: Double = 1

    var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    var duration: Double { sourceDuration / max(0.25, speed) }

    mutating func trimStart(to sourceTime: Double) {
        sourceStart = min(max(sourceTime, sourceStart), sourceEnd)
    }

    mutating func trimEnd(to sourceTime: Double) {
        sourceEnd = max(min(sourceTime, sourceEnd), sourceStart)
    }

    func split(at timelineTime: Double) -> (TimelineClip, TimelineClip)? {
        let offset = timelineTime - timelineStart
        guard offset > 0, offset < duration else { return nil }
        let splitSourceTime = sourceStart + offset * max(0.25, speed)
        let left = TimelineClip(id: id, sourceMediaID: sourceMediaID, sourceStart: sourceStart, sourceEnd: splitSourceTime, timelineStart: timelineStart, speed: speed)
        let right = TimelineClip(id: UUID(), sourceMediaID: sourceMediaID, sourceStart: splitSourceTime, sourceEnd: sourceEnd, timelineStart: timelineTime, speed: speed)
        return (left, right)
    }
}

extension TimelineClip {
    private enum CodingKeys: String, CodingKey {
        case id, sourceMediaID, sourceStart, sourceEnd, timelineStart, speed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceMediaID = try values.decode(UUID.self, forKey: .sourceMediaID)
        sourceStart = try values.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try values.decode(Double.self, forKey: .sourceEnd)
        timelineStart = try values.decode(Double.self, forKey: .timelineStart)
        speed = min(max(try values.decodeIfPresent(Double.self, forKey: .speed) ?? 1, 0.25), 4)
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

    func sourceTime(at timelineTime: Double) -> Double? {
        guard let clip = clips.first(where: {
            timelineTime >= $0.timelineStart && timelineTime <= $0.timelineStart + $0.duration
        }) else { return nil }
        return clip.sourceStart + (timelineTime - clip.timelineStart) * clip.speed
    }

    func firstTimelineTime(forSourceTime sourceTime: Double) -> Double? {
        guard let clip = clips.first(where: { sourceTime >= $0.sourceStart && sourceTime <= $0.sourceEnd }) else {
            return nil
        }
        return clip.timelineStart + (sourceTime - clip.sourceStart) / max(0.25, clip.speed)
    }
}
