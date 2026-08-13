import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

struct OpenProject: Sendable {
    var project: ScreenProject
    var events: [InteractionEvent]
    var packageURL: URL
}

@MainActor
final class AppModel: ObservableObject {
    private static let recentProjectPathsKey = "captura.recentProjectPaths"
    @Published var displays: [DisplayChoice] = []
    @Published var windows: [WindowChoice] = []
    @Published var microphones: [MicrophoneChoice] = []
    @Published var cameras: [CameraChoice] = []
    @Published var externalDevices: [ExternalDeviceChoice] = []
    @Published var sourceKind: CaptureSourceKind = .display
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var captureRegionNormalized = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @Published var selectedMicrophoneID: String?
    @Published var selectedCameraID: String?
    @Published var selectedExternalDeviceID: String?
    @Published var resolution: RecordingResolution = .native
    @Published var frameRate = 60
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published var captureWebcam = false
    @Published var recordingState: RecordingState = .idle
    @Published var elapsed = 0.0
    @Published var permissionSnapshot = PermissionCenter.current()
    @Published var openProject: OpenProject?
    @Published var recentProjects: [RecentProject] = []
    @Published var sourcePreview: NSImage?
    @Published var isRefreshingSourcePreview = false
    @Published var sourcePreviewMessage: String?
    @Published var errorMessage: String?
    @Published var sourceStatusMessage: String?

    private let webcamCaptureEngine: WebcamCaptureEngine
    private let session: RecordingSession
    private let projectStore = ProjectStore()
    private var stateTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    var webcamPreviewSession: AVCaptureSession { webcamCaptureEngine.previewSession }

    init() {
        let webcamCaptureEngine = WebcamCaptureEngine()
        self.webcamCaptureEngine = webcamCaptureEngine
        session = RecordingSession(webcamCaptureEngine: webcamCaptureEngine)
        stateTask = Task { [weak self, session] in
            for await state in await session.states() {
                guard let self else { return }
                recordingState = state
            }
        }
    }

    deinit {
        stateTask?.cancel()
        clockTask?.cancel()
        previewTask?.cancel()
    }

