import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let project = model.openProject {
                EditorView(
                    openProject: project,
                    close: model.closeEditor,
                    save: model.saveOpenProject
                )
            } else {
                HomeView()
            }
        }
        .alert("captura", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onChange(of: model.recordingState) { _, state in
            switch state {
            case .recording, .paused, .stopping:
                openWindow(id: "recording-controller")
            case .idle, .finished, .failed:
                dismissWindow(id: "recording-controller")
            case .preparing:
                break
            }
        }
        .onChange(of: model.openProject?.project.id) { _, projectID in
            if projectID == nil {
                dismissWindow(id: "project-preview")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshSourcesAfterActivation() }
        }
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    brandHeader
                    if model.recordingState == .recording || model.recordingState == .paused || model.recordingState == .stopping {
                        RecordingController()
                            .frame(maxWidth: .infinity)
                    } else {
                        sourcePreviewCard
                        configurationForm
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(40)
            }
            .frame(minWidth: 540, maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            RecentProjectsView()
                .frame(width: 330)
        }
        .onChange(of: model.sourceKind) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedDisplayID) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedWindowID) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedExternalDeviceID) { _, _ in model.scheduleSourcePreviewRefresh() }
    }

    private var brandHeader: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("captura")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Record your screen. Shape the story.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.green.opacity(0.1), in: Capsule())
        }
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Source", icon: "rectangle.dashed.badge.record")
                Picker("Capture", selection: $model.sourceKind) {
                    ForEach(CaptureSourceKind.allCases, id: \.self) {
                        Label($0.rawValue, systemImage: sourceIcon($0)).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if let sourceStatusMessage = model.sourceStatusMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(sourceStatusMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Refresh Sources") { Task { await model.refreshDisplays() } }
                            if model.permissionSnapshot.screenRecording != .granted {
                                Button("Grant Access") { Task { await model.requestScreenPermission() } }
                                Button("Open Settings") { model.openPermissionSettings() }
                            }
                        }
                        .buttonStyle(.link)
                    }
                } else if model.sourceKind == .display || model.sourceKind == .area {
                    Picker("Display", selection: $model.selectedDisplayID) {
                        ForEach(model.displays) { display in
                            Text("\(display.name) — \(display.width)×\(display.height)").tag(Optional(display.id))
                        }
                    }
                } else if model.sourceKind == .window {
                    Picker("Window", selection: $model.selectedWindowID) {
                        ForEach(model.windows) { window in
                            Text("\(window.displayName) — \(window.width)×\(window.height)").tag(Optional(window.id))
                        }
                    }
                } else {
                    HStack {
                        Picker("Device", selection: $model.selectedExternalDeviceID) {
                            ForEach(model.externalDevices) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        Button {
                            model.refreshExternalDevices()
                        } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh connected devices")
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Quality", icon: "sparkles.rectangle.stack")
                    Picker("Resolution", selection: $model.resolution) {
                        ForEach(RecordingResolution.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Frame rate", selection: $model.frameRate) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface()

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Inputs", icon: "waveform.and.mic")
                    Toggle(isOn: $model.captureSystemAudio) {
                        Label(
                            model.sourceKind == .device ? "Device audio" : "System audio",
                            systemImage: "speaker.wave.2.fill"
                        )
                    }
                    Toggle(isOn: $model.captureMicrophone) {
                        Label("Microphone", systemImage: "mic.fill")
                    }
                    Toggle(isOn: $model.captureWebcam) {
                        Label("Webcam", systemImage: "video.fill")
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface()
            }

            if model.captureMicrophone {
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(Optional(microphone.id))
                    }
                }
            }
            if model.captureWebcam {
                Picker("Camera", selection: $model.selectedCameraID) {
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
            }

            HStack(spacing: 10) {
                Circle().fill(permissionColor).frame(width: 7, height: 7)
                Text(model.permissionSnapshot.screenRecording == .granted ? "Screen access granted" : "Screen access required")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.permissionSnapshot.screenRecording != .granted {
                    Button("Grant Access") { Task { await model.requestScreenPermission() } }
                        .buttonStyle(.link)
                }
                if model.permissionSnapshot.accessibility != .granted {
                    Button("Enable cursor tracking") { model.requestAccessibility() }
                        .buttonStyle(.link)
                }
                Button("Privacy Settings") { model.openPermissionSettings() }
                    .buttonStyle(.link)
            }
            .font(.caption)

            HStack {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label(model.recordingState == .preparing ? "Preparing…" : "Start Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(
                    (model.sourceKind != .device && model.sourceStatusMessage != nil) ||
                    (model.sourceKind == .device
                        ? model.selectedExternalDeviceID == nil
                        : (model.sourceKind == .window ? model.selectedWindowID == nil : model.selectedDisplayID == nil)) ||
                    model.recordingState == .preparing
                )
            }
        }
        .frame(maxWidth: 560)
    }

    private var sourcePreviewCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let preview = model.sourcePreview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                } else if model.isRefreshingSourcePreview {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 30, weight: .light))
                        Text(model.sourcePreviewMessage ?? "Choose a source to preview")
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                if model.sourceKind == .area, model.sourcePreview != nil {
                    AreaSelectionOverlay(rect: $model.captureRegionNormalized)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack(spacing: 8) {
                Image(systemName: sourceIcon(model.sourceKind))
                Text(selectedSourceName)
                    .lineLimit(1)
                Spacer()
                if model.isRefreshingSourcePreview {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refreshSourcePreview() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh source preview")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.bar)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
        .frame(maxWidth: 560)
        .task(id: previewSelectionKey) {
            await model.refreshSourcePreview()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await model.refreshSourcePreview()
            }
        }
    }

    private var previewSelectionKey: String {
        "\(model.sourceKind.rawValue)-\(model.selectedDisplayID ?? 0)-\(model.selectedWindowID ?? 0)-\(model.selectedExternalDeviceID ?? "")"
    }

    private var selectedSourceName: String {
        if model.sourceKind == .display || model.sourceKind == .area {
            let name = model.displays.first(where: { $0.id == model.selectedDisplayID })?.name ?? "Display preview"
            if model.sourceKind == .area {
                return "\(name) — \(Int(model.captureRegionNormalized.width * 100))% × \(Int(model.captureRegionNormalized.height * 100))%"
            }
            return name
        }
        if model.sourceKind == .device {
            return model.externalDevices.first(where: { $0.id == model.selectedExternalDeviceID })?.name ?? "External device"
        }
        return model.windows.first(where: { $0.id == model.selectedWindowID })?.displayName ?? "Window preview"
    }

    private func sourceIcon(_ kind: CaptureSourceKind) -> String {
        switch kind {
        case .display: "display"
        case .window: "macwindow"
        case .area: "viewfinder.rectangular"
        case .device: "ipad.and.iphone"
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private var permissionColor: Color {
        model.permissionSnapshot.screenRecording == .granted ? .green : .orange
    }
}

private struct AreaSelectionOverlay: View {
    @Binding var rect: CGRect
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let selection = CGRect(
                x: rect.minX * proxy.size.width,
                y: rect.minY * proxy.size.height,
                width: rect.width * proxy.size.width,
                height: rect.height * proxy.size.height
            )
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(selection)
                }
                .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                Text("Drag to select recording area")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                    .position(x: selection.midX, y: max(18, selection.minY - 18))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStart == nil { dragStart = value.startLocation }
                    guard let start = dragStart else { return }
                    let minX = min(start.x, value.location.x) / max(proxy.size.width, 1)
                    let minY = min(start.y, value.location.y) / max(proxy.size.height, 1)
                    let width = abs(value.location.x - start.x) / max(proxy.size.width, 1)
                    let height = abs(value.location.y - start.y) / max(proxy.size.height, 1)
                    rect = CGRect(
                        x: min(max(minX, 0), 0.98),
                        y: min(max(minY, 0), 0.98),
                        width: min(max(width, 0.02), 1 - minX),
                        height: min(max(height, 0.02), 1 - minY)
                    )
                }
                .onEnded { _ in dragStart = nil }
            )
        }
        .accessibilityLabel("Recording area selection")
    }
}

