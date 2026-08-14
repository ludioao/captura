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
    var overlays: [OverlayRegion] = []
    var timelineTime = 0.0
    var isMetalComposed = false
    @State private var cameraDragOrigin: CGPoint?
    @State private var cameraResizeOrigin: CGSize?

    var body: some View {
        Group {
            if isMetalComposed {
                GeometryReader { proxy in
                    ZStack {
                        NativePlayerView(player: player)
                            .background(.black)
                        if allowsCameraDragging, cameraPlayer != nil {
                            cameraInteractionOverlay(in: proxy.size)
                        }
                        if let caption, !caption.isEmpty {
                            Text(caption)
                                .font(.system(size: max(14, proxy.size.width * 0.026), weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.88)
                        }
                    }
                }
            } else {
                GeometryReader { proxy in
            let shortestSide = min(proxy.size.width, proxy.size.height)
            let previewPadding = min(shortestSide * 0.22, max(14, shortestSide * appearance.padding / 720))
            ZStack {
                Rectangle().fill(canvasBackgroundStyle(appearance))

                GeometryReader { mockupProxy in
                    let titlebarHeight = appearance.showsWindowFrame
                        ? mockupProxy.size.width * MacWindowChromeMetrics.titlebarToWindowWidth
                        : 0
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

                                ForEach(activeOverlays) { overlay in
                                    overlayView(overlay, in: contentProxy.size)
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
            }
        }
        .background(.black)
        .accessibilityLabel("Styled video preview")
    }

    private func cameraInteractionOverlay(in size: CGSize) -> some View {
        let geometry = ExportGeometry(outputSize: size, sourceSize: sourceSize, appearance: appearance)
        let width = geometry.cameraRect.width
        let height = geometry.cameraRect.height
        let halfWidth = appearance.cameraWidth / 2
        let halfHeight = appearance.cameraHeight / 2
        return Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: width, height: height)
            .overlay(alignment: .bottomTrailing) {
                CameraResizeHandle()
                    .offset(x: 6, y: 6)
                    .highPriorityGesture(cameraResizeGesture(in: geometry.screenRect.size))
            }
            .position(x: geometry.cameraRect.midX, y: geometry.cameraRect.midY)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if cameraDragOrigin == nil {
                        cameraDragOrigin = CGPoint(x: appearance.cameraPositionX, y: appearance.cameraPositionY)
                    }
                    guard let origin = cameraDragOrigin else { return }
                    appearance.cameraPositionX = min(
                        1 - halfWidth,
                        max(halfWidth, origin.x + value.translation.width / max(geometry.screenRect.width, 1))
                    )
                    appearance.cameraPositionY = min(
                        1 - halfHeight,
                        max(halfHeight, origin.y + value.translation.height / max(geometry.screenRect.height, 1))
                    )
                }
                .onEnded { _ in cameraDragOrigin = nil }
            )
            .help("Drag to reposition the camera")
    }

    private var activeOverlays: [OverlayRegion] {
        overlays.filter { timelineTime >= $0.startTime && timelineTime <= $0.endTime }
    }

    @ViewBuilder
    private func overlayView(_ overlay: OverlayRegion, in size: CGSize) -> some View {
        let rect = CGRect(
            x: size.width * (overlay.normalizedX - overlay.normalizedWidth / 2),
            y: size.height * (overlay.normalizedY - overlay.normalizedHeight / 2),
            width: size.width * overlay.normalizedWidth,
            height: size.height * overlay.normalizedHeight
        )
        switch overlay.kind {
        case .privacy:
            RoundedRectangle(cornerRadius: 7)
                .fill(.ultraThickMaterial)
                .overlay {
                    Image(systemName: "eye.slash.fill").foregroundStyle(.secondary)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .highlight:
            RoundedRectangle(cornerRadius: 7)
                .fill(.yellow.opacity(0.15))
                .stroke(.yellow, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private var sourceAspectRatio: Double {
        Double(sourceSize.width) / Double(max(1, sourceSize.height))
    }

    private var mockupAspectRatio: Double {
        guard appearance.showsWindowFrame else { return sourceAspectRatio }
        return 1 / (1 / sourceAspectRatio + MacWindowChromeMetrics.titlebarToWindowWidth)
    }

    private var windowCornerRadius: Double {
        appearance.showsWindowFrame ? 9 : appearance.cornerRadius
    }

    private func cameraOverlay(player: AVPlayer, in size: CGSize) -> some View {
        let width = max(56, size.width * appearance.cameraWidth)
        let height = max(56, size.height * appearance.cameraHeight)
        let normalizedHalfWidth = width / max(size.width, 1) / 2
        let normalizedHalfHeight = height / max(size.height, 1) / 2
        let shape = cameraClipShape(width: width, height: height)
        return NativePlayerView(player: player, videoGravity: .resizeAspectFill)
            .scaleEffect(x: appearance.cameraMirrored ? -1 : 1, y: 1)
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    Color(capturaHex: appearance.cameraBorderHex),
                    lineWidth: appearance.cameraBorderWidth
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if allowsCameraDragging {
                    CameraResizeHandle()
                        .offset(x: 6, y: 6)
                        .highPriorityGesture(cameraResizeGesture(in: size))
                }
            }
            .shadow(color: .black.opacity(appearance.cameraShadow), radius: 14 * appearance.cameraShadow, y: 6 * appearance.cameraShadow)
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

    private func cameraClipShape(width: Double, height: Double) -> AnyShape {
        switch appearance.cameraShape {
        case .circle: AnyShape(Ellipse())
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: min(width, height) * 0.32, style: .continuous))
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: min(width, height) * appearance.cameraCornerRadius, style: .continuous))
        case .rectangle: AnyShape(Rectangle())
        }
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
        HStack(spacing: trafficLightSize * (MacWindowChromeMetrics.trafficLightCenterSpacing - 1)) {
            trafficLight("#FF5F57")
            trafficLight("#FEBC2E")
            trafficLight("#28C840")
            Spacer()
        }
        .padding(.leading, height * MacWindowChromeMetrics.trafficLightLeadingToTitlebarHeight)
        .background {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(capturaHex: "#353537"), Color(capturaHex: "#2C2C2E")]
                    : [Color(capturaHex: "#F3F3F4"), Color(capturaHex: "#E9E9EA")],
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

    private var trafficLightSize: Double {
        max(5, min(12, height * MacWindowChromeMetrics.trafficLightToTitlebarHeight))
    }

    private func trafficLight(_ hex: String) -> some View {
        Circle()
            .fill(Color(capturaHex: hex))
            .overlay(Circle().stroke(.black.opacity(0.18), lineWidth: 0.5))
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
    @Binding var audio: ProjectAudioSettings
    @Binding var cursor: CursorAppearance
    @Binding var brandKit: BrandKit?
    let hasCamera: Bool
    @State private var savedPresets = CapturaPresetStore.load()
    @State private var savedBrandKits = BrandKitStore.load()
    @State private var presetError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Canvas")
                    .font(.title3.weight(.semibold))

                HStack {
                    Menu("Presets") {
                        Button("Captura Default") { appearance = .default }
                        ForEach(savedPresets) { preset in
                            Button(preset.name) { apply(preset) }
                        }
                        if !savedPresets.isEmpty {
                            Divider()
                            Button("Clear saved presets", role: .destructive) {
                                savedPresets = []
                                CapturaPresetStore.save(savedPresets)
                            }
                        }
                    }
                    Button("Save current") {
                        savedPresets.append(CapturaPreset(
                            name: "Preset \(savedPresets.count + 1)",
                            appearance: appearance,
                            audio: audio,
                            cursor: cursor,
                            export: lastExportSettings,
                            brandKit: brandKit
                        ))
                        CapturaPresetStore.save(savedPresets)
                    }
                    Menu {
                        Button("Import preset…", action: importPreset)
                        ForEach(savedPresets) { preset in
                            Button("Export \(preset.name)…") { exportPreset(preset) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .help("Import or export .capturapreset files")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Brand Kit").font(.headline)
                    Picker("Brand", selection: Binding(
                        get: { brandKit?.id },
                        set: { id in
                            brandKit = savedBrandKits.first { $0.id == id }
                            applyBrandKit()
                        }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(savedBrandKits) { kit in Text(kit.name).tag(Optional(kit.id)) }
                    }
                    HStack {
                        Button("Save Current Brand") {
                            let kit = BrandKit(
                                name: "Brand \(savedBrandKits.count + 1)",
                                primaryHex: appearance.customGradientStartHex,
                                secondaryHex: appearance.customGradientEndHex
                            )
                            savedBrandKits.append(kit)
                            BrandKitStore.save(savedBrandKits)
                            brandKit = kit
                        }
                        if brandKit != nil {
                            Button("Apply", action: applyBrandKit)
                        }
                    }
                    Text("Brand colors style the canvas; typography and text color are reused by title layers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        ColorPicker("Start color", selection: customGradientStartBinding)
                        ColorPicker("End color", selection: customGradientEndBinding)
                        slider("Direction", value: $appearance.gradientAngle, range: 0...360, suffix: "°")
                    }
                }

                slider("Padding", value: $appearance.padding, range: 0...180, suffix: " px")
                slider("Inset", value: $appearance.inset, range: 0...32, suffix: " px")
                slider("Corner radius", value: $appearance.cornerRadius, range: 0...36, suffix: " px")
                slider("Shadow", value: $appearance.shadowStrength, range: 0...32, suffix: "")
                slider("Vignette", value: $appearance.vignette, range: 0...1, suffix: "")

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
        .alert("Preset error", isPresented: Binding(
            get: { presetError != nil },
            set: { if !$0 { presetError = nil } }
        )) {
            Button("OK", role: .cancel) { presetError = nil }
        } message: {
            Text(presetError ?? "Unknown preset error")
        }
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
            Picker("Shape", selection: $appearance.cameraShape) {
                ForEach(CameraFrameShape.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Camera corners", value: $appearance.cameraCornerRadius, range: 0...0.5, suffix: "")
            slider("Camera border", value: $appearance.cameraBorderWidth, range: 0...12, suffix: " px")
            ColorPicker("Border color", selection: cameraBorderBinding)
            slider("Camera shadow", value: $appearance.cameraShadow, range: 0...1, suffix: "")
            Toggle("Mirror camera", isOn: $appearance.cameraMirrored)
            Button("Remove border and shadow", systemImage: "circle.slash") {
                appearance.cameraBorderWidth = 0
                appearance.cameraShadow = 0
            }
            .disabled(appearance.cameraBorderWidth == 0 && appearance.cameraShadow == 0)

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

    private var customGradientStartBinding: Binding<Color> {
        Binding(
            get: { Color(capturaHex: appearance.customGradientStartHex) },
            set: {
                appearance.customGradientStartHex = NSColor($0).capturaHex
                appearance.customColorHex = appearance.customGradientStartHex
                appearance.backgroundPreset = .custom
            }
        )
    }

    private var customGradientEndBinding: Binding<Color> {
        Binding(
            get: { Color(capturaHex: appearance.customGradientEndHex) },
            set: { appearance.customGradientEndHex = NSColor($0).capturaHex; appearance.backgroundPreset = .custom }
        )
    }

    private var cameraBorderBinding: Binding<Color> {
        Binding(
            get: { Color(capturaHex: appearance.cameraBorderHex) },
            set: { appearance.cameraBorderHex = NSColor($0).capturaHex }
        )
    }

    private func applyBrandKit() {
        guard let brandKit else { return }
        appearance.backgroundPreset = .custom
        appearance.customGradientStartHex = brandKit.primaryHex
        appearance.customGradientEndHex = brandKit.secondaryHex
        appearance.customColorHex = brandKit.primaryHex
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "capturapreset") ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try CapturaPresetStore.importPreset(from: url)
            savedPresets.removeAll { $0.id == preset.id }
            savedPresets.append(preset)
            CapturaPresetStore.save(savedPresets)
            apply(preset)
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func exportPreset(_ preset: CapturaPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "capturapreset") ?? .json]
        panel.nameFieldStringValue = "\(preset.name).capturapreset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CapturaPresetStore.export(preset, to: url)
        } catch {
            presetError = error.localizedDescription
        }
    }

    private var lastExportSettings: ExportSettings? {
        guard let data = UserDefaults.standard.data(forKey: "captura.lastExportSettings") else { return nil }
        return try? JSONDecoder().decode(ExportSettings.self, from: data)
    }

    private func apply(_ preset: CapturaPreset) {
        appearance = preset.appearance
        audio = preset.audio
        cursor = preset.cursor
        brandKit = preset.brandKit
        applyBrandKit()
        if let export = preset.export, let data = try? JSONEncoder().encode(export) {
            UserDefaults.standard.set(data, forKey: "captura.lastExportSettings")
        }
    }
}

func canvasBackgroundStyle(_ appearance: CanvasAppearance) -> AnyShapeStyle {
    let customPoints = gradientUnitPoints(angle: appearance.gradientAngle)
    return switch appearance.backgroundPreset {
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
        AnyShapeStyle(LinearGradient(
            colors: [Color(capturaHex: appearance.customGradientStartHex), Color(capturaHex: appearance.customGradientEndHex)],
            startPoint: customPoints.start,
            endPoint: customPoints.end
        ))
    }
}

func gradientUnitPoints(angle: Double) -> (start: UnitPoint, end: UnitPoint) {
    let radians = angle * .pi / 180
    let dx = cos(radians) * 0.5
    let dy = sin(radians) * 0.5
    return (
        UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
        UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    )
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
