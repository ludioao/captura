import CoreMedia
import Foundation

/// A single host-clock timeline shared by screen, audio, microphone and webcam.
/// Screen video establishes the origin; webcam frames received while the camera
/// is warming up are ignored until that origin exists.
final class CaptureTimeline: @unchecked Sendable {
    struct Adjustment: Sendable {
        let origin: CMTime
        let pauseOffset: CMTime
    }

    private let lock = NSLock()
    private var origin: CMTime?
    private var pauseStartedAt: CMTime?
    private var accumulatedPause = CMTime.zero

    @discardableResult
    func beginIfNeeded(at presentationTime: CMTime) -> CMTime {
        withLock {
            if origin == nil { origin = presentationTime }
            return origin ?? presentationTime
        }
    }

    func adjustment(for presentationTime: CMTime) -> Adjustment? {
        withLock {
            guard let origin else { return nil }
            if let pauseStartedAt, CMTimeCompare(presentationTime, pauseStartedAt) >= 0 {
                return nil
            }
            return Adjustment(origin: origin, pauseOffset: accumulatedPause)
        }
    }

    func pause(at hostTime: CMTime = CaptureTimeline.currentHostTime()) {
        withLock {
            guard pauseStartedAt == nil else { return }
            pauseStartedAt = hostTime
        }
    }

    func resume(at hostTime: CMTime = CaptureTimeline.currentHostTime()) {
        withLock {
            guard let pauseStartedAt else { return }
            let pauseDuration = CMTimeMaximum(.zero, CMTimeSubtract(hostTime, pauseStartedAt))
            accumulatedPause = CMTimeAdd(accumulatedPause, pauseDuration)
            self.pauseStartedAt = nil
        }
    }

    static func currentHostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
