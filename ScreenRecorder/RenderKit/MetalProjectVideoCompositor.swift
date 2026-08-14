@preconcurrency import AVFoundation
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import simd

final class CapturaVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let project: ScreenProject
    let events: [InteractionEvent]
    let geometry: ExportGeometry
    let brandingImages: [UUID: CGImage]

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        project: ScreenProject,
        events: [InteractionEvent],
        geometry: ExportGeometry,
        brandingImages: [UUID: CGImage] = [:]
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.project = project
        self.events = events
        self.geometry = geometry
        self.brandingImages = brandingImages
        requiredSourceTrackIDs = [screenTrackID, cameraTrackID].compactMap { id in
            guard let id else { return nil }
            return NSNumber(value: id)
        }
    }
}

enum BrandingAssetLoader {
    static func load(project: ScreenProject, packageURL: URL) -> [UUID: CGImage] {
        Dictionary(uniqueKeysWithValues: (project.brandingOverlays ?? []).compactMap { overlay in
            let url = packageURL.appending(path: overlay.assetPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (overlay.id, image)
        })
    }
}

final class MetalProjectVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String]
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String]
    ]

    private let queue = DispatchQueue(label: "com.captura.metal-project-compositor", qos: .userInitiated)
    private let renderer: MetalProjectRenderer?
    private let lock = NSLock()
    private var cancelled = false

    override init() {
        renderer = try? MetalProjectRenderer()
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard !lock.withLock({ cancelled }) else {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? CapturaVideoInstruction,
                  let renderer,
                  let source = request.sourceFrame(byTrackID: instruction.screenTrackID),
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: MetalCompositorError.outputAllocation)
                return
            }
            let camera = instruction.cameraTrackID.flatMap(request.sourceFrame(byTrackID:))
            do {
                try renderer.render(
                    source: source,
                    camera: camera,
                    destination: output,
                    compositionTime: request.compositionTime,
                    instruction: instruction
                )
                request.finish(withComposedVideoFrame: output)
            } catch {
                request.finish(with: error)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.withLock { cancelled = true }
        queue.async { [weak self] in self?.lock.withLock { self?.cancelled = false } }
    }
}

final class MetalProjectRenderer: @unchecked Sendable {
    private struct Uniforms {
        var backgroundStart: SIMD4<Float>
        var backgroundEnd: SIMD4<Float>
        var windowRect: SIMD4<Float>
        var screenRect: SIMD4<Float>
        var cameraRect: SIMD4<Float>
        var cameraFocus: SIMD4<Float>
        var cursor: SIMD4<Float>
        var chrome: SIMD4<Float>
        var output: SIMD4<Float>
        var transition: SIMD4<Float>
        var videoRect: SIMD4<Float>
        var video: SIMD4<Float>
        var brandingRect: SIMD4<Float>
        var branding: SIMD4<Float>
        var textRect: SIMD4<Float>
        var text: SIMD4<Float>
    }

