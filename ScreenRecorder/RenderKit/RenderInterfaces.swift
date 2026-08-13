import CoreMedia
import CoreVideo
import Foundation

/// The Metal compositor consumes pixel buffers without converting them to images.
protocol FrameCompositor: Sendable {
    func render(
        source: CVPixelBuffer,
        at time: CMTime,
        camera: CameraKeyframe?,
        cursor: CursorSample?
    ) async throws -> CVPixelBuffer
}

struct CursorInterpolator: Sendable {
    func sample(at time: Double, from samples: [CursorSample]) -> CursorSample? {
        guard let nextIndex = samples.firstIndex(where: { $0.time >= time }) else { return samples.last }
        guard nextIndex > 0 else { return samples.first }
        let previous = samples[nextIndex - 1]
        let next = samples[nextIndex]
        let span = max(next.time - previous.time, .ulpOfOne)
        let amount = min(max((time - previous.time) / span, 0), 1)
        return CursorSample(
            time: time,
            normalizedX: previous.normalizedX + (next.normalizedX - previous.normalizedX) * amount,
            normalizedY: previous.normalizedY + (next.normalizedY - previous.normalizedY) * amount,
            cursorType: next.cursorType
        )
    }
}
