import CoreGraphics
import Foundation

actor RecordingSession {
    private let projectStore: ProjectStore
    private let captureEngine: ScreenCaptureEngine
    private let interactionRecorder: InteractionRecorder
    private var configuration: RecordingConfiguration?
    private var package: ProjectPackage?
    private var details: CaptureDetails?
    private var state: RecordingState = .idle
    private var observers: [UUID: AsyncStream<RecordingState>.Continuation] = [:]

    init(
        projectStore: ProjectStore = ProjectStore(),
        captureEngine: ScreenCaptureEngine = ScreenCaptureEngine(),
        interactionRecorder: InteractionRecorder = InteractionRecorder()
    ) {
        self.projectStore = projectStore
        self.captureEngine = captureEngine
        self.interactionRecorder = interactionRecorder
    }

    func states() -> AsyncStream<RecordingState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func start(configuration: RecordingConfiguration) async throws {
        guard state == .idle || isTerminal(state) else { throw RecorderError.invalidState }
        guard CGPreflightScreenCaptureAccess() else {
            let error = RecorderError.permissionDenied("Screen Recording")
            transition(to: .failed(error))
            throw error
        }
        guard !configuration.captureMicrophone else {
            let error = RecorderError.captureFailed("Microphone capture is not enabled in this milestone")
            transition(to: .failed(error))
            throw error
        }

        transition(to: .preparing)
        do {
            let package = try await projectStore.createPackage()
            let details = try await captureEngine.start(
                configuration: configuration,
                outputURL: package.screenMediaURL,
                failureHandler: { [weak self] error in
                    Task { await self?.captureDidFail(error) }
                }
            )
            interactionRecorder.start(displayFrame: details.displayFrame)
            self.package = package
            self.configuration = configuration
            self.details = details
            transition(to: .recording)
        } catch let error as RecorderError {
            transition(to: .failed(error))
            throw error
        } catch {
            let recorderError = RecorderError.captureFailed(error.localizedDescription)
            transition(to: .failed(recorderError))
            throw recorderError
        }
    }

    func pause() throws {
        guard state == .recording else { throw RecorderError.invalidState }
        captureEngine.pause()
        interactionRecorder.pause()
        transition(to: .paused)
    }

    func resume() throws {
        guard state == .paused else { throw RecorderError.invalidState }
        captureEngine.resume()
        interactionRecorder.resume()
        transition(to: .recording)
    }

    func stop() async throws -> URL {
        guard state == .recording || state == .paused,
              let package,
              let configuration,
              let details else { throw RecorderError.invalidState }
        if state == .paused {
            captureEngine.resume()
            interactionRecorder.resume()
        }
        transition(to: .stopping)
        do {
            let events = interactionRecorder.stop()
            var metrics = try await captureEngine.stop()
            metrics.eventCount = events.count
            let duration = metrics.elapsedSeconds
            let director = AutoDirector()
            let intents = director.makeIntents(from: events, duration: duration)
            let keyframes = director.makeKeyframes(from: intents, duration: duration)
            let mediaID = UUID()
            let timeline = Timeline(clips: [TimelineClip(
                id: UUID(),
                sourceMediaID: mediaID,
                sourceStart: 0,
                sourceEnd: duration,
                timelineStart: 0
            )])
            let project = ScreenProject(
                id: UUID(),
                createdAt: Date(),
                duration: duration,
                media: ProjectMedia(screen: "media/screen.mov", microphone: nil, systemAudio: nil),
                settings: ProjectSettings(
                    canvas: CanvasSize(width: details.outputWidth, height: details.outputHeight),
                    sourceDisplay: CanvasSize(width: details.sourceWidth, height: details.sourceHeight),
                    frameRate: configuration.frameRate,
                    codec: configuration.codec
                ),
                recording: RecordingMetadata(
                    eventsPath: "metadata/events.json",
                    eventCount: events.count,
                    droppedVideoFrames: metrics.droppedFrames
                ),
                cameraKeyframes: keyframes,
                timeline: timeline
            )
            try await projectStore.save(project: project, events: events, to: package)
            resetOwnedResources()
            transition(to: .finished(package.rootURL))
            return package.rootURL
        } catch let error as RecorderError {
            transition(to: .failed(error))
            throw error
        } catch {
            let recorderError = RecorderError.writerFailed(error.localizedDescription)
            transition(to: .failed(recorderError))
            throw recorderError
        }
    }

    func reset() {
        guard isTerminal(state) else { return }
        transition(to: .idle)
    }

    private func transition(to newState: RecordingState) {
        state = newState
        observers.values.forEach { $0.yield(newState) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func captureDidFail(_ error: RecorderError) {
        _ = interactionRecorder.stop()
        transition(to: .failed(error))
    }

    private func resetOwnedResources() {
        configuration = nil
        package = nil
        details = nil
    }

    private func isTerminal(_ state: RecordingState) -> Bool {
        switch state {
        case .finished, .failed: true
        default: false
        }
    }
}
