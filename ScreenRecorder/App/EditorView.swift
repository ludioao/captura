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
    @Published var usesMetalPreview = false
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

    func updateMetalPreview(project: ScreenProject, packageURL: URL, events: [InteractionEvent]) async {
        let time = currentTime
        let wasPlaying = player.timeControlStatus == .playing
        do {
            let item = try await MetalPreviewCompositionBuilder.makePlayerItem(
                project: project,
                packageURL: packageURL,
                events: events
            )
            player.replaceCurrentItem(with: item)
            usesMetalPreview = true
            await player.seek(
                to: CMTime(seconds: min(time, project.duration), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            updateAudio(project.settings.audio ?? .default)
            if wasPlaying { player.play() }
        } catch {
            usesMetalPreview = false
            Log.render.error("Metal preview rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@MainActor
private final class ProjectEditHistory: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let project: ScreenProject
    }

    @Published private(set) var undoEntries: [Entry] = []
    @Published private(set) var redoEntries: [Entry] = []
    private var pendingOld: ScreenProject?
    private var pendingNew: ScreenProject?
    private var pendingTask: Task<Void, Never>?

    var canUndo: Bool { pendingOld != nil || !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }

    func record(old: ScreenProject, new: ScreenProject) {
        guard old != new else { return }
        if pendingOld == nil { pendingOld = old }
        pendingNew = new
        redoEntries.removeAll()
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
        objectWillChange.send()
    }

    func undo(current: ScreenProject) -> ScreenProject? {
        flush()
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(label: entry.label, project: current))
        return entry.project
    }

    func redo(current: ScreenProject) -> ScreenProject? {
        flush()
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(label: entry.label, project: current))
        return entry.project
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let old = pendingOld, let new = pendingNew else { return }
        undoEntries.append(Entry(label: label(from: old, to: new), project: old))
        if undoEntries.count > 80 { undoEntries.removeFirst(undoEntries.count - 80) }
        pendingOld = nil
        pendingNew = nil
    }

    private func label(from old: ScreenProject, to new: ScreenProject) -> String {
        if (new.videoAssets?.count ?? 0) > (old.videoAssets?.count ?? 0) { return "Import Video" }
        if new.timeline.clips.count > old.timeline.clips.count { return "Split or Add Clip" }
        if new.timeline.clips.count < old.timeline.clips.count { return "Delete Clip" }
        if new.timeline != old.timeline { return "Edit Clip" }
        if new.timelineTracks != old.timelineTracks { return "Edit Track" }
        if new.brandingOverlays != old.brandingOverlays { return "Edit Overlay" }
        return "Edit Project"
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
    @StateObject private var editHistory = ProjectEditHistory()
    @State private var project: ScreenProject
    @State private var selectedClipID: UUID?
    @State private var selectedBrandingID: UUID?
    @State private var selectedTrackID: UUID? = TimelineTrack.primaryVideoID
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
    @State private var brandingImportError: String?
    @State private var mediaImportError: String?
    @State private var showsRegenerateZoomConfirmation = false
    @State private var isApplyingHistory = false

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
                    timelineTime: playback.currentTime,
                    isMetalComposed: playback.usesMetalPreview
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
            ProfessionalTimelineView(
                timeline: $project.timeline,
                brandingOverlays: brandingOverlaysBinding,
                customTracks: timelineTracksBinding,
                cameraKeyframes: project.cameraKeyframes,
                webcamKeyframes: project.webcamKeyframes ?? [],
                events: openProject.events,
                waveform: waveform,
                sourceDuration: sourceDuration,
                videoAssets: project.videoAssets ?? [],
                playhead: playback.currentTime,
                selectedClipID: $selectedClipID,
                selectedBrandingID: $selectedBrandingID,
                selectedTrackID: $selectedTrackID,
                seek: playback.seek,
                importVideos: { urls, time in importVideos(urls, at: time) },
                changed: timelineDidChange
            )
            .frame(height: 300)
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
        .alert("Could not add image", isPresented: Binding(
            get: { brandingImportError != nil },
            set: { if !$0 { brandingImportError = nil } }
        )) {
            Button("OK", role: .cancel) { brandingImportError = nil }
        } message: {
            Text(brandingImportError ?? "Unknown error")
        }
        .alert("Could not import video", isPresented: Binding(
            get: { mediaImportError != nil },
            set: { if !$0 { mediaImportError = nil } }
        )) {
            Button("OK", role: .cancel) { mediaImportError = nil }
        } message: {
            Text(mediaImportError ?? "Unknown error")
        }
        .confirmationDialog(
            "Replace all zoom keyframes?",
            isPresented: $showsRegenerateZoomConfirmation
        ) {
            Button("Regenerate Zoom", role: .destructive, action: regenerateAutoZoom)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces manual zoom edits with motion generated only from clicks and typing.")
        }
        .task(id: openProject.project.id) {
            let url = openProject.packageURL.appending(path: openProject.project.media.screen)
            waveform = await AudioWaveform.load(from: url)
            await playback.updateMetalPreview(
                project: project,
                packageURL: openProject.packageURL,
                events: openProject.events
            )
        }
        .onChange(of: project.settings.audio, initial: true) { _, value in
            playback.updateAudio(value ?? .default)
        }
        .onChange(of: project) { old, value in
            if isApplyingHistory { isApplyingHistory = false }
            else { editHistory.record(old: old, new: value) }
            autosaveTask?.cancel()
            hasUnsavedChanges = true
            autosaveTask = Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                await playback.updateMetalPreview(
                    project: value,
                    packageURL: openProject.packageURL,
                    events: openProject.events
                )
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
            Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editHistory.canUndo)
                .help("Undo")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editHistory.canRedo)
                .help("Redo")
            Menu {
                if editHistory.undoEntries.isEmpty {
                    Text("No edits yet")
                } else {
                    ForEach(editHistory.undoEntries.suffix(12).reversed()) { entry in
                        Label(entry.label, systemImage: "clock.arrow.circlepath")
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Edit history")
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
                .keyboardShortcut("b", modifiers: .command)
            Menu("Zoom") {
                Button("Add zoom at playhead") { addManualZoom() }
                Button("Remove nearby zoom") { removeNearbyZoom() }
                    .disabled(project.cameraKeyframes.isEmpty)
                Divider()
                Button("Regenerate from clicks & typing…") {
                    showsRegenerateZoomConfirmation = true
                }
                .disabled(openProject.events.allSatisfy { $0.type != .click && $0.type != .keyActivity })
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

    private var brandingOverlaysBinding: Binding<[BrandingOverlay]> {
        Binding(
            get: { project.brandingOverlays ?? [] },
            set: { project.brandingOverlays = $0; hasUnsavedChanges = true }
        )
    }

    private var timelineTracksBinding: Binding<[TimelineTrack]> {
        Binding(
            get: { project.timelineTracks ?? [] },
            set: { project.timelineTracks = $0; hasUnsavedChanges = true }
        )
    }

    private var webcamKeyframesBinding: Binding<[WebcamLayoutKeyframe]> {
        Binding(
            get: { project.webcamKeyframes ?? [] },
            set: { project.webcamKeyframes = $0.sorted { $0.time < $1.time }; hasUnsavedChanges = true }
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
            case .media:
                MediaInspector(
                    timeline: $project.timeline,
                    selectedClipID: selectedClipID,
                    playhead: playback.currentTime,
                    projectDuration: project.duration,
                    packageURL: openProject.packageURL,
                    branding: brandingOverlaysBinding,
                    split: splitSelectedClip,
                    importImage: importBrandingImage
                )
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
            case .webcam:
                WebcamFocusInspector(
                    keyframes: webcamKeyframesBinding,
                    appearance: project.settings.appearance ?? .default,
                    playhead: playback.currentTime,
                    duration: project.duration,
                    hasCamera: playback.cameraPlayer != nil,
                    seek: playback.seek
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
        guard project.timeline.split(clipID: selectedClipID, at: playback.currentTime) != nil else { return }
        if let leftIndex = project.timeline.clips.firstIndex(where: { $0.id == selectedClipID }) {
            project.timeline.clips[leftIndex].transitionOut = ClipTransition(kind: .fade)
        }
        project.duration = project.timeline.duration
        hasUnsavedChanges = true
    }

    private func importBrandingImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let directory = openProject.packageURL.appending(path: "assets/branding", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            let filename = "\(UUID().uuidString).\(fileExtension)"
            let destination = directory.appending(path: filename)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            var overlays = project.brandingOverlays ?? []
            overlays.append(BrandingOverlay(
                name: sourceURL.deletingPathExtension().lastPathComponent,
                assetPath: "assets/branding/\(filename)",
                startTime: playback.currentTime,
                endTime: min(project.duration, playback.currentTime + 5),
                trackID: selectedOverlayTrackID
            ))
            project.brandingOverlays = overlays
            inspectorSection = .media
            hasUnsavedChanges = true
        } catch {
            brandingImportError = error.localizedDescription
        }
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

    private func regenerateAutoZoom() {
        let director = AutoDirector()
        let intents = director.makeIntents(from: openProject.events, duration: project.duration)
        project.cameraKeyframes = director.makeKeyframes(from: intents, duration: project.duration)
        hasUnsavedChanges = true
    }

    private var sourceDuration: Double {
        project.timeline.clips.map(\.sourceEnd).max() ?? project.duration
    }

    private var selectedOverlayTrackID: UUID {
        guard let selectedTrackID else { return TimelineTrack.defaultOverlayID }
        if selectedTrackID == TimelineTrack.defaultOverlayID { return selectedTrackID }
        return (project.timelineTracks ?? []).first {
            $0.id == selectedTrackID && $0.kind == .overlay
        }?.id ?? TimelineTrack.defaultOverlayID
    }

    private func timelineDidChange() {
        project.duration = project.timeline.duration
        playback.seek(to: min(playback.currentTime, project.duration))
        hasUnsavedChanges = true
    }

    private func undo() {
        guard let snapshot = editHistory.undo(current: project) else { return }
        applyHistory(snapshot)
    }

    private func redo() {
        guard let snapshot = editHistory.redo(current: project) else { return }
        applyHistory(snapshot)
    }

    private func applyHistory(_ snapshot: ScreenProject) {
        isApplyingHistory = true
        project = snapshot
        if !project.timeline.clips.contains(where: { $0.id == selectedClipID }) { selectedClipID = nil }
        if !(project.brandingOverlays ?? []).contains(where: { $0.id == selectedBrandingID }) { selectedBrandingID = nil }
        playback.seek(to: min(playback.currentTime, project.duration))
    }

    private func importVideos(_ suppliedURLs: [URL], at insertionTime: Double) {
        let urls: [URL]
        if suppliedURLs.isEmpty {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            urls = panel.urls
        } else {
            urls = suppliedURLs
        }
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                var cursor = min(max(insertionTime, 0), project.timeline.duration)
                for url in urls {
                    let assetID = UUID()
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    let directory = openProject.packageURL.appending(path: "assets/video", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let relativePath = "assets/video/\(assetID.uuidString).\(fileExtension)"
                    let destination = openProject.packageURL.appending(path: relativePath)
                    try FileManager.default.copyItem(at: url, to: destination)

                    let asset = AVURLAsset(url: destination)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0,
                          let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
                    let rotation = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
                    let media = ProjectVideoAsset(
                        id: assetID,
                        path: relativePath,
                        name: url.deletingPathExtension().lastPathComponent,
                        duration: duration,
                        width: max(1, Int(oriented.width.rounded())),
                        height: max(1, Int(oriented.height.rounded())),
                        rotationQuarterTurns: rotation
                    )
                    project.videoAssets = (project.videoAssets ?? []) + [media]
                    let clip = TimelineClip(
                        id: UUID(), sourceMediaID: assetID, sourceStart: 0, sourceEnd: duration,
                        timelineStart: cursor, speed: 1, transitionOut: nil, layout: .default
                    )
                    project.timeline.insert(clip, at: cursor)
                    cursor = clip.timelineStart + clip.duration
                    selectedClipID = clip.id
                }
                timelineDidChange()
            } catch {
                mediaImportError = error.localizedDescription
            }
        }
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
    case media, canvas, audio, cursor, zoom, webcam, captions, overlays
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .media: "film.stack"
        case .canvas: "paintpalette"
        case .audio: "waveform"
        case .cursor: "cursorarrow.motionlines"
        case .zoom: "viewfinder"
        case .webcam: "person.crop.rectangle"
        case .captions: "captions.bubble"
        case .overlays: "rectangle.dashed"
        }
    }
}

private struct MediaInspector: View {
    @Binding var timeline: Timeline
    let selectedClipID: UUID?
    let playhead: Double
    let projectDuration: Double
    let packageURL: URL
    @Binding var branding: [BrandingOverlay]
    let split: () -> Void
    let importImage: () -> Void

    var body: some View {
        Form {
            Section("Clip") {
                if let clipBinding, let clip = selectedClip {
                    LabeledContent("Range") {
                        Text("\(format(clip.timelineStart))–\(format(clip.timelineStart + clip.duration))")
                            .monospacedDigit()
                    }
                    Button("Split at playhead", systemImage: "scissors", action: split)
                        .disabled(playhead <= clip.timelineStart || playhead >= clip.timelineStart + clip.duration)
                    Picker("Transition", selection: transitionKind(for: clipBinding)) {
                        Text("None").tag(ClipTransitionKind?.none)
                        ForEach(ClipTransitionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(Optional(kind))
                        }
                    }
                    .disabled(isLastSelectedClip)
                    if clip.transitionOut != nil {
                        LabeledContent("Duration") {
                            Text("\(transitionDuration(for: clipBinding).wrappedValue, specifier: "%.2f") s")
                                .monospacedDigit()
                        }
                        Slider(value: transitionDuration(for: clipBinding), in: 0.12...1.5)
                            .disabled(isLastSelectedClip)
                    }
                    Divider()
                    Text("Frame").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Sizing", selection: layoutBinding(for: clipBinding).contentMode) {
                        Text("Fit").tag(VideoClipContentMode.fit)
                        Text("Fill").tag(VideoClipContentMode.fill)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Scale", value: layoutBinding(for: clipBinding).scale.wrappedValue, format: .percent)
                    Slider(value: layoutBinding(for: clipBinding).scale, in: 0.2...2)
                    LabeledContent("Position X", value: layoutBinding(for: clipBinding).positionX.wrappedValue, format: .percent)
                    Slider(value: layoutBinding(for: clipBinding).positionX, in: 0...1)
                    LabeledContent("Position Y", value: layoutBinding(for: clipBinding).positionY.wrappedValue, format: .percent)
                    Slider(value: layoutBinding(for: clipBinding).positionY, in: 0...1)
                    LabeledContent("Opacity", value: layoutBinding(for: clipBinding).opacity.wrappedValue, format: .percent)
                    Slider(value: layoutBinding(for: clipBinding).opacity, in: 0...1)
                    Button("Reset Frame") { clipBinding.wrappedValue.layout = .default }
                } else {
                    ContentUnavailableView(
                        "Select a clip",
                        systemImage: "film",
                        description: Text("Choose a video segment in the timeline to split it or add a transition.")
                    )
                }
            }

            Section("Branding") {
                Button("Add logo or image…", systemImage: "photo.badge.plus", action: importImage)
                Text("Images are stored inside the project and rendered into preview and export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if branding.isEmpty {
                    Text("No branding images")
                        .foregroundStyle(.secondary)
                }
                ForEach($branding) { $item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 9) {
                            if let image = image(for: item) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 38, height: 30)
                            } else {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .frame(width: 38, height: 30)
                            }
                            TextField("Image name", text: $item.name)
                            Button(role: .destructive) {
                                branding.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("Start", value: $item.startTime, format: .number.precision(.fractionLength(1)))
                            TextField("End", value: $item.endTime, format: .number.precision(.fractionLength(1)))
                        }
                        Picker("Sizing", selection: $item.contentMode) {
                            ForEach(BrandingContentMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        LabeledContent("Position X", value: item.normalizedX, format: .number.precision(.fractionLength(2)))
                        Slider(value: $item.normalizedX, in: 0...1)
                        LabeledContent("Position Y", value: item.normalizedY, format: .number.precision(.fractionLength(2)))
                        Slider(value: $item.normalizedY, in: 0...1)
                        LabeledContent("Width", value: item.normalizedWidth, format: .percent)
                        Slider(value: $item.normalizedWidth, in: 0.05...1)
                        LabeledContent("Height", value: item.normalizedHeight, format: .percent)
                        Slider(value: $item.normalizedHeight, in: 0.05...1)
                        LabeledContent("Opacity", value: item.opacity, format: .percent)
                        Slider(value: $item.opacity, in: 0...1)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedClip: TimelineClip? {
        timeline.clips.first { $0.id == selectedClipID }
    }

    private var clipBinding: Binding<TimelineClip>? {
        guard let selectedClipID,
              timeline.clips.contains(where: { $0.id == selectedClipID }) else { return nil }
        return Binding(
            get: { timeline.clips.first { $0.id == selectedClipID } ?? timeline.clips[0] },
            set: { value in
                guard let index = timeline.clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
                timeline.clips[index] = value
            }
        )
    }

    private var isLastSelectedClip: Bool {
        timeline.clips.sorted { $0.timelineStart < $1.timelineStart }.last?.id == selectedClipID
    }

    private func transitionKind(for clip: Binding<TimelineClip>) -> Binding<ClipTransitionKind?> {
        Binding(
            get: { clip.wrappedValue.transitionOut?.kind },
            set: { kind in
                clip.wrappedValue.transitionOut = kind.map {
                    ClipTransition(kind: $0, duration: clip.wrappedValue.transitionOut?.duration ?? 0.45)
                }
            }
        )
    }

    private func transitionDuration(for clip: Binding<TimelineClip>) -> Binding<Double> {
        Binding(
            get: { clip.wrappedValue.transitionOut?.duration ?? 0.45 },
            set: { clip.wrappedValue.transitionOut?.duration = $0 }
        )
    }

    private func image(for item: BrandingOverlay) -> NSImage? {
        NSImage(contentsOf: packageURL.appending(path: item.assetPath))
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func layoutBinding(for clip: Binding<TimelineClip>) -> Binding<VideoClipLayout> {
        Binding(
            get: { clip.wrappedValue.layout ?? .default },
            set: { clip.wrappedValue.layout = $0 }
        )
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
                Toggle("Voice enhancement", isOn: $settings.voiceEnhancement)
                Toggle("Reduce background noise", isOn: $settings.noiseReduction)
            }
            Section("Click sound") {
                Toggle("Add click sounds", isOn: $settings.clickSounds)
                LabeledContent("Level", value: "\(Int(settings.clickVolume * 100))%")
                Slider(value: $settings.clickVolume, in: 0...1)
                    .disabled(!settings.clickSounds)
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

private struct WebcamFocusInspector: View {
    @Binding var keyframes: [WebcamLayoutKeyframe]
    let appearance: CanvasAppearance
    let playhead: Double
    let duration: Double
    let hasCamera: Bool
    let seek: (Double) -> Void
    @State private var focusDuration = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Webcam focus").font(.headline)
                Text("Create a segment that expands the webcam, holds it, and returns to its previous layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if !hasCamera {
                ContentUnavailableView("No webcam track", systemImage: "video.slash")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Focus duration", value: String(format: "%.1fs", focusDuration))
                    Slider(value: $focusDuration, in: 1...15, step: 0.5)
                    HStack {
                        Button("Focus here") { addFocusSegment() }
                            .buttonStyle(.borderedProminent)
                        Button("Keyframe") { addCurrentKeyframe() }
                    }
                }
                .padding(.horizontal, 16)

                if keyframes.isEmpty {
                    ContentUnavailableView(
                        "Static webcam",
                        systemImage: "person.crop.rectangle",
                        description: Text("Move the playhead and choose Focus here.")
                    )
                } else {
                    List {
                        ForEach(keyframes.indices, id: \.self) { index in
                            keyframeRow(index)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func addFocusSegment() {
        let generated = WebcamLayoutInterpolator().focusSegment(
            at: playhead,
            duration: focusDuration,
            frames: keyframes,
            fallback: appearance,
            projectDuration: duration
        )
        let range = playhead...(min(duration, playhead + focusDuration))
        keyframes.removeAll { range.contains($0.time) }
        keyframes.append(contentsOf: generated)
        keyframes.sort { $0.time < $1.time }
    }

    private func addCurrentKeyframe() {
        var value = WebcamLayoutInterpolator().value(at: playhead, frames: keyframes, fallback: appearance)
        value.id = UUID()
        value.time = playhead
        keyframes.removeAll { abs($0.time - playhead) < 0.08 }
        keyframes.append(value)
        keyframes.sort { $0.time < $1.time }
    }

    @ViewBuilder
    private func keyframeRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button { seek(keyframes[index].time) } label: {
                    Label(String(format: "%.2fs", keyframes[index].time), systemImage: "diamond.fill")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(role: .destructive) { keyframes.remove(at: index) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            LabeledContent("Time", value: String(format: "%.2fs", keyframes[index].time))
            Slider(value: $keyframes[index].time, in: 0...max(duration, 0.1))
            LabeledContent("Width", value: "\(Int(keyframes[index].width * 100))%")
            Slider(value: $keyframes[index].width, in: 0.08...1)
            LabeledContent("Height", value: "\(Int(keyframes[index].height * 100))%")
            Slider(value: $keyframes[index].height, in: 0.08...1)
            HStack {
                Text("X")
                Slider(value: $keyframes[index].positionX, in: 0...1)
                Text("Y")
                Slider(value: $keyframes[index].positionY, in: 0...1)
            }
            Toggle("Visible", isOn: Binding(
                get: { keyframes[index].opacity > 0.5 },
                set: { keyframes[index].opacity = $0 ? 1 : 0 }
            ))
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

private enum EditorTimelineLaneRole: Equatable {
    case video, overlay, zoom, webcam, interactions, audio
}

private struct EditorTimelineLane: Identifiable {
    let track: TimelineTrack
    let role: EditorTimelineLaneRole
    let isRemovable: Bool
    var id: UUID { track.id }
}

private struct ProfessionalTimelineView: View {
    @Binding var timeline: Timeline
    @Binding var brandingOverlays: [BrandingOverlay]
    @Binding var customTracks: [TimelineTrack]
    let cameraKeyframes: [CameraKeyframe]
    let webcamKeyframes: [WebcamLayoutKeyframe]
    let events: [InteractionEvent]
    let waveform: [Double]
    let sourceDuration: Double
    let videoAssets: [ProjectVideoAsset]
    let playhead: Double
    @Binding var selectedClipID: UUID?
    @Binding var selectedBrandingID: UUID?
    @Binding var selectedTrackID: UUID?
    let seek: (Double) -> Void
    let importVideos: ([URL], Double) -> Void
    let changed: () -> Void

    @State private var pixelsPerSecond = 86.0
    @State private var snappingEnabled = true
    @State private var playheadDragOrigin: Double?

    private let headerWidth = 142.0
    private let rulerHeight = 28.0
    private let laneHeight = 44.0
    private static let zoomTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private static let webcamTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    private static let interactionTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
    private static let audioTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    trackHeaders
                    Divider()
                    ScrollView(.horizontal) {
                        timelineContent
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .focusable()
        .onDeleteCommand(perform: deleteSelection)
        .accessibilityLabel("Video editing timeline")
    }

    private var timelineToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Overlay Track", systemImage: "rectangle.stack.badge.plus", action: addOverlayTrack)
            } label: {
                Label("Add Track", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            Button {
                importVideos([], playhead)
            } label: {
                Label("Import Video", systemImage: "film.badge.plus")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 16)
            Button {
                snappingEnabled.toggle()
            } label: {
                Label("Snap", systemImage: snappingEnabled ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill" : "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .buttonStyle(.borderless)
            .tint(snappingEnabled ? .accentColor : .secondary)
            Spacer()
            Text(formatTime(playhead))
                .font(.caption.monospacedDigit().weight(.medium))
            Image(systemName: "timeline.selection")
                .foregroundStyle(.secondary)
            Slider(value: $pixelsPerSecond, in: 40...240)
                .frame(width: 120)
                .help("Timeline zoom")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var trackHeaders: some View {
        VStack(spacing: 1) {
            Color.clear.frame(width: headerWidth, height: rulerHeight)
                .overlay(alignment: .leading) {
                    Text("TRACKS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
            ForEach(lanes) { lane in
                TimelineTrackHeader(
                    track: lane.track,
                    role: lane.role,
                    isSelected: selectedTrackID == lane.id,
                    canRemove: lane.isRemovable,
                    canRename: lane.role == .video || lane.role == .overlay,
                    select: { selectedTrackID = lane.id },
                    toggleLock: { updateTrack(lane.track, lock: !lane.track.isLocked) },
                    toggleMute: { updateTrack(lane.track, mute: !lane.track.isMuted) },
                    rename: { updateTrack(lane.track, name: $0) },
                    remove: { removeTrack(lane.track) }
                )
                .frame(width: headerWidth, height: laneHeight)
            }
        }
    }

    private var timelineContent: some View {
        let height = rulerHeight + Double(lanes.count) * laneHeight
        return VStack(spacing: 1) {
            TimelineRuler(
                duration: max(timeline.duration, 0.1),
                pixelsPerSecond: pixelsPerSecond,
                seek: seekToPosition
            )
            .frame(height: rulerHeight)
            ForEach(lanes) { lane in
                laneView(lane)
                    .frame(height: laneHeight)
            }
        }
        .frame(width: timelineWidth, height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            TimelinePlayhead(
                x: playhead * pixelsPerSecond,
                height: height,
                drag: dragPlayhead
            )
        }
        .dropDestination(for: URL.self) { urls, location in
            let movieURLs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
            guard !movieURLs.isEmpty else { return false }
            importVideos(movieURLs, min(max(location.x / pixelsPerSecond, 0), timeline.duration))
            return true
        }
    }

    @ViewBuilder
    private func laneView(_ lane: EditorTimelineLane) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(selectedTrackID == lane.id ? Color.accentColor.opacity(0.07) : .black.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTrackID = lane.id
                    selectedClipID = nil
                    selectedBrandingID = nil
                }

            switch lane.role {
            case .video:
                ForEach($timeline.clips) { $clip in
                    TimelineVideoClip(
                        clip: clip,
                        index: timeline.clips.firstIndex(where: { $0.id == clip.id }) ?? 0,
                        pixelsPerSecond: pixelsPerSecond,
                        laneHeight: laneHeight,
                        playhead: playhead,
                        title: videoAssets.first(where: { $0.id == clip.sourceMediaID })?.name ?? "Screen Clip",
                        isSelected: selectedClipID == clip.id,
                        isLocked: lane.track.isLocked,
                        select: {
                            selectedClipID = clip.id
                            selectedBrandingID = nil
                            selectedTrackID = lane.id
                        },
                        move: { moveClip(clip.id, by: $0) },
                        trimStart: { trimClipStart(clip.id, by: $0) },
                        trimEnd: { trimClipEnd(clip.id, by: $0) },
                        split: { splitClip(clip.id, at: $0) },
                        trimStartToPoint: { trimClipStart(clip.id, to: $0) },
                        trimEndToPoint: { trimClipEnd(clip.id, to: $0) },
                        setSpeed: { setClipSpeed(clip.id, speed: $0) },
                        setTransition: { setClipTransition(clip.id, kind: $0) },
                        duplicate: { duplicateClip(clip.id) },
                        delete: { deleteClip(clip.id) }
                    )
                }
            case .overlay:
                ForEach($brandingOverlays) { $overlay in
                    if (overlay.trackID ?? TimelineTrack.defaultOverlayID) == lane.id {
                        TimelineOverlayClip(
                            overlay: overlay,
                            pixelsPerSecond: pixelsPerSecond,
                            laneHeight: laneHeight,
                            playhead: playhead,
                            isSelected: selectedBrandingID == overlay.id,
                            isLocked: lane.track.isLocked,
                            availableTracks: overlayTracks,
                            select: {
                                selectedBrandingID = overlay.id
                                selectedClipID = nil
                                selectedTrackID = lane.id
                            },
                            move: { moveOverlay(overlay.id, by: $0) },
                            trimStart: { trimOverlayStart(overlay.id, by: $0) },
                            trimEnd: { trimOverlayEnd(overlay.id, by: $0) },
                            split: { splitOverlay(overlay.id, at: $0) },
                            trimStartToPoint: { trimOverlayStart(overlay.id, to: $0) },
                            trimEndToPoint: { trimOverlayEnd(overlay.id, to: $0) },
                            moveToTrack: { moveOverlay(overlay.id, to: $0) },
                            duplicate: { duplicateOverlay(overlay.id) },
                            delete: { deleteOverlay(overlay.id) }
                        )
                        .opacity(lane.track.isMuted ? 0.35 : 1)
                    }
                }
            case .zoom:
                TimelineAutomationLane(
                    color: .purple,
                    spans: zoomSpans,
                    markers: zoomMarkers,
                    pixelsPerSecond: pixelsPerSecond
                )
            case .webcam:
                TimelineAutomationLane(
                    color: .pink,
                    spans: webcamSpans,
                    markers: webcamKeyframes.map(\.time),
                    pixelsPerSecond: pixelsPerSecond
                )
            case .interactions:
                TimelineInteractionLane(
                    timeline: timeline,
                    events: events,
                    pixelsPerSecond: pixelsPerSecond
                )
            case .audio:
                TimelineWaveformLane(
                    waveform: waveform,
                    duration: max(timeline.duration, 0.1),
                    pixelsPerSecond: pixelsPerSecond
                )
            }
        }
        .frame(width: timelineWidth, height: laneHeight, alignment: .leading)
        .clipped()
    }

    private var lanes: [EditorTimelineLane] {
        let video = trackState(fallback: .primaryVideo)
        let branding = trackState(fallback: .defaultOverlay)
        let custom = customTracks
            .filter {
                $0.kind == .overlay &&
                $0.id != TimelineTrack.primaryVideoID && $0.id != TimelineTrack.defaultOverlayID
            }
            .map { EditorTimelineLane(track: $0, role: .overlay, isRemovable: true) }
        return [
            EditorTimelineLane(track: video, role: .video, isRemovable: false),
            EditorTimelineLane(track: branding, role: .overlay, isRemovable: false)
        ] + custom + [
            EditorTimelineLane(track: TimelineTrack(id: Self.zoomTrackID, name: "Auto Zoom", kind: .overlay), role: .zoom, isRemovable: false),
            EditorTimelineLane(track: TimelineTrack(id: Self.webcamTrackID, name: "Webcam", kind: .overlay), role: .webcam, isRemovable: false),
            EditorTimelineLane(track: TimelineTrack(id: Self.interactionTrackID, name: "Interactions", kind: .overlay), role: .interactions, isRemovable: false),
            EditorTimelineLane(track: TimelineTrack(id: Self.audioTrackID, name: "Audio", kind: .audio), role: .audio, isRemovable: false)
        ]
    }

    private var overlayTracks: [TimelineTrack] {
        lanes.filter { $0.role == .overlay }.map(\.track)
    }

    private var timelineWidth: Double {
        max(960, (max(timeline.duration, 0.1) + 1) * pixelsPerSecond)
    }

    private var zoomMarkers: [Double] {
        cameraKeyframes.compactMap { timeline.firstTimelineTime(forSourceTime: $0.time) }
    }

    private var zoomSpans: [ClosedRange<Double>] {
        let frames = cameraKeyframes.sorted { $0.time < $1.time }
        return frames.enumerated().compactMap { index, frame in
            guard frame.scale > 1,
                  let start = timeline.firstTimelineTime(forSourceTime: frame.time) else { return nil }
            let sourceEnd = index + 1 < frames.count ? frames[index + 1].time : frame.time + 1
            let end = timeline.firstTimelineTime(forSourceTime: sourceEnd) ?? min(timeline.duration, start + 1)
            return start...max(start, end)
        }
    }

    private var webcamSpans: [ClosedRange<Double>] {
        let frames = webcamKeyframes.sorted { $0.time < $1.time }
        return frames.indices.compactMap { index in
            guard frames[index].width > 0.6 else { return nil }
            let end = index + 1 < frames.count ? frames[index + 1].time : min(timeline.duration, frames[index].time + 1)
            return frames[index].time...max(frames[index].time, end)
        }
    }

    private func trackState(fallback: TimelineTrack) -> TimelineTrack {
        customTracks.first { $0.id == fallback.id } ?? fallback
    }

    private func updateTrack(
        _ track: TimelineTrack,
        name: String? = nil,
        lock: Bool? = nil,
        mute: Bool? = nil
    ) {
        var updated = track
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.name = name
        }
        if let lock { updated.isLocked = lock }
        if let mute { updated.isMuted = mute }
        if let index = customTracks.firstIndex(where: { $0.id == track.id }) {
            customTracks[index] = updated
        } else {
            customTracks.append(updated)
        }
        changed()
    }

    private func addOverlayTrack() {
        let number = customTracks.filter { $0.kind == .overlay }.count + 2
        let track = TimelineTrack(id: UUID(), name: "Overlay \(number)", kind: .overlay)
        customTracks.append(track)
        selectedTrackID = track.id
        changed()
    }

    private func removeTrack(_ track: TimelineTrack) {
        guard track.id != TimelineTrack.primaryVideoID, track.id != TimelineTrack.defaultOverlayID else { return }
        customTracks.removeAll { $0.id == track.id }
        for index in brandingOverlays.indices where brandingOverlays[index].trackID == track.id {
            brandingOverlays[index].trackID = TimelineTrack.defaultOverlayID
        }
        selectedTrackID = TimelineTrack.defaultOverlayID
        changed()
    }

    private func seekToPosition(_ x: Double) {
        seek(clampedTime(x / pixelsPerSecond))
    }

    private func dragPlayhead(_ translation: Double, ended: Bool) {
        if playheadDragOrigin == nil { playheadDragOrigin = playhead }
        let origin = playheadDragOrigin ?? playhead
        seek(clampedTime(origin + translation / pixelsPerSecond))
        if ended { playheadDragOrigin = nil }
    }

    private func clampedTime(_ value: Double) -> Double {
        let clamped = min(max(value, 0), timeline.duration)
        guard snappingEnabled else { return clamped }
        return (clamped * 10).rounded() / 10
    }

    private func moveClip(_ id: UUID, by delta: Double) {
        var ordered = timeline.clips.sorted { $0.timelineStart < $1.timelineStart }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let clip = ordered.remove(at: index)
        let proposedCenter = clip.timelineStart + clip.duration / 2 + delta
        let target = ordered.firstIndex {
            proposedCenter < $0.timelineStart + $0.duration / 2
        } ?? ordered.endIndex
        ordered.insert(clip, at: target)
        timeline.clips = ordered
        timeline.rippleLayout()
        changed()
    }

    private func trimClipStart(_ id: UUID, by delta: Double) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = timeline.clips[index]
        let sourceTime = min(clip.sourceEnd - 0.05, max(0, clip.sourceStart + delta * clip.speed))
        timeline.clips[index].sourceStart = sourceTime
        timeline.rippleLayout()
        changed()
    }

    private func trimClipEnd(_ id: UUID, by delta: Double) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = timeline.clips[index]
        let limit = videoAssets.first(where: { $0.id == clip.sourceMediaID })?.duration ?? sourceDuration
        let sourceTime = max(clip.sourceStart + 0.05, min(limit, clip.sourceEnd + delta * clip.speed))
        timeline.clips[index].sourceEnd = sourceTime
        timeline.rippleLayout()
        changed()
    }

    private func splitClip(_ id: UUID, at time: Double) {
        guard timeline.split(clipID: id, at: time) != nil else { return }
        if let index = timeline.clips.firstIndex(where: { $0.id == id }) {
            timeline.clips[index].transitionOut = ClipTransition(kind: .fade)
        }
        changed()
    }

    private func trimClipStart(_ id: UUID, to editTime: Double) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = timeline.clips[index]
        guard editTime > clip.timelineStart, editTime < clip.timelineStart + clip.duration else { return }
        timeline.clips[index].sourceStart += (editTime - clip.timelineStart) * clip.speed
        timeline.rippleLayout()
        changed()
    }

    private func trimClipEnd(_ id: UUID, to editTime: Double) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = timeline.clips[index]
        guard editTime > clip.timelineStart, editTime < clip.timelineStart + clip.duration else { return }
        timeline.clips[index].sourceEnd = clip.sourceStart + (editTime - clip.timelineStart) * clip.speed
        timeline.rippleLayout()
        changed()
    }

    private func setClipSpeed(_ id: UUID, speed: Double) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        timeline.clips[index].speed = speed
        timeline.rippleLayout()
        changed()
    }

    private func setClipTransition(_ id: UUID, kind: ClipTransitionKind?) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        timeline.clips[index].transitionOut = kind.map {
            ClipTransition(kind: $0, duration: timeline.clips[index].transitionOut?.duration ?? 0.45)
        }
        changed()
    }

    private func duplicateClip(_ id: UUID) {
        guard let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return }
        var copy = timeline.clips[index]
        copy.id = UUID()
        copy.transitionOut = nil
        timeline.clips.insert(copy, at: index + 1)
        timeline.rippleLayout()
        selectedClipID = copy.id
        changed()
    }

    private func deleteClip(_ id: UUID) {
        guard !trackState(fallback: .primaryVideo).isLocked else { return }
        timeline.delete(clipID: id)
        if selectedClipID == id { selectedClipID = nil }
        changed()
    }

    private func moveOverlay(_ id: UUID, by delta: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }) else { return }
        let length = brandingOverlays[index].endTime - brandingOverlays[index].startTime
        let start = min(max(brandingOverlays[index].startTime + delta, 0), max(0, timeline.duration - length))
        brandingOverlays[index].startTime = clampedTime(start)
        brandingOverlays[index].endTime = min(timeline.duration, brandingOverlays[index].startTime + length)
        changed()
    }

    private func trimOverlayStart(_ id: UUID, by delta: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }) else { return }
        brandingOverlays[index].startTime = min(
            brandingOverlays[index].endTime - 0.05,
            max(0, brandingOverlays[index].startTime + delta)
        )
        changed()
    }

    private func trimOverlayEnd(_ id: UUID, by delta: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }) else { return }
        brandingOverlays[index].endTime = max(
            brandingOverlays[index].startTime + 0.05,
            min(timeline.duration, brandingOverlays[index].endTime + delta)
        )
        changed()
    }

    private func splitOverlay(_ id: UUID, at time: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }) else { return }
        let item = brandingOverlays[index]
        guard time > item.startTime, time < item.endTime else { return }
        brandingOverlays[index].endTime = time
        var right = item
        right.id = UUID()
        right.startTime = time
        brandingOverlays.insert(right, at: index + 1)
        selectedBrandingID = right.id
        changed()
    }

    private func trimOverlayStart(_ id: UUID, to editTime: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }),
              editTime > brandingOverlays[index].startTime,
              editTime < brandingOverlays[index].endTime else { return }
        brandingOverlays[index].startTime = editTime
        changed()
    }

    private func trimOverlayEnd(_ id: UUID, to editTime: Double) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }),
              editTime > brandingOverlays[index].startTime,
              editTime < brandingOverlays[index].endTime else { return }
        brandingOverlays[index].endTime = editTime
        changed()
    }

    private func moveOverlay(_ id: UUID, to trackID: UUID) {
        guard let index = brandingOverlays.firstIndex(where: { $0.id == id }) else { return }
        brandingOverlays[index].trackID = trackID
        selectedTrackID = trackID
        changed()
    }

    private func duplicateOverlay(_ id: UUID) {
        guard let item = brandingOverlays.first(where: { $0.id == id }) else { return }
        var copy = item
        copy.id = UUID()
        let length = item.endTime - item.startTime
        copy.startTime = item.endTime + length <= timeline.duration
            ? item.endTime
            : max(0, item.startTime - length)
        copy.endTime = min(timeline.duration, copy.startTime + length)
        brandingOverlays.append(copy)
        selectedBrandingID = copy.id
        changed()
    }

    private func deleteOverlay(_ id: UUID) {
        guard let item = brandingOverlays.first(where: { $0.id == id }) else { return }
        let locked = overlayTracks.first {
            $0.id == (item.trackID ?? TimelineTrack.defaultOverlayID)
        }?.isLocked ?? false
        guard !locked else { return }
        brandingOverlays.removeAll { $0.id == id }
        if selectedBrandingID == id { selectedBrandingID = nil }
        changed()
    }

    private func deleteSelection() {
        if let selectedClipID { deleteClip(selectedClipID) }
        else if let selectedBrandingID { deleteOverlay(selectedBrandingID) }
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%02d:%02d.%01d", Int(seconds) / 60, Int(seconds) % 60, Int(seconds * 10) % 10)
    }
}

