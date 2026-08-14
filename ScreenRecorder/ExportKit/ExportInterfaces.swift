@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case mp4
    case gif
}

enum ExportQuality: String, Codable, Sendable, CaseIterable {
    case compact, balanced, high
}

struct ExportSettings: Codable, Sendable, Hashable {
    var format: ExportFormat
    var codec: VideoCodec
    var resolution: CanvasSize
    var fps: Int
    var quality: ExportQuality

    static func mp4(resolution: CanvasSize, fps: Int = 60) -> ExportSettings {
        ExportSettings(format: .mp4, codec: .h264, resolution: resolution, fps: fps, quality: .high)
    }
}

protocol ProjectExporter: Sendable {
    func export(
        project: ScreenProject,
        packageURL: URL,
        destination: URL,
        settings: ExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

enum ExportError: LocalizedError {
    case unsupportedFormat
    case missingScreenMedia
    case compositionFailed(String)
    case exportFailed(String)
    case cancelled
    case insufficientDiskSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This export format is not available yet."
        case .missingScreenMedia: "The project screen recording is missing."
        case let .compositionFailed(message): "Could not prepare the project: \(message)"
        case let .exportFailed(message): "Export failed: \(message)"
        case .cancelled: "Export was cancelled."
        case let .insufficientDiskSpace(required, available):
            "Not enough free disk space. Captura estimates \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) is required, but \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        }
    }
}

final class MP4ProjectExporter: @unchecked Sendable, ProjectExporter {
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
    private let stateLock = NSLock()
    private var activeSession: AVAssetExportSession?

    func cancel() {
        let session = stateLock.withLock { activeSession }
        session?.cancelExport()
    }

