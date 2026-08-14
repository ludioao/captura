import SwiftUI

@main
struct CapturaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
                .task { await model.prepareForRecording() }
                .onOpenURL { url in Task { await model.openProject(at: url) } }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project…") { Task { await model.chooseProject() } }
                    .keyboardShortcut("o")
            }
        }

        Window("captura Recording", id: "recording-controller") {
            RecordingController(isFloating: true)
                .environmentObject(model)
                .background(FloatingWindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 450)
        .defaultPosition(.topTrailing)

        Window("Project Preview", id: "project-preview") {
            if let project = model.openProject {
                FloatingProjectPreview(openProject: project)
                    .id(project.project.id)
                    .background(FloatingWindowAccessor())
            } else {
                ContentUnavailableView("No Project Open", systemImage: "play.rectangle")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}