private struct TimelineTrackHeader: View {
    let track: TimelineTrack
    let role: EditorTimelineLaneRole
    let isSelected: Bool
    let canRemove: Bool
    let canRename: Bool
    let select: () -> Void
    let toggleLock: () -> Void
    let toggleMute: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            if canRename {
                TimelineTrackNameField(name: track.name, rename: rename)
            } else {
                Text(track.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if role == .overlay {
                Button(action: toggleMute) {
                    Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .help(track.isMuted ? "Enable track" : "Mute track")
            }
            if role == .video || role == .overlay {
                Button(action: toggleLock) {
                    Image(systemName: track.isLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.borderless)
                .help(track.isLocked ? "Unlock track" : "Lock track")
            }
        }
        .padding(.horizontal, 9)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            if canRemove {
                Button("Delete Track", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }

    private var icon: String {
        switch role {
        case .video: "film"
        case .overlay: "rectangle.on.rectangle"
        case .zoom: "viewfinder"
        case .webcam: "person.crop.rectangle"
        case .interactions: "cursorarrow.click"
        case .audio: "waveform"
        }
    }
}

private struct TimelineTrackNameField: View {
    @State private var value: String
    let rename: (String) -> Void

    init(name: String, rename: @escaping (String) -> Void) {
        _value = State(initialValue: name)
        self.rename = rename
    }

    var body: some View {
        TextField("Track name", text: $value)
            .textFieldStyle(.plain)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .onSubmit { rename(value) }
    }
}

private struct TimelineRuler: View {
    let duration: Double
    let pixelsPerSecond: Double
    let seek: (Double) -> Void

    var body: some View {
        Canvas { context, size in
            let interval = pixelsPerSecond >= 160 ? 0.5 : pixelsPerSecond >= 72 ? 1.0 : 2.0
            var time = 0.0
            while time <= duration + 1 {
                let x = time * pixelsPerSecond
                let major = abs(time.rounded() - time) < 0.001
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: major ? 13 : 19))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(.secondary.opacity(major ? 0.55 : 0.25)), lineWidth: 1)
                if major {
                    context.draw(
                        Text(label(time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: 7), anchor: .leading
                    )
                }
                time += interval
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { seek($0.location.x) }
            .onEnded { seek($0.location.x) }
        )
    }

    private func label(_ time: Double) -> String {
        String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

private struct TimelinePlayhead: View {
    let x: Double
    let height: Double
    let drag: (Double, Bool) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.red).frame(width: 1, height: height)
            Image(systemName: "triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .rotationEffect(.degrees(180))
                .offset(y: -1)
        }
        .frame(width: 12, height: height)
        .contentShape(Rectangle())
        .offset(x: x - 6)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag($0.translation.width, false) }
            .onEnded { drag($0.translation.width, true) }
        )
        .zIndex(20)
    }
}

private struct TimelineVideoClip: View {
    let clip: TimelineClip
    let index: Int
    let pixelsPerSecond: Double
    let laneHeight: Double
    let playhead: Double
    let title: String
    let isSelected: Bool
    let isLocked: Bool
    let select: () -> Void
    let move: (Double) -> Void
    let trimStart: (Double) -> Void
    let trimEnd: (Double) -> Void
    let split: (Double) -> Void
    let trimStartToPoint: (Double) -> Void
    let trimEndToPoint: (Double) -> Void
    let setSpeed: (Double) -> Void
    let setTransition: (ClipTransitionKind?) -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @State private var moveOffset = 0.0
    @State private var startTrimOffset = 0.0
    @State private var endTrimOffset = 0.0
    @State private var pointerTime: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.blue.opacity(0.78))
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? .white.opacity(0.9) : .white.opacity(0.22), lineWidth: isSelected ? 1.5 : 0.5)
            HStack(spacing: 5) {
                Image(systemName: "film.fill").font(.caption2)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(speedLabel)
                    .font(.caption2.monospacedDigit())
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            HStack {
                trimHandle
                    .highPriorityGesture(trimGesture(isStart: true))
                Spacer()
                trimHandle
                    .highPriorityGesture(trimGesture(isStart: false))
            }
        }
        .frame(width: displayedWidth, height: laneHeight - 8)
        .offset(x: displayedX, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                pointerTime = min(
                    clip.timelineStart + clip.duration,
                    max(clip.timelineStart, clip.timelineStart + location.x / pixelsPerSecond)
                )
            case .ended:
                break // Preserve the point while the contextual menu owns the pointer.
            }
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { if !isLocked { moveOffset = $0.translation.width } }
            .onEnded {
                if !isLocked { move($0.translation.width / pixelsPerSecond) }
                moveOffset = 0
            }
        )
        .contextMenu { clipContextMenu }
    }

    private var displayedX: Double {
        clip.timelineStart * pixelsPerSecond + moveOffset + startTrimOffset
    }

    private var displayedWidth: Double {
        max(28, clip.duration * pixelsPerSecond - startTrimOffset + endTrimOffset)
    }

    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.85))
            .frame(width: 5, height: laneHeight - 16)
            .padding(.horizontal, 3)
            .help("Drag to trim")
    }

    private func trimGesture(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isLocked else { return }
                if isStart { startTrimOffset = value.translation.width }
                else { endTrimOffset = value.translation.width }
            }
            .onEnded { value in
                guard !isLocked else { return }
                let delta = value.translation.width / pixelsPerSecond
                if isStart { trimStart(delta); startTrimOffset = 0 }
                else { trimEnd(delta); endTrimOffset = 0 }
            }
    }

    @ViewBuilder
    private var clipContextMenu: some View {
        Button("Split Here", systemImage: "scissors") { split(editTime) }
            .disabled(isLocked || !containsEditTime)
        Menu("Trim") {
            Button("Trim Start Here") { trimStartToPoint(editTime) }
            Button("Trim End Here") { trimEndToPoint(editTime) }
        }
        .disabled(isLocked || !containsEditTime)
        Menu("Speed") {
            ForEach([0.5, 1, 1.5, 2, 3, 4], id: \.self) { speed in
                Button(speed == 1 ? "1× Normal" : "\(speed.formatted())×") { setSpeed(speed) }
            }
        }
        .disabled(isLocked)
        Menu("Transition") {
            Button("None") { setTransition(nil) }
            ForEach(ClipTransitionKind.allCases, id: \.self) { kind in
                Button(kind.displayName) { setTransition(kind) }
            }
        }
        .disabled(isLocked)
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
            .disabled(isLocked)
        Button("Delete Clip", systemImage: "trash", role: .destructive, action: delete)
            .disabled(isLocked)
    }

    private var editTime: Double { pointerTime ?? playhead }
    private var containsEditTime: Bool {
        editTime > clip.timelineStart && editTime < clip.timelineStart + clip.duration
    }

    private var speedLabel: String {
        clip.speed == 1 ? "" : "\(clip.speed.formatted())×"
    }
}

