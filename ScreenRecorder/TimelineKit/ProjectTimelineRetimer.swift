import Foundation

enum ProjectTimelineRetimer {
    static func apply(to project: inout ScreenProject, removing ranges: [ClosedRange<Double>]) {
        let map = RemovedTimeMap(ranges: ranges, duration: project.duration)
        guard !map.ranges.isEmpty else { return }

        project.timeline.remove(timeRanges: map.ranges)
        project.captions = project.captions?.flatMap { cue in
            map.fragments(of: cue.startTime...cue.endTime).map {
                CaptionCue(startTime: $0.new.lowerBound, endTime: $0.new.upperBound, text: cue.text)
            }
        }
        project.overlays = project.overlays?.flatMap { item in
            map.fragments(of: item.startTime...item.endTime).map {
                OverlayRegion(
                    startTime: $0.new.lowerBound, endTime: $0.new.upperBound,
                    normalizedX: item.normalizedX, normalizedY: item.normalizedY,
                    normalizedWidth: item.normalizedWidth, normalizedHeight: item.normalizedHeight,
                    kind: item.kind
                )
            }
        }
        project.textOverlays = project.textOverlays?.flatMap { item in
            map.fragments(of: item.startTime...item.endTime).map { fragment in
                var copy = item
                copy.id = UUID()
                copy.startTime = fragment.new.lowerBound
                copy.endTime = fragment.new.upperBound
                return copy
            }
        }
        project.brandingOverlays = project.brandingOverlays?.flatMap { item in
            map.fragments(of: item.startTime...item.endTime).map { fragment in
                var copy = item
                copy.id = UUID()
                copy.startTime = fragment.new.lowerBound
                copy.endTime = fragment.new.upperBound
                return copy
            }
        }
        project.layoutSegments = project.layoutSegments?.flatMap { item in
            map.fragments(of: item.startTime...item.endTime).map { fragment in
                var copy = item
                copy.id = UUID()
                copy.startTime = fragment.new.lowerBound
                copy.endTime = fragment.new.upperBound
                return copy
            }
        }
        project.audioAssets = project.audioAssets?.flatMap { item in
            map.fragments(of: item.startTime...(item.startTime + item.duration)).map { fragment in
                var copy = item
                copy.id = UUID()
                copy.startTime = fragment.new.lowerBound
                copy.sourceStart += fragment.old.lowerBound - item.startTime
                copy.duration = fragment.old.upperBound - fragment.old.lowerBound
                return copy
            }
        }
        project.webcamKeyframes = project.webcamKeyframes?.compactMap { frame in
            guard !map.contains(frame.time) else { return nil }
            var copy = frame
            copy.time = map.time(frame.time)
            return copy
        }
        project.visualKeyframes = project.visualKeyframes?.compactMap { frame in
            guard !map.contains(frame.time) else { return nil }
            var copy = frame
            copy.time = map.time(frame.time)
            return copy
        }
        project.duration = project.timeline.duration
    }
}

struct RemovedTimeMap: Sendable {
    struct Fragment: Sendable {
        var old: ClosedRange<Double>
        var new: ClosedRange<Double>
    }

    let ranges: [ClosedRange<Double>]

    init(ranges: [ClosedRange<Double>], duration: Double) {
        let valid = ranges
            .map { max(0, $0.lowerBound)...min(max(0, duration), $0.upperBound) }
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in valid {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        self.ranges = merged
    }

    func contains(_ time: Double) -> Bool {
        ranges.contains { time >= $0.lowerBound && time <= $0.upperBound }
    }

    func time(_ oldTime: Double) -> Double {
        let removedBefore = ranges.reduce(0.0) { result, range in
            result + max(0, min(oldTime, range.upperBound) - range.lowerBound)
        }
        return max(0, oldTime - removedBefore)
    }

    func fragments(of interval: ClosedRange<Double>) -> [Fragment] {
        guard interval.upperBound > interval.lowerBound else { return [] }
        var cursor = interval.lowerBound
        var pieces: [ClosedRange<Double>] = []
        for range in ranges where range.upperBound > interval.lowerBound && range.lowerBound < interval.upperBound {
            if range.lowerBound > cursor {
                pieces.append(cursor...min(range.lowerBound, interval.upperBound))
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= interval.upperBound { break }
        }
        if cursor < interval.upperBound { pieces.append(cursor...interval.upperBound) }
        return pieces.filter { $0.upperBound - $0.lowerBound >= 0.01 }.map {
            Fragment(old: $0, new: time($0.lowerBound)...time($0.upperBound))
        }
    }
}
