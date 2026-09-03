import Foundation

/// Filesystem helpers for on-device Whisper models. Kept separate from WhisperKit so
/// startup paths can check download state without pulling in the transcription runtime.
enum LocalWhisperStorage {
    static var modelsDirectory: URL {
        let folder = AppPaths.supportDirectory.appendingPathComponent("whisperkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func isDownloaded(_ model: LocalWhisperModel) -> Bool {
        resolvedModelFolder(for: model) != nil
    }

    static func downloadedModels() -> [LocalWhisperModel] {
        LocalWhisperModel.allCases.filter(isDownloaded)
    }

    static func resolvedModelFolder(for model: LocalWhisperModel) -> URL? {
        let expected = defaultModelFolder(for: model)
        if hasCoreML(at: expected) {
            return expected
        }
        let root = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries.first { url in
            url.lastPathComponent == model.folderName && hasCoreML(at: url)
        }
    }

    static func defaultModelFolder(for model: LocalWhisperModel) -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model.folderName, isDirectory: true)
    }

    static func foldersToDelete(for model: LocalWhisperModel) -> [URL] {
        var folders: [URL] = []
        if let resolved = resolvedModelFolder(for: model) {
            folders.append(resolved)
        }
        let expected = defaultModelFolder(for: model)
        if FileManager.default.fileExists(atPath: expected.path), !folders.contains(expected) {
            folders.append(expected)
        }
        return folders
    }

    static func hasCoreML(at folder: URL) -> Bool {
        let fm = FileManager.default
        let compiled = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        let package = folder.appendingPathComponent("AudioEncoder.mlpackage")
        return fm.fileExists(atPath: compiled.path) || fm.fileExists(atPath: package.path)
    }
}
