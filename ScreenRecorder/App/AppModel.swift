import AppKit
import Combine
import Foundation

struct OpenProject: Sendable {
    var project: ScreenProject
    var events: [InteractionEvent]
    var packageURL: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var displays: [DisplayChoice] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var resolution: RecordingResolution = .native
    @Published var frameRate = 60
    @Published var captureSystemAudio = true
    @Published var recordingState: RecordingState = .idle
    @Published var elapsed = 0.0
    @Published var permissionSnapshot = PermissionCenter.current()
    @Published var openProject: OpenProject?
    @Published var errorMessage: String?

    private let session = RecordingSession()
    private let projectStore = ProjectStore()
    private var stateTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    init() {
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
    }

    func refreshDisplays() async {
        permissionSnapshot = PermissionCenter.current()
        do {
            displays = try await ScreenCaptureEngine.availableDisplays()
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.id }
        } catch {
            errorMessage = "Displays are unavailable: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        errorMessage = nil
        if !CGPreflightScreenCaptureAccess() {
            _ = PermissionCenter.requestScreenRecording()
            permissionSnapshot = PermissionCenter.current()
            if !CGPreflightScreenCaptureAccess() {
                errorMessage = "Enable Screen Recording in System Settings, then relaunch the app."
                return
            }
        }
        guard let displayID = selectedDisplayID else {
            errorMessage = "Choose a display before recording."
            return
        }
        let configuration = RecordingConfiguration(
            displayID: displayID,
            resolution: resolution,
            frameRate: frameRate,
            codec: .hevc,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: false,
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

    func openProject(at url: URL) async {
        do {
            let (project, events) = try await projectStore.load(from: url)
            openProject = OpenProject(project: project, events: events, packageURL: url)
            errorMessage = nil
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
    }

    func closeEditor() {
        openProject = nil
        Task { await session.reset() }
    }

    func requestAccessibility() {
        _ = PermissionCenter.requestAccessibility(prompt: true)
        permissionSnapshot = PermissionCenter.current()
    }

    func openPermissionSettings() {
        PermissionCenter.openSystemSettings()
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