    private struct GPUOverlay {
        var rect: SIMD4<Float>
        var values: SIMD4<Float>
    }

    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipeline: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private var brandingTextureCache: [UUID: MTLTexture] = [:]
    private var textTextureCache: [TextOverlay: MTLTexture] = [:]
    private let lock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            throw MetalCompositorError.unavailable
        }
        self.commandQueue = commandQueue
        textureLoader = MTKTextureLoader(device: device)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalCompositorError.unavailable }
        textureCache = cache
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "capturaProjectVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "capturaProjectFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalCompositorError.pipeline(error.localizedDescription)
        }
    }

    func render(
        source: CVPixelBuffer,
        camera: CVPixelBuffer?,
        destination: CVPixelBuffer,
        compositionTime: CMTime,
        instruction: CapturaVideoInstruction
    ) throws {
        try lock.withLock {
            guard let sourceTexture = texture(from: source),
                  let destinationTexture = texture(from: destination) else {
                throw MetalCompositorError.textureCreation
            }
            let cameraTexture = camera.flatMap(texture(from:)) ?? sourceTexture
            let timelineTime = max(0, compositionTime.seconds)
            let activeClip = instruction.project.timeline.clip(at: timelineTime)
            let importedMedia = activeClip.flatMap { clip in
                instruction.project.videoAssets?.first { $0.id == clip.sourceMediaID }
            }
            let isPrimaryClip = importedMedia == nil
            let sourceTime = instruction.project.timeline.sourceTime(at: timelineTime) ?? timelineTime
            let keyframe = isPrimaryClip ? CameraKeyframeInterpolator().value(
                at: sourceTime,
                frames: instruction.project.cameraKeyframes
            ) : nil
            let cursor = isPrimaryClip ? cursorSample(at: sourceTime, instruction: instruction) : nil
            let appearance = instruction.project.settings.appearance ?? .default
            let colors = backgroundColors(appearance)
            let geometry = instruction.geometry
            let outputSize = geometry.outputSize
            let activeTransition = instruction.project.timeline.activeTransition(at: timelineTime)
            let mutedTracks = Set((instruction.project.timelineTracks ?? []).filter(\.isMuted).map(\.id))
            let activeBranding = (instruction.project.brandingOverlays ?? []).last {
                timelineTime >= $0.startTime && timelineTime <= $0.endTime &&
                !mutedTracks.contains($0.trackID ?? TimelineTrack.defaultOverlayID)
            }
            let activeText = (instruction.project.textOverlays ?? []).last {
                timelineTime >= $0.startTime && timelineTime <= $0.endTime &&
                !mutedTracks.contains($0.trackID ?? TimelineTrack.defaultTextID)
            }
            let webcamLayout = WebcamLayoutInterpolator().value(
                at: timelineTime,
                frames: instruction.project.webcamKeyframes ?? [],
                fallback: appearance
            )
            let cameraWidth = max(2, geometry.screenRect.width * min(max(webcamLayout.width, 0.05), 1))
            let cameraHeight = max(2, geometry.screenRect.height * min(max(webcamLayout.height, 0.05), 1))
            let cameraCenter = CGPoint(
                x: geometry.screenRect.minX + geometry.screenRect.width * min(max(webcamLayout.positionX, 0), 1),
                y: geometry.screenRect.minY + geometry.screenRect.height * min(max(webcamLayout.positionY, 0), 1)
            )
            let cameraRect = CGRect(
                x: cameraCenter.x - cameraWidth / 2,
                y: cameraCenter.y - cameraHeight / 2,
                width: cameraWidth,
                height: cameraHeight
            ).intersection(geometry.screenRect)
            let normalize: (CGRect) -> SIMD4<Float> = { rect in
                SIMD4(
                    Float(rect.minX / outputSize.width), Float(rect.minY / outputSize.height),
                    Float(rect.width / outputSize.width), Float(rect.height / outputSize.height)
                )
            }
            let layout = activeClip?.layout ?? .default
            let sourceAspect = Double(importedMedia.map { Double($0.width) / Double(max(1, $0.height)) }
                ?? Double(instruction.project.settings.sourceDisplay.width) / Double(max(1, instruction.project.settings.sourceDisplay.height)))
            let destinationAspect = geometry.screenRect.width / max(geometry.screenRect.height, 1)
            var relativeWidth = min(max(layout.scale, 0.05), 2)
            var relativeHeight = relativeWidth
            if layout.contentMode == .fit {
                if sourceAspect > destinationAspect { relativeHeight *= destinationAspect / sourceAspect }
                else { relativeWidth *= sourceAspect / destinationAspect }
            }
            let videoRect = CGRect(
                x: geometry.screenRect.minX + geometry.screenRect.width * (layout.positionX - relativeWidth / 2),
                y: geometry.screenRect.minY + geometry.screenRect.height * (layout.positionY - relativeHeight / 2),
                width: geometry.screenRect.width * relativeWidth,
                height: geometry.screenRect.height * relativeHeight
            )
            let brandingImage = activeBranding.flatMap { instruction.brandingImages[$0.id] }
            let brandingTexture = activeBranding.flatMap { overlay in
                cachedBrandingTexture(for: overlay.id, image: brandingImage)
            } ?? sourceTexture
            let brandingAspect = brandingImage.map { Float($0.width) / Float(max(1, $0.height)) } ?? 1
            let textTexture = activeText.flatMap(cachedTextTexture(for:)) ?? sourceTexture
            let textAspect = Float(4)
            var uniforms = Uniforms(
                backgroundStart: colors.0,
                backgroundEnd: colors.1,
                windowRect: normalize(geometry.windowRect),
                screenRect: normalize(geometry.screenRect),
                cameraRect: normalize(cameraRect),
                cameraFocus: SIMD4(
                    Float(keyframe?.centerX ?? 0.5), Float(keyframe?.centerY ?? 0.5),
                    Float(max(1, keyframe?.scale ?? 1)),
                    camera == nil || !isPrimaryClip ? 0 : Float(min(max(webcamLayout.opacity, 0), 1))
                ),
                cursor: SIMD4(
                    Float(cursor?.normalizedX ?? 0.5), Float(cursor?.normalizedY ?? 0.5),
                    cursor == nil ? 0 : 1,
                    Float((instruction.project.settings.cursor ?? .default).size)
                ),
                chrome: SIMD4(
                    (instruction.project.settings.appearance ?? .default).showsWindowFrame ? 1 : 0,
                    Float(geometry.windowCornerRadius / outputSize.width),
                    Float((instruction.project.settings.appearance ?? .default).shadowStrength * geometry.scale / outputSize.width),
                    0
                ),
                output: SIMD4(Float(outputSize.width), Float(outputSize.height), 0, 0),
                transition: SIMD4(
                    transitionCode(activeTransition?.kind),
                    Float(activeTransition?.intensity ?? 0), 0, 0
                ),
                videoRect: normalize(videoRect),
                video: SIMD4(
                    Float(min(max(layout.opacity, 0), 1)),
                    layout.contentMode == .fill ? 1 : 0,
                    Float(sourceAspect),
                    Float(importedMedia?.rotationQuarterTurns ?? 0)
                ),
                brandingRect: activeBranding.map {
                    SIMD4(
                        Float($0.normalizedX - $0.normalizedWidth / 2),
                        Float($0.normalizedY - $0.normalizedHeight / 2),
                        Float($0.normalizedWidth), Float($0.normalizedHeight)
                    )
                } ?? .zero,
                branding: SIMD4(
                    brandingImage == nil ? 0 : Float(min(max(activeBranding?.opacity ?? 0, 0), 1)),
                    activeBranding?.contentMode == .fill ? 1 : 0,
                    brandingAspect,
                    Float(activeBranding?.cornerRadius ?? 0)
                ),
                textRect: activeText.map {
                    let width = min(max($0.normalizedWidth, 0.05), 1)
                    let height = width * outputSize.width / max(outputSize.height, 1) / Double(textAspect)
                    return SIMD4(
                        Float($0.normalizedX - width / 2), Float($0.normalizedY - height / 2),
                        Float(width), Float(height)
                    )
                } ?? .zero,
                text: SIMD4(
                    activeText == nil ? 0 : Float(min(max(activeText?.opacity ?? 0, 0), 1)),
                    0, 0, 0
                )
            )
            var overlays = activeOverlays(at: timelineTime, instruction: instruction)
            if overlays.isEmpty {
                overlays = [GPUOverlay(rect: .zero, values: .zero)]
            }
            var overlayCount = UInt32(min(overlays.count, 16))

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destinationTexture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw MetalCompositorError.commandEncoding
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentTexture(cameraTexture, index: 1)
            encoder.setFragmentTexture(brandingTexture, index: 2)
            encoder.setFragmentTexture(textTexture, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&overlays, length: MemoryLayout<GPUOverlay>.stride * overlays.count, index: 1)
            encoder.setFragmentBytes(&overlayCount, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else { throw MetalCompositorError.renderingFailed }
        }
    }

    private func texture(from buffer: CVPixelBuffer) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var image: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
            width, height, 0, &image
        ) == kCVReturnSuccess, let image else { return nil }
        return CVMetalTextureGetTexture(image)
    }

    private func cachedBrandingTexture(for id: UUID, image: CGImage?) -> MTLTexture? {
        if let cached = brandingTextureCache[id] { return cached }
        guard let image,
              let texture = try? textureLoader.newTexture(
                cgImage: image,
                options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
              ) else { return nil }
        brandingTextureCache[id] = texture
        return texture
    }

    private func cachedTextTexture(for item: TextOverlay) -> MTLTexture? {
        if let cached = textTextureCache[item] { return cached }
        guard let image = makeTextImage(item),
              let texture = try? textureLoader.newTexture(
                cgImage: image,
                options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
              ) else { return nil }
        textTextureCache[item] = texture
        if textTextureCache.count > 96 { textTextureCache.removeAll(keepingCapacity: true) }
        return texture
    }

    private func makeTextImage(_ item: TextOverlay) -> CGImage? {
        let width = 1600
        let height = 400
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(cgColor(item.backgroundHex, alpha: item.backgroundOpacity))
        context.addPath(CGPath(roundedRect: CGRect(x: 12, y: 12, width: width - 24, height: height - 24), cornerWidth: 34, cornerHeight: 34, transform: nil))
        context.fillPath()

        let fontName: CFString = switch item.weight {
        case .regular: "SFProDisplay-Regular" as CFString
        case .medium: "SFProDisplay-Medium" as CFString
        case .semibold: "SFProDisplay-Semibold" as CFString
        case .bold: "SFProDisplay-Bold" as CFString
        }
        let font = CTFontCreateWithName(fontName, CGFloat(min(max(item.fontSize, 18), 144)), nil)
        var alignment: CTTextAlignment = switch item.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph = withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: lineBreakPointer
                    )
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributed = NSAttributedString(
            string: item.text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor(item.foregroundHex, alpha: 1),
                kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 72, y: 48, width: width - 144, height: height - 96), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        context.restoreGState()
        return context.makeImage()
    }

    private func cgColor(_ hex: String, alpha: Double) -> CGColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(cleaned, radix: 16) ?? 0xFFFFFF
        return CGColor(
            red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: CGFloat(min(max(alpha, 0), 1))
        )
    }

    private func transitionCode(_ kind: ClipTransitionKind?) -> Float {
        switch kind {
        case .fade: 1
        case .flash: 2
        case .zoom: 3
        case nil: 0
        }
    }

    private func cursorSample(at sourceTime: Double, instruction: CapturaVideoInstruction) -> CursorSample? {
        let settings = instruction.project.settings.cursor ?? .default
        guard settings.isVisible else { return nil }
        let samples = instruction.events.compactMap { event -> CursorSample? in
            guard let x = event.normalizedX, let y = event.normalizedY,
                  event.type == .mouseMove || event.type == .click || event.type == .mouseDown else { return nil }
            return CursorSample(time: event.timestamp, normalizedX: x, normalizedY: y, cursorType: .arrow)
        }
        guard let sample = CursorInterpolator().sample(at: sourceTime, from: samples) else { return nil }
        if settings.hidesWhenIdle,
           let closest = samples.min(by: { abs($0.time - sourceTime) < abs($1.time - sourceTime) }),
           abs(closest.time - sourceTime) > 1.5 { return nil }
        return sample
    }

    private func activeOverlays(at time: Double, instruction: CapturaVideoInstruction) -> [GPUOverlay] {
        (instruction.project.overlays ?? []).filter {
            time >= $0.startTime && time <= $0.endTime
        }.prefix(16).map { overlay in
            GPUOverlay(
                rect: SIMD4(
                    Float(overlay.normalizedX - overlay.normalizedWidth / 2),
                    Float(overlay.normalizedY - overlay.normalizedHeight / 2),
                    Float(overlay.normalizedWidth), Float(overlay.normalizedHeight)
                ),
                values: SIMD4(overlay.kind == .privacy ? 1 : 2, 0, 0, 0)
            )
        }
    }

    private func backgroundColors(_ appearance: CanvasAppearance) -> (SIMD4<Float>, SIMD4<Float>) {
        let hexes: (String, String) = switch appearance.backgroundPreset {
        case .studio: ("#F2D6C8", "#C6A7E8")
        case .midnight: ("#101426", "#343E68")
        case .ocean: ("#0B6B78", "#7BDCB5")
        case .sunset: ("#F97356", "#8E4EC6")
        case .graphite: ("#24262B", "#555A65")
        case .custom: (appearance.customColorHex, appearance.customColorHex)
        }
        return (rgba(hexes.0), rgba(hexes.1))
    }

    private func rgba(_ hex: String) -> SIMD4<Float> {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(cleaned, radix: 16) ?? 0x6C5CE7
        return SIMD4(
            Float((value >> 16) & 255) / 255,
            Float((value >> 8) & 255) / 255,
            Float(value & 255) / 255,
            1
        )
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct Uniforms {
        float4 backgroundStart; float4 backgroundEnd;
        float4 windowRect; float4 screenRect; float4 cameraRect;
        float4 cameraFocus; float4 cursor; float4 chrome; float4 output;
        float4 transition; float4 videoRect; float4 video;
        float4 brandingRect; float4 branding;
        float4 textRect; float4 text;
    };
    struct Overlay { float4 rect; float4 values; };

    vertex VertexOut capturaProjectVertex(uint id [[vertex_id]]) {
        const float2 positions[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        const float2 uvs[3] = { float2(0,1), float2(2,1), float2(0,-1) };
        return { float4(positions[id], 0, 1), uvs[id] };
    }

    float roundedMask(float2 uv, float4 rect, float radius) {
        float2 p = uv - (rect.xy + rect.zw * 0.5);
        float2 q = abs(p) - rect.zw * 0.5 + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        return 1.0 - smoothstep(-0.0015, 0.0015, distance);
    }

    bool inside(float2 point, float4 rect) {
        return all(point >= rect.xy) && all(point <= rect.xy + rect.zw);
    }

    float4 gaussianBlur(texture2d<float> texture, sampler s, float2 uv) {
        const float weights[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
        float2 texel = 1.0 / float2(texture.get_width(), texture.get_height());
        float4 result = 0;
        float total = 0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float weight = weights[x + 2] * weights[y + 2];
                result += texture.sample(s, uv + float2(x, y) * texel * 4.0) * weight;
                total += weight;
            }
        }
        return result / total;
    }

    fragment float4 capturaProjectFragment(
        VertexOut in [[stage_in]],
        texture2d<float> screen [[texture(0)]],
        texture2d<float> camera [[texture(1)]],
        texture2d<float> brandingTexture [[texture(2)]],
        texture2d<float> textTexture [[texture(3)]],
        constant Uniforms &u [[buffer(0)]],
        constant Overlay *overlays [[buffer(1)]],
        constant uint &overlayCount [[buffer(2)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;
        float4 color = mix(u.backgroundStart, u.backgroundEnd, clamp((uv.x + uv.y) * 0.5, 0.0, 1.0));

        float windowMask = roundedMask(uv, u.windowRect, max(u.chrome.y, 0.002));
        float shadow = roundedMask(uv - float2(0, u.chrome.z * 0.45), u.windowRect, max(u.chrome.y, 0.002));
        color = mix(color, float4(0,0,0,1), shadow * (1.0 - windowMask) * 0.22);
        if (windowMask > 0.001) color = mix(color, float4(0.055,0.055,0.065,1), windowMask);

        if (inside(uv, u.videoRect)) {
            float2 local = (uv - u.videoRect.xy) / u.videoRect.zw;
            float2 sourceUV = u.cameraFocus.xy + (local - 0.5) / max(u.cameraFocus.z, 1.0);
            float destinationAspect = (u.videoRect.z * u.output.x) / max(u.videoRect.w * u.output.y, 1.0);
            if (u.video.y > 0.5) {
                if (u.video.z > destinationAspect) sourceUV.x = (sourceUV.x - 0.5) * destinationAspect / u.video.z + 0.5;
                else sourceUV.y = (sourceUV.y - 0.5) * u.video.z / destinationAspect + 0.5;
            }
            int rotations = (int(u.video.w) % 4 + 4) % 4;
            if (rotations == 1) sourceUV = float2(sourceUV.y, 1.0 - sourceUV.x);
            else if (rotations == 2) sourceUV = 1.0 - sourceUV;
            else if (rotations == 3) sourceUV = float2(1.0 - sourceUV.y, sourceUV.x);
            if (u.transition.x > 2.5) {
                sourceUV = 0.5 + (sourceUV - 0.5) / (1.0 + u.transition.y * 0.1);
            }
            float4 video = screen.sample(s, sourceUV);
            for (uint index = 0; index < overlayCount; index++) {
                if (!inside(local, overlays[index].rect)) continue;
                if (overlays[index].values.x < 1.5) {
                    video = gaussianBlur(screen, s, sourceUV);
                } else {
                    float2 edge = min(local - overlays[index].rect.xy, overlays[index].rect.xy + overlays[index].rect.zw - local);
                    float border = 1.0 - smoothstep(0.0, 0.006, min(edge.x, edge.y));
                    video.rgb = mix(video.rgb, float3(1.0, 0.74, 0.08), 0.13 + border * 0.7);
                }
            }
            color = mix(color, video, u.video.x);

            if (u.cursor.z > 0.5) {
                float2 cursorLocal = (u.cursor.xy - u.cameraFocus.xy) * u.cameraFocus.z + 0.5;
                float2 delta = local - cursorLocal;
                delta.x *= u.screenRect.z * u.output.x / max(u.screenRect.w * u.output.y, 1.0);
                float2 arrow = delta / (0.016 * max(u.cursor.w, 0.5));
                bool body = arrow.x >= 0 && arrow.y >= 0 && arrow.y <= 1.45 && arrow.x <= 0.22 + arrow.y * 0.48;
                bool tail = arrow.y > 0.62 && arrow.y < 1.55 && arrow.x > 0.25 && arrow.x < 0.52;
                if (body || tail) color = float4(1,1,1,1);
            }
        }

        if (u.cameraFocus.w > 0.5 && inside(uv, u.cameraRect)) {
            float cameraMask = roundedMask(uv, u.cameraRect, 0.012);
            float2 cameraUV = (uv - u.cameraRect.xy) / u.cameraRect.zw;
            float sourceAspect = float(camera.get_width()) / max(float(camera.get_height()), 1.0);
            float destinationAspect = (u.cameraRect.z * u.output.x) / max(u.cameraRect.w * u.output.y, 1.0);
            if (sourceAspect > destinationAspect) {
                cameraUV.x = (cameraUV.x - 0.5) * destinationAspect / sourceAspect + 0.5;
            } else {
                cameraUV.y = (cameraUV.y - 0.5) * sourceAspect / destinationAspect + 0.5;
            }
            float4 cameraColor = camera.sample(s, cameraUV);
            color = mix(color, cameraColor, cameraMask * u.cameraFocus.w);
        }

        if (u.chrome.x > 0.5 && windowMask > 0.5 && inside(uv, float4(u.windowRect.xy, u.windowRect.z, u.screenRect.y - u.windowRect.y))) {
            float titleAmount = (uv.y - u.windowRect.y) / max(u.screenRect.y - u.windowRect.y, 0.001);
            color = mix(float4(0.95,0.95,0.955,1), float4(0.91,0.91,0.915,1), titleAmount);
            if (titleAmount > 0.975) color.rgb *= 0.86;

            // Use output pixels for distances. In normalized UV space, a circle
            // becomes a horizontal pill whenever the video is not square.
            float titleHeightPixels = (u.screenRect.y - u.windowRect.y) * u.output.y;
            float radiusPixels = titleHeightPixels * 0.16;
            float startX = u.windowRect.x * u.output.x + titleHeightPixels * 0.36;
            float centerY = (u.windowRect.y + u.screenRect.y) * 0.5 * u.output.y;
            float2 pixel = uv * u.output.xy;
            const float3 lights[3] = { float3(1,0.37,0.34), float3(1,0.74,0.18), float3(0.16,0.78,0.25) };
            for (int i = 0; i < 3; i++) {
                float2 center = float2(startX + float(i) * radiusPixels * 3.36, centerY);
                float distanceToLight = distance(pixel, center);
                if (distanceToLight < radiusPixels) {
                    float edge = smoothstep(radiusPixels - 1.0, radiusPixels, distanceToLight);
                    color = float4(mix(lights[i], lights[i] * 0.62, edge), 1);
                }
            }
        }

        if (u.transition.x > 0.5 && u.transition.x < 1.5) {
            color = mix(color, float4(0.015, 0.015, 0.02, 1), u.transition.y);
        } else if (u.transition.x > 1.5 && u.transition.x < 2.5) {
            color = mix(color, float4(1, 1, 1, 1), u.transition.y * 0.94);
        }

        if (u.branding.x > 0.001 && inside(uv, u.brandingRect)) {
            float2 imageUV = (uv - u.brandingRect.xy) / u.brandingRect.zw;
            float destinationAspect = (u.brandingRect.z * u.output.x) / max(u.brandingRect.w * u.output.y, 1.0);
            float imageAspect = max(u.branding.z, 0.001);
            if (u.branding.y < 0.5) {
                if (imageAspect > destinationAspect) {
                    imageUV.y = (imageUV.y - 0.5) * imageAspect / destinationAspect + 0.5;
                } else {
                    imageUV.x = (imageUV.x - 0.5) * destinationAspect / imageAspect + 0.5;
                }
            } else if (imageAspect > destinationAspect) {
                imageUV.x = (imageUV.x - 0.5) * destinationAspect / imageAspect + 0.5;
            } else {
                imageUV.y = (imageUV.y - 0.5) * imageAspect / destinationAspect + 0.5;
            }
            if (all(imageUV >= 0.0) && all(imageUV <= 1.0)) {
                float4 brandColor = brandingTexture.sample(s, imageUV);
                float radius = min(u.brandingRect.z, u.brandingRect.w) * u.branding.w;
                float brandMask = roundedMask(uv, u.brandingRect, radius);
                color = mix(color, brandColor, brandColor.a * u.branding.x * brandMask);
            }
        }
        if (u.text.x > 0.001 && inside(uv, u.textRect)) {
            float2 textUV = (uv - u.textRect.xy) / u.textRect.zw;
            float4 textColor = textTexture.sample(s, textUV);
            color = mix(color, textColor, textColor.a * u.text.x);
        }
        return color;
    }
    """#
}