    func refreshDisplays() async {
        permissionSnapshot = PermissionCenter.current()
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
            windows = try await ScreenCaptureEngine.availableWindows()
            permissionSnapshot.screenRecording = .granted
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.id }
            if selectedWindowID == nil { selectedWindowID = windows.first?.id }
            sourceStatusMessage = displays.isEmpty
                ? "macOS returned no displays. Reopen captura after granting permission."
                : nil
        } catch {
            displays = []
            windows = []
            selectedDisplayID = nil
            selectedWindowID = nil
            sourceStatusMessage = "ScreenCaptureKit could not list sources: \(error.localizedDescription)"
            Log.capture.error("Source discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForRecording() async {
        refreshMicrophones()
        refreshCameras()
        refreshExternalDevices()
        await refreshDisplays()
        await refreshRecentProjects()
        await refreshSourcePreview()
    }

    func scheduleSourcePreviewRefresh() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.refreshSourcePreview()
        }
    }

    func refreshSourcePreview() async {
        guard recordingState == .idle || isTerminalRecordingState else { return }
        if sourceKind == .device {
            sourcePreview = nil
            sourcePreviewMessage = selectedExternalDeviceID == nil
                ? "Connect and choose an iPhone, iPad, or capture device."
                : "External device selected. Its native video feed will be recorded."
            return
        }
        let displayID = sourceKind == .display || sourceKind == .area ? selectedDisplayID : nil
        let windowID = sourceKind == .window ? selectedWindowID : nil
        guard displayID != nil || windowID != nil else {
            sourcePreview = nil
            sourcePreviewMessage = "Choose a source to preview."
            return
        }

        isRefreshingSourcePreview = true
        defer { isRefreshingSourcePreview = false }
        do {
            let image = try await SourcePreviewService.snapshot(displayID: displayID, windowID: windowID)
            guard displayID == (sourceKind == .display || sourceKind == .area ? selectedDisplayID : nil),
                  windowID == (sourceKind == .window ? selectedWindowID : nil) else { return }
            sourcePreview = image
            sourcePreviewMessage = nil
        } catch {
            sourcePreviewMessage = "Preview unavailable: \(error.localizedDescription)"
        }
    }

    private var isTerminalRecordingState: Bool {
        switch recordingState {
        case .finished, .failed: true
        default: false
        }
    }

    func refreshRecentProjects() async {
        do {
            var projects = try await projectStore.recentProjects()
            let storedPaths = UserDefaults.standard.stringArray(forKey: Self.recentProjectPathsKey) ?? []
            for path in storedPaths {
                let url = URL(filePath: path, directoryHint: .isDirectory)
                guard !projects.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
                      let summary = try? await projectStore.projectSummary(at: url) else { continue }
                projects.append(summary)
            }
            recentProjects = Array(projects.sorted { $0.createdAt > $1.createdAt }.prefix(20))
        } catch {
            Log.project.warning("Could not load recent projects: \(error.localizedDescription)")
            recentProjects = []
        }
    }

    func requestScreenPermission() async {
        _ = PermissionCenter.requestScreenRecording()
        permissionSnapshot = PermissionCenter.current()
        await refreshDisplays()
        if !CGPreflightScreenCaptureAccess() {
            errorMessage = "macOS may require enabling captura in Privacy & Security → Screen & System Audio Recording, then reopening the app."
        }
    }

    func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        microphones = session.devices.map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }
        if selectedMicrophoneID == nil { selectedMicrophoneID = microphones.first?.id }
    }

    func refreshCameras() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        cameras = session.devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        if selectedCameraID == nil { selectedCameraID = cameras.first?.id }
    }

    func refreshExternalDevices() {
        externalDevices = ExternalDeviceCaptureEngine.availableDevices()
        if selectedExternalDeviceID == nil { selectedExternalDeviceID = externalDevices.first?.id }
    }

    func startRecording() async {
        errorMessage = nil
        if sourceKind != .device && displays.isEmpty && windows.isEmpty {
            await refreshDisplays()
        }
        if sourceKind == .device && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await PermissionCenter.requestCamera() else {
                errorMessage = "Device video access was denied. Enable captura in Privacy & Security → Camera."
                return
            }
            refreshExternalDevices()
        }
        if sourceKind == .device && captureSystemAudio && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await PermissionCenter.requestMicrophone() else {
                errorMessage = "Device audio access was denied. Disable device audio or enable captura in Privacy & Security → Microphone."
                return
            }
        }
        if captureWebcam && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await PermissionCenter.requestCamera() else {
                errorMessage = "Camera access was denied. Enable it in Privacy & Security → Camera."
                return
            }
            refreshCameras()
        }
        if captureMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await PermissionCenter.requestMicrophone() else {
                errorMessage = "Microphone access was denied. Enable it in Privacy & Security → Microphone."
                return
            }
            refreshMicrophones()
        }
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        let windowID = sourceKind == .window ? selectedWindowID : nil
        guard sourceKind == .device
                ? selectedExternalDeviceID != nil
                : (sourceKind == .window ? windowID != nil : selectedDisplayID != nil) else {
            errorMessage = "Choose a \(sourceKind.rawValue.lowercased()) before recording."
            return
        }
        let configuration = RecordingConfiguration(
            displayID: displayID,
            windowID: windowID,
            normalizedCropRect: sourceKind == .area ? captureRegionNormalized : nil,
            externalDeviceID: sourceKind == .device ? selectedExternalDeviceID : nil,
            resolution: resolution,
            frameRate: frameRate,
            codec: .hevc,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            microphoneDeviceID: captureMicrophone ? selectedMicrophoneID : nil,
            captureWebcam: captureWebcam,
            webcamDeviceID: captureWebcam ? selectedCameraID : nil,
            captureCursorInVideo: false
        )
        do {
            try await session.start(configuration: configuration)
            elapsed = 0
            startClock()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pauseOrResume() async {
        do {
            switch recordingState {
            case .recording:
                try await session.pause()
                clockTask?.cancel()
            case .paused:
                try await session.resume()
                startClock()
            default: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        clockTask?.cancel()
        do {
            let url = try await session.stop()
            await openProject(at: url)
            await refreshRecentProjects()
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.windows.first { window in
                window.level == .normal && window.isVisible && window.canBecomeMain
            })?.makeKeyAndOrderFront(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseProject() async {
        let panel = NSOpenPanel()
        panel.title = "Open Screen Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openProject(at: url)
    }

    func chooseMediaToImport() async {
        let panel = NSOpenPanel()
        panel.title = "Import Video"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let projectURL = try await projectStore.importVideo(from: sourceURL)
            await openProject(at: projectURL)
        } catch {
            errorMessage = "Could not import video: \(error.localizedDescription)"
        }
    }

    func openProject(at url: URL) async {
        do {
            let (project, events) = try await projectStore.load(from: url)
            openProject = OpenProject(project: project, events: events, packageURL: url)
            rememberProject(url)
            await refreshRecentProjects()
            errorMessage = nil
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
    }

    private func rememberProject(_ url: URL) {
        let normalized = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentProjectPathsKey) ?? []
        paths.removeAll { $0 == normalized }
        paths.insert(normalized, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: Self.recentProjectPathsKey)
    }

    func closeEditor() {
        openProject = nil
        Task { await session.reset() }
    }

    func saveOpenProject(_ project: ScreenProject) async -> Bool {
        guard let current = openProject else { return false }
        do {
            try await projectStore.update(project: project, events: current.events, at: current.packageURL)
            openProject = OpenProject(project: project, events: current.events, packageURL: current.packageURL)
            await refreshRecentProjects()
            return true
        } catch {
            errorMessage = "Could not save project: \(error.localizedDescription)"
            return false
        }
    }

    func requestAccessibility() {
        _ = PermissionCenter.requestAccessibility(prompt: true)
        permissionSnapshot = PermissionCenter.current()
    }

    func openPermissionSettings() {
        PermissionCenter.openSystemSettings()
    }

    func refreshSourcesAfterActivation() async {
        let wasGranted = permissionSnapshot.screenRecording == .granted
        await refreshDisplays()
        if !wasGranted && permissionSnapshot.screenRecording == .granted {
            sourceStatusMessage = displays.isEmpty ? "Permission changed. Reopen captura if sources remain unavailable." : nil
        }
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.elapsed += 1
            }
        }
    }
}
