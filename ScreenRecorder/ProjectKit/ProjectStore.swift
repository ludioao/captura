import Foundation

struct ProjectPackage: Sendable {
    let rootURL: URL
    let mediaDirectory: URL
    let metadataDirectory: URL
    let screenMediaURL: URL
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