    func export(
        project: ScreenProject,
        packageURL: URL,
        destination: URL,
        settings: ExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard settings.format == .mp4 else { throw ExportError.unsupportedFormat }
        let screenURL = packageURL.appending(path: project.media.screen)
        guard FileManager.default.fileExists(atPath: screenURL.path) else { throw ExportError.missingScreenMedia }
        try preflightDiskSpace(destination: destination, project: project, settings: settings)

        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = project.media.camera.map { AVURLAsset(url: packageURL.appending(path: $0)) }
        let eventsURL = packageURL.appending(path: project.recording.eventsPath)
        let events = (try? JSONDecoder().decode([InteractionEvent].self, from: Data(contentsOf: eventsURL))) ?? []
        let prepared = try await makeComposition(
            project: project,
            packageURL: packageURL,
            screenAsset: screenAsset,
            cameraAsset: cameraAsset,
            events: events,
            settings: settings,
            brandingImages: BrandingAssetLoader.load(project: project, packageURL: packageURL)
        )
        defer { prepared.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let preset: String
        if settings.codec == .hevc {
            preset = AVAssetExportPresetHEVCHighestQuality
        } else {
            preset = switch settings.quality {
            case .compact: AVAssetExportPresetLowQuality
            case .balanced: AVAssetExportPresetMediumQuality
            case .high: AVAssetExportPresetHighestQuality
            }
        }
        guard let session = AVAssetExportSession(asset: prepared.composition, presetName: preset) else {
            throw ExportError.exportFailed("AVFoundation rejected the selected codec and resolution.")
        }
        session.videoComposition = prepared.videoComposition
        session.audioMix = prepared.audioMix
        session.shouldOptimizeForNetworkUse = true
        session.metadata = exportMetadata(for: project)

        stateLock.withLock { activeSession = session }
        let sessionBox = SessionBox(session)
        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(Double(sessionBox.session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer {
            progressTask.cancel()
            stateLock.withLock { activeSession = nil }
        }

        progress(0)
        do {
            try await session.export(to: destination, as: .mp4)
            progress(1)
        } catch is CancellationError {
            throw ExportError.cancelled
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    private func preflightDiskSpace(destination: URL, project: ScreenProject, settings: ExportSettings) throws {
        let parent = destination.deletingLastPathComponent()
        let values = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        let pixels = Double(settings.resolution.width * settings.resolution.height)
        let bitsPerPixel: Double = switch settings.quality {
        case .compact: 0.045
        case .balanced: 0.08
        case .high: 0.14
        }
        let videoBytes = pixels * Double(max(1, settings.fps)) * bitsPerPixel / 8 * max(project.duration, 1)
        let audioBytes = 32_000 * max(project.duration, 1)
        let required = Int64((videoBytes + audioBytes) * 1.25)
        if available < required {
            throw ExportError.insufficientDiskSpace(required: required, available: available)
        }
    }

    private struct PreparedComposition {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let temporaryFiles: [URL]
    }

    private func makeComposition(
        project: ScreenProject,
        packageURL: URL,
        screenAsset: AVURLAsset,
        cameraAsset: AVURLAsset?,
        events: [InteractionEvent],
        settings: ExportSettings,
        brandingImages: [UUID: CGImage]
    ) async throws -> PreparedComposition {
        guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.missingScreenMedia
        }
        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.compositionFailed("Unable to allocate the screen video track.")
        }
        let cameraSource = try await cameraAsset?.loadTracks(withMediaType: .video).first
        let cameraTrack = cameraSource.flatMap {
            _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let primaryAudioSources = try await screenAsset.loadTracks(withMediaType: .audio)
        var additionalVideoSources: [UUID: AVAssetTrack] = [:]
        var additionalAudioSources: [UUID: [AVAssetTrack]] = [:]
        for media in project.videoAssets ?? [] {
            let asset = AVURLAsset(url: packageURL.appending(path: media.path))
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                additionalVideoSources[media.id] = video
                additionalAudioSources[media.id] = try await asset.loadTracks(withMediaType: .audio)
            }
        }
        let audioLaneCount = max(primaryAudioSources.count, additionalAudioSources.values.map(\.count).max() ?? 0)
        let audioTracks = (0..<audioLaneCount).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        let clips = project.timeline.clips.sorted { $0.timelineStart < $1.timelineStart }
        var destinationCursor = CMTime.zero
        for clip in clips {
            let isPrimary = additionalVideoSources[clip.sourceMediaID] == nil
            let videoSource = additionalVideoSources[clip.sourceMediaID] ?? screenSource
            let audioSources = additionalAudioSources[clip.sourceMediaID] ?? primaryAudioSources
            let requested = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            )
            let screenRange = CMTimeRangeGetIntersection(requested, otherRange: try await videoSource.load(.timeRange))
            guard screenRange.duration > .zero else { continue }
            try screenTrack.insertTimeRange(screenRange, of: videoSource, at: destinationCursor)

            for (source, target) in zip(audioSources, audioTracks) {
                let available = CMTimeRangeGetIntersection(screenRange, otherRange: try await source.load(.timeRange))
                guard available.duration > .zero else { continue }
                let audioDestination = CMTimeAdd(destinationCursor, CMTimeSubtract(available.start, screenRange.start))
                try target.insertTimeRange(available, of: source, at: audioDestination)
            }

            if isPrimary, let cameraSource, let cameraTrack {
                let available = CMTimeRangeGetIntersection(screenRange, otherRange: try await cameraSource.load(.timeRange))
                if available.duration > .zero {
                    let cameraDestination = CMTimeAdd(destinationCursor, CMTimeSubtract(available.start, screenRange.start))
                    try cameraTrack.insertTimeRange(available, of: cameraSource, at: cameraDestination)
                }
            }
            let outputDuration = CMTimeMultiplyByFloat64(screenRange.duration, multiplier: 1 / max(0.25, clip.speed))
            if outputDuration != screenRange.duration {
                let insertedRange = CMTimeRange(start: destinationCursor, duration: screenRange.duration)
                screenTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                for audioTrack in audioTracks {
                    audioTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                }
                cameraTrack?.scaleTimeRange(insertedRange, toDuration: outputDuration)
            }
            destinationCursor = CMTimeAdd(destinationCursor, outputDuration)
        }
        guard destinationCursor > .zero else {
            throw ExportError.compositionFailed("The timeline has no exportable video.")
        }

        var clickTracks: [AVMutableCompositionTrack] = []
        var clickURL: URL?
        let audioSettings = project.settings.audio ?? .default
        if audioSettings.clickSounds {
            let url = try ClickSoundAsset.makeTemporary()
            clickURL = url
            let clickAsset = AVURLAsset(url: url)
            if let clickSource = try await clickAsset.loadTracks(withMediaType: .audio).first {
                let clickRange = try await clickSource.load(.timeRange)
                var voiceEnds = Array(repeating: CMTime.zero, count: 4)
                for event in events where event.type == .click {
                    guard let timelineTime = project.timeline.firstTimelineTime(forSourceTime: event.timestamp),
                          timelineTime < destinationCursor.seconds else { continue }
                    let start = CMTime(seconds: timelineTime, preferredTimescale: 48_000)
                    let voice = voiceEnds.indices.first(where: { voiceEnds[$0] <= start }) ?? 0
                    while clickTracks.count <= voice {
                        guard let track = composition.addMutableTrack(
                            withMediaType: .audio,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        ) else { break }
                        clickTracks.append(track)
                    }
                    guard voice < clickTracks.count else { continue }
                    try clickTracks[voice].insertTimeRange(clickRange, of: clickSource, at: start)
                    voiceEnds[voice] = CMTimeAdd(start, clickRange.duration)
                }
            }
        }

        let outputSize = CGSize(width: settings.resolution.width, height: settings.resolution.height)
        let appearance = project.settings.appearance ?? .default
        let geometry = ExportGeometry(outputSize: outputSize, sourceSize: project.settings.canvas, appearance: appearance)

        let instruction = CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: destinationCursor),
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrack?.trackID,
            project: project,
            events: events,
            geometry: geometry,
            brandingImages: brandingImages
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = MetalProjectVideoCompositor.self
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        videoComposition.renderScale = 1
        videoComposition.animationTool = makeCaptionAnimationTool(
            geometry: geometry,
            cues: project.captions ?? [],
            duration: destinationCursor.seconds
        )

        var mixParameters = try audioTracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let isSystemAudio = index == 0
            let muted = isSystemAudio ? audioSettings.systemMuted : audioSettings.microphoneMuted
            let volume = isSystemAudio ? audioSettings.systemVolume : audioSettings.microphoneVolume
            parameters.setVolume(muted ? 0 : Float(volume), at: .zero)
            if !isSystemAudio && (audioSettings.voiceEnhancement || audioSettings.noiseReduction) {
                parameters.audioTapProcessor = try VoiceProcessingAudioTap.make(
                    voiceEnhancement: audioSettings.voiceEnhancement,
                    noiseReduction: audioSettings.noiseReduction
                )
            }
            return parameters
        }
        mixParameters.append(contentsOf: clickTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(audioSettings.clickVolume), at: .zero)
            return parameters
        })
        let audioMix: AVAudioMix?
        if mixParameters.isEmpty {
            audioMix = nil
        } else {
            let mutableMix = AVMutableAudioMix()
            mutableMix.inputParameters = mixParameters
            audioMix = mutableMix
        }
        return PreparedComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            temporaryFiles: clickURL.map { [$0] } ?? []
        )
    }

    private func makeCaptionAnimationTool(
        geometry: ExportGeometry,
        cues: [CaptionCue],
        duration: Double
    ) -> AVVideoCompositionCoreAnimationTool? {
        guard !cues.isEmpty else { return nil }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: geometry.outputSize)
        root.isGeometryFlipped = true
        let video = CALayer()
        video.frame = root.bounds
        root.addSublayer(video)
        addCaptions(to: root, geometry: geometry, cues: cues, duration: duration)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: root)
    }

    private func aspectFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        destination: CGRect
    ) -> CGAffineTransform {
        transformedMediaTransform(naturalSize: naturalSize, preferredTransform: preferredTransform, destination: destination, fill: false)
    }

    private func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        destination: CGRect
    ) -> CGAffineTransform {
        // AVVideoComposition layer instructions cannot clip an individual track,
        // so fit is used here. The camera layer remains fully visible and is
        // cropped by the containing window in the final Metal compositor milestone.
        transformedMediaTransform(naturalSize: naturalSize, preferredTransform: preferredTransform, destination: destination, fill: false)
    }

    private func transformedMediaTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        destination: CGRect,
        fill: Bool
    ) -> CGAffineTransform {
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformedBounds.width), height: abs(transformedBounds.height))
        let scaleX = destination.width / max(orientedSize.width, 1)
        let scaleY = destination.height / max(orientedSize.height, 1)
        let scale = fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let renderedSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let origin = CGPoint(
            x: destination.midX - renderedSize.width / 2,
            y: destination.midY - renderedSize.height / 2
        )
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -transformedBounds.minX, y: -transformedBounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func zoomDestination(for frame: CameraKeyframe, screenRect: CGRect) -> CGRect {
        let scale = max(1, frame.scale)
        let width = screenRect.width * scale
        let height = screenRect.height * scale
        return CGRect(
            x: screenRect.midX - min(max(frame.centerX, 0), 1) * width,
            y: screenRect.midY - min(max(frame.centerY, 0), 1) * height,
            width: width,
            height: height
        )
    }

    private func makeAnimationTool(
        geometry: ExportGeometry,
        appearance: CanvasAppearance,
        project: ScreenProject,
        events: [InteractionEvent],
        duration: Double
    ) -> AVVideoCompositionCoreAnimationTool {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: geometry.outputSize)
        root.isGeometryFlipped = true

        let background = CAGradientLayer()
        background.frame = root.bounds
        let colors = exportBackgroundColors(appearance)
        background.colors = colors.map(\.cgColor)
        background.startPoint = CGPoint(x: 0, y: 0)
        background.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(background)

        let shadow = CALayer()
        shadow.frame = geometry.windowRect
        shadow.cornerRadius = geometry.windowCornerRadius
        shadow.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = Float(min(0.48, 0.12 + appearance.shadowStrength / 80))
        shadow.shadowRadius = appearance.shadowStrength * geometry.scale
        shadow.shadowOffset = CGSize(width: 0, height: appearance.shadowStrength * geometry.scale * 0.45)
        root.addSublayer(shadow)

        let windowSurface = CALayer()
        windowSurface.frame = geometry.windowRect
        windowSurface.cornerRadius = geometry.windowCornerRadius
        windowSurface.masksToBounds = true
        windowSurface.backgroundColor = NSColor.black.cgColor
        root.addSublayer(windowSurface)

        let videoLayer = CALayer()
        videoLayer.frame = root.bounds
        let videoMask = CAShapeLayer()
        videoMask.path = CGPath(rect: geometry.screenRect, transform: nil)
        videoLayer.mask = videoMask
        root.addSublayer(videoLayer)

        if appearance.showsWindowFrame {
            addMacWindowChrome(to: root, geometry: geometry)
        }

        let outline = CAShapeLayer()
        outline.frame = root.bounds
        outline.path = CGPath(roundedRect: geometry.windowRect, cornerWidth: geometry.windowCornerRadius, cornerHeight: geometry.windowCornerRadius, transform: nil)
        outline.fillColor = nil
        outline.strokeColor = NSColor.black.withAlphaComponent(0.24).cgColor
        outline.lineWidth = max(1, geometry.scale)
        root.addSublayer(outline)

        addOverlays(to: root, geometry: geometry, regions: project.overlays ?? [], duration: duration)
        addCursor(to: root, geometry: geometry, project: project, events: events, duration: duration)
        addCaptions(to: root, geometry: geometry, cues: project.captions ?? [], duration: duration)

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: root)
    }

    private func addOverlays(
        to root: CALayer,
        geometry: ExportGeometry,
        regions: [OverlayRegion],
        duration: Double
    ) {
        guard duration > 0 else { return }
        for region in regions where region.endTime > region.startTime {
            let layer = CALayer()
            layer.frame = CGRect(
                x: geometry.screenRect.minX + geometry.screenRect.width * (region.normalizedX - region.normalizedWidth / 2),
                y: geometry.screenRect.minY + geometry.screenRect.height * (region.normalizedY - region.normalizedHeight / 2),
                width: geometry.screenRect.width * region.normalizedWidth,
                height: geometry.screenRect.height * region.normalizedHeight
            )
            layer.cornerRadius = 7 * geometry.scale
            if region.kind == .privacy {
                layer.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
                layer.borderWidth = max(1, geometry.scale)
            } else {
                layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor
                layer.borderColor = NSColor.systemYellow.cgColor
                layer.borderWidth = max(2, 3 * geometry.scale)
            }
            layer.opacity = 0
            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            let start = min(max(region.startTime / duration, 0), 1)
            let end = min(max(region.endTime / duration, start), 1)
            visibility.values = [0, 0, 1, 1, 0, 0]
            visibility.keyTimes = [0, NSNumber(value: start), NSNumber(value: start), NSNumber(value: end), NSNumber(value: end), 1]
            visibility.duration = duration
            visibility.beginTime = AVCoreAnimationBeginTimeAtZero
            visibility.calculationMode = .discrete
            visibility.isRemovedOnCompletion = false
            layer.add(visibility, forKey: "captura.overlay.visibility")
            root.addSublayer(layer)
        }
    }

    private func addCursor(
        to root: CALayer,
        geometry: ExportGeometry,
        project: ScreenProject,
        events: [InteractionEvent],
        duration: Double
    ) {
        let settings = project.settings.cursor ?? .default
        guard settings.isVisible, duration > 0 else { return }
        let points: [(time: Double, point: CGPoint)] = events.compactMap { event in
            guard event.type == .mouseMove || event.type == .click || event.type == .mouseDown,
                  let x = event.normalizedX, let y = event.normalizedY,
                  let timelineTime = project.timeline.firstTimelineTime(forSourceTime: event.timestamp) else { return nil }
            return (
                timelineTime,
                CGPoint(
                    x: geometry.screenRect.minX + geometry.screenRect.width * x,
                    y: geometry.screenRect.minY + geometry.screenRect.height * y
                )
            )
        }
        guard !points.isEmpty else { return }

        let cursor = CAShapeLayer()
        let size = max(12, 24 * geometry.scale * settings.size)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: size * 0.42, y: size))
        path.addLine(to: CGPoint(x: size * 0.58, y: size * 0.58))
        path.addLine(to: CGPoint(x: size, y: size * 0.46))
        path.closeSubpath()
        cursor.path = path
        cursor.fillColor = NSColor.white.cgColor
        cursor.strokeColor = NSColor.black.withAlphaComponent(0.85).cgColor
        cursor.lineWidth = max(1, 1.6 * geometry.scale)
        cursor.shadowColor = NSColor.black.cgColor
        cursor.shadowOpacity = 0.45
        cursor.shadowRadius = 1.5 * geometry.scale
        cursor.position = points[0].point

        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.values = points.map(\.point)
        movement.keyTimes = points.map { NSNumber(value: min(max($0.time / duration, 0), 1)) }
        movement.duration = duration
        movement.beginTime = AVCoreAnimationBeginTimeAtZero
        movement.calculationMode = settings.smoothing > 0.05 ? .cubic : .linear
        movement.isRemovedOnCompletion = false
        movement.fillMode = .forwards
        cursor.add(movement, forKey: "captura.cursor.position")
        root.addSublayer(cursor)

        guard settings.clickEffect else { return }
        for event in events where event.type == .click {
            guard let x = event.normalizedX, let y = event.normalizedY,
                  let time = project.timeline.firstTimelineTime(forSourceTime: event.timestamp) else { continue }
            let ring = CAShapeLayer()
            let diameter = 38 * geometry.scale
            ring.frame = CGRect(
                x: geometry.screenRect.minX + geometry.screenRect.width * x - diameter / 2,
                y: geometry.screenRect.minY + geometry.screenRect.height * y - diameter / 2,
                width: diameter,
                height: diameter
            )
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor.systemYellow.cgColor
            ring.lineWidth = max(2, 3 * geometry.scale)
            ring.opacity = 0
            let group = CAAnimationGroup()
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.25
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.95, 0]
            opacity.keyTimes = [0, 0.15, 1]
            group.animations = [scale, opacity]
            group.duration = 0.55
            group.beginTime = AVCoreAnimationBeginTimeAtZero + time
            ring.add(group, forKey: "captura.click")
            root.addSublayer(ring)
        }
    }

    private func addCaptions(to root: CALayer, geometry: ExportGeometry, cues: [CaptionCue], duration: Double) {
        guard duration > 0 else { return }
        for cue in cues where !cue.text.isEmpty && cue.endTime > cue.startTime {
            let container = CALayer()
            let width = min(geometry.screenRect.width * 0.82, max(220 * geometry.scale, Double(cue.text.count) * 13 * geometry.scale))
            let height = 54 * geometry.scale
            container.frame = CGRect(
                x: geometry.screenRect.midX - width / 2,
                y: geometry.screenRect.maxY - height - 34 * geometry.scale,
                width: width,
                height: height
            )
            container.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            container.cornerRadius = 9 * geometry.scale
            container.opacity = 0

            let text = CATextLayer()
            text.frame = container.bounds.insetBy(dx: 12 * geometry.scale, dy: 8 * geometry.scale)
            text.string = cue.text
            text.font = NSFont.systemFont(ofSize: 22 * geometry.scale, weight: .semibold)
            text.fontSize = 22 * geometry.scale
            text.foregroundColor = NSColor.white.cgColor
            text.alignmentMode = .center
            text.contentsScale = 2
            text.isWrapped = true
            container.addSublayer(text)

            let visibility = CAKeyframeAnimation(keyPath: "opacity")
            visibility.values = [0, 0, 1, 1, 0, 0]
            let start = min(max(cue.startTime / duration, 0), 1)
            let end = min(max(cue.endTime / duration, start), 1)
            visibility.keyTimes = [0, NSNumber(value: start), NSNumber(value: start), NSNumber(value: end), NSNumber(value: end), 1]
            visibility.duration = duration
            visibility.beginTime = AVCoreAnimationBeginTimeAtZero
            visibility.calculationMode = .discrete
            visibility.isRemovedOnCompletion = false
            container.add(visibility, forKey: "captura.caption.visibility")
            root.addSublayer(container)
        }
    }

    private func addMacWindowChrome(to root: CALayer, geometry: ExportGeometry) {
        let titlebar = CAGradientLayer()
        titlebar.frame = geometry.titlebarRect
        titlebar.colors = [NSColor(calibratedWhite: 0.95, alpha: 1).cgColor, NSColor(calibratedWhite: 0.91, alpha: 1).cgColor]
        titlebar.startPoint = CGPoint(x: 0.5, y: 0)
        titlebar.endPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(titlebar)

        let separator = CALayer()
        separator.frame = CGRect(x: geometry.titlebarRect.minX, y: geometry.titlebarRect.maxY - max(1, geometry.scale), width: geometry.titlebarRect.width, height: max(1, geometry.scale))
        separator.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        root.addSublayer(separator)

        let diameter = max(6, geometry.titlebarRect.height * MacWindowChromeMetrics.trafficLightToTitlebarHeight)
        let centerSpacing = diameter * MacWindowChromeMetrics.trafficLightCenterSpacing
        let leading = geometry.titlebarRect.height * MacWindowChromeMetrics.trafficLightLeadingToTitlebarHeight
        for (index, color) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            let light = CALayer()
            light.frame = CGRect(
                x: geometry.titlebarRect.minX + leading + Double(index) * centerSpacing,
                y: geometry.titlebarRect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            light.cornerRadius = diameter / 2
            light.backgroundColor = NSColor(capturaHex: color).cgColor
            light.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
            light.borderWidth = max(0.5, geometry.scale * 0.5)
            root.addSublayer(light)
        }
    }

    private func exportBackgroundColors(_ appearance: CanvasAppearance) -> [NSColor] {
        switch appearance.backgroundPreset {
        case .studio: [NSColor(capturaHex: "#F2D6C8"), NSColor(capturaHex: "#C6A7E8")]
        case .midnight: [NSColor(capturaHex: "#101426"), NSColor(capturaHex: "#343E68")]
        case .ocean: [NSColor(capturaHex: "#0B6B78"), NSColor(capturaHex: "#7BDCB5")]
        case .sunset: [NSColor(capturaHex: "#F97356"), NSColor(capturaHex: "#8E4EC6")]
        case .graphite: [NSColor(capturaHex: "#24262B"), NSColor(capturaHex: "#555A65")]
        case .custom: [NSColor(capturaHex: appearance.customColorHex), NSColor(capturaHex: appearance.customColorHex)]
        }
    }

    private func exportMetadata(for project: ScreenProject) -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Captura Recording" as NSString
        title.extendedLanguageTag = "und"
        let creation = AVMutableMetadataItem()
        creation.identifier = .commonIdentifierCreationDate
        creation.value = ISO8601DateFormatter().string(from: project.createdAt) as NSString
        creation.extendedLanguageTag = "und"
        return [title, creation]
    }
}

