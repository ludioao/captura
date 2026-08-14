@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import SwiftUI

enum VideoTemplateCategory: String, CaseIterable, Identifiable, Sendable {
    case intro = "Intros"
    case chapter = "Chapters"
    case outro = "Outros"
    case callToAction = "Calls to action"

    var id: String { rawValue }
}

enum VideoTemplateStyle: String, Sendable {
    case spotlight, minimal, split, bands
}

struct TemplateRGB: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
}

struct VideoTemplateDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: VideoTemplateCategory
    let style: VideoTemplateStyle
    let duration: Double
    let primary: TemplateRGB
    let secondary: TemplateRGB
    let accent: TemplateRGB
    let defaultTitle: String
    let defaultSubtitle: String

    static let library: [VideoTemplateDescriptor] = [
        .init(
            id: "signal", name: "Signal", category: .intro, style: .spotlight, duration: 3,
            primary: .init(red: 0.08, green: 0.06, blue: 0.16),
            secondary: .init(red: 0.35, green: 0.16, blue: 0.90),
            accent: .init(red: 0.82, green: 0.38, blue: 1),
            defaultTitle: "Your story starts here", defaultSubtitle: "A film by your brand"
        ),
        .init(
            id: "quiet", name: "Quiet", category: .intro, style: .minimal, duration: 2.5,
            primary: .init(red: 0.035, green: 0.04, blue: 0.05),
            secondary: .init(red: 0.08, green: 0.09, blue: 0.11),
            accent: .init(red: 0.35, green: 0.82, blue: 0.72),
            defaultTitle: "A focused introduction", defaultSubtitle: "Clear. Simple. Yours."
        ),
        .init(
            id: "chapter", name: "Chapter", category: .chapter, style: .split, duration: 2,
            primary: .init(red: 0.03, green: 0.12, blue: 0.24),
            secondary: .init(red: 0.06, green: 0.35, blue: 0.65),
            accent: .init(red: 0.35, green: 0.80, blue: 1),
            defaultTitle: "Chapter One", defaultSubtitle: "The essential idea"
        ),
        .init(
            id: "momentum", name: "Momentum", category: .chapter, style: .bands, duration: 2.25,
            primary: .init(red: 0.15, green: 0.035, blue: 0.02),
            secondary: .init(red: 0.75, green: 0.18, blue: 0.05),
            accent: .init(red: 1, green: 0.70, blue: 0.18),
            defaultTitle: "The next move", defaultSubtitle: "Turning insight into action"
        ),
        .init(
            id: "thanks", name: "Thank You", category: .outro, style: .spotlight, duration: 3,
            primary: .init(red: 0.04, green: 0.03, blue: 0.10),
            secondary: .init(red: 0.24, green: 0.08, blue: 0.48),
            accent: .init(red: 0.95, green: 0.50, blue: 0.84),
            defaultTitle: "Thanks for watching", defaultSubtitle: "See you in the next one"
        ),
        .init(
            id: "follow", name: "Follow", category: .callToAction, style: .split, duration: 2.5,
            primary: .init(red: 0.12, green: 0.02, blue: 0.035),
            secondary: .init(red: 0.72, green: 0.04, blue: 0.12),
            accent: .init(red: 1, green: 0.35, blue: 0.38),
            defaultTitle: "Keep the conversation going", defaultSubtitle: "@yourbrand"
        )
    ]
}

