@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import Foundation

struct CaptureDetails: Sendable {
    let displayFrame: CGRect
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
}

final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.screenrecorder.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: MediaWriter?
    private var failureHandler: (@Sendable (RecorderError) -> Void)?

    static func availableDisplays() async throws -> [DisplayChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let name = display.displayID == CGMainDisplayID() ? "Main Display" : "Display \(display.displayID)"
            return DisplayChoice(id: display.displayID, name: name, width: display.width, height: display.height)
        }
    }

    static func availableWindows() async throws -> [WindowChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  window.frame.width >= 160,
                  window.frame.height >= 100 else { return nil }
            return WindowChoice(
                id: window.windowID,
                title: window.title ?? "",
                applicationName: app.applicationName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func start(
        configuration: RecordingConfiguration,
        outputURL: URL,
        failureHandler: @escaping @Sendable (RecorderError) -> Void
    ) async throws -> CaptureDetails {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let displayFrame: CGRect
        let sourceWidth: Int
        let sourceHeight: Int
        if let windowID = configuration.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.displayUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            displayFrame = window.frame
            sourceWidth = max(2, Int(window.frame.width * 2))
            sourceHeight = max(2, Int(window.frame.height * 2))
        } else {
            guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
                throw RecorderError.displayUnavailable
            }
            let excludedApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])
            displayFrame = display.frame
            sourceWidth = display.width
            sourceHeight = display.height
        }
        let output = configuration.resolution.dimensions(nativeWidth: sourceWidth, nativeHeight: sourceHeight)
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = output.width
        streamConfiguration.height = output.height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        streamConfiguration.queueDepth = 6
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = configuration.captureCursorInVideo
        streamConfiguration.capturesAudio = configuration.captureSystemAudio
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.captureMicrophone = configuration.captureMicrophone
        streamConfiguration.microphoneCaptureDeviceID = configuration.microphoneDeviceID

        let writer = try MediaWriter(
            outputURL: outputURL,
            width: output.width,
            height: output.height,
            frameRate: configuration.frameRate,
            codec: configuration.codec,
            includesSystemAudio: configuration.captureSystemAudio,
            includesMicrophone: configuration.captureMicrophone
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            if configuration.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            }
            if configuration.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
            }
            self.writer = writer
            self.stream = stream
            self.failureHandler = failureHandler
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.writer = nil
            throw RecorderError.captureFailed(error.localizedDescription)
        }
        Log.capture.info("Capture started at \(output.width)x\(output.height), \(configuration.frameRate) fps")
        return CaptureDetails(
            displayFrame: displayFrame,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: output.width,
            outputHeight: output.height
        )
    }

    func pause() { writer?.pause() }
    func resume() { writer?.resume() }

    func stop() async throws -> RecordingMetrics {
        if let stream {
            do { try await stream.stopCapture() }
            catch { Log.capture.warning("ScreenCaptureKit stop returned: \(error.localizedDescription)") }
        }
        self.stream = nil
        guard let writer else { throw RecorderError.invalidState }
        self.writer = nil
        return try await writer.finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureHandler?(.captureFailed(error.localizedDescription))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            writer?.appendVideo(sampleBuffer, dropped: frameWasDropped(sampleBuffer))
        case .audio:
            writer?.appendAudio(sampleBuffer)
        case .microphone:
            writer?.appendMicrophone(sampleBuffer)
        @unknown default:
            break
        }
    }

    private func frameWasDropped(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusNumber = attachments.first?[.status] as? NSNumber,
              let status = SCFrameStatus(rawValue: statusNumber.intValue) else { return true }
        return status != .complete
    }
}
