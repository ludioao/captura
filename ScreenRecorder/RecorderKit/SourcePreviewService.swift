import AppKit
@preconcurrency import CoreGraphics
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum SourcePreviewService {
    static func snapshot(displayID: CGDirectDisplayID?, windowID: CGWindowID?) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let sourceSize: CGSize

        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.displayUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceSize = window.frame.size
        } else {
            guard let displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayUnavailable
            }
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            sourceSize = CGSize(width: display.width, height: display.height)
        }

        let targetWidth = min(960.0, max(320.0, sourceSize.width))
        let targetHeight = max(180.0, targetWidth * sourceSize.height / max(sourceSize.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(targetWidth)
        configuration.height = Int(targetHeight)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