private struct TimelineOverlayClip: View {
    let overlay: BrandingOverlay
    let pixelsPerSecond: Double
    let laneHeight: Double
    let playhead: Double
    let isSelected: Bool
    let isLocked: Bool
    let availableTracks: [TimelineTrack]
    let select: () -> Void
    let move: (Double) -> Void
    let trimStart: (Double) -> Void
    let trimEnd: (Double) -> Void
    let split: (Double) -> Void
    let trimStartToPoint: (Double) -> Void
    let trimEndToPoint: (Double) -> Void
    let moveToTrack: (UUID) -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @State private var moveOffset = 0.0
    @State private var startTrimOffset = 0.0
    @State private var endTrimOffset = 0.0
    @State private var pointerTime: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.orange : Color.orange.opacity(0.72))
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(isSelected ? 0.9 : 0.24), lineWidth: isSelected ? 1.5 : 0.5)
            HStack(spacing: 5) {
                Image(systemName: "photo.fill").font(.caption2)
                Text(overlay.name).font(.caption2.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            HStack {
                overlayTrimHandle.highPriorityGesture(trimGesture(isStart: true))
                Spacer()
                overlayTrimHandle.highPriorityGesture(trimGesture(isStart: false))
            }
        }
        .frame(width: displayedWidth, height: laneHeight - 8)
        .offset(x: displayedX, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                pointerTime = min(overlay.endTime, max(overlay.startTime, overlay.startTime + location.x / pixelsPerSecond))
            case .ended:
                break // Preserve the point while the contextual menu owns the pointer.
            }
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { if !isLocked { moveOffset = $0.translation.width } }
            .onEnded {
                if !isLocked { move($0.translation.width / pixelsPerSecond) }
                moveOffset = 0
            }
        )
        .contextMenu {
            Button("Split Here", systemImage: "scissors") { split(editTime) }
                .disabled(isLocked || !containsEditTime)
            Menu("Trim") {
                Button("Trim Start Here") { trimStartToPoint(editTime) }
                Button("Trim End Here") { trimEndToPoint(editTime) }
            }
            .disabled(isLocked || !containsEditTime)
            Menu("Move to Track") {
                ForEach(availableTracks) { track in
                    Button(track.name) { moveToTrack(track.id) }
                }
            }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate).disabled(isLocked)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete).disabled(isLocked)
        }
    }

    private var displayedX: Double { overlay.startTime * pixelsPerSecond + moveOffset + startTrimOffset }
    private var displayedWidth: Double {
        max(24, (overlay.endTime - overlay.startTime) * pixelsPerSecond - startTrimOffset + endTrimOffset)
    }
    private var editTime: Double { pointerTime ?? playhead }
    private var containsEditTime: Bool { editTime > overlay.startTime && editTime < overlay.endTime }
    private var overlayTrimHandle: some View {
        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.86))
            .frame(width: 5, height: laneHeight - 16).padding(.horizontal, 3)
    }
    private func trimGesture(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isLocked else { return }
                if isStart { startTrimOffset = value.translation.width }
                else { endTrimOffset = value.translation.width }
            }
            .onEnded { value in
                guard !isLocked else { return }
                let delta = value.translation.width / pixelsPerSecond
                if isStart { trimStart(delta); startTrimOffset = 0 }
                else { trimEnd(delta); endTrimOffset = 0 }
            }
    }
}

