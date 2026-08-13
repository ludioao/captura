import AVFoundation
import SwiftUI

@MainActor
private final class FloatingPreviewModel: ObservableObject {
    let screenPlayer: AVPlayer
    let cameraPlayer: AVPlayer?
    @Published var isPlaying = false

    init(openProject: OpenProject) {
        screenPlayer = AVPlayer(url: openProject.packageURL.appending(path: openProject.project.media.screen))
        cameraPlayer = openProject.project.media.camera.map {
            AVPlayer(url: openProject.packageURL.appending(path: $0))
        }
    }

    func play() {
        screenPlayer.play()
        cameraPlayer?.play()
        isPlaying = true
    }

    func toggle() {
        if isPlaying {
            screenPlayer.pause()
            cameraPlayer?.pause()
        } else {
            screenPlayer.play()
            cameraPlayer?.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        screenPlayer.pause()
        cameraPlayer?.pause()
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
                allowsCameraDragging: false
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
}
