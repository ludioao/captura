import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    let cameraPlayer: AVPlayer?
    @Published var currentTime = 0.0
    private var observation: PlayerTimeObserver?

    init(url: URL, cameraURL: URL?) {
        player = AVPlayer(url: url)
        cameraPlayer = cameraURL.map(AVPlayer.init(url:))
        SynchronizedPlayback.configure(player, cameraPlayer)
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in self?.currentTime = max(0, time.seconds) }
        }
        observation = PlayerTimeObserver(player: player, token: token)
    }

    func seek(to seconds: Double) {
        SynchronizedPlayback.seek(
            player,
            cameraPlayer,
            to: CMTime(seconds: seconds, preferredTimescale: 600)
        )
        currentTime = seconds
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            SynchronizedPlayback.pause(player, cameraPlayer)
        } else {
            SynchronizedPlayback.play(player, cameraPlayer)
        }
    }

    func updateAudio(_ settings: ProjectAudioSettings) {
        guard let item = player.currentItem else { return }
        Task {
            let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            let parameters = tracks.enumerated().map { index, track in
                let parameter = AVMutableAudioMixInputParameters(track: track)
                let system = index == 0
                let muted = system ? settings.systemMuted : settings.microphoneMuted
                let volume = system ? settings.systemVolume : settings.microphoneVolume
                parameter.setVolume(muted ? 0 : Float(volume), at: .zero)
                return parameter
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            item.audioMix = mix
        }
    }
}

@MainActor
private final class ExportCoordinator: ObservableObject {
    @Published var isExporting = false
    @Published var progress = 0.0
    @Published var errorMessage: String?
    @Published var completedURL: URL?
    private let exporter = MP4ProjectExporter()
    private let gifExporter = GIFExporter()
    private var task: Task<Void, Never>?