private struct RecentProjectsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Recent Projects")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { Task { await model.refreshRecentProjects() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh projects")
            }

            if model.recentProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Your recordings live here")
                        .font(.headline)
                    Text("Finish a recording or open an existing project to start editing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.recentProjects) { project in
                            Button {
                                Task { await model.openProject(at: project.url) }
                            } label: {
                                RecentProjectRow(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button {
                Task { await model.chooseProject() }
            } label: {
                Label("Open Project…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.recordingState == .preparing)

            Button {
                Task { await model.chooseMediaToImport() }
            } label: {
                Label("Import Video…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.recordingState == .preparing)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct RecentProjectRow: View {
    let project: RecentProject

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.blue.opacity(0.13))
                Image(systemName: project.hasWebcam ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .frame(width: 54, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(format(project.duration))
                    Text("·")
                    Text("\(project.canvas.width)×\(project.canvas.height)")
                    if project.hasWebcam { Image(systemName: "video.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(project.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct RecordingController: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if model.captureWebcam {
                CameraPreviewView(session: model.webcamPreviewSession)
                    .frame(width: 300, height: 169)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .topLeading) {
                        Label("LIVE", systemImage: "circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.88), in: Capsule())
                            .padding(10)
                    }
            }
            HStack(spacing: 12) {
                Circle().fill(model.recordingState == .paused ? .orange : .red).frame(width: 9, height: 9)
                Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                    .monospacedDigit().font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer()
                Button {
                    Task { await model.pauseOrResume() }
                } label: {
                    Image(systemName: model.recordingState == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .help(model.recordingState == .paused ? "Resume" : "Pause")
                Button { Task { await model.stopRecording() } } label: {
                    Label(model.recordingState == .stopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.recordingState == .stopping)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension View {
    func panelSurface() -> some View {
        padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

private final class FloatingWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.isMovableByWindowBackground = true
    }
}

struct FloatingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
