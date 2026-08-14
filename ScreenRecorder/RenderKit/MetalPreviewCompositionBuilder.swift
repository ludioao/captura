@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum MetalPreviewCompositionBuilder {
    @MainActor
    static func makePlayerItem(
        project: ScreenProject,
        packageURL: URL,
        events: [InteractionEvent]
    ) async throws -> AVPlayerItem {
        let screenAsset = AVURLAsset(url: packageURL.appending(path: project.media.screen))
        guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.missingScreenMedia
        }
        let cameraAsset = project.media.camera.map { AVURLAsset(url: packageURL.appending(path: $0)) }
        let cameraSource = try await cameraAsset?.loadTracks(withMediaType: .video).first
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
        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.compositionFailed("Could not allocate the preview track.") }
        let cameraTrack = cameraSource.flatMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let audioLaneCount = max(primaryAudioSources.count, additionalAudioSources.values.map(\.count).max() ?? 0)
        let audioTracks = (0..<audioLaneCount).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var destination = CMTime.zero
        for clip in project.timeline.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let isPrimary = additionalVideoSources[clip.sourceMediaID] == nil
            let videoSource = additionalVideoSources[clip.sourceMediaID] ?? screenSource
            let audioSources = additionalAudioSources[clip.sourceMediaID] ?? primaryAudioSources
            let requested = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            )
            let range = CMTimeRangeGetIntersection(requested, otherRange: try await videoSource.load(.timeRange))
            guard range.duration > .zero else { continue }
            try screenTrack.insertTimeRange(range, of: videoSource, at: destination)
            if isPrimary, let cameraSource, let cameraTrack {
                let available = CMTimeRangeGetIntersection(range, otherRange: try await cameraSource.load(.timeRange))
                if available.duration > .zero { try cameraTrack.insertTimeRange(available, of: cameraSource, at: destination) }
            }
            for (source, target) in zip(audioSources, audioTracks) {
                let available = CMTimeRangeGetIntersection(range, otherRange: try await source.load(.timeRange))
                if available.duration > .zero { try target.insertTimeRange(available, of: source, at: destination) }
            }
            let outputDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / max(0.25, clip.speed))
            if outputDuration != range.duration {
                let inserted = CMTimeRange(start: destination, duration: range.duration)
                screenTrack.scaleTimeRange(inserted, toDuration: outputDuration)
                cameraTrack?.scaleTimeRange(inserted, toDuration: outputDuration)
                audioTracks.forEach { $0.scaleTimeRange(inserted, toDuration: outputDuration) }
            }
            destination = CMTimeAdd(destination, outputDuration)
        }
        guard destination > .zero else { throw ExportError.compositionFailed("The preview timeline is empty.") }

        let appearance = project.settings.appearance ?? .default
        let size = CGSize(width: project.settings.canvas.width, height: project.settings.canvas.height)
        let geometry = ExportGeometry(outputSize: size, sourceSize: project.settings.canvas, appearance: appearance)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MetalProjectVideoCompositor.self
        videoComposition.instructions = [CapturaVideoInstruction(
            timeRange: CMTimeRange(start: .zero, duration: destination),
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrack?.trackID,
            project: project,
            events: events,
            geometry: geometry,
            brandingImages: BrandingAssetLoader.load(project: project, packageURL: packageURL)
        )]
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.settings.frameRate)))

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }
}