    func start(project: ScreenProject, packageURL: URL, destination: URL, settings: ExportSettings) {
        task?.cancel()
        isExporting = true
        progress = 0
        errorMessage = nil
        completedURL = nil
        task = Task {
            do {
                let selectedExporter: any ProjectExporter = settings.format == .gif ? gifExporter : exporter
                try await selectedExporter.export(
                    project: project,
                    packageURL: packageURL,
                    destination: destination,
                    settings: settings
                ) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                guard !Task.isCancelled else { return }
                isExporting = false
                completedURL = destination
                if let data = try? JSONEncoder().encode(settings) {
                    UserDefaults.standard.set(data, forKey: "captura.lastExportSettings")
                }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                isExporting = false
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        task?.cancel()
        exporter.cancel()
        gifExporter.cancel()
        isExporting = false
    }
}

struct EditorView: View {
    @Environment(\.openWindow) private var openWindow
    let openProject: OpenProject
    let close: () -> Void
    let save: (ScreenProject) async -> Bool
    @StateObject private var playback: PlaybackModel
    @StateObject private var exportCoordinator = ExportCoordinator()
    @State private var project: ScreenProject
    @State private var selectedClipID: UUID?
    @State private var hasUnsavedChanges = false
    @State private var showsEvents = false
    @State private var showsCanvasInspector = true
    @State private var showsExportSettings = false
    @State private var inspectorSection = EditorInspectorSection.canvas
    @State private var waveform: [Double] = []
    @State private var showsCaptionEntry = false
    @State private var captionDraft = ""
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isTranscribing = false
    @State private var transcriptionError: String?

    init(openProject: OpenProject, close: @escaping () -> Void, save: @escaping (ScreenProject) async -> Bool) {
        self.openProject = openProject
        self.close = close
        self.save = save
        let mediaURL = openProject.packageURL.appending(path: openProject.project.media.screen)
        let cameraURL = openProject.project.media.camera.map { openProject.packageURL.appending(path: $0) }
        _playback = StateObject(wrappedValue: PlaybackModel(url: mediaURL, cameraURL: cameraURL))
        var project = openProject.project
        if project.settings.appearance == nil { project.settings.appearance = .default }
        _project = State(initialValue: project)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                CanvasMockupPreview(
                    player: playback.player,
                    cameraPlayer: playback.cameraPlayer,
                    sourceSize: project.settings.canvas,
                    appearance: appearanceBinding,
                    cursorSample: currentCursorSample,
                    cursorAppearance: project.settings.cursor ?? .default,
                    caption: activeCaption,
                    cameraFrame: currentCameraFrame,
                    overlays: project.overlays ?? [],
                    timelineTime: playback.currentTime
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if showsCanvasInspector {
                    Divider()
                    editorInspector.frame(width: 270)
                }
            }
            Divider()
            transport
            TimelineCanvas(
                timeline: project.timeline,
                cameraKeyframes: project.cameraKeyframes,
                events: openProject.events,
                waveform: waveform,
                playhead: playback.currentTime,
                selectedClipID: selectedClipID,
                seek: playback.seek,
                select: { selectedClipID = $0 },
                moveCameraKeyframe: moveCameraKeyframe
            )
            .frame(height: 190)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            eventSummary
            if showsEvents { eventInspector }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsExportSettings) {
            ExportSettingsView(
                sourceFPS: project.settings.frameRate,
                sourceCanvas: project.settings.canvas,
                export: startExport
            )
        }
        .overlay(alignment: .topTrailing) { exportStatus }
        .alert("Export failed", isPresented: Binding(
            get: { exportCoordinator.errorMessage != nil },
            set: { if !$0 { exportCoordinator.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { exportCoordinator.errorMessage = nil }
        } message: {
            Text(exportCoordinator.errorMessage ?? "Unknown error")
        }
        .alert("Add caption", isPresented: $showsCaptionEntry) {
            TextField("Caption text", text: $captionDraft)
            Button("Cancel", role: .cancel) { captionDraft = "" }
            Button("Add") { addCaption() }.disabled(captionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The caption starts at the playhead and lasts three seconds.")
        }
        .alert("Transcription failed", isPresented: Binding(
            get: { transcriptionError != nil },
            set: { if !$0 { transcriptionError = nil } }
        )) {
            Button("OK", role: .cancel) { transcriptionError = nil }
        } message: {
            Text(transcriptionError ?? "Unknown error")
        }
        .task(id: openProject.project.id) {
            let url = openProject.packageURL.appending(path: openProject.project.media.screen)
            waveform = await AudioWaveform.load(from: url)
        }
        .onChange(of: project.settings.audio, initial: true) { _, value in
            playback.updateAudio(value ?? .default)
        }
        .onChange(of: project) { _, value in
            autosaveTask?.cancel()
            hasUnsavedChanges = true
            autosaveTask = Task {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                if await save(value) { hasUnsavedChanges = false }
            }
        }
        .onDisappear { autosaveTask?.cancel() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: close) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back to projects")
            VStack(alignment: .leading, spacing: 1) {
                Text(openProject.packageURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                Text("HEVC · \(openProject.project.settings.frameRate) FPS · \(format(project.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsCanvasInspector.toggle() }
            } label: {
                Label("Canvas", systemImage: "paintpalette")
            }
            .buttonStyle(.bordered)
            .tint(showsCanvasInspector ? .accentColor : .secondary)
            Button {
                openWindow(id: "project-preview")
            } label: {
                Label("Floating Preview", systemImage: "pip")
            }
            Button("Split") { splitSelectedClip() }
                .disabled(selectedClipID == nil)
            Menu("Zoom") {
                Button("Add zoom at playhead") { addManualZoom() }
                Button("Remove nearby zoom") { removeNearbyZoom() }
                    .disabled(project.cameraKeyframes.isEmpty)
            }
            Button("Trim Start") { trimStart() }
                .disabled(selectedClipID == nil)
            Button("Trim End") { trimEnd() }
                .disabled(selectedClipID == nil)
            Menu("Speed") {
                ForEach([0.5, 1, 1.5, 2, 3, 4], id: \.self) { speed in
                    Button(speed == 1 ? "1× (Normal)" : "\(speed.formatted())×") { setSpeed(speed) }
                }
            }
            .disabled(selectedClipID == nil)
            Button(role: .destructive) { deleteSelectedClip() } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedClipID == nil)
            Button("Save") {
                Task {
                    if await save(project) { hasUnsavedChanges = false }
                }
            }
            .keyboardShortcut("s")
            .disabled(!hasUnsavedChanges)
            Menu {
                Button("Quick export with last settings", action: quickExport)
                    .disabled(lastExportSettings == nil)
                Divider()
                Button("Export settings…") { showsExportSettings = true }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(exportCoordinator.isExporting || project.timeline.clips.isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.bar)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            Text(format(playback.currentTime))
                .monospacedDigit()
                .font(.callout.weight(.medium))
            Text("/")
                .foregroundStyle(.tertiary)
            Text(format(project.duration))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Label("Timeline", systemImage: "timeline.selection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .frame(height: 48)
    }

    private var eventSummary: some View {
        HStack {
            Button {
                withAnimation { showsEvents.toggle() }
            } label: {
                Label("\(openProject.events.count) interaction events", systemImage: "cursorarrow.motionlines")
            }
            .buttonStyle(.link)
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

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var appearanceBinding: Binding<CanvasAppearance> {
        Binding(
            get: { project.settings.appearance ?? .default },
            set: {
                project.settings.appearance = $0
                hasUnsavedChanges = true
            }
        )
    }

    private var audioBinding: Binding<ProjectAudioSettings> {
        Binding(
            get: { project.settings.audio ?? .default },
            set: { project.settings.audio = $0; hasUnsavedChanges = true }
        )
    }

    private var cursorBinding: Binding<CursorAppearance> {
        Binding(
            get: { project.settings.cursor ?? .default },
            set: { project.settings.cursor = $0; hasUnsavedChanges = true }
        )
    }

    private var overlaysBinding: Binding<[OverlayRegion]> {
        Binding(
            get: { project.overlays ?? [] },
            set: { project.overlays = $0; hasUnsavedChanges = true }
        )
    }

    private var currentCursorSample: CursorSample? {
        let sourceTime = project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime
        let samples = openProject.events.compactMap { event -> CursorSample? in
            guard let x = event.normalizedX, let y = event.normalizedY,
                  event.type == .mouseMove || event.type == .click || event.type == .mouseDown else { return nil }
            return CursorSample(time: event.timestamp, normalizedX: x, normalizedY: y, cursorType: .arrow)
        }
        guard let sample = CursorInterpolator().sample(at: sourceTime, from: samples) else { return nil }
        if (project.settings.cursor ?? .default).hidesWhenIdle,
           let closest = samples.min(by: { abs($0.time - sourceTime) < abs($1.time - sourceTime) }),
           abs(closest.time - sourceTime) > 1.5 { return nil }
        return sample
    }

    private var activeCaption: String? {
        (project.captions ?? []).first {
            playback.currentTime >= $0.startTime && playback.currentTime <= $0.endTime
        }?.text
    }

    private var currentCameraFrame: CameraKeyframe? {
        let sourceTime = project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime
        return CameraKeyframeInterpolator().value(at: sourceTime, frames: project.cameraKeyframes)
    }

    @ViewBuilder
    private var editorInspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorSection) {
                ForEach(EditorInspectorSection.allCases) { section in
                    Image(systemName: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            switch inspectorSection {
            case .canvas:
                CanvasAppearanceInspector(
                    appearance: appearanceBinding,
                    audio: audioBinding,
                    cursor: cursorBinding,
                    hasCamera: playback.cameraPlayer != nil
                )
            case .audio:
                AudioInspector(settings: audioBinding)
            case .cursor:
                CursorInspector(settings: cursorBinding)
            case .zoom:
                ZoomInspector(
                    keyframes: $project.cameraKeyframes,
                    sourceTime: project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime,
                    duration: sourceDuration,
                    seekToSourceTime: seekToSourceTime
                )
            case .captions:
                CaptionInspector(
                    captions: project.captions ?? [],
                    add: { showsCaptionEntry = true },
                    delete: deleteCaption,
                    generate: generateTranscript,
                    isGenerating: isTranscribing
                )
            case .overlays:
                OverlayInspector(
                    overlays: overlaysBinding,
                    add: addOverlay
                )
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func addCaption() {
        let text = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var captions = project.captions ?? []
        captions.append(CaptionCue(
            startTime: playback.currentTime,
            endTime: min(project.duration, playback.currentTime + 3),
            text: text
        ))
        project.captions = captions.sorted { $0.startTime < $1.startTime }
        captionDraft = ""
        hasUnsavedChanges = true
    }

    private func deleteCaption(_ id: UUID) {
        project.captions?.removeAll { $0.id == id }
        hasUnsavedChanges = true
    }

    private func generateTranscript() {
        guard !isTranscribing else { return }
        isTranscribing = true
        let mediaURL = openProject.packageURL.appending(path: project.media.screen)
        Task {
            defer { isTranscribing = false }
            do {
                let sourceCues = try await LocalTranscriber().transcribe(url: mediaURL)
                let timelineCues = sourceCues.compactMap { cue -> CaptionCue? in
                    guard let start = project.timeline.firstTimelineTime(forSourceTime: cue.startTime),
                          let end = project.timeline.firstTimelineTime(forSourceTime: cue.endTime) else { return nil }
                    return CaptionCue(startTime: start, endTime: max(start + 0.2, end), text: cue.text)
                }
                project.captions = timelineCues
                hasUnsavedChanges = true
            } catch {
                transcriptionError = error.localizedDescription
            }
        }
    }

    private func addOverlay(_ kind: OverlayRegionKind) {
        let point = currentCursorSample.map { CGPoint(x: $0.normalizedX, y: $0.normalizedY) }
            ?? CGPoint(x: 0.5, y: 0.5)
        var overlays = project.overlays ?? []
        overlays.append(OverlayRegion(
            startTime: playback.currentTime,
            endTime: min(project.duration, playback.currentTime + 3),
            normalizedX: point.x,
            normalizedY: point.y,
            normalizedWidth: 0.24,
            normalizedHeight: 0.14,
            kind: kind
        ))
        project.overlays = overlays
        hasUnsavedChanges = true
    }

    private var eventInspector: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(openProject.events) { event in
                    HStack(spacing: 10) {
                        Text(String(format: "%8.3f", event.timestamp))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(event.type.rawValue)
                            .frame(width: 90, alignment: .leading)
                        if let x = event.normalizedX, let y = event.normalizedY {
                            Text(String(format: "x %.3f  y %.3f", x, y))
                                .monospacedDigit()
                        }
                        if let title = event.accessibility?.title ?? event.windowTitle {
                            Text(title).lineLimit(1)
                        }
                        Spacer()
                        if let application = event.accessibility?.applicationName ?? event.applicationName {
                            Text(application).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 120)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func splitSelectedClip() {
        guard let selectedClipID else { return }
        project.timeline.split(clipID: selectedClipID, at: playback.currentTime)
        hasUnsavedChanges = true
    }

    private func trimStart() {
        guard let selectedClipID,
              let index = project.timeline.clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let clip = project.timeline.clips[index]
        let sourceTime = clip.sourceStart + max(0, playback.currentTime - clip.timelineStart) * clip.speed
        project.timeline.clips[index].trimStart(to: sourceTime)
        project.timeline.rippleLayout()
        project.duration = project.timeline.duration
        hasUnsavedChanges = true
    }

    private func trimEnd() {
        guard let selectedClipID,
              let index = project.timeline.clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let clip = project.timeline.clips[index]
        let sourceTime = clip.sourceStart + max(0, playback.currentTime - clip.timelineStart) * clip.speed
        project.timeline.clips[index].trimEnd(to: sourceTime)
        project.timeline.rippleLayout()
        project.duration = project.timeline.duration
        hasUnsavedChanges = true
    }

    private func deleteSelectedClip() {
        guard let selectedClipID else { return }
        project.timeline.delete(clipID: selectedClipID)
        project.duration = project.timeline.duration
        self.selectedClipID = nil
        playback.seek(to: min(playback.currentTime, project.duration))
        hasUnsavedChanges = true
    }

    private func setSpeed(_ speed: Double) {
        guard let selectedClipID,
              let index = project.timeline.clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        project.timeline.clips[index].speed = speed
        project.timeline.rippleLayout()
        project.duration = project.timeline.duration
        hasUnsavedChanges = true
    }

    private func addManualZoom() {
        let sourceTime = project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime
        let target = currentCursorSample
        let centerX = target?.normalizedX ?? 0.5
        let centerY = target?.normalizedY ?? 0.5
        project.cameraKeyframes.removeAll { abs($0.time - sourceTime) < 0.12 }
        project.cameraKeyframes.append(contentsOf: [
            CameraKeyframe(time: max(0, sourceTime - 0.35), centerX: centerX, centerY: centerY, scale: 1, easing: .easeInOut),
            CameraKeyframe(time: sourceTime, centerX: centerX, centerY: centerY, scale: 1.75, easing: .spring),
            CameraKeyframe(time: min(project.duration, sourceTime + 2.4), centerX: centerX, centerY: centerY, scale: 1, easing: .easeInOut)
        ])
        project.cameraKeyframes.sort { $0.time < $1.time }
        hasUnsavedChanges = true
    }

    private func removeNearbyZoom() {
        let sourceTime = project.timeline.sourceTime(at: playback.currentTime) ?? playback.currentTime
        guard let closest = project.cameraKeyframes.min(by: { abs($0.time - sourceTime) < abs($1.time - sourceTime) }) else { return }
        let focusTime = closest.time
        project.cameraKeyframes.removeAll { abs($0.time - focusTime) < 2.6 }
        hasUnsavedChanges = true
    }

    private var sourceDuration: Double {
        project.timeline.clips.map(\.sourceEnd).max() ?? project.duration
    }

    private func seekToSourceTime(_ sourceTime: Double) {
        guard let timelineTime = project.timeline.firstTimelineTime(forSourceTime: sourceTime) else { return }
        playback.seek(to: timelineTime)
    }

    @discardableResult
    private func moveCameraKeyframe(from previousSourceTime: Double, to timelineTime: Double) -> Double? {
        guard let index = project.cameraKeyframes.indices.min(by: {
            abs(project.cameraKeyframes[$0].time - previousSourceTime) < abs(project.cameraKeyframes[$1].time - previousSourceTime)
        }), let sourceTime = project.timeline.sourceTime(at: timelineTime) else { return nil }
        let clampedTime = min(max(sourceTime, 0), sourceDuration)
        project.cameraKeyframes[index].time = clampedTime
        hasUnsavedChanges = true
        return clampedTime
    }

    private func startExport(_ settings: ExportSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = settings.format == .gif ? [.gif] : [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let fileExtension = settings.format == .gif ? "gif" : "mp4"
        panel.nameFieldStringValue = "\(openProject.packageURL.deletingPathExtension().lastPathComponent).\(fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        showsExportSettings = false
        exportCoordinator.start(
            project: project,
            packageURL: openProject.packageURL,
            destination: destination,
            settings: settings
        )
    }

    private var lastExportSettings: ExportSettings? {
        guard let data = UserDefaults.standard.data(forKey: "captura.lastExportSettings") else { return nil }
        return try? JSONDecoder().decode(ExportSettings.self, from: data)
    }

    private func quickExport() {
        guard let settings = lastExportSettings else {
            showsExportSettings = true
            return
        }
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? openProject.packageURL.deletingLastPathComponent()
        let fileExtension = settings.format == .gif ? "gif" : "mp4"
        let baseName = openProject.packageURL.deletingPathExtension().lastPathComponent
        var destination = directory.appending(path: "\(baseName).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appending(path: "\(baseName)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        exportCoordinator.start(
            project: project,
            packageURL: openProject.packageURL,
            destination: destination,
            settings: settings
        )
    }

    @ViewBuilder
    private var exportStatus: some View {
        if exportCoordinator.isExporting {
            HStack(spacing: 12) {
                ProgressView(value: exportCoordinator.progress)
                    .frame(width: 68)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exporting video…").font(.callout.weight(.semibold))
                    Text("Rendering canvas, camera and audio · \(Int(exportCoordinator.progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { exportCoordinator.cancel() }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12, y: 5)
            .padding(12)
        }
    }
}

private struct ExportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let sourceFPS: Int
    let sourceCanvas: CanvasSize
    let export: (ExportSettings) -> Void
    @State private var preset = ExportPreset.fullHD
    @State private var format = ExportFormat.mp4
    @State private var fps = 60
    @State private var codec = VideoCodec.h264
    @State private var quality = ExportQuality.high

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export video").font(.title2.weight(.semibold))
                Text("Canvas styling, window frame, camera, cursor, captions and synced audio are rendered together.")
                    .foregroundStyle(.secondary)
            }
            Form {
                Picker("Format", selection: $format) {
                    Text("MP4 video").tag(ExportFormat.mp4)
                    Text("Animated GIF").tag(ExportFormat.gif)
                }
                Picker("Size", selection: $preset) {
                    ForEach(ExportPreset.allCases) { Text($0.title).tag($0) }
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                Picker("Codec", selection: $codec) {
                    Text("H.264 (compatible)").tag(VideoCodec.h264)
                    Text("HEVC (smaller)").tag(VideoCodec.hevc)
                }
                .disabled(format == .gif)
                Picker("Quality", selection: $quality) {
                    Text("Compact").tag(ExportQuality.compact)
                    Text("Balanced").tag(ExportQuality.balanced)
                    Text("High").tag(ExportQuality.high)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Choose destination…") {
                    export(ExportSettings(format: format, codec: codec, resolution: preset.size(source: sourceCanvas), fps: fps, quality: quality))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onAppear { fps = sourceFPS >= 50 ? 60 : 30 }
    }
}

private enum ExportPreset: String, CaseIterable, Identifiable {
    case source, fullHD, quadHD, ultraHD, square, portrait, socialPortrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: "Source size"
        case .fullHD: "Full HD · 1920 × 1080"
        case .quadHD: "1440p · 2560 × 1440"
        case .ultraHD: "4K · 3840 × 2160"
        case .square: "Square · 1080 × 1080"
        case .portrait: "Vertical · 1080 × 1920"
        case .socialPortrait: "Social · 1080 × 1350"
        }
    }
    func size(source: CanvasSize) -> CanvasSize {
        switch self {
        case .source: source
        case .fullHD: CanvasSize(width: 1920, height: 1080)
        case .quadHD: CanvasSize(width: 2560, height: 1440)
        case .ultraHD: CanvasSize(width: 3840, height: 2160)
        case .square: CanvasSize(width: 1080, height: 1080)
        case .portrait: CanvasSize(width: 1080, height: 1920)
        case .socialPortrait: CanvasSize(width: 1080, height: 1350)
        }
    }
}

private enum EditorInspectorSection: String, CaseIterable, Identifiable {
    case canvas, audio, cursor, zoom, captions, overlays
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .canvas: "paintpalette"
        case .audio: "waveform"
        case .cursor: "cursorarrow.motionlines"
        case .zoom: "viewfinder"
        case .captions: "captions.bubble"
        case .overlays: "rectangle.dashed"
        }
    }
}

private struct OverlayInspector: View {
    @Binding var overlays: [OverlayRegion]
    let add: (OverlayRegionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overlays").font(.headline)
            HStack {
                Button("Privacy") { add(.privacy) }
                Button("Highlight") { add(.highlight) }
            }
            Text("New overlays start at the playhead, follow the cursor position and last three seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if overlays.isEmpty {
                ContentUnavailableView("No overlays", systemImage: "rectangle.dashed")
            } else {
                List {
                    ForEach($overlays) { $overlay in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(
                                    overlay.kind == .privacy ? "Privacy mask" : "Highlight",
                                    systemImage: overlay.kind == .privacy ? "eye.slash" : "highlighter"
                                )
                                Spacer()
                                Button(role: .destructive) {
                                    overlays.removeAll { $0.id == overlay.id }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                            HStack {
                                TextField("Start", value: $overlay.startTime, format: .number.precision(.fractionLength(1)))
                                TextField("End", value: $overlay.endTime, format: .number.precision(.fractionLength(1)))
                            }
                            Slider(value: $overlay.normalizedWidth, in: 0.08...0.8) { Text("Width") }
                            Slider(value: $overlay.normalizedHeight, in: 0.06...0.8) { Text("Height") }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }
}

private struct AudioInspector: View {
    @Binding var settings: ProjectAudioSettings

    var body: some View {
        Form {
            Section("System audio") {
                Toggle("Muted", isOn: $settings.systemMuted)
                Slider(value: $settings.systemVolume, in: 0...2) {
                    Text("Volume")
                } minimumValueLabel: { Image(systemName: "speaker") } maximumValueLabel: { Image(systemName: "speaker.wave.3") }
                    .disabled(settings.systemMuted)
            }
            Section("Microphone") {
                Toggle("Muted", isOn: $settings.microphoneMuted)
                Slider(value: $settings.microphoneVolume, in: 0...2) {
                    Text("Volume")
                } minimumValueLabel: { Image(systemName: "mic") } maximumValueLabel: { Image(systemName: "mic.fill") }
                    .disabled(settings.microphoneMuted)
            }
            Text("Tracks remain independent and source media is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct CursorInspector: View {
    @Binding var settings: CursorAppearance

    var body: some View {
        Form {
            Toggle("Show cursor", isOn: $settings.isVisible)
            Toggle("Hide when idle", isOn: $settings.hidesWhenIdle)
            Toggle("Click effect", isOn: $settings.clickEffect)
            LabeledContent("Size", value: "\(Int(settings.size * 100))%")
            Slider(value: $settings.size, in: 0.5...2)
            LabeledContent("Smoothing", value: "\(Int(settings.smoothing * 100))%")
            Slider(value: $settings.smoothing, in: 0...1)
        }
        .formStyle(.grouped)
        .disabled(!settings.isVisible)
    }
}

private struct ZoomInspector: View {
    @Binding var keyframes: [CameraKeyframe]
    let sourceTime: Double
    let duration: Double
    let seekToSourceTime: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Camera motion").font(.headline)
                Text("Drag the diamond handles in the camera lane, then refine scale, focus and easing here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if keyframes.isEmpty {
                ContentUnavailableView("No zooms", systemImage: "viewfinder")
            } else {
                List {
                    ForEach(keyframes.indices, id: \.self) { index in
                        zoomRow(index: index)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func zoomRow(index: Int) -> some View {
        let isNearPlayhead = abs(keyframes[index].time - sourceTime) < 0.15
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button {
                    seekToSourceTime(keyframes[index].time)
                } label: {
                    Label(
                        String(format: "%.2fs", keyframes[index].time),
                        systemImage: isNearPlayhead ? "play.fill" : "diamond.fill"
                    )
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(role: .destructive) {
                    keyframes.remove(at: index)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            LabeledContent("Time", value: String(format: "%.2fs", keyframes[index].time))
            Slider(value: $keyframes[index].time, in: 0...max(duration, 0.1))
            LabeledContent("Zoom", value: String(format: "%.2f×", keyframes[index].scale))
            Slider(value: $keyframes[index].scale, in: 1...4)
            LabeledContent("Horizontal", value: "\(Int(keyframes[index].centerX * 100))%")
            Slider(value: $keyframes[index].centerX, in: 0...1)
            LabeledContent("Vertical", value: "\(Int(keyframes[index].centerY * 100))%")
            Slider(value: $keyframes[index].centerY, in: 0...1)
            Picker("Easing", selection: $keyframes[index].easing) {
                Text("Linear").tag(CameraEasing.linear)
                Text("Smooth").tag(CameraEasing.easeInOut)
                Text("Spring").tag(CameraEasing.spring)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct CaptionInspector: View {
    let captions: [CaptionCue]
    let add: () -> Void
    let delete: (UUID) -> Void
    let generate: () -> Void
    let isGenerating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Captions").font(.headline)
                Spacer()
                Button(action: add) { Image(systemName: "plus") }
                    .help("Add caption at playhead")
            }
            Button(action: generate) {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on device…")
                } else {
                    Label("Generate from audio", systemImage: "waveform.and.mic")
                }
            }
            .disabled(isGenerating)
            if captions.isEmpty {
                ContentUnavailableView(
                    "No captions",
                    systemImage: "captions.bubble",
                    description: Text("Move the playhead and add editable text.")
                )
            } else {
                List(captions) { cue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cue.text).lineLimit(2)
                            Spacer()
                            Button(role: .destructive) { delete(cue.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(String(format: "%.1fs – %.1fs", cue.startTime, cue.endTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }
}

private struct TimelineCanvas: View {
    let timeline: Timeline
    let cameraKeyframes: [CameraKeyframe]
    let events: [InteractionEvent]
    let waveform: [Double]
    let playhead: Double
    let selectedClipID: UUID?
    let seek: (Double) -> Void
    let select: (UUID?) -> Void
    let moveCameraKeyframe: (Double, Double) -> Double?
    @State private var draggedCameraSourceTime: Double?

    private let labelWidth = 72.0

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let timelineTime = time(at: value.location.x, width: proxy.size.width)
                    if draggedCameraSourceTime == nil, (69...100).contains(value.startLocation.y) {
                        draggedCameraSourceTime = nearestCameraKeyframe(
                            to: value.startLocation.x,
                            width: proxy.size.width,
                            maximumDistance: 14
                        )
                    }
                    if let sourceTime = draggedCameraSourceTime {
                        draggedCameraSourceTime = moveCameraKeyframe(sourceTime, timelineTime) ?? sourceTime
                    } else {
                        seek(timelineTime)
                        if value.location.y < 69 {
                            select(timeline.clips.first(where: {
                                timelineTime >= $0.timelineStart && timelineTime <= $0.timelineStart + $0.duration
                            })?.id)
                        }
                    }
                }
                .onEnded { _ in draggedCameraSourceTime = nil }
            )
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
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

        let sortedCameraKeyframes = cameraKeyframes.sorted { $0.time < $1.time }
        for (index, frame) in sortedCameraKeyframes.enumerated() where frame.scale > 1 {
            guard let frameTime = timeline.firstTimelineTime(forSourceTime: frame.time) else { continue }
            let nextSourceTime = index + 1 < sortedCameraKeyframes.count ? sortedCameraKeyframes[index + 1].time : frame.time + 1
            let nextTime = timeline.firstTimelineTime(forSourceTime: nextSourceTime) ?? min(duration, frameTime + 1)
            let rect = CGRect(
                x: labelWidth + frameTime / duration * trackWidth,
                y: 73,
                width: max(3, (nextTime - frameTime) / duration * trackWidth),
                height: 23
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.purple.opacity(0.8)))
        }

        for frame in sortedCameraKeyframes {
            guard let frameTime = timeline.firstTimelineTime(forSourceTime: frame.time) else { continue }
            let x = labelWidth + frameTime / duration * trackWidth
            let handle = Path { path in
                path.move(to: CGPoint(x: x, y: 72))
                path.addLine(to: CGPoint(x: x + 5, y: 84.5))
                path.addLine(to: CGPoint(x: x, y: 97))
                path.addLine(to: CGPoint(x: x - 5, y: 84.5))
                path.closeSubpath()
            }
            context.fill(handle, with: .color(frame.scale > 1 ? .white : .purple.opacity(0.9)))
            context.stroke(handle, with: .color(.purple), lineWidth: 1.5)
        }

        for event in events where event.type == .mouseMove || event.type == .click {
            guard let eventTime = timeline.firstTimelineTime(forSourceTime: event.timestamp) else { continue }
            let x = labelWidth + eventTime / duration * trackWidth
            let height = event.type == .click ? 20.0 : 7.0
            let color: Color = event.type == .click ? .orange : .secondary.opacity(0.4)
            context.fill(Path(CGRect(x: x, y: 108 + (23 - height) / 2, width: event.type == .click ? 2 : 1, height: height)), with: .color(color))
        }

        if waveform.isEmpty {
            context.draw(Text("No audio waveform").font(.caption2).foregroundStyle(.tertiary), at: CGPoint(x: labelWidth + 8, y: 154), anchor: .leading)
        } else {
            let audioPath = Path { path in
                for (index, peak) in waveform.enumerated() {
                    let x = labelWidth + Double(index) / Double(max(1, waveform.count - 1)) * trackWidth
                    let height = max(1, peak * 9)
                    path.move(to: CGPoint(x: x, y: 154 - height))
                    path.addLine(to: CGPoint(x: x, y: 154 + height))
                }
            }
            context.stroke(audioPath, with: .color(.green.opacity(0.78)), lineWidth: 1)
        }

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

    private func nearestCameraKeyframe(to x: CGFloat, width: CGFloat, maximumDistance: CGFloat) -> Double? {
        let duration = max(timeline.duration, 0.001)
        let trackWidth = max(1, width - labelWidth - 12)
        return cameraKeyframes.compactMap { frame -> (Double, CGFloat)? in
            guard let timelineTime = timeline.firstTimelineTime(forSourceTime: frame.time) else { return nil }
            let handleX = labelWidth + timelineTime / duration * trackWidth
            return (frame.time, abs(handleX - x))
        }
        .filter { $0.1 <= maximumDistance }
        .min { $0.1 < $1.1 }?.0
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
