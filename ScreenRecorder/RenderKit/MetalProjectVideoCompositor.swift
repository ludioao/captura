@preconcurrency import AVFoundation
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import simd

struct CapturaVideoRenderSnapshot: @unchecked Sendable {
    let project: ScreenProject
    let events: [InteractionEvent]
    let cursorSamples: [CursorSample]
    let geometry: ExportGeometry
    let brandingImages: [UUID: CGImage]
}

final class CapturaVideoRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CapturaVideoRenderSnapshot

    init(
        project: ScreenProject,
        events: [InteractionEvent],
        geometry: ExportGeometry,
        brandingImages: [UUID: CGImage]
    ) {
        value = CapturaVideoRenderSnapshot(
            project: project,
            events: events,
            cursorSamples: Self.makeCursorSamples(from: events),
            geometry: geometry,
            brandingImages: brandingImages
        )
    }

    func snapshot() -> CapturaVideoRenderSnapshot {
        lock.withLock { value }
    }

    func update(
        project: ScreenProject,
        events: [InteractionEvent]? = nil,
        geometry: ExportGeometry,
        brandingImages: [UUID: CGImage]? = nil
    ) {
        lock.withLock {
            let resolvedEvents = events ?? value.events
            let cursorSamples = if let events, events != value.events {
                Self.makeCursorSamples(from: events)
            } else {
                value.cursorSamples
            }
            value = CapturaVideoRenderSnapshot(
                project: project,
                events: resolvedEvents,
                cursorSamples: cursorSamples,
                geometry: geometry,
                brandingImages: brandingImages ?? value.brandingImages
            )
        }
    }

    private static func makeCursorSamples(from events: [InteractionEvent]) -> [CursorSample] {
        events.compactMap { event -> CursorSample? in
            guard let x = event.normalizedX, let y = event.normalizedY,
                  event.type == .mouseMove || event.type == .click || event.type == .mouseDown else { return nil }
            return CursorSample(time: event.timestamp, normalizedX: x, normalizedY: y, cursorType: .arrow)
        }
        .sorted { $0.time < $1.time }
    }
}

