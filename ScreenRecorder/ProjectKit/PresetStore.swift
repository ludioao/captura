import Foundation

enum PresetStoreError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "This preset uses format version \(version), which this Captura build cannot open."
        }
    }
}

enum CapturaPresetStore {
    private static let key = "captura.projectPresets"

    static func load() -> [CapturaPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CapturaPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [CapturaPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
    }

    static func export(_ preset: CapturaPreset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(preset).write(to: url, options: .atomic)
    }

    static func importPreset(from url: URL) throws -> CapturaPreset {
        let preset = try JSONDecoder().decode(CapturaPreset.self, from: Data(contentsOf: url))
        guard preset.formatVersion <= CapturaPreset.currentFormatVersion else {
            throw PresetStoreError.unsupportedVersion(preset.formatVersion)
        }
        return preset
    }
}
