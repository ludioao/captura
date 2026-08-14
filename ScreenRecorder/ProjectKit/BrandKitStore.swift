import Foundation

enum BrandKitStore {
    private static let key = "captura.brand-kits.v1"

    static func load() -> [BrandKit] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let kits = try? JSONDecoder().decode([BrandKit].self, from: data) else { return [] }
        return kits
    }

    static func save(_ kits: [BrandKit]) {
        guard let data = try? JSONEncoder().encode(kits) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func upsert(_ kit: BrandKit) {
        var kits = load()
        kits.removeAll { $0.id == kit.id }
        kits.append(kit)
        save(kits)
    }
}
