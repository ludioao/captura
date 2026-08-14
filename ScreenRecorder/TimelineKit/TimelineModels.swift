import Foundation

enum ClipTransitionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case fade
    case flash
    case zoom

    var displayName: String {
        switch self {
        case .fade: "Fade"
        case .flash: "Flash"
        case .zoom: "Zoom"
        }
    }
}

struct ClipTransition: Codable, Hashable, Sendable {
    var kind: ClipTransitionKind
    var duration: Double = 0.45
}

struct ActiveClipTransition: Equatable, Sendable {
    var kind: ClipTransitionKind
    var intensity: Double
}

enum VideoClipContentMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fit
    case fill
}

struct VideoClipLayout: Codable, Hashable, Sendable {
    var positionX = 0.5
    var positionY = 0.5
    var scale = 1.0
    var opacity = 1.0
    var contentMode: VideoClipContentMode = .fit

    static let `default` = VideoClipLayout()
}

struct TimelineClip: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var sourceMediaID: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double
    var speed: Double = 1
    var transitionOut: ClipTransition? = nil
    var layout: VideoClipLayout? = nil

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
        let left = TimelineClip(
            id: id, sourceMediaID: sourceMediaID, sourceStart: sourceStart,
            sourceEnd: splitSourceTime, timelineStart: timelineStart, speed: speed,
            transitionOut: nil, layout: layout
        )
        let right = TimelineClip(
            id: UUID(), sourceMediaID: sourceMediaID, sourceStart: splitSourceTime,
            sourceEnd: sourceEnd, timelineStart: timelineTime, speed: speed,
            transitionOut: transitionOut, layout: layout
        )
        return (left, right)
    }
}

extension TimelineClip {
    private enum CodingKeys: String, CodingKey {
        case id, sourceMediaID, sourceStart, sourceEnd, timelineStart, speed, transitionOut, layout
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceMediaID = try values.decode(UUID.self, forKey: .sourceMediaID)
        sourceStart = try values.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try values.decode(Double.self, forKey: .sourceEnd)
        timelineStart = try values.decode(Double.self, forKey: .timelineStart)
        speed = min(max(try values.decodeIfPresent(Double.self, forKey: .speed) ?? 1, 0.25), 4)
        transitionOut = try values.decodeIfPresent(ClipTransition.self, forKey: .transitionOut)
        layout = try values.decodeIfPresent(VideoClipLayout.self, forKey: .layout)
    }
}

struct Timeline: Codable, Hashable, Sendable {
    var clips: [TimelineClip]

    var duration: Double {
        clips.map { $0.timelineStart + $0.duration }.max() ?? 0
    }

    @discardableResult
    mutating func split(clipID: UUID, at timelineTime: Double) -> UUID? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }),
              let halves = clips[index].split(at: timelineTime) else { return nil }
        clips.replaceSubrange(index...index, with: [halves.0, halves.1])
        return halves.1.id
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

    mutating func insert(_ clip: TimelineClip, at timelineTime: Double) {
        let insertionTime = min(max(timelineTime, 0), duration)
        if let index = clips.firstIndex(where: {
            insertionTime > $0.timelineStart && insertionTime < $0.timelineStart + $0.duration
        }), let halves = clips[index].split(at: insertionTime) {
            clips.replaceSubrange(index...index, with: [halves.0, clip, halves.1])
        } else {
            clips.sort { $0.timelineStart < $1.timelineStart }
            let index = clips.firstIndex { $0.timelineStart >= insertionTime } ?? clips.endIndex
            clips.insert(clip, at: index)
        }
        rippleLayout()
    }

    func clip(at timelineTime: Double) -> TimelineClip? {
        clips.first {
            timelineTime >= $0.timelineStart && timelineTime <= $0.timelineStart + $0.duration
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

    func activeTransition(at timelineTime: Double) -> ActiveClipTransition? {
        let ordered = clips.sorted { $0.timelineStart < $1.timelineStart }
        guard ordered.count > 1 else { return nil }
        for index in 0..<(ordered.count - 1) {
            let clip = ordered[index]
            guard let transition = clip.transitionOut else { continue }
            let next = ordered[index + 1]
            let duration = min(
                max(0.12, transition.duration),
                max(0.12, clip.duration),
                max(0.12, next.duration)
            )
            let boundary = clip.timelineStart + clip.duration
            let distance = abs(timelineTime - boundary)
            guard distance <= duration / 2 else { continue }
            return ActiveClipTransition(
                kind: transition.kind,
                intensity: 1 - distance / max(duration / 2, .ulpOfOne)
            )
        }
        return nil
    }
}
