@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class ExternalDeviceCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.captura.external-device", qos: .userInteractive)
    private let session = AVCaptureSession()
    private var writer: MediaWriter?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)

    static func availableDevices() -> [ExternalDeviceChoice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices.map { ExternalDeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(
        deviceID: String,
        outputURL: URL,
        frameRate: Int,
        codec: VideoCodec,
        captureAudio: Bool,
        timeline: CaptureTimeline
    ) async throws -> CaptureDetails {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                        throw RecorderError.captureFailed("Selected external device is unavailable")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    let audioOutput = AVCaptureAudioDataOutput()
                    session.beginConfiguration()
                    session.sessionPreset = .high
                    guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
                        session.commitConfiguration()
                        throw RecorderError.captureFailed("The external device cannot provide video frames")
                    }
                    session.addInput(input)
                    session.addOutput(videoOutput)
                    if captureAudio, session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
                    videoOutput.setSampleBufferDelegate(self, queue: queue)
                    audioOutput.setSampleBufferDelegate(self, queue: queue)
                    session.commitConfiguration()

                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    self.dimensions = dimensions
                    writer = try MediaWriter(
                        outputURL: outputURL,
                        width: Int(dimensions.width),
                        height: Int(dimensions.height),
                        frameRate: frameRate,
                        codec: codec,
                        includesSystemAudio: captureAudio && session.outputs.contains(audioOutput),
                        includesMicrophone: false,
                        timeline: timeline
                    )
                    self.videoOutput = videoOutput
                    self.audioOutput = audioOutput
                    session.startRunning()
                    continuation.resume(returning: CaptureDetails(
                        displayFrame: CGRect(x: 0, y: 0, width: Int(dimensions.width), height: Int(dimensions.height)),
                        sourceWidth: Int(dimensions.width), sourceHeight: Int(dimensions.height),
                        outputWidth: Int(dimensions.width), outputHeight: Int(dimensions.height)
                    ))
                } catch {
                    reset()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws -> RecordingMetrics {
        if session.isRunning { session.stopRunning() }
        guard let writer else { throw RecorderError.invalidState }
        self.writer = nil
        let metrics = try await writer.finish()
        reset()
        return metrics
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        if output === videoOutput {
            writer?.appendVideo(sampleBuffer, dropped: false)
        } else if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
        }
    }

    private func reset() {
        writer = nil
        videoOutput = nil
        audioOutput = nil
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
    }
}
