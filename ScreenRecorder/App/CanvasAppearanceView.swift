import AppKit
import AVFoundation
import SwiftUI

struct CanvasMockupPreview: View {
    let player: AVPlayer
    let cameraPlayer: AVPlayer?
    let sourceSize: CanvasSize
    @Binding var appearance: CanvasAppearance
    var allowsCameraDragging = true
    var cursorSample: CursorSample? = nil
    var cursorAppearance: CursorAppearance = .default
    var caption: String? = nil
    var cameraFrame: CameraKeyframe? = nil
    @State private var cameraDragOrigin: CGPoint?
    @State private var cameraResizeOrigin: CGSize?

    private let macTitlebarRatio = 0.032

    var body: some View {
        GeometryReader { proxy in
            let shortestSide = min(proxy.size.width, proxy.size.height)
            let previewPadding = min(shortestSide * 0.22, max(14, shortestSide * appearance.padding / 720))
            ZStack {
                Rectangle().fill(canvasBackgroundStyle(appearance))

                GeometryReader { mockupProxy in
                    let titlebarHeight = appearance.showsWindowFrame ? mockupProxy.size.width * macTitlebarRatio : 0
                    VStack(spacing: 0) {
                        if appearance.showsWindowFrame {
                            MacWindowTitleBar(height: titlebarHeight)
                                .frame(height: titlebarHeight)
                        }
                        GeometryReader { contentProxy in
                            ZStack {
                                NativePlayerView(player: player)
                                    .background(.black)
                                    .scaleEffect(max(1, cameraFrame?.scale ?? 1))
                                    .offset(
                                        x: (0.5 - (cameraFrame?.centerX ?? 0.5)) * contentProxy.size.width * max(0, (cameraFrame?.scale ?? 1) - 1),
                                        y: (0.5 - (cameraFrame?.centerY ?? 0.5)) * contentProxy.size.height * max(0, (cameraFrame?.scale ?? 1) - 1)
                                    )

                                if let cameraPlayer {
                                    cameraOverlay(player: cameraPlayer, in: contentProxy.size)
                                }

                                if cursorAppearance.isVisible, let cursorSample {
                                    Image(systemName: cursorSample.cursorType == .pointingHand ? "hand.point.up.left.fill" : "cursorarrow")
                                        .font(.system(size: 22 * cursorAppearance.size, weight: .semibold))
                                        .foregroundStyle(.white, .black)
                                        .shadow(color: .black.opacity(0.65), radius: 1, x: 1, y: 1)
                                        .position(
                                            x: contentProxy.size.width * cursorSample.normalizedX,
                                            y: contentProxy.size.height * cursorSample.normalizedY
                                        )
                                }

                                if let caption, !caption.isEmpty {
                                    Text(caption)
                                        .font(.system(size: max(14, contentProxy.size.width * 0.026), weight: .semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 9)
                                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                        .frame(maxWidth: contentProxy.size.width * 0.82)
                                        .position(x: contentProxy.size.width / 2, y: contentProxy.size.height * 0.88)
                                }
                            }
                        }
                    }
                }
                .aspectRatio(mockupAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius))
                .overlay {
                    if appearance.showsWindowFrame {
                        RoundedRectangle(cornerRadius: windowCornerRadius)
                            .strokeBorder(.black.opacity(0.28), lineWidth: 0.75)
                    }
                }
                .shadow(
                    color: .black.opacity(min(0.42, 0.08 + appearance.shadowStrength / 90)),
                    radius: appearance.shadowStrength,
                    y: appearance.shadowStrength * 0.45
                )
                .padding(previewPadding)
            }
        }
        .background(.black)
        .accessibilityLabel("Styled video preview")
    }

    private var sourceAspectRatio: Double {
        Double(sourceSize.width) / Double(max(1, sourceSize.height))
    }

    private var mockupAspectRatio: Double {
        guard appearance.showsWindowFrame else { return sourceAspectRatio }
        return 1 / (1 / sourceAspectRatio + macTitlebarRatio)
    }

    private var windowCornerRadius: Double {
        appearance.showsWindowFrame ? 9 : appearance.cornerRadius
    }