private struct TimelineAutomationLane: View {
    let color: Color
    let spans: [ClosedRange<Double>]
    let markers: [Double]
    let pixelsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            for span in spans {
                let rect = CGRect(
                    x: span.lowerBound * pixelsPerSecond, y: 7,
                    width: max(3, (span.upperBound - span.lowerBound) * pixelsPerSecond),
                    height: size.height - 14
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color.opacity(0.62)))
            }
            for time in markers {
                let x = time * pixelsPerSecond
                let diamond = Path { path in
                    path.move(to: CGPoint(x: x, y: 8))
                    path.addLine(to: CGPoint(x: x + 5, y: size.height / 2))
                    path.addLine(to: CGPoint(x: x, y: size.height - 8))
                    path.addLine(to: CGPoint(x: x - 5, y: size.height / 2))
                    path.closeSubpath()
                }
                context.fill(diamond, with: .color(.white))
                context.stroke(diamond, with: .color(color), lineWidth: 1.2)
            }
        }
    }
}

private struct TimelineInteractionLane: View {
    let timeline: Timeline
    let events: [InteractionEvent]
    let pixelsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            for event in events where event.type == .click || event.type == .keyActivity {
                guard let time = timeline.firstTimelineTime(forSourceTime: event.timestamp) else { continue }
                let x = time * pixelsPerSecond
                let color: Color = event.type == .click ? .orange : .cyan
                context.fill(
                    Path(roundedRect: CGRect(x: x - 1, y: 8, width: 3, height: size.height - 16), cornerRadius: 1.5),
                    with: .color(color)
                )
            }
        }
    }
}

private struct TimelineWaveformLane: View {
    let waveform: [Double]
    let duration: Double
    let pixelsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            guard !waveform.isEmpty else {
                context.draw(Text("No waveform").font(.caption2).foregroundStyle(.tertiary), at: CGPoint(x: 9, y: size.height / 2), anchor: .leading)
                return
            }
            let path = Path { path in
                for (index, peak) in waveform.enumerated() {
                    let fraction = Double(index) / Double(max(1, waveform.count - 1))
                    let x = fraction * duration * pixelsPerSecond
                    let amplitude = max(CGFloat(1), CGFloat(peak) * (size.height / 2 - 5))
                    path.move(to: CGPoint(x: CGFloat(x), y: size.height / 2 - amplitude))
                    path.addLine(to: CGPoint(x: CGFloat(x), y: size.height / 2 + amplitude))
                }
            }
            context.stroke(path, with: .color(.green.opacity(0.78)), lineWidth: 1)
        }
    }
}
