@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

final class WebcamCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private struct WriterBox: @unchecked Sendable {
        let value: AVAssetWriter
    }

    private let queue = DispatchQueue(label: "com.captura.webcam", qos: .userInitiated)
    private let session = AVCaptureSession()

    var previewSession: AVCaptureSession { session }
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var hasStartedWriting = false
    private var isPaused = false
    private var pauseStartedAt: CMTime?
    private var accumulatedPause = CMTime.zero

    func start(deviceID: String, outputURL: URL, frameRate: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                        throw RecorderError.captureFailed("Selected webcam is unavailable")
                    }
                    let deviceInput = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]

                    session.beginConfiguration()
                    session.sessionPreset = .high
                    guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw RecorderError.captureFailed("Webcam input/output configuration is unsupported")
                    }
                    session.addInput(deviceInput)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: queue)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                    session.commitConfiguration()

                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                    let settings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoWidthKey: Int(dimensions.width),
                        AVVideoHeightKey: Int(dimensions.height),
                        AVVideoEncoderSpecificationKey: [
                            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
                        ],
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: 5_000_000,
                            AVVideoExpectedSourceFrameRateKey: frameRate,
                            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
                        ]
                    ]
                    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                    writerInput.expectsMediaDataInRealTime = true
                    guard writer.canAdd(writerInput) else {
                        throw RecorderError.encoderInitializationFailed("Webcam HEVC writer rejected its video input")
                    }
                    writer.add(writerInput)
                    self.writer = writer
                    self.writerInput = writerInput
                    session.startRunning()
                    Log.capture.info("Webcam capture started using \(device.localizedName, privacy: .public)")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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

    func stop() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                guard let writer, let writerInput else {
                    continuation.resume()
                    return
                }
                guard hasStartedWriting else {
                    writer.cancelWriting()
                    reset()
                    continuation.resume(throwing: RecorderError.writerFailed("Webcam produced no complete frames"))
                    return
                }
                writerInput.markAsFinished()
                let writerBox = WriterBox(value: writer)
                reset()
                writerBox.value.finishWriting {
                    guard writerBox.value.status == .completed else {
                        continuation.resume(throwing: RecorderError.writerFailed(writerBox.value.error?.localizedDescription ?? "Webcam writer failed"))
                        return
                    }
                    continuation.resume()
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let writer, let writerInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused {
            if pauseStartedAt == nil { pauseStartedAt = time }
            return
        }
        if let pauseStartedAt {
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(time, pauseStartedAt))
            self.pauseStartedAt = nil
        }
        if !hasStartedWriting {
            guard writer.startWriting() else {
                Log.encoder.error("Webcam writer failed to start: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writer.startSession(atSourceTime: time)
            hasStartedWriting = true
        }
        guard writerInput.isReadyForMoreMediaData else { return }
        do {
            let adjusted = try retimed(sampleBuffer, subtracting: accumulatedPause)
            if !writerInput.append(adjusted) {
                Log.encoder.error("Webcam frame append failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
        } catch {
            Log.encoder.error("Webcam timestamp adjustment failed: \(error.localizedDescription)")
        }
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer, subtracting offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
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
        guard status == noErr, let copy else {
            throw RecorderError.writerFailed("Webcam sample retiming failed (\(status))")
        }
        return copy
    }

    private func reset() {
        writer = nil
        writerInput = nil
        hasStartedWriting = false
        isPaused = false
        pauseStartedAt = nil
        accumulatedPause = .zero
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
    }
}