struct ExportGeometry: Sendable {
    let outputSize: CGSize
    let windowRect: CGRect
    let screenRect: CGRect
    let titlebarRect: CGRect
    let cameraRect: CGRect
    let windowCornerRadius: Double
    let scale: Double

    init(outputSize: CGSize, sourceSize: CanvasSize, appearance: CanvasAppearance) {
        self.outputSize = outputSize
        scale = min(outputSize.width, outputSize.height) / 720
        let padding = max(16 * scale, appearance.padding * scale)
        let available = CGRect(x: padding, y: padding, width: max(2, outputSize.width - padding * 2), height: max(2, outputSize.height - padding * 2))
        let sourceAspect = Double(sourceSize.width) / Double(max(1, sourceSize.height))
        let titleRatio = appearance.showsWindowFrame ? MacWindowChromeMetrics.titlebarToWindowWidth : 0
        let outerAspect = 1 / (1 / sourceAspect + titleRatio)
        let width: Double
        let height: Double
        if available.width / available.height > outerAspect {
            height = available.height
            width = height * outerAspect
        } else {
            width = available.width
            height = width / outerAspect
        }
        windowRect = CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        let titleHeight = appearance.showsWindowFrame ? width * titleRatio : 0
        titlebarRect = CGRect(x: windowRect.minX, y: windowRect.minY, width: width, height: titleHeight)
        screenRect = CGRect(x: windowRect.minX, y: windowRect.minY + titleHeight, width: width, height: max(1, height - titleHeight))
        let cameraWidth = max(56 * scale, screenRect.width * appearance.cameraWidth)
        let cameraHeight = max(56 * scale, screenRect.height * appearance.cameraHeight)
        let center = CGPoint(
            x: screenRect.minX + screenRect.width * appearance.cameraPositionX,
            y: screenRect.minY + screenRect.height * appearance.cameraPositionY
        )
        cameraRect = CGRect(x: center.x - cameraWidth / 2, y: center.y - cameraHeight / 2, width: cameraWidth, height: cameraHeight)
        windowCornerRadius = appearance.showsWindowFrame ? 9 * scale : appearance.cornerRadius * scale
    }
}

