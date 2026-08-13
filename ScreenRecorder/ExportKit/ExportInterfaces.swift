import Foundation

enum ExportFormat: String, Codable, Sendable {
    case mp4
    case gif
}

enum ExportQuality: String, Codable, Sendable {
    case compact, balanced, high
}

struct ExportSettings: Codable, Sendable {
    var format: ExportFormat
    var codec: VideoCodec
    var resolution: CanvasSize
    var fps: Int
    var quality: ExportQuality
}

protocol ProjectExporter: Sendable {
    func export(project: ScreenProject, destination: URL, settings: ExportSettings) async throws
}

enum ExportError: Error {
    case notImplemented
}

struct GIFExporter: ProjectExporter {
    func export(project: ScreenProject, destination: URL, settings: ExportSettings) async throws {
        // ImageIO encoding will be fed by RenderKit downscaled pixel buffers in the export milestone.
        throw ExportError.notImplemented
    }
}
