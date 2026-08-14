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
        VStack(spacing: 0) {
            brandHeader
            Divider()

            if model.recordingState == .recording || model.recordingState == .paused || model.recordingState == .stopping {
                RecordingController()
                    .frame(minWidth: 600, idealWidth: 960, maxWidth: 1_200, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
            } else {
                HSplitView {
                    sourcePreviewCard
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                    ScrollView {
                        configurationForm
                            .padding(24)
                    }
                    .frame(minWidth: 330, idealWidth: 360, maxWidth: 390)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
                }

                Divider()

                RecentProjectsView()
                    .frame(height: 190)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.sourceKind) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedDisplayID) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedWindowID) { _, _ in model.scheduleSourcePreviewRefresh() }
        .onChange(of: model.selectedExternalDeviceID) { _, _ in model.scheduleSourcePreviewRefresh() }
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("captura")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("New recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button { Task { await model.chooseMediaToImport() } } label: {
                Label("Import Video", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)

            Button { Task { await model.chooseProject() } } label: {
                Label("Open Project", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(.bar)
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up recording")
                    .font(.title2.weight(.semibold))
                Text("Choose what captura should record and how it should sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Source", icon: "rectangle.dashed.badge.record")
                Picker("Capture", selection: $model.sourceKind) {
                    ForEach(CaptureSourceKind.allCases, id: \.self) {
                        Label($0.rawValue, systemImage: sourceIcon($0)).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if let sourceStatusMessage = model.sourceStatusMessage, model.sourceKind != .device {
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
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Display", selection: $model.selectedDisplayID) {
                            ForEach(model.displays) { display in
                                Text("\(display.name) — \(display.width)×\(display.height)").tag(Optional(display.id))
                            }
                        }
                        if model.sourceKind == .area {
                            Picker("Area aspect", selection: $model.areaAspectLock) {
                                ForEach(AreaAspectLock.allCases, id: \.self) { lock in
                                    Text(lock.rawValue).tag(lock)
                                }
                            }
                            .pickerStyle(.segmented)
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

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Audio & camera", icon: "waveform.and.mic")
                inputToggle(
                    title: model.sourceKind == .device ? "Device audio" : "System audio",
                    detail: model.sourceKind == .device ? "Sound from the connected device" : "Apps, calls and browser audio",
                    icon: "speaker.wave.2.fill",
                    isOn: $model.captureSystemAudio
                )
                inputToggle(
                    title: "Microphone",
                    detail: "Add your voice as a separate input",
                    icon: "mic.fill",
                    isOn: $model.captureMicrophone
                )
                if model.captureMicrophone {
                    Picker("Microphone", selection: $model.selectedMicrophoneID) {
                        ForEach(model.microphones) { microphone in
                            Text(microphone.name).tag(Optional(microphone.id))
                        }
                    }
                }
                inputToggle(
                    title: "Webcam",
                    detail: "Record your camera alongside the screen",
                    icon: "video.fill",
                    isOn: $model.captureWebcam
                )
                if model.captureWebcam {
                    Picker("Camera", selection: $model.selectedCameraID) {
                        ForEach(model.cameras) { camera in
                            Text(camera.name).tag(Optional(camera.id))
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Quality", icon: "sparkles.rectangle.stack")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Resolution").foregroundStyle(.secondary)
                        Picker("Resolution", selection: $model.resolution) {
                            ForEach(RecordingResolution.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Frame rate").foregroundStyle(.secondary)
                        Picker("Frame rate", selection: $model.frameRate) {
                            Text("30 FPS").tag(30)
                            Text("60 FPS").tag(60)
                        }
                        .labelsHidden()
                    }
                }
            }

            HStack(spacing: 10) {
                Circle().fill(permissionColor).frame(width: 7, height: 7)
                Text(permissionStatusText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.sourceKind != .device && model.permissionSnapshot.screenRecording != .granted {
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

            Button {
                Task { await model.startRecording() }
            } label: {
                HStack {
                    Image(systemName: "record.circle.fill")
                    Text(model.recordingState == .preparing ? "Preparing…" : "Start Recording")
                    Spacer()
                    Text("⌘↩")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.72))
                }
                .font(.headline)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(recordButtonDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var sourcePreviewCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live preview")
                        .font(.headline)
                    Text(selectedSourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.isRefreshingSourcePreview { ProgressView().controlSize(.small) }
                Button { Task { await model.refreshSourcePreview() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh source preview")
            }
            .padding(.horizontal, 24)
            .frame(height: 64)

            ZStack {
                Color(nsColor: .black)
                VStack {
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
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.dashed")
                                    .font(.system(size: 34, weight: .light))
                                Text(model.sourcePreviewMessage ?? "Choose a source to preview")
                                    .font(.callout)
                            }
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        if model.sourceKind == .area, model.sourcePreview != nil {
                            AreaSelectionOverlay(
                                rect: $model.captureRegionNormalized,
                                aspectRatio: model.areaAspectLock.ratio
                            )
                        }
                    }
                    .aspectRatio(sourcePreviewAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 14)
                }
                .padding(32)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: sourceIcon(model.sourceKind))
                Text(model.sourceKind.rawValue)
                Spacer()
                Label(model.resolution.displayName, systemImage: "aspectratio")
                Text("·")
                Text("\(model.frameRate) FPS")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .frame(height: 44)
            .background(.bar)
        }
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

    private func inputToggle(
        title: String,
        detail: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var recordButtonDisabled: Bool {
        (model.sourceKind != .device && model.sourceStatusMessage != nil) ||
        (model.sourceKind == .device
            ? model.selectedExternalDeviceID == nil
            : (model.sourceKind == .window ? model.selectedWindowID == nil : model.selectedDisplayID == nil)) ||
        model.recordingState == .preparing
    }

    private var permissionColor: Color {
        if model.sourceKind == .device {
            return model.selectedExternalDeviceID == nil ? .orange : .green
        }
        return model.permissionSnapshot.screenRecording == .granted ? .green : .orange
    }

    private var permissionStatusText: String {
        if model.sourceKind == .device {
            return model.selectedExternalDeviceID == nil ? "Connect a capture device" : "Device ready"
        }
        return model.permissionSnapshot.screenRecording == .granted ? "Screen access granted" : "Screen access required"
    }

    private var sourcePreviewAspectRatio: CGFloat {
        guard let image = model.sourcePreview, image.size.height > 0 else { return 16 / 9 }
        return image.size.width / image.size.height
    }
}

private struct AreaSelectionOverlay: View {
    @Binding var rect: CGRect
    let aspectRatio: CGFloat?
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
                    rect = AreaSelectionGeometry.normalizedRect(
                        start: start,
                        current: value.location,
                        canvasSize: proxy.size,
                        aspectRatio: aspectRatio
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recent projects")
                        .font(.headline)
                    Text(model.recentProjects.isEmpty ? "Your finished recordings will appear here" : "Continue where you left off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshRecentProjects() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh projects")
            }

            if model.recentProjects.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Record something new, open a project, or import an existing video.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
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
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct RecentProjectRow: View {
    let project: RecentProject

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Circle().fill(.red.opacity(0.9))
                        Circle().fill(.yellow.opacity(0.9))
                        Circle().fill(.green.opacity(0.9))
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 13)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            Image(systemName: project.hasWebcam ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                }
            }
            .frame(width: 88, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.callout.weight(.semibold))
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
            .frame(width: 150, alignment: .leading)
        }
        .padding(8)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct RecordingController: View {
    @EnvironmentObject private var model: AppModel
    var isFloating = false

    var body: some View {
        VStack(spacing: 14) {
            recordingPreview
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
        .padding(isFloating ? 16 : 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordingPreview: some View {
        GeometryReader { proxy in
            let cameraWidth = min(max(proxy.size.width * 0.22, 120), 280)
            ZStack(alignment: .bottomTrailing) {
                Color.black
                if let preview = model.liveScreenPreview ?? model.sourcePreview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                if model.captureWebcam {
                    CameraPreviewView(session: model.webcamPreviewSession)
                        .frame(width: cameraWidth, height: cameraWidth * 0.625)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.75), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.42), radius: 10, y: 5)
                        .padding(min(max(proxy.size.width * 0.018, 10), 20))
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(
            minWidth: isFloating ? 500 : nil,
            idealWidth: isFloating ? 640 : 960,
            maxWidth: isFloating ? 820 : .infinity,
            minHeight: isFloating ? 281 : nil,
            idealHeight: isFloating ? 360 : 540,
            maxHeight: .infinity
        )
        .layoutPriority(1)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topLeading) {
            Label("LIVE", systemImage: "circle.fill")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.red.opacity(0.9), in: Capsule())
                .padding(10)
        }
        .accessibilityLabel("Live screen and webcam recording preview")
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
