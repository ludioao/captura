@preconcurrency import Metal
import CoreMedia
import CoreVideo
import Foundation
import simd

enum MetalCompositorError: LocalizedError {
    case unavailable
    case pipeline(String)
    case unsupportedPixelFormat
    case outputAllocation
    case textureCreation
    case commandEncoding
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Metal is unavailable on this Mac."
        case let .pipeline(message): "Metal pipeline creation failed: \(message)"
        case .unsupportedPixelFormat: "The frame is not BGRA and cannot be rendered by this pipeline."
        case .outputAllocation: "Could not allocate a Metal-compatible output frame."
        case .textureCreation: "Could not create Metal textures for the video frame."
        case .commandEncoding: "Could not encode the Metal render pass."
        case .renderingFailed: "The GPU did not complete the video frame."
        }
    }
}

/// A zero-CPU-copy frame renderer used by preview and offline composition.
/// Source and destination remain IOSurface-backed CVPixelBuffers throughout.
final class MetalFrameCompositor: @unchecked Sendable, FrameCompositor {
    private struct Uniforms {
        var center: SIMD2<Float>
        var scale: Float
        var showsCursor: Float
        var cursor: SIMD2<Float>
        var cursorScale: Float
        var padding: Float = 0
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipeline: MTLRenderPipelineState
    private let renderLock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw MetalCompositorError.unavailable
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalCompositorError.unavailable }
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "capturaVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "capturaFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalCompositorError.pipeline(error.localizedDescription)
        }
    }

    func render(
        source: CVPixelBuffer,
        at time: CMTime,
        camera: CameraKeyframe?,
        cursor: CursorSample?
    ) async throws -> CVPixelBuffer {
        try renderLock.withLock {
            guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
                throw MetalCompositorError.unsupportedPixelFormat
            }
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            var output: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &output
            ) == kCVReturnSuccess, let output else {
                throw MetalCompositorError.outputAllocation
            }
            guard let sourceTexture = makeTexture(from: source, width: width, height: height),
                  let outputTexture = makeTexture(from: output, width: width, height: height) else {
                throw MetalCompositorError.textureCreation
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = outputTexture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw MetalCompositorError.commandEncoding
            }
            var uniforms = Uniforms(
                center: SIMD2(Float(camera?.centerX ?? 0.5), Float(camera?.centerY ?? 0.5)),
                scale: Float(max(1, camera?.scale ?? 1)),
                showsCursor: cursor == nil ? 0 : 1,
                cursor: SIMD2(Float(cursor?.normalizedX ?? 0.5), Float(cursor?.normalizedY ?? 0.5)),
                cursorScale: Float(max(0.65, min(2.2, Double(width) / 1920)))
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw MetalCompositorError.renderingFailed
            }
            return output
        }
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texture
        ) == kCVReturnSuccess, let texture else { return nil }
        return CVMetalTextureGetTexture(texture)
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float2 center;
        float scale;
        float showsCursor;
        float2 cursor;
        float cursorScale;
        float padding;
    };

    vertex VertexOut capturaVertex(uint id [[vertex_id]]) {
        const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        const float2 uvs[3] = { float2(0, 1), float2(2, 1), float2(0, -1) };
        VertexOut out;
        out.position = float4(positions[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }

    fragment float4 capturaFragment(
        VertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        constant Uniforms &uniforms [[buffer(0)]]) {
        constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = uniforms.center + (in.uv - 0.5) / max(uniforms.scale, 1.0);
        float4 color = source.sample(videoSampler, uv);

        if (uniforms.showsCursor > 0.5) {
            float2 delta = in.uv - uniforms.cursor;
            delta.x *= float(source.get_width()) / float(max(source.get_height(), 1u));
            float cursorSize = 0.018 * uniforms.cursorScale;
            float2 local = delta / cursorSize;
            bool arrow = local.x >= 0.0 && local.y >= 0.0 && local.y <= 1.45 &&
                local.x <= (0.22 + local.y * 0.48);
            bool tail = local.y > 0.62 && local.y < 1.55 && local.x > 0.25 && local.x < 0.52;
            if (arrow || tail) {
                float edge = min(min(local.x, local.y), 1.4 - local.y);
                color = edge < 0.08 ? float4(0.03, 0.03, 0.03, 1) : float4(1, 1, 1, 1);
            }
        }
        return color;
    }
    """#
}
