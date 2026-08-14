@preconcurrency import AVFoundation
import Foundation

enum MusicAudioMix {
    static func parameters(
        track: AVAssetTrack,
        item: ProjectAudioAsset,
        insertedDuration: Double,
        narration: [CaptionCue]
    ) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let startSeconds = max(0, item.startTime)
        let duration = max(0, insertedDuration)
        let endSeconds = startSeconds + duration
        let start = time(startSeconds)
        let base = Float(min(max(item.volume, 0), 1))
        let fadeIn = min(max(item.fadeIn, 0), duration / 2)
        let fadeOut = min(max(item.fadeOut, 0), duration / 2)

        parameters.setVolume(base, at: start)
        if fadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: base,
                timeRange: CMTimeRange(start: start, duration: time(fadeIn))
            )
        }
        if fadeOut > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: base,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: time(endSeconds - fadeOut), duration: time(fadeOut))
            )
        }

        guard item.ducksUnderVoice else { return parameters }
        let ducked = base * 0.42
        let attack = 0.12
        let release = 0.22
        for cue in mergedNarration(narration).filter({ $0.upperBound > startSeconds && $0.lowerBound < endSeconds }) {
            let cueStart = max(startSeconds + fadeIn, cue.lowerBound)
            let cueEnd = min(endSeconds - fadeOut, cue.upperBound)
            guard cueEnd > cueStart else { continue }
            let attackStart = max(startSeconds + fadeIn, cueStart - attack)
            parameters.setVolumeRamp(
                fromStartVolume: base,
                toEndVolume: ducked,
                timeRange: CMTimeRange(start: time(attackStart), duration: time(max(0.01, cueStart - attackStart)))
            )
            parameters.setVolume(ducked, at: time(cueStart))
            let releaseEnd = min(endSeconds - fadeOut, cueEnd + release)
            parameters.setVolumeRamp(
                fromStartVolume: ducked,
                toEndVolume: base,
                timeRange: CMTimeRange(start: time(cueEnd), duration: time(max(0.01, releaseEnd - cueEnd)))
            )
        }
        return parameters
    }

    static func mergedNarration(_ cues: [CaptionCue], joinGap: Double = 0.18) -> [ClosedRange<Double>] {
        let ranges = cues
            .filter { $0.endTime > $0.startTime }
            .map { max(0, $0.startTime)...max(0, $0.endTime) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = result.last, range.lowerBound <= last.upperBound + joinGap {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 48_000)
    }
}