    private func cameraOverlay(player: AVPlayer, in size: CGSize) -> some View {
        let width = max(56, size.width * appearance.cameraWidth)
        let height = max(56, size.height * appearance.cameraHeight)
        let normalizedHalfWidth = width / max(size.width, 1) / 2
        let normalizedHalfHeight = height / max(size.height, 1) / 2
        return NativePlayerView(player: player, videoGravity: .resizeAspectFill)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: max(8, appearance.cornerRadius * 0.65)))
            .overlay(
                RoundedRectangle(cornerRadius: max(8, appearance.cornerRadius * 0.65))
                    .stroke(.white.opacity(0.78), lineWidth: 1.5)
            )
            .overlay(alignment: .bottomTrailing) {
                if allowsCameraDragging {
                    CameraResizeHandle()
                        .offset(x: 6, y: 6)
                        .highPriorityGesture(cameraResizeGesture(in: size))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            .position(
                x: size.width * appearance.cameraPositionX,
                y: size.height * appearance.cameraPositionY
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard allowsCameraDragging else { return }
                        if cameraDragOrigin == nil {
                            cameraDragOrigin = CGPoint(x: appearance.cameraPositionX, y: appearance.cameraPositionY)
                        }
                        guard let origin = cameraDragOrigin else { return }
                        appearance.cameraPositionX = min(
                            1 - normalizedHalfWidth,
                            max(normalizedHalfWidth, origin.x + value.translation.width / max(size.width, 1))
                        )
                        appearance.cameraPositionY = min(
                            1 - normalizedHalfHeight,
                            max(normalizedHalfHeight, origin.y + value.translation.height / max(size.height, 1))
                        )
                    }
                    .onEnded { _ in cameraDragOrigin = nil }
            )
            .help(allowsCameraDragging ? "Drag to reposition the camera" : "Camera overlay")
    }

    private func cameraResizeGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cameraResizeOrigin == nil {
                    cameraResizeOrigin = CGSize(width: appearance.cameraWidth, height: appearance.cameraHeight)
                }
                guard let origin = cameraResizeOrigin else { return }
                appearance.cameraWidth = min(0.62, max(0.12, origin.width + value.translation.width / max(size.width, 1)))
                appearance.cameraHeight = min(0.62, max(0.12, origin.height + value.translation.height / max(size.height, 1)))
                clampCameraPosition()
            }
            .onEnded { _ in cameraResizeOrigin = nil }
    }

    private func clampCameraPosition() {
        let halfWidth = appearance.cameraWidth / 2
        let halfHeight = appearance.cameraHeight / 2
        appearance.cameraPositionX = min(1 - halfWidth, max(halfWidth, appearance.cameraPositionX))
        appearance.cameraPositionY = min(1 - halfHeight, max(halfHeight, appearance.cameraPositionY))
    }
}

private struct MacWindowTitleBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let height: Double

    var body: some View {
        ZStack {
            HStack(spacing: trafficLightSize * 0.68) {
                trafficLight("#FF5F57")
                trafficLight("#FEBC2E")
                trafficLight("#28C840")
                Spacer()
            }
            .padding(.leading, height * 0.48)

            Text("captura")
                .font(.system(size: max(8, height * 0.36), weight: .medium))
                .foregroundStyle(.secondary)
        }
        .background {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(capturaHex: "#3A3A3D"), Color(capturaHex: "#303033")]
                    : [Color(capturaHex: "#F4F4F5"), Color(capturaHex: "#E6E6E8")],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(colorScheme == .dark ? 0.08 : 0.72)).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(colorScheme == .dark ? 0.34 : 0.12))
                .frame(height: 0.75)
        }
    }

    private var trafficLightSize: Double { max(7, min(12, height * 0.4)) }

    private func trafficLight(_ hex: String) -> some View {
        Circle()
            .fill(Color(capturaHex: hex))
            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            .overlay(alignment: .top) {
                Circle().fill(.white.opacity(0.2)).frame(width: trafficLightSize * 0.62, height: trafficLightSize * 0.34)
                    .padding(.top, trafficLightSize * 0.08)
            }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .frame(width: trafficLightSize, height: trafficLightSize)
    }
}

private struct CameraResizeHandle: View {
    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(.black.opacity(0.24), lineWidth: 0.75)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .frame(width: 19, height: 19)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .contentShape(Circle())
        .help("Drag to resize width and height")
        .accessibilityLabel("Resize camera")
    }
}

struct CanvasAppearanceInspector: View {
    @Binding var appearance: CanvasAppearance
    let hasCamera: Bool
    @State private var savedPresets = CanvasPresetStore.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Canvas")
                    .font(.title3.weight(.semibold))

