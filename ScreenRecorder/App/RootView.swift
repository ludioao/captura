import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let project = model.openProject {
                EditorView(openProject: project, close: model.closeEditor)
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
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("captura")
                .font(.largeTitle.weight(.semibold))

            if model.recordingState == .recording || model.recordingState == .paused || model.recordingState == .stopping {
                RecordingController()
            } else {
                configurationForm
            }
            Spacer()
            Button("Open Existing Project…") { Task { await model.chooseProject() } }
                .buttonStyle(.link)
                .disabled(model.recordingState == .preparing)
        }
        .padding(40)
    }

    private var configurationForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
            GridRow {
                Text("Source")
                Picker("Source", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in
                        Text("\(display.name) — \(display.width)×\(display.height)").tag(Optional(display.id))
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Resolution")
                Picker("Resolution", selection: $model.resolution) {
                    ForEach(RecordingResolution.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Frame rate")
                Picker("Frame rate", selection: $model.frameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                .labelsHidden()
            }
            GridRow {
                Toggle("System Audio", isOn: $model.captureSystemAudio)
                    .gridCellColumns(2)
            }
            GridRow {
                HStack {
                    Toggle("Microphone", isOn: .constant(false)).disabled(true)
                    Text("Coming next").foregroundStyle(.secondary).font(.caption)
                }
                .gridCellColumns(2)
            }
            GridRow {
                HStack {
                    Circle().fill(permissionColor).frame(width: 8, height: 8)
                    Text("Screen permission: \(model.permissionSnapshot.screenRecording.rawValue)")
                        .foregroundStyle(.secondary)
                    Button("Settings") { model.openPermissionSettings() }.buttonStyle(.link)
                    if model.permissionSnapshot.accessibility != .granted {
                        Button("Enable Accessibility") { model.requestAccessibility() }.buttonStyle(.link)
                    }
                }
                .font(.caption)
                .gridCellColumns(2)
            }
            GridRow {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label(model.recordingState == .preparing ? "Preparing…" : "Start Recording", systemImage: "record.circle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedDisplayID == nil || model.recordingState == .preparing)
                .gridCellColumns(2)
            }
        }
        .frame(width: 450)
    }

    private var permissionColor: Color {
        model.permissionSnapshot.screenRecording == .granted ? .green : .orange
    }
}

private struct RecordingController: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            Circle().fill(.red).frame(width: 12, height: 12)
            Text(Duration.seconds(model.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                .monospacedDigit().font(.title2)
            Button(model.recordingState == .paused ? "Resume" : "Pause") {
                Task { await model.pauseOrResume() }
            }
            Button("Stop", role: .destructive) { Task { await model.stopRecording() } }
                .disabled(model.recordingState == .stopping)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
