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
    enum PreparationState: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    let screenPlayer: AVPlayer
    let cameraPlayer: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime = 0.0
    @Published var usesMetalPreview = false
    @Published var preparationState: PreparationState = .preparing
    private var timeObserver: FloatingTimeObserver?
    private var renderState: CapturaVideoRenderState?
    private var renderedProject: ScreenProject?
    private var latestOpenProject: OpenProject?
    private var previewRevision = 0
    private var frameRefreshTask: Task<Void, Never>?
    private var duration = 0.0

    init(openProject: OpenProject) {
        screenPlayer = AVPlayer(url: openProject.packageURL.appending(path: openProject.project.media.screen))
        cameraPlayer = openProject.project.media.camera.map {
            AVPlayer(url: openProject.packageURL.appending(path: $0))
        }
        SynchronizedPlayback.configure(screenPlayer, cameraPlayer)
        let token = screenPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds)
                if self.duration > 0, self.currentTime >= self.duration - 0.02 { self.isPlaying = false }
            }
        }
        timeObserver = FloatingTimeObserver(player: screenPlayer, token: token)
    }

    func play() {
        SynchronizedPlayback.play(screenPlayer, synchronizedCameraPlayer)
        isPlaying = true
    }

    func synchronize(openProject: OpenProject) async {
        latestOpenProject = openProject
        duration = openProject.project.duration
        guard let renderedProject else {
            await rebuild(openProject: openProject, autoplay: true)
            return
        }
        if PreviewUpdateClassifier.requiresRebuild(from: renderedProject, to: openProject.project) {
            await rebuild(openProject: openProject, autoplay: isPlaying)
        } else {
            updateLive(openProject: openProject, previousProject: renderedProject)
        }
    }

    private func rebuild(openProject: OpenProject, autoplay: Bool) async {
        previewRevision += 1
        let revision = previewRevision
        preparationState = .preparing
        let state = makeRenderState(openProject: openProject)
        do {
            let item = try await MetalPreviewCompositionBuilder.makePlayerItem(
                project: openProject.project,
                packageURL: openProject.packageURL,
                events: openProject.events,
                renderState: state
            )
            guard revision == previewRevision else { return }
            let latest = latestOpenProject ?? openProject
            state.update(
                project: latest.project,
                events: latest.events,
                geometry: renderGeometry(for: latest.project),
                brandingImages: BrandingAssetLoader.load(project: latest.project, packageURL: latest.packageURL)
            )
            let resumeTime = min(currentTime, latest.project.duration)
            renderState = state
            renderedProject = latest.project
            duration = latest.project.duration
            screenPlayer.replaceCurrentItem(with: item)
            usesMetalPreview = true
            cameraPlayer?.pause()
            preparationState = .ready
            await screenPlayer.seek(
                to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if autoplay { play() }
        } catch {
            guard revision == previewRevision else { return }
            preparationState = .failed(error.localizedDescription)
            usesMetalPreview = renderedProject != nil
            Log.render.error("Floating Metal preview failed: \(error.localizedDescription, privacy: .public)")
            if renderedProject == nil { play() }
        }
    }

    private func updateLive(openProject: OpenProject, previousProject: ScreenProject) {
        guard let renderState else { return }
        renderState.update(
            project: openProject.project,
            geometry: renderGeometry(for: openProject.project),
            brandingImages: PreviewUpdateClassifier.brandingAssetsChanged(
                from: previousProject,
                to: openProject.project
            ) ? BrandingAssetLoader.load(project: openProject.project, packageURL: openProject.packageURL) : nil
        )
        renderedProject = openProject.project
        preparationState = .ready
        refreshPausedFrame()
    }

    func toggle() {
        if isPlaying {
            SynchronizedPlayback.pause(screenPlayer, synchronizedCameraPlayer)
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            SynchronizedPlayback.play(screenPlayer, synchronizedCameraPlayer)
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let destination = min(max(seconds, 0), max(duration, 0))
        SynchronizedPlayback.seek(
            screenPlayer,
            synchronizedCameraPlayer,
            to: CMTime(seconds: destination, preferredTimescale: 600)
        )
        currentTime = destination
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        SynchronizedPlayback.pause(screenPlayer, synchronizedCameraPlayer)
        isPlaying = false
        frameRefreshTask?.cancel()
    }

    private func refreshPausedFrame() {
        guard screenPlayer.timeControlStatus == .paused else { return }
        frameRefreshTask?.cancel()
        frameRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            await screenPlayer.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func makeRenderState(openProject: OpenProject) -> CapturaVideoRenderState {
        CapturaVideoRenderState(
            project: openProject.project,
            events: openProject.events,
            geometry: renderGeometry(for: openProject.project),
            brandingImages: BrandingAssetLoader.load(project: openProject.project, packageURL: openProject.packageURL)
        )
    }

    private func renderGeometry(for project: ScreenProject) -> ExportGeometry {
        let size = CGSize(width: project.settings.canvas.width, height: project.settings.canvas.height)
        return ExportGeometry(
            outputSize: size,
            sourceSize: project.settings.canvas,
            appearance: project.settings.appearance ?? .default
        )
    }

    private var synchronizedCameraPlayer: AVPlayer? {
        usesMetalPreview ? nil : cameraPlayer
    }
}

struct FloatingProjectPreview: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let openProject: OpenProject
    @StateObject private var playback: FloatingPreviewModel
    @State private var wasPlayingBeforeScrub = false

    init(openProject: OpenProject) {
        self.openProject = openProject
        _playback = StateObject(wrappedValue: FloatingPreviewModel(openProject: openProject))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CanvasMockupPreview(
                player: playback.screenPlayer,
                cameraPlayer: playback.cameraPlayer,
                sourceSize: openProject.project.settings.canvas,
                appearance: .constant(openProject.project.settings.appearance ?? .default),
                allowsCameraDragging: false,
                cursorSample: playback.usesMetalPreview ? nil : currentCursorSample,
                cursorAppearance: openProject.project.settings.cursor ?? .default,
                caption: activeCaption,
                cameraFrame: playback.usesMetalPreview ? nil : currentCameraFrame,
                overlays: openProject.project.overlays ?? [],
                timelineTime: playback.currentTime,
                isMetalComposed: playback.usesMetalPreview
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismissWindow(id: "project-preview")
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(FloatingTransportButtonStyle())
                    .floatingGlassSurface(in: Circle(), interactive: true)
                    .help("Close preview")
                    .accessibilityLabel("Close preview")
                }
                Spacer()
                transport
            }
            .padding(16)

            preparationOverlay
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: 960)
        .frame(minHeight: 338, idealHeight: 405, maxHeight: 540)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: openProject.project) { await playback.synchronize(openProject: openProject) }
        .onDisappear { playback.stop() }
        .accessibilityLabel("Floating project preview")
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(openProject.packageURL.deletingPathExtension().lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(playback.isPlaying ? "Playing" : "Preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text("\(format(playback.currentTime)) / \(format(openProject.project.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                transportButton("gobackward.5", help: "Back 5 seconds") { playback.skip(by: -5) }
                Button(action: playback.toggle) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.tint, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(FloatingTransportButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .help(playback.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { min(playback.currentTime, max(openProject.project.duration, 0.01)) },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(openProject.project.duration, 0.01),
                    onEditingChanged: scrubChanged
                )
                .controlSize(.small)
                .accessibilityLabel("Preview position")
                .accessibilityValue(format(playback.currentTime))

                transportButton("goforward.5", help: "Forward 5 seconds") { playback.skip(by: 5) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .floatingGlassSurface(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            interactive: true
        )
    }

    @ViewBuilder
    private var preparationOverlay: some View {
        Group {
            switch playback.preparationState {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing preview…").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .floatingGlassSurface(in: Capsule(), interactive: false)
            case .failed(let message):
                Label("Preview unavailable — reopen to retry", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .help(message)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .floatingGlassSurface(in: Capsule(), interactive: false)
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    private func transportButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(FloatingTransportButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func scrubChanged(_ isEditing: Bool) {
        if isEditing {
            wasPlayingBeforeScrub = playback.isPlaying
            if playback.isPlaying { playback.toggle() }
        } else if wasPlayingBeforeScrub, !playback.isPlaying {
            playback.toggle()
        }
    }

    private func format(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%02d", Int(safe) / 60, Int(safe) % 60)
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

private struct FloatingTransportButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .background(
                Circle().fill(.primary.opacity(configuration.isPressed ? 0.16 : isHovering ? 0.1 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private extension View {
    @ViewBuilder
    func floatingGlassSurface<S: Shape>(in shape: S, interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
        }
    }
}
