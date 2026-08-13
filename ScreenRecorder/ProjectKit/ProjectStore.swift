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

    func save(project: ScreenProject, events: [InteractionEvent], to package: ProjectPackage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: package.eventsURL, options: .atomic)
        try encoder.encode(project).write(to: package.rootURL.appending(path: "project.json"), options: .atomic)
        Log.project.info("Saved project package with \(events.count) interaction events")
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
}
