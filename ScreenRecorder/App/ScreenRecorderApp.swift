import SwiftUI

@main
struct CapturaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
                .task { await model.refreshDisplays() }
                .onOpenURL { url in Task { await model.openProject(at: url) } }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project…") { Task { await model.chooseProject() } }
                    .keyboardShortcut("o")
            }
        }
    }
}
