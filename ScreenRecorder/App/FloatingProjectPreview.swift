import AVFoundation
import SwiftUI

private final class FloatingTimeObserver: @unchecked Sendable {
    let player: AVPlayer
    let token: Any
    init(player: AVPlayer, token: Any) { self.player = player; self.token = token }
    deinit { player.removeTimeObserver(token) }
}

@MainActor
private final class FloatingPreviewModel: ObservableObject {
    let screenPlayer: AVPlayer
    let cameraPlayer: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime = 0.0
    private var timeObserver: FloatingTimeObserver?

    init(openProject: OpenProject) {
        screenPlayer = AVPlayer(url: openProject.packageURL.appending(path: openProject.project.media.screen))
        cameraPlayer = openProject.project.media.camera.map {
            AVPlayer(url: openProject.packageURL.appending(path: $0))
        }
        SynchronizedPlayback.configure(screenPlayer, cameraPlayer)
        let token = screenPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.currentTime = max(0, time.seconds) }
        }
        timeObserver = FloatingTimeObserver(player: screenPlayer, token: token)
    }

    func play() {
        SynchronizedPlayback.play(screenPlayer, cameraPlayer)
        isPlaying = true
    }

    func toggle() {
        if isPlaying {
            SynchronizedPlayback.pause(screenPlayer, cameraPlayer)
        } else {
            SynchronizedPlayback.play(screenPlayer, cameraPlayer)
        }
        isPlaying.toggle()
    }

    func stop() {
        SynchronizedPlayback.pause(screenPlayer, cameraPlayer)
        isPlaying = false
    }
}

struct FloatingProjectPreview: View {
    let openProject: OpenProject
    @StateObject private var playback: FloatingPreviewModel

    init(openProject: OpenProject) {
        self.openProject = openProject
        _playback = StateObject(wrappedValue: FloatingPreviewModel(openProject: openProject))
    }

    var body: some View {
        VStack(spacing: 0) {
            CanvasMockupPreview(
                player: playback.screenPlayer,
                cameraPlayer: playback.cameraPlayer,
                sourceSize: openProject.project.settings.canvas,
                appearance: .constant(openProject.project.settings.appearance ?? .default),
                allowsCameraDragging: false,
                cursorSample: currentCursorSample,
                cursorAppearance: openProject.project.settings.cursor ?? .default,
                caption: activeCaption,
                cameraFrame: currentCameraFrame
            )
            .frame(width: 520, height: 292)
            HStack {
                Text(openProject.packageURL.deletingPathExtension().lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button {
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { playback.play() }
        .onDisappear { playback.stop() }
    }

    private var sourceTime: Double {
        openProject.project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime
    }

    private var currentCameraFrame: CameraKeyframe? {
        CameraKeyframeInterpolator().value(at: sourceTime, frames: openProject.project.cameraKeyframes)
    }

    private var activeCaption: String? {
        (openProject.project.captions ?? []).first {
            playback.currentTime >= $0.startTime && playback.currentTime <= $0.endTime
        }?.text
    }

    private var currentCursorSample: CursorSample? {
        let samples = openProject.events.compactMap { event -> CursorSample? in
            guard let x = event.normalizedX, let y = event.normalizedY,
                  event.type == .mouseMove || event.type == .click else { return nil }
            return CursorSample(time: event.timestamp, normalizedX: x, normalizedY: y, cursorType: .arrow)
        }
        return CursorInterpolator().sample(at: sourceTime, from: samples)
    }
}