final class CapturaVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let renderState: CapturaVideoRenderState

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        project: ScreenProject,
        events: [InteractionEvent],
        geometry: ExportGeometry,
        brandingImages: [UUID: CGImage] = [:],
        renderState: CapturaVideoRenderState? = nil
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderState = renderState ?? CapturaVideoRenderState(
            project: project,
            events: events,
            geometry: geometry,
            brandingImages: brandingImages
        )
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
        var background: SIMD4<Float>
        var cameraStyle: SIMD4<Float>
        var cameraBorderColor: SIMD4<Float>
    }

    private struct GPUOverlay {
        var rect: SIMD4<Float>
        var values: SIMD4<Float>
    }

    private struct CachedTextTexture {
        let item: TextOverlay
        let texture: MTLTexture
    }

    private struct CachedBrandingTexture {
        let assetPath: String
        let texture: MTLTexture
    }

    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipeline: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private var brandingTextureCache: [UUID: CachedBrandingTexture] = [:]
    private var textTextureCache: [UUID: CachedTextTexture] = [:]
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
            let snapshot = instruction.renderState.snapshot()
            let project = snapshot.project
            let timelineTime = max(0, compositionTime.seconds)
            let activeClip = project.timeline.clip(at: timelineTime)
            let importedMedia = activeClip.flatMap { clip in
                project.videoAssets?.first { $0.id == clip.sourceMediaID }
            }
            let isPrimaryClip = importedMedia == nil
            let sourceTime = project.timeline.sourceTime(at: timelineTime) ?? timelineTime
            let keyframe = isPrimaryClip ? CameraKeyframeInterpolator().value(
                at: sourceTime,
                frames: project.cameraKeyframes
            ) : nil
            let cursor = isPrimaryClip ? cursorSample(at: sourceTime, project: project, samples: snapshot.cursorSamples) : nil
            let appearance = project.settings.appearance ?? .default
            let colors = backgroundColors(appearance)
            let gradientRadians = appearance.gradientAngle * .pi / 180
            let geometry = snapshot.geometry
            let outputSize = geometry.outputSize
            let activeTransition = project.timeline.activeTransition(at: timelineTime)
            let mutedTracks = Set((project.timelineTracks ?? []).filter(\.isMuted).map(\.id))
            let activeBranding = (project.brandingOverlays ?? []).last {
                timelineTime >= $0.startTime && timelineTime <= $0.endTime &&
                !mutedTracks.contains($0.trackID ?? TimelineTrack.defaultOverlayID)
            }
            let activeText = (project.textOverlays ?? []).last {
                timelineTime >= $0.startTime && timelineTime <= $0.endTime &&
                !mutedTracks.contains($0.trackID ?? TimelineTrack.defaultTextID)
            }
            let layoutSegments = (project.layoutSegments ?? [])
                .filter { $0.endTime > $0.startTime }
                .sorted { lhs, rhs in
                    lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
                }
            let activeLayoutSegment = layoutSegments.last {
                timelineTime >= $0.startTime && timelineTime < $0.endTime
            }
            let webcamLayout = WebcamLayoutInterpolator().value(
                at: timelineTime,
                frames: project.webcamKeyframes ?? [],
                fallback: appearance
            )
            let cameraWidth = max(2, geometry.screenRect.width * min(max(webcamLayout.width, 0.05), 1))
            let cameraHeight = max(2, geometry.screenRect.height * min(max(webcamLayout.height, 0.05), 1))
            let cameraCenter = CGPoint(
                x: geometry.screenRect.minX + geometry.screenRect.width * min(max(webcamLayout.positionX, 0), 1),
                y: geometry.screenRect.minY + geometry.screenRect.height * min(max(webcamLayout.positionY, 0), 1)
            )
            let baseCameraRect = CGRect(
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
                ?? Double(project.settings.sourceDisplay.width) / Double(max(1, project.settings.sourceDisplay.height)))
            let destinationAspect = geometry.screenRect.width / max(geometry.screenRect.height, 1)
            var relativeWidth = min(max(layout.scale, 0.05), 2)
            var relativeHeight = relativeWidth
            if layout.contentMode == .fit {
                if sourceAspect > destinationAspect { relativeHeight *= destinationAspect / sourceAspect }
                else { relativeWidth *= sourceAspect / destinationAspect }
            }
            let baseVideoRect = CGRect(
                x: geometry.screenRect.minX + geometry.screenRect.width * (layout.positionX - relativeWidth / 2),
                y: geometry.screenRect.minY + geometry.screenRect.height * (layout.positionY - relativeHeight / 2),
                width: geometry.screenRect.width * relativeWidth,
                height: geometry.screenRect.height * relativeHeight
            )
            let fallbackLayout = PresenterLayoutGeometry.resolve(
                layout: .pictureInPicture,
                container: geometry.screenRect,
                baseVideoRect: baseVideoRect,
                baseCameraRect: baseCameraRect,
                videoAspect: sourceAspect,
                videoContentMode: layout.contentMode,
                sideBySide: nil
            )
            var resolvedLayout = activeLayoutSegment.map { segment in
                PresenterLayoutGeometry.resolve(
                    layout: segment.layout,
                    container: geometry.screenRect,
                    baseVideoRect: baseVideoRect,
                    baseCameraRect: baseCameraRect,
                    videoAspect: sourceAspect,
                    videoContentMode: layout.contentMode,
                    sideBySide: segment.sideBySide
                )
            } ?? fallbackLayout
            if let segment = activeLayoutSegment, segment.transitionDuration > 0 {
                let previousSegment = layoutSegments.last {
                    $0.startTime < segment.startTime && $0.endTime <= segment.startTime
                }
                let previousLayout = previousSegment.map {
                    PresenterLayoutGeometry.resolve(
                        layout: $0.layout,
                        container: geometry.screenRect,
                        baseVideoRect: baseVideoRect,
                        baseCameraRect: baseCameraRect,
                        videoAspect: sourceAspect,
                        videoContentMode: layout.contentMode,
                        sideBySide: $0.sideBySide
                    )
                } ?? fallbackLayout
                let transitionProgress = (timelineTime - segment.startTime) / max(segment.transitionDuration, 0.01)
                resolvedLayout = PresenterLayoutGeometry.interpolate(
                    from: previousLayout,
                    to: resolvedLayout,
                    progress: transitionProgress
                )
            }
            let videoRect = resolvedLayout.videoRect
            let cameraRect = resolvedLayout.cameraRect
            let videoOpacity = min(max(layout.opacity * resolvedLayout.videoOpacity, 0), 1)
            let cameraOpacity = camera == nil || !isPrimaryClip
                ? 0
                : min(max(webcamLayout.opacity * resolvedLayout.cameraOpacity, 0), 1)
            let brandingImage = activeBranding.flatMap { snapshot.brandingImages[$0.id] }
            let brandingTexture = activeBranding.flatMap { overlay in
                cachedBrandingTexture(for: overlay.id, assetPath: overlay.assetPath, image: brandingImage)
            } ?? sourceTexture
            let brandingAspect = brandingImage.map { Float($0.width) / Float(max(1, $0.height)) } ?? 1
            let textAnimation = activeText.map { textAnimationState(for: $0, at: timelineTime) }
            var renderedText = activeText
            if var item = renderedText, item.entrance == .typewriter {
                let progress = textAnimation?.progress ?? 1
                item.text = String(item.text.prefix(max(1, Int(Double(item.text.count) * progress))))
                renderedText = item
            }
            let textTexture = renderedText.flatMap(cachedTextTexture(for:)) ?? sourceTexture
            let textAspect = Float(4)
            let brandingRect: SIMD4<Float>
            let brandingOpacity: Float
            if let activeBranding {
                let x = visualValue(for: activeBranding.id, property: .positionX, at: timelineTime, project: project, fallback: activeBranding.normalizedX)
                let y = visualValue(for: activeBranding.id, property: .positionY, at: timelineTime, project: project, fallback: activeBranding.normalizedY)
                let width = visualValue(for: activeBranding.id, property: .width, at: timelineTime, project: project, fallback: activeBranding.normalizedWidth)
                brandingRect = SIMD4(
                    Float(x - width / 2), Float(y - activeBranding.normalizedHeight / 2),
                    Float(width), Float(activeBranding.normalizedHeight)
                )
                let opacity = visualValue(for: activeBranding.id, property: .opacity, at: timelineTime, project: project, fallback: activeBranding.opacity)
                brandingOpacity = brandingImage == nil ? 0 : Float(min(max(opacity, 0), 1))
            } else {
                brandingRect = .zero
                brandingOpacity = 0
            }
            let textRect: SIMD4<Float>
            let textOpacity: Float
            if let activeText {
                let keyedScale = visualValue(for: activeText.id, property: .scale, at: timelineTime, project: project, fallback: 1)
                let scale = (textAnimation?.scale ?? 1) * keyedScale
                let baseWidth = visualValue(for: activeText.id, property: .width, at: timelineTime, project: project, fallback: activeText.normalizedWidth)
                let x = visualValue(for: activeText.id, property: .positionX, at: timelineTime, project: project, fallback: activeText.normalizedX)
                let y = visualValue(for: activeText.id, property: .positionY, at: timelineTime, project: project, fallback: activeText.normalizedY)
                let width = min(max(baseWidth * scale, 0.05), 1)
                let height = width * outputSize.width / max(outputSize.height, 1) / Double(textAspect)
                textRect = SIMD4(
                    Float(x - width / 2 + (textAnimation?.offsetX ?? 0)),
                    Float(y - height / 2 + (textAnimation?.offsetY ?? 0)),
                    Float(width), Float(height)
                )
                let opacity = visualValue(for: activeText.id, property: .opacity, at: timelineTime, project: project, fallback: activeText.opacity)
                textOpacity = Float(min(max(opacity * (textAnimation?.opacity ?? 1), 0), 1))
            } else {
                textRect = .zero
                textOpacity = 0
            }
            var cameraBorderColor = rgba(appearance.cameraBorderHex)
            cameraBorderColor.w = Float(min(max(appearance.cameraShadow, 0), 1))
            var uniforms = Uniforms(
                backgroundStart: colors.0,
                backgroundEnd: colors.1,
                windowRect: normalize(geometry.windowRect),
                screenRect: normalize(geometry.screenRect),
                cameraRect: normalize(cameraRect),
                cameraFocus: SIMD4(
                    Float(keyframe?.centerX ?? 0.5), Float(keyframe?.centerY ?? 0.5),
                    Float(max(1, keyframe?.scale ?? 1)),
                    Float(cameraOpacity)
                ),
                cursor: SIMD4(
                    Float(cursor?.normalizedX ?? 0.5), Float(cursor?.normalizedY ?? 0.5),
                    cursor == nil ? 0 : 1,
                    Float((project.settings.cursor ?? .default).size)
                ),
                chrome: SIMD4(
                    appearance.showsWindowFrame ? 1 : 0,
                    Float(geometry.windowCornerRadius / outputSize.width),
                    Float(appearance.shadowStrength * geometry.scale / outputSize.width),
                    0
                ),
                output: SIMD4(Float(outputSize.width), Float(outputSize.height), 0, 0),
                transition: SIMD4(
                    transitionCode(activeTransition?.kind),
                    Float(activeTransition?.intensity ?? 0), 0, 0
                ),
                videoRect: normalize(videoRect),
                video: SIMD4(
                    Float(videoOpacity),
                    layout.contentMode == .fill ? 1 : 0,
                    Float(sourceAspect),
                    Float(importedMedia?.rotationQuarterTurns ?? 0)
                ),
                brandingRect: brandingRect,
                branding: SIMD4(
                    brandingOpacity,
                    activeBranding?.contentMode == .fill ? 1 : 0,
                    brandingAspect,
                    Float(activeBranding?.cornerRadius ?? 0)
                ),
                textRect: textRect,
                text: SIMD4(textOpacity, 0, 0, 0),
                background: SIMD4(
                    Float(cos(gradientRadians)), Float(sin(gradientRadians)),
                    Float(min(max(appearance.vignette, 0), 1)), 0
                ),
                cameraStyle: SIMD4(
                    cameraShapeCode(appearance.cameraShape),
                    Float(min(max(appearance.cameraCornerRadius, 0), 0.5)),
                    Float(max(0, appearance.cameraBorderWidth) / max(outputSize.width, 1)),
                    appearance.cameraMirrored ? 1 : 0
                ),
                cameraBorderColor: cameraBorderColor
            )
            var overlays = activeOverlays(at: timelineTime, project: project)
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

    private func visualValue(
        for elementID: UUID,
        property: AnimatableVisualProperty,
        at time: Double,
        project: ScreenProject,
        fallback: Double
    ) -> Double {
        let frames = (project.visualKeyframes ?? [])
            .filter { $0.elementID == elementID && $0.property == property }
            .sorted { $0.time < $1.time }
        guard !frames.isEmpty else { return fallback }
        guard let next = frames.firstIndex(where: { $0.time >= time }) else { return frames.last?.value ?? fallback }
        guard next > 0 else { return frames[next].value }
        let left = frames[next - 1]
        let right = frames[next]
        let span = max(right.time - left.time, .ulpOfOne)
        var progress = min(max((time - left.time) / span, 0), 1)
        if right.easing != .linear { progress = progress * progress * (3 - 2 * progress) }
        return left.value + (right.value - left.value) * progress
    }

    private func cachedBrandingTexture(for id: UUID, assetPath: String, image: CGImage?) -> MTLTexture? {
        if let cached = brandingTextureCache[id], cached.assetPath == assetPath { return cached.texture }
        guard let image,
              let texture = try? textureLoader.newTexture(
                  cgImage: image,
                  options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
              ) else { return nil }
        brandingTextureCache[id] = CachedBrandingTexture(assetPath: assetPath, texture: texture)
        return texture
    }

    private func cachedTextTexture(for item: TextOverlay) -> MTLTexture? {
        if let cached = textTextureCache[item.id], cached.item == item { return cached.texture }
        guard let image = makeTextImage(item),
              let texture = try? textureLoader.newTexture(
                  cgImage: image,
                  options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
              ) else { return nil }
        textTextureCache[item.id] = CachedTextTexture(item: item, texture: texture)
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

        let fallbackFontName: CFString = switch item.weight {
        case .regular: "SFProDisplay-Regular" as CFString
        case .medium: "SFProDisplay-Medium" as CFString
        case .semibold: "SFProDisplay-Semibold" as CFString
        case .bold: "SFProDisplay-Bold" as CFString
        }
        let font = CTFontCreateWithName((item.fontName as CFString?) ?? fallbackFontName, CGFloat(min(max(item.fontSize, 18), 144)), nil)
        var alignment: CTTextAlignment = switch item.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        var lineHeight = CGFloat(item.fontSize * min(max(item.lineHeight ?? 1, 0.8), 2))
        let paragraph = withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                withUnsafePointer(to: &lineHeight) { lineHeightPointer in
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
                        ),
                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lineHeightPointer),
                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lineHeightPointer)
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor(item.foregroundHex, alpha: 1),
                kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
                kCTKernAttributeName as NSAttributedString.Key: item.letterSpacing ?? 0
        ]
        if (item.strokeWidth ?? 0) > 0 {
            attributes[kCTStrokeColorAttributeName as NSAttributedString.Key] = cgColor(item.strokeHex ?? "#000000", alpha: 1)
            attributes[kCTStrokeWidthAttributeName as NSAttributedString.Key] = -(item.strokeWidth ?? 0)
        }
        let attributed = NSAttributedString(string: item.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if (item.shadowOpacity ?? 0) > 0 {
            context.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: cgColor("#000000", alpha: item.shadowOpacity ?? 0))
        }
        let path = CGPath(rect: CGRect(x: 72, y: 48, width: width - 144, height: height - 96), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        context.restoreGState()
        return context.makeImage()
    }

    private struct TextAnimationState {
        var opacity = 1.0
        var offsetX = 0.0
        var offsetY = 0.0
        var scale = 1.0
        var progress = 1.0
    }

    private func textAnimationState(for item: TextOverlay, at time: Double) -> TextAnimationState {
        let duration = min(0.45, max(0.12, (item.endTime - item.startTime) * 0.2))
        let entranceProgress = min(max((time - item.startTime) / duration, 0), 1)
        let exitProgress = min(max((item.endTime - time) / duration, 0), 1)
        if entranceProgress < 1 { return animationState(item.entrance ?? .none, progress: entranceProgress) }
        if exitProgress < 1 { return animationState(item.exit ?? .none, progress: exitProgress) }
        return TextAnimationState()
    }

    private func animationState(_ transition: VisualTransition, progress: Double) -> TextAnimationState {
        let eased = progress * progress * (3 - 2 * progress)
        return switch transition {
        case .none: TextAnimationState()
        case .fade, .typewriter: TextAnimationState(opacity: eased, progress: eased)
        case .slideUp: TextAnimationState(opacity: eased, offsetY: (1 - eased) * 0.06, progress: eased)
        case .slideLeft: TextAnimationState(opacity: eased, offsetX: (1 - eased) * 0.08, progress: eased)
        case .scale: TextAnimationState(opacity: eased, scale: 0.78 + eased * 0.22, progress: eased)
        }
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

    private func cameraShapeCode(_ shape: CameraFrameShape) -> Float {
        switch shape {
        case .circle: 1
        case .squircle: 2
        case .roundedRectangle: 3
        case .rectangle: 4
        }
    }

    private func cursorSample(
        at sourceTime: Double,
        project: ScreenProject,
        samples: [CursorSample]
    ) -> CursorSample? {
        let settings = project.settings.cursor ?? .default
        guard settings.isVisible else { return nil }
        guard let sample = CursorInterpolator().sample(at: sourceTime, from: samples) else { return nil }
        if settings.hidesWhenIdle,
           let closest = nearestCursorSample(to: sourceTime, in: samples),
           abs(closest.time - sourceTime) > 1.5 { return nil }
        return sample
    }

    private func nearestCursorSample(to time: Double, in samples: [CursorSample]) -> CursorSample? {
        guard !samples.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = samples.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if samples[middle].time < time { lowerBound = middle + 1 }
            else { upperBound = middle }
        }
        if lowerBound == 0 { return samples[0] }
        if lowerBound == samples.count { return samples[samples.count - 1] }
        let previous = samples[lowerBound - 1]
        let next = samples[lowerBound]
        return abs(previous.time - time) <= abs(next.time - time) ? previous : next
    }

    private func activeOverlays(at time: Double, project: ScreenProject) -> [GPUOverlay] {
        (project.overlays ?? []).filter {
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
        case .custom: (appearance.customGradientStartHex, appearance.customGradientEndHex)
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
        float4 background; float4 cameraStyle; float4 cameraBorderColor;
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
        float gradient = clamp(0.5 + dot(uv - 0.5, normalize(u.background.xy)) * 0.72, 0.0, 1.0);
        float4 color = mix(u.backgroundStart, u.backgroundEnd, gradient);
        float vignette = smoothstep(0.28, 0.78, length((uv - 0.5) * float2(1.0, u.output.y / max(u.output.x, 1.0))));
        color.rgb *= 1.0 - vignette * u.background.z * 0.62;

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

        if (u.cameraFocus.w > 0.001 && u.cameraBorderColor.w > 0.001) {
            float spread = 0.012 * u.cameraBorderColor.w;
            float4 shadowRect = float4(u.cameraRect.xy - spread, u.cameraRect.zw + spread * 2.0);
            float shadowMask = roundedMask(uv - float2(0, spread * 0.45), shadowRect, min(shadowRect.z, shadowRect.w) * max(u.cameraStyle.y, 0.08));
            float cameraBody = roundedMask(uv, u.cameraRect, min(u.cameraRect.z, u.cameraRect.w) * max(u.cameraStyle.y, 0.08));
            color = mix(color, float4(0,0,0,1), max(0.0, shadowMask - cameraBody) * u.cameraBorderColor.w * 0.34);
        }

        if (u.cameraFocus.w > 0.001 && inside(uv, u.cameraRect)) {
            float cameraMask;
            if (u.cameraStyle.x < 1.5) {
                float2 cameraCenter = u.cameraRect.xy + u.cameraRect.zw * 0.5;
                float2 delta = (uv - cameraCenter) / max(u.cameraRect.zw * 0.5, 0.0001);
                cameraMask = 1.0 - smoothstep(0.985, 1.0, length(delta));
            } else if (u.cameraStyle.x < 2.5) {
                cameraMask = roundedMask(uv, u.cameraRect, min(u.cameraRect.z, u.cameraRect.w) * 0.32);
            } else if (u.cameraStyle.x < 3.5) {
                cameraMask = roundedMask(uv, u.cameraRect, min(u.cameraRect.z, u.cameraRect.w) * u.cameraStyle.y);
            } else {
                cameraMask = inside(uv, u.cameraRect) ? 1.0 : 0.0;
            }
            float2 cameraUV = (uv - u.cameraRect.xy) / u.cameraRect.zw;
            if (u.cameraStyle.w > 0.5) cameraUV.x = 1.0 - cameraUV.x;
            float sourceAspect = float(camera.get_width()) / max(float(camera.get_height()), 1.0);
            float destinationAspect = (u.cameraRect.z * u.output.x) / max(u.cameraRect.w * u.output.y, 1.0);
            if (sourceAspect > destinationAspect) {
                cameraUV.x = (cameraUV.x - 0.5) * destinationAspect / sourceAspect + 0.5;
            } else {
                cameraUV.y = (cameraUV.y - 0.5) * sourceAspect / destinationAspect + 0.5;
            }
            float4 cameraColor = camera.sample(s, cameraUV);
            color = mix(color, cameraColor, cameraMask * u.cameraFocus.w);
            if (u.cameraStyle.z > 0.0) {
                float inner = roundedMask(uv, float4(u.cameraRect.xy + u.cameraStyle.z, u.cameraRect.zw - u.cameraStyle.z * 2.0), max(0.0, min(u.cameraRect.z, u.cameraRect.w) * u.cameraStyle.y - u.cameraStyle.z));
                float border = max(0.0, cameraMask - inner);
                color = mix(color, u.cameraBorderColor, border);
            }
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
            textUV.y = 1.0 - textUV.y;
            float4 textColor = textTexture.sample(s, textUV);
            color = mix(color, textColor, textColor.a * u.text.x);
        }
        return color;
    }
    """#
}
