import AVFoundation
import AVKit
import SwiftUI

private final class PlayerTimeObserver: @unchecked Sendable {
    let player: AVPlayer
    let token: Any

    init(player: AVPlayer, token: Any) {
        self.player = player
        self.token = token
    }

    deinit { player.removeTimeObserver(token) }
}

@MainActor
private final class PlaybackModel: ObservableObject {
    let player: AVPlayer
    @Published var currentTime = 0.0
    private var observation: PlayerTimeObserver?

    init(url: URL) {
        player = AVPlayer(url: url)
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in self?.currentTime = max(0, time.seconds) }
        }
        observation = PlayerTimeObserver(player: player, token: token)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }
}

struct EditorView: View {
    let openProject: OpenProject
    let close: () -> Void
    @StateObject private var playback: PlaybackModel
    @State private var timeline: Timeline
    @State private var selectedClipID: UUID?

    init(openProject: OpenProject, close: @escaping () -> Void) {
        self.openProject = openProject
        self.close = close
        let mediaURL = openProject.packageURL.appending(path: openProject.project.media.screen)
        _playback = StateObject(wrappedValue: PlaybackModel(url: mediaURL))
        _timeline = State(initialValue: openProject.project.timeline)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VideoPlayer(player: playback.player)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            Divider()
            TimelineCanvas(
                timeline: timeline,
                cameraKeyframes: openProject.project.cameraKeyframes,
                events: openProject.events,
                playhead: playback.currentTime,
                selectedClipID: selectedClipID,
                seek: playback.seek,
                select: { selectedClipID = $0 }
            )
            .frame(height: 190)
            .padding(.horizontal, 18)
            eventSummary
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: close) { Image(systemName: "chevron.left") }
            Text(openProject.packageURL.deletingPathExtension().lastPathComponent)
                .font(.headline)
            Spacer()
            Button {
                playback.player.timeControlStatus == .playing ? playback.player.pause() : playback.player.play()
            } label: {
                Label("Play/Pause", systemImage: playback.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
            }
            Button("Split") { splitSelectedClip() }
                .disabled(selectedClipID == nil)
            Button("Trim Start") { trimStart() }
                .disabled(selectedClipID == nil)
            Text("HEVC source · \(openProject.project.settings.frameRate) FPS")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(14)
    }

    private var eventSummary: some View {
        HStack {
            Label("\(openProject.events.count) interaction events", systemImage: "cursorarrow.motionlines")
            Text("·")
            Text("\(openProject.events.filter { $0.type == .click }.count) clicks")
            Text("·")
            Text("\(openProject.project.cameraKeyframes.filter { $0.scale > 1 }.count) zoom regions")
            Spacer()
            Text(openProject.packageURL.path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func splitSelectedClip() {
        guard let selectedClipID else { return }
        timeline.split(clipID: selectedClipID, at: playback.currentTime)
    }

    private func trimStart() {
        guard let selectedClipID,
              let index = timeline.clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let clip = timeline.clips[index]
        let sourceTime = clip.sourceStart + max(0, playback.currentTime - clip.timelineStart)
        timeline.clips[index].trimStart(to: sourceTime)
        timeline.rippleLayout()
    }
}

private struct TimelineCanvas: View {
    let timeline: Timeline
    let cameraKeyframes: [CameraKeyframe]
    let events: [InteractionEvent]
    let playhead: Double
    let selectedClipID: UUID?
    let seek: (Double) -> Void
    let select: (UUID?) -> Void

    private let labelWidth = 72.0

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = time(at: value.location.x, width: proxy.size.width)
                seek(time)
                if value.location.y < 72 {
                    select(timeline.clips.first(where: { time >= $0.timelineStart && time <= $0.timelineStart + $0.duration })?.id)
                }
            })
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Project timeline")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let duration = max(timeline.duration, 0.001)
        let trackWidth = max(1, size.width - labelWidth - 12)
        let rows: [(String, Double)] = [("VIDEO", 38), ("CAMERA", 73), ("CURSOR", 108), ("AUDIO", 143)]
        for (label, y) in rows {
            context.draw(Text(label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 34, y: y + 11))
            let lane = CGRect(x: labelWidth, y: y, width: trackWidth, height: 23)
            context.fill(Path(roundedRect: lane, cornerRadius: 4), with: .color(.black.opacity(0.08)))
        }

        for clip in timeline.clips {
            let x = labelWidth + clip.timelineStart / duration * trackWidth
            let width = max(2, clip.duration / duration * trackWidth)
            let rect = CGRect(x: x, y: 38, width: width, height: 23)
            let color: Color = clip.id == selectedClipID ? .accentColor : .blue.opacity(0.65)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color))
        }

        for (index, frame) in cameraKeyframes.enumerated() where frame.scale > 1 {
            let nextTime = index + 1 < cameraKeyframes.count ? cameraKeyframes[index + 1].time : min(duration, frame.time + 1)
            let rect = CGRect(
                x: labelWidth + frame.time / duration * trackWidth,
                y: 73,
                width: max(3, (nextTime - frame.time) / duration * trackWidth),
                height: 23
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.purple.opacity(0.8)))
        }

        for event in events where event.type == .mouseMove || event.type == .click {
            let x = labelWidth + event.timestamp / duration * trackWidth
            let height = event.type == .click ? 20.0 : 7.0
            let color: Color = event.type == .click ? .orange : .secondary.opacity(0.4)
            context.fill(Path(CGRect(x: x, y: 108 + (23 - height) / 2, width: event.type == .click ? 2 : 1, height: height)), with: .color(color))
        }

        let audioPath = Path { path in
            path.move(to: CGPoint(x: labelWidth, y: 154))
            let segments = 80
            for index in 0...segments {
                let x = labelWidth + Double(index) / Double(segments) * trackWidth
                let y = 154 + sin(Double(index) * 1.7) * 7 * (0.4 + Double(index % 5) / 8)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(audioPath, with: .color(.green.opacity(0.75)), lineWidth: 1)

        let playheadX = labelWidth + min(max(playhead / duration, 0), 1) * trackWidth
        context.stroke(Path { path in
            path.move(to: CGPoint(x: playheadX, y: 24))
            path.addLine(to: CGPoint(x: playheadX, y: 172))
        }, with: .color(.red), lineWidth: 1)
        context.fill(Path(CGRect(x: playheadX - 4, y: 22, width: 8, height: 8)), with: .color(.red))

        context.draw(Text(format(0)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: labelWidth, y: 12), anchor: .leading)
        context.draw(Text(format(duration)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: size.width - 12, y: 12), anchor: .trailing)
    }

    private func time(at x: Double, width: Double) -> Double {
        let fraction = min(max((x - labelWidth) / max(1, width - labelWidth - 12), 0), 1)
        return fraction * timeline.duration
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
