import OSLog

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "captura"

    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let encoder = Logger(subsystem: subsystem, category: "Encoder")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let interaction = Logger(subsystem: subsystem, category: "Interaction")
    static let project = Logger(subsystem: subsystem, category: "Project")
    static let timeline = Logger(subsystem: subsystem, category: "Timeline")
    static let render = Logger(subsystem: subsystem, category: "Render")
    static let export = Logger(subsystem: subsystem, category: "Export")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
}
