@preconcurrency import AVFoundation
import CoreMedia

@MainActor
enum SynchronizedPlayback {
    static func configure(_ primary: AVPlayer, _ secondary: AVPlayer?) {
        primary.automaticallyWaitsToMinimizeStalling = false
        secondary?.automaticallyWaitsToMinimizeStalling = false
    }

    static func play(_ primary: AVPlayer, _ secondary: AVPlayer?, at itemTime: CMTime? = nil) {
        let time = itemTime ?? primary.currentTime()
        let leadTime = CMTime(value: 80, timescale: 1_000)
        let hostTime = CMTimeAdd(CaptureTimeline.currentHostTime(), leadTime)
        primary.setRate(1, time: time, atHostTime: hostTime)
        secondary?.setRate(1, time: time, atHostTime: hostTime)
    }

    static func pause(_ primary: AVPlayer, _ secondary: AVPlayer?) {
        primary.pause()
        secondary?.pause()
    }

    static func seek(_ primary: AVPlayer, _ secondary: AVPlayer?, to time: CMTime) {
        let wasPlaying = primary.timeControlStatus == .playing
        pause(primary, secondary)
        primary.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        secondary?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { play(primary, secondary, at: time) }
    }
}
