import Foundation

enum SmartEditAnalyzer {
    static func timelineWaveform(
        sourceWaveform: [Double],
        sourceDuration: Double,
        timeline: Timeline,
        importedMediaIDs: Set<UUID>
    ) -> [Double] {
        guard !sourceWaveform.isEmpty, sourceDuration > 0, timeline.duration > 0 else { return [] }
        return sourceWaveform.indices.map { index in
            let timelineTime = timeline.duration * (Double(index) + 0.5) / Double(sourceWaveform.count)
            guard let clip = timeline.clip(at: timelineTime),
                  !importedMediaIDs.contains(clip.sourceMediaID),
                  let sourceTime = timeline.sourceTime(at: timelineTime) else { return 1 }
            let sourceIndex = min(
                sourceWaveform.count - 1,
                max(0, Int(sourceTime / sourceDuration * Double(sourceWaveform.count)))
            )
            return sourceWaveform[sourceIndex]
        }
    }

    static func silentRanges(
        waveform: [Double],
        duration: Double,
        threshold: Double = 0.07,
        minimumDuration: Double = 0.65,
        preserveEdge: Double = 0.08
    ) -> [ClosedRange<Double>] {
        guard !waveform.isEmpty, duration > 0 else { return [] }
        let bucket = duration / Double(waveform.count)
        var result: [ClosedRange<Double>] = []
        var startIndex: Int?
        for index in 0...waveform.count {
            let silent = index < waveform.count && waveform[index] <= threshold
            if silent, startIndex == nil { startIndex = index }
            if !silent, let start = startIndex {
                let rawStart = Double(start) * bucket
                let rawEnd = Double(index) * bucket
                if rawEnd - rawStart >= minimumDuration {
                    let lower = min(duration, rawStart + preserveEdge)
                    let upper = max(lower, min(duration, rawEnd - preserveEdge))
                    if upper - lower >= 0.05 { result.append(lower...upper) }
                }
                startIndex = nil
            }
        }
        return result
    }
}
