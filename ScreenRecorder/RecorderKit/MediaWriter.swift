@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

final class MediaWriter: @unchecked Sendable {
    private struct SampleBufferBox: @unchecked Sendable {
        let value: CMSampleBuffer
    }

    private let queue = DispatchQueue(label: "com.screenrecorder.media-writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var hasStarted = false
    private var isPaused = false
    private var pauseStartedAt: CMTime?
    private var accumulatedPause = CMTime.zero
    private var latestPresentationTime = CMTime.invalid
    private var firstPresentationTime = CMTime.invalid
    private var capturedFrames = 0
    private var encodedFrames = 0
    private var droppedFrames = 0
    private var totalProcessingSeconds = 0.0

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: VideoCodec,
        includesSystemAudio: Bool
    ) throws {
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw RecorderError.encoderInitializationFailed(error.localizedDescription)
        }
        let codecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
        let bitrate = max(8_000_000, min(45_000_000, width * height * frameRate / 5))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: codec == .hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.encoderInitializationFailed("AVAssetWriter rejected HEVC video settings")
        }
        writer.add(videoInput)

        if includesSystemAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.encoderInitializationFailed("AVAssetWriter rejected system audio settings")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, dropped: Bool) {
        let sample = SampleBufferBox(value: sampleBuffer)
        queue.async { [self] in
            capturedFrames += 1
            if dropped {
                droppedFrames += 1
                return
            }
            append(sample.value, to: videoInput, countsAsVideo: true)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioInput != nil else { return }
        let sample = SampleBufferBox(value: sampleBuffer)
        queue.async { [self] in
            guard let audioInput else { return }
            append(sample.value, to: audioInput, countsAsVideo: false)
        }
    }

    func pause() {
        queue.async { [self] in
            isPaused = true
            pauseStartedAt = nil
        }
    }

    func resume() {
        queue.async { [self] in isPaused = false }
    }

    func finish() async throws -> RecordingMetrics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard hasStarted else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecorderError.writerFailed("No complete video frames were received"))
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: metricsSnapshot())
                    } else {
                        continuation.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "Unknown writer failure"))
                    }
                }
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput, countsAsVideo: Bool) {
        let started = CFAbsoluteTimeGetCurrent()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = presentationTime }
            return
        }
        if let pauseStartedAt {
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(presentationTime, pauseStartedAt))
            self.pauseStartedAt = nil
        }

        guard ensureWritingStarted(at: presentationTime), input.isReadyForMoreMediaData else {
            if countsAsVideo { droppedFrames += 1 }
            return
        }
        do {
            let adjusted = try retimed(sampleBuffer, subtracting: accumulatedPause)
            if input.append(adjusted) {
                latestPresentationTime = CMTimeSubtract(presentationTime, accumulatedPause)
                if countsAsVideo { encodedFrames += 1 }
            } else if countsAsVideo {
                droppedFrames += 1
            }
        } catch {
            if countsAsVideo { droppedFrames += 1 }
            Log.encoder.error("Failed to retime sample: \(error.localizedDescription)")
        }
        totalProcessingSeconds += CFAbsoluteTimeGetCurrent() - started
    }

    private func ensureWritingStarted(at time: CMTime) -> Bool {
        if hasStarted { return writer.status == .writing }
        guard writer.startWriting() else {
            Log.encoder.error("Could not start writer: \(self.writer.error?.localizedDescription ?? "unknown")")
            return false
        }
        writer.startSession(atSourceTime: time)
        firstPresentationTime = time
        latestPresentationTime = time
        hasStarted = true
        Log.encoder.info("Hardware-backed asset writer session started")
        return true
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer, subtracting offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { throw RecorderError.writerFailed("CMSampleBuffer retiming failed (\(status))") }
        return copy
    }

    private func metricsSnapshot() -> RecordingMetrics {
        let duration = latestPresentationTime.isValid && firstPresentationTime.isValid
            ? max(0, CMTimeGetSeconds(CMTimeSubtract(latestPresentationTime, firstPresentationTime)))
            : 0
        return RecordingMetrics(
            capturedFrames: capturedFrames,
            encodedFrames: encodedFrames,
            droppedFrames: droppedFrames,
            averageProcessingMilliseconds: encodedFrames > 0 ? totalProcessingSeconds / Double(encodedFrames) * 1_000 : 0,
            elapsedSeconds: duration,
            eventCount: 0
        )
    }
}