                HStack {
                    Menu("Presets") {
                        Button("Captura Default") { appearance = .default }
                        ForEach(savedPresets) { preset in
                            Button(preset.name) { appearance = preset.appearance }
                        }
                        if !savedPresets.isEmpty {
                            Divider()
                            Button("Clear saved presets", role: .destructive) {
                                savedPresets = []
                                CanvasPresetStore.save(savedPresets)
                            }
                        }
                    }
                    Button("Save current") {
                        savedPresets.append(SavedCanvasPreset(
                            name: "Preset \(savedPresets.count + 1)",
                            appearance: appearance
                        ))
                        CanvasPresetStore.save(savedPresets)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Background").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 10)], spacing: 10) {
                        ForEach(CanvasBackgroundPreset.allCases, id: \.self) { preset in
                            Button {
                                appearance.backgroundPreset = preset
                            } label: {
                                Circle()
                                    .fill(canvasBackgroundStyle(appearanceForSwatch(preset)))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if appearance.backgroundPreset == preset {
                                            Circle().stroke(.white, lineWidth: 2)
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                                .shadow(radius: 2)
                                        }
                                    }
                                    .overlay(Circle().stroke(.black.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .help(preset.displayName)
                        }
                    }
                    if appearance.backgroundPreset == .custom {
                        ColorPicker("Custom color", selection: customColorBinding)
                    }
                }

                slider("Padding", value: $appearance.padding, range: 16...144, suffix: " px")
                slider("Corner radius", value: $appearance.cornerRadius, range: 0...36, suffix: " px")
                slider("Shadow", value: $appearance.shadowStrength, range: 0...32, suffix: "")

                Toggle(isOn: $appearance.showsWindowFrame) {
                    Label("Window frame", systemImage: "macwindow")
                }
                .toggleStyle(.switch)

                if hasCamera {
                    Divider()
                    cameraControls
                }

                Text("These settings are saved with the project and are the source of truth for the render pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera").font(.headline)
            HStack(spacing: 9) {
                cameraPositionButton(x: 0.16, y: 0.18, label: "Top left")
                cameraPositionButton(x: 0.84, y: 0.18, label: "Top right")
                cameraPositionButton(x: 0.16, y: 0.82, label: "Bottom left")
                cameraPositionButton(x: 0.84, y: 0.82, label: "Bottom right")
            }

            cameraDimensionSlider("Width", value: cameraDimensionBinding(\.cameraWidth))
            cameraDimensionSlider("Height", value: cameraDimensionBinding(\.cameraHeight))

            Label("Drag the camera to move it, or use its corner handle to resize it.", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cameraDimensionSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.12...0.62)
        }
    }

    private func cameraDimensionBinding(_ keyPath: WritableKeyPath<CanvasAppearance, Double>) -> Binding<Double> {
        Binding(
            get: { appearance[keyPath: keyPath] },
            set: { newValue in
                appearance[keyPath: keyPath] = newValue
                let halfWidth = appearance.cameraWidth / 2
                let halfHeight = appearance.cameraHeight / 2
                appearance.cameraPositionX = min(1 - halfWidth, max(halfWidth, appearance.cameraPositionX))
                appearance.cameraPositionY = min(1 - halfHeight, max(halfHeight, appearance.cameraPositionY))
            }
        )
    }

    private func cameraPositionButton(x: Double, y: Double, label: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                appearance.cameraPositionX = x
                appearance.cameraPositionY = y
            }
        } label: {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Circle()
                            .fill(.tint)
                            .frame(width: 8, height: 8)
                            .position(x: proxy.size.width * x, y: proxy.size.height * y)
                    }
            }
            .frame(width: 42, height: 30)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func appearanceForSwatch(_ preset: CanvasBackgroundPreset) -> CanvasAppearance {
        var value = appearance
        value.backgroundPreset = preset
        return value
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(capturaHex: appearance.customColorHex) },
            set: {
                appearance.customColorHex = NSColor($0).capturaHex
                appearance.backgroundPreset = .custom
            }
        )
    }
}

private struct SavedCanvasPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var appearance: CanvasAppearance
}

private enum CanvasPresetStore {
    private static let key = "captura.canvasPresets"
    static func load() -> [SavedCanvasPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedCanvasPreset].self, from: data)) ?? []
    }
    static func save(_ presets: [SavedCanvasPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
    }
}

func canvasBackgroundStyle(_ appearance: CanvasAppearance) -> AnyShapeStyle {
    switch appearance.backgroundPreset {
    case .studio:
        AnyShapeStyle(LinearGradient(colors: [Color(capturaHex: "#F2D6C8"), Color(capturaHex: "#C6A7E8")], startPoint: .topLeading, endPoint: .bottomTrailing))
    case .midnight:
        AnyShapeStyle(LinearGradient(colors: [Color(capturaHex: "#101426"), Color(capturaHex: "#343E68")], startPoint: .topLeading, endPoint: .bottomTrailing))
    case .ocean:
        AnyShapeStyle(LinearGradient(colors: [Color(capturaHex: "#0B6B78"), Color(capturaHex: "#7BDCB5")], startPoint: .topLeading, endPoint: .bottomTrailing))
    case .sunset:
        AnyShapeStyle(LinearGradient(colors: [Color(capturaHex: "#F97356"), Color(capturaHex: "#8E4EC6")], startPoint: .topLeading, endPoint: .bottomTrailing))
    case .graphite:
        AnyShapeStyle(LinearGradient(colors: [Color(capturaHex: "#24262B"), Color(capturaHex: "#555A65")], startPoint: .top, endPoint: .bottom))
    case .custom:
        AnyShapeStyle(Color(capturaHex: appearance.customColorHex))
    }
}

private extension Color {
    init(capturaHex hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let parsed = UInt64(value, radix: 16) ?? 0x6C5CE7
        let red = Double((parsed >> 16) & 0xFF) / 255
        let green = Double((parsed >> 8) & 0xFF) / 255
        let blue = Double(parsed & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private extension NSColor {
    var capturaHex: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#6C5CE7" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
