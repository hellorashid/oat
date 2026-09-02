import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folderName = Bundle.main.bundleIdentifier ?? "Oat"
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

struct SettingsStore {
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("settings.json")
    }

    func load() -> Settings {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return Settings()
        }
        return settings
    }

    func save(_ settings: Settings) throws {
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