struct VideoTemplateLibraryView: View {
    let canvas: CanvasSize
    let insert: (VideoTemplateDescriptor, String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: VideoTemplateCategory = .intro
    @State private var selection = VideoTemplateDescriptor.library[0]
    @State private var title = VideoTemplateDescriptor.library[0].defaultTitle
    @State private var subtitle = VideoTemplateDescriptor.library[0].defaultSubtitle
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Library").font(.title2.weight(.semibold))
                    Text("Add a ready-made scene at the playhead")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            HStack(spacing: 0) {
                List(VideoTemplateCategory.allCases, selection: $category) { item in
                    Label(item.rawValue, systemImage: icon(for: item)).tag(item)
                }
                .listStyle(.sidebar)
                .frame(width: 180)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(filteredTemplates) { template in
                            Button { select(template) } label: {
                                VideoTemplateCard(template: template, isSelected: selection.id == template.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
                .frame(minWidth: 470)

                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    VideoTemplatePreview(template: selection, title: title, subtitle: subtitle)
                        .aspectRatio(CGFloat(canvas.width) / CGFloat(max(1, canvas.height)), contentMode: .fit)
                    Form {
                        TextField("Title", text: $title)
                        TextField("Subtitle", text: $subtitle)
                        LabeledContent("Duration", value: selection.duration, format: .number.precision(.fractionLength(1)))
                    }
                    .formStyle(.grouped)
                    Spacer()
                    Button {
                        generate()
                    } label: {
                        if isGenerating { ProgressView().controlSize(.small) }
                        else { Label("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(isGenerating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(18)
                .frame(width: 310)
            }
        }
        .frame(minWidth: 980, minHeight: 590)
        .alert("Could not create template", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Unknown error") }
        .onChange(of: category) { _, _ in
            if let first = filteredTemplates.first { select(first) }
        }
    }

    private var filteredTemplates: [VideoTemplateDescriptor] {
        VideoTemplateDescriptor.library.filter { $0.category == category }
    }

    private func select(_ template: VideoTemplateDescriptor) {
        selection = template
        title = template.defaultTitle
        subtitle = template.defaultSubtitle
    }

    private func generate() {
        isGenerating = true
        Task {
            do {
                try await insert(selection, title, subtitle)
                isGenerating = false
                dismiss()
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func icon(for category: VideoTemplateCategory) -> String {
        switch category {
        case .intro: "play.rectangle.fill"
        case .chapter: "text.rectangle"
        case .outro: "checkmark.rectangle.fill"
        case .callToAction: "megaphone.fill"
        }
    }
}

private struct VideoTemplateCard: View {
    let template: VideoTemplateDescriptor
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VideoTemplatePreview(
                template: template,
                title: template.defaultTitle,
                subtitle: template.defaultSubtitle
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            Text(template.name).font(.callout.weight(.semibold))
            Text("\(template.duration.formatted(.number.precision(.fractionLength(1)))) sec")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(9)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
    }
}

private struct VideoTemplatePreview: View {
    let template: VideoTemplateDescriptor
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [template.primary.color, template.secondary.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            templateShape
            VStack(spacing: 5) {
                Text(title).font(.headline.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                Text(subtitle).font(.caption).opacity(0.76).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityLabel("\(template.name) video template")
    }

    @ViewBuilder private var templateShape: some View {
        switch template.style {
        case .spotlight:
            Circle().fill(template.accent.color.opacity(0.30)).blur(radius: 8).scaleEffect(0.72).offset(x: 58, y: -18)
        case .minimal:
            Rectangle().fill(template.accent.color).frame(height: 3).padding(.horizontal, 34)
        case .split:
            HStack(spacing: 0) { Color.clear; template.accent.color.opacity(0.20) }.rotationEffect(.degrees(-8)).scaleEffect(1.25)
        case .bands:
            VStack(spacing: 12) { template.accent.color.opacity(0.25).frame(height: 18); template.accent.color.opacity(0.12).frame(height: 8) }
                .rotationEffect(.degrees(-10)).scaleEffect(1.3)
        }
    }
}

enum VideoTemplateGenerator {
    static func generate(
        template: VideoTemplateDescriptor,
        title: String,
        subtitle: String,
        canvas: CanvasSize,
        outputURL: URL,
        frameRate: Int = 30
    ) async throws {
        let width = max(2, canvas.width - canvas.width % 2)
        let height = max(2, canvas.height - canvas.height % 2)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw TemplateVideoError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TemplateVideoError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)

        let frames = max(1, Int(template.duration * Double(frameRate)))
        for frame in 0..<frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let buffer = try makeFrame(
                template: template, title: title, subtitle: subtitle,
                width: width, height: height, progress: Double(frame) / Double(max(1, frames - 1))
            )
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))) else {
                throw writer.error ?? TemplateVideoError.appendFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TemplateVideoError.appendFailed }
    }

    private static func makeFrame(
        template: VideoTemplateDescriptor, title: String, subtitle: String,
        width: Int, height: Int, progress: Double
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw TemplateVideoError.pixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw TemplateVideoError.pixelBuffer }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [template.primary.cgColor, template.secondary.cgColor] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        drawMotion(template: template, context: context, bounds: bounds, progress: progress)

        let enter = smoothstep(min(1, progress / 0.28))
        let exit = smoothstep(min(1, (1 - progress) / 0.16))
        let alpha = enter * exit
        let offset = CGFloat((1 - enter) * -42 + (1 - exit) * 28)
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: 0, y: offset)
        drawText(title, size: CGFloat(height) * 0.071, weight: "HelveticaNeue-Bold", y: CGFloat(height) * 0.54, context: context, width: CGFloat(width))
        if !subtitle.isEmpty {
            drawText(subtitle, size: CGFloat(height) * 0.027, weight: "HelveticaNeue-Medium", y: CGFloat(height) * 0.44, context: context, width: CGFloat(width), alpha: 0.78)
        }
        context.restoreGState()
        return buffer
    }

    private static func drawMotion(template: VideoTemplateDescriptor, context: CGContext, bounds: CGRect, progress: Double) {
        context.saveGState()
        context.setFillColor(template.accent.cgColor.copy(alpha: 0.22)!)
        switch template.style {
        case .spotlight:
            let size = bounds.height * CGFloat(0.65 + progress * 0.34)
            context.fillEllipse(in: CGRect(x: bounds.width * 0.62 - size / 2, y: bounds.height * 0.58 - size / 2, width: size, height: size))
        case .minimal:
            context.setFillColor(template.accent.cgColor)
            context.fill(CGRect(x: bounds.width * 0.32, y: bounds.height * 0.37, width: bounds.width * 0.36 * CGFloat(smoothstep(min(1, progress / 0.45))), height: max(3, bounds.height * 0.005)))
        case .split:
            context.translateBy(x: bounds.width * CGFloat(0.74 - progress * 0.08), y: bounds.midY)
            context.rotate(by: -0.14)
            context.fill(CGRect(x: 0, y: -bounds.height, width: bounds.width * 0.55, height: bounds.height * 2))
        case .bands:
            context.translateBy(x: bounds.width * CGFloat(progress * 0.18 - 0.12), y: bounds.midY)
            context.rotate(by: -0.16)
            context.fill(CGRect(x: -bounds.width * 0.2, y: bounds.height * 0.08, width: bounds.width * 1.4, height: bounds.height * 0.12))
            context.setAlpha(0.55)
            context.fill(CGRect(x: -bounds.width * 0.2, y: -bounds.height * 0.12, width: bounds.width * 1.4, height: bounds.height * 0.045))
        }
        context.restoreGState()
    }

    private static func drawText(
        _ text: String, size: CGFloat, weight: String, y: CGFloat,
        context: CGContext, width: CGFloat, alpha: CGFloat = 1
    ) {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        let color = CGColor(gray: 1, alpha: alpha)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]
        ))
        let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(x: max(30, (width - lineBounds.width) / 2), y: y)
        CTLineDraw(line, context)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }
}

enum TemplateVideoError: LocalizedError {
    case writerUnavailable, appendFailed, pixelBuffer

    var errorDescription: String? {
        switch self {
        case .writerUnavailable: "The video encoder is unavailable."
        case .appendFailed: "The template video could not be encoded."
        case .pixelBuffer: "A template frame could not be created."
        }
    }
}
