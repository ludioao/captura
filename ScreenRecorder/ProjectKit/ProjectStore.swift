@preconcurrency import AVFoundation
import Foundation

struct ProjectPackage: Sendable {
    let rootURL: URL
    let mediaDirectory: URL
    let metadataDirectory: URL
    let screenMediaURL: URL
    let cameraMediaURL: URL
    let eventsURL: URL
}

actor ProjectStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createPackage(in parent: URL? = nil) throws -> ProjectPackage {
        let base = try parent ?? fileManager.url(for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let root = uniqueURL(in: base, name: "Recording \(formatter.string(from: Date()))", extension: "screenproject")
        let media = root.appending(path: "media", directoryHint: .isDirectory)
        let metadata = root.appending(path: "metadata", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "cache/thumbnails", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "autosave", directoryHint: .isDirectory), withIntermediateDirectories: true)

        return ProjectPackage(
            rootURL: root,
            mediaDirectory: media,
            metadataDirectory: metadata,
            screenMediaURL: media.appending(path: "screen.mov"),
            cameraMediaURL: media.appending(path: "camera.mov"),
            eventsURL: metadata.appending(path: "events.json")
        )
    }

    func importVideo(from sourceURL: URL, in parent: URL? = nil) async throws -> URL {
        let package = try createPackage(in: parent)
        do {
            try fileManager.copyItem(at: sourceURL, to: package.screenMediaURL)
            let asset = AVURLAsset(url: package.screenMediaURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let duration = max(0, try await asset.load(.duration).seconds)
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let width = max(2, Int(abs(transformed.width)))
            let height = max(2, Int(abs(transformed.height)))
            let nominalFPS = try await track.load(.nominalFrameRate)
            let fps = nominalFPS >= 50 ? 60 : 30
            let mediaID = UUID()
            let project = ScreenProject(
                id: UUID(),
                createdAt: Date(),
                duration: duration,
                media: ProjectMedia(screen: "media/screen.mov"),
                settings: ProjectSettings(
                    canvas: CanvasSize(width: width, height: height),
                    sourceDisplay: CanvasSize(width: width, height: height),
                    frameRate: fps,
                    codec: .h264,
                    appearance: .default
                ),
                recording: RecordingMetadata(eventsPath: "metadata/events.json", eventCount: 0, droppedVideoFrames: 0),
                cameraKeyframes: [],
                timeline: Timeline(clips: [TimelineClip(
                    id: UUID(), sourceMediaID: mediaID,
                    sourceStart: 0, sourceEnd: duration, timelineStart: 0
                )])
            )
            try save(project: project, events: [], to: package)
            return package.rootURL
        } catch {
            try? fileManager.removeItem(at: package.rootURL)
            throw error
        }
    }

    func save(project: ScreenProject, events: [InteractionEvent], to package: ProjectPackage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: package.eventsURL, options: .atomic)
        try encoder.encode(project).write(to: package.rootURL.appending(path: "project.json"), options: .atomic)
        try? fileManager.removeItem(at: package.rootURL.appending(path: "autosave/recovery.json"))
        Log.project.info("Saved project package with \(events.count) interaction events")
    }

    func writeRecoveryManifest(_ manifest: RecordingRecoveryManifest, to package: ProjectPackage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: package.rootURL.appending(path: "autosave/recovery.json"),
            options: .atomic
        )
    }

    func recoverInterruptedRecordings(in parent: URL? = nil) async -> [URL] {
        let base: URL
        do {
            base = try parent ?? fileManager.url(
                for: .moviesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch { return [] }
        guard let packages = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recovered: [URL] = []
        for root in packages where root.pathExtension.lowercased() == "screenproject" {
            guard !fileManager.fileExists(atPath: root.appending(path: "project.json").path) else { continue }
            let manifestURL = root.appending(path: "autosave/recovery.json")
            let mediaURL = root.appending(path: "media/screen.mov")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: mediaURL.path),
                  let data = try? Data(contentsOf: manifestURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(RecordingRecoveryManifest.self, from: data) else { continue }
            let asset = AVURLAsset(url: mediaURL)
            guard let durationValue = try? await asset.load(.duration), durationValue.seconds > 0.05,
                  let _ = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = durationValue.seconds
            let mediaID = UUID()
            let cameraURL = root.appending(path: "media/camera.mov")
            let cameraSize = (try? cameraURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let project = ScreenProject(
                id: UUID(),
                createdAt: manifest.createdAt,
                duration: duration,
                media: ProjectMedia(
                    screen: "media/screen.mov",
                    camera: manifest.hasWebcam && cameraSize > 0 ? "media/camera.mov" : nil
                ),
                settings: ProjectSettings(
                    canvas: manifest.canvas,
                    sourceDisplay: manifest.sourceDisplay,
                    frameRate: manifest.frameRate,
                    codec: manifest.codec,
                    appearance: .default
                ),
                recording: RecordingMetadata(eventsPath: "metadata/events.json", eventCount: 0, droppedVideoFrames: 0),
                cameraKeyframes: [],
                timeline: Timeline(clips: [TimelineClip(
                    id: UUID(), sourceMediaID: mediaID,
                    sourceStart: 0, sourceEnd: duration, timelineStart: 0
                )])
            )
            let package = package(at: root, project: project)
            do {
                try save(project: project, events: [], to: package)
                recovered.append(root)
            } catch {
                Log.project.error("Could not recover interrupted recording: \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    func update(project: ScreenProject, events: [InteractionEvent], at rootURL: URL) throws {
        let media = rootURL.appending(path: "media", directoryHint: .isDirectory)
        let metadata = rootURL.appending(path: "metadata", directoryHint: .isDirectory)
        let package = ProjectPackage(
            rootURL: rootURL,
            mediaDirectory: media,
            metadataDirectory: metadata,
            screenMediaURL: rootURL.appending(path: project.media.screen),
            cameraMediaURL: rootURL.appending(path: project.media.camera ?? "media/camera.mov"),
            eventsURL: rootURL.appending(path: project.recording.eventsPath)
        )
        try save(project: project, events: events, to: package)
    }

    func load(from rootURL: URL) throws -> (ScreenProject, [InteractionEvent]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ScreenProject.self, from: Data(contentsOf: rootURL.appending(path: "project.json")))
        guard project.formatVersion <= ScreenProject.currentFormatVersion else {
            throw CocoaError(.fileReadUnknown)
        }
        let events = try decoder.decode([InteractionEvent].self, from: Data(contentsOf: rootURL.appending(path: project.recording.eventsPath)))
        return (project, events)
    }

    func recentProjects(in parent: URL? = nil, limit: Int = 20) throws -> [RecentProject] {
        let base = try parent ?? fileManager.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let urls = try fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == "screenproject" }
            .compactMap { try? projectSummary(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    func projectSummary(at url: URL) throws -> RecentProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url.appending(path: "project.json"))
        let project = try decoder.decode(ScreenProject.self, from: data)
        return RecentProject(
            projectID: project.id,
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            createdAt: project.createdAt,
            duration: project.duration,
            canvas: project.settings.canvas,
            hasWebcam: project.media.camera != nil,
            eventCount: project.recording.eventCount
        )
    }

    private func uniqueURL(in parent: URL, name: String, extension pathExtension: String) -> URL {
        var counter = 1
        var candidate = parent.appending(path: "\(name).\(pathExtension)", directoryHint: .isDirectory)
        while fileManager.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = parent.appending(path: "\(name) \(counter).\(pathExtension)", directoryHint: .isDirectory)
        }
        return candidate
    }

    private func package(at root: URL, project: ScreenProject) -> ProjectPackage {
        let media = root.appending(path: "media", directoryHint: .isDirectory)
        let metadata = root.appending(path: "metadata", directoryHint: .isDirectory)
        return ProjectPackage(
            rootURL: root,
            mediaDirectory: media,
            metadataDirectory: metadata,
            screenMediaURL: root.appending(path: project.media.screen),
            cameraMediaURL: root.appending(path: project.media.camera ?? "media/camera.mov"),
            eventsURL: root.appending(path: project.recording.eventsPath)
        )
    }
}