private extension NSColor {
    convenience init(capturaHex hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let parsed = UInt64(value, radix: 16) ?? 0x6C5CE7
        self.init(
            red: CGFloat((parsed >> 16) & 0xFF) / 255,
            green: CGFloat((parsed >> 8) & 0xFF) / 255,
            blue: CGFloat(parsed & 0xFF) / 255,
            alpha: 1
        )
    }
}

final class GIFExporter: @unchecked Sendable, ProjectExporter {
    private let mp4Exporter = MP4ProjectExporter()

    func cancel() { mp4Exporter.cancel() }

    func export(
        project: ScreenProject,
        packageURL: URL,
        destination: URL,
        settings: ExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard settings.format == .gif else { throw ExportError.unsupportedFormat }
        let intermediate = FileManager.default.temporaryDirectory
            .appending(path: "captura-gif-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        var mp4Settings = settings
        mp4Settings.format = .mp4
        mp4Settings.codec = .h264
        try await mp4Exporter.export(
            project: project,
            packageURL: packageURL,
            destination: intermediate,
            settings: mp4Settings,
            progress: { progress($0 * 0.72) }
        )

        let asset = AVURLAsset(url: intermediate)
        let duration = try await asset.load(.duration).seconds
        let gifFPS = min(max(settings.fps, 5), 20)
        let frameCount = max(1, Int(ceil(duration * Double(gifFPS))))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { throw ExportError.exportFailed("Could not create the GIF destination.") }
        CGImageDestinationSetProperties(output, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(gifFPS))
        let delay = 1 / Double(gifFPS)
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let requested = CMTime(seconds: min(duration, Double(frame) * delay), preferredTimescale: 600)
            let (image, _) = try await generator.image(at: requested)
            CGImageDestinationAddImage(output, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
            progress(0.72 + 0.27 * Double(frame + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(output) else {
            throw ExportError.exportFailed("ImageIO could not finalize the GIF.")
        }
        progress(1)
    }
}
