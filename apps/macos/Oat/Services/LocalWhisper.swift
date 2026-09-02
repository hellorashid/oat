import Foundation
import WhisperKit

actor LocalWhisper {
    static let shared = LocalWhisper()

    private var cachedModel: LocalWhisperModel?
    private var cachedKit: WhisperKit?

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

    func download(_ model: LocalWhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await fetchModel(model, progress: progress)
        if cachedModel == model {
            cachedKit = nil
            cachedModel = nil
        }
    }

    func delete(_ model: LocalWhisperModel) async throws {
        if cachedModel == model {
            await cachedKit?.unloadModels()
            cachedKit = nil
            cachedModel = nil
        }

        let folders = Self.foldersToDelete(for: model)
        guard !folders.isEmpty else { return }
        for folder in folders {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func transcribe(
        wav url: URL,
        model: LocalWhisperModel,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        let kit = try await loadKit(model: model, onDownloadProgress: onDownloadProgress)
        let results = try await kit.transcribe(
            audioPath: url.path,
            decodeOptions: DecodingOptions(verbose: false, skipSpecialTokens: true)
        )
        return Self.transcript(from: results)
    }

    private func loadKit(
        model: LocalWhisperModel,
        onDownloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> WhisperKit {
        if let cachedKit, cachedModel == model {
            return cachedKit
        }

        let folder: URL
        if let existing = Self.resolvedModelFolder(for: model) {
            folder = existing
        } else {
            folder = try await fetchModel(model, progress: onDownloadProgress ?? { _ in })
        }
        guard Self.hasCoreML(at: folder) else {
            throw OatError.needsModel
        }

        let config = WhisperKitConfig(
            downloadBase: Self.modelsDirectory,
            modelFolder: folder.path,
            tokenizerFolder: Self.modelsDirectory,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        cachedModel = model
        cachedKit = kit
        return kit
    }

    private func fetchModel(
        _ model: LocalWhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: model.variant,
            downloadBase: Self.modelsDirectory,
            progressCallback: { snapshot in
                progress(snapshot.fractionCompleted)
            }
        )
    }

    private static func foldersToDelete(for model: LocalWhisperModel) -> [URL] {
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

    private static func defaultModelFolder(for model: LocalWhisperModel) -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model.folderName, isDirectory: true)
    }

    private static func hasCoreML(at folder: URL) -> Bool {
        let fm = FileManager.default
        let compiled = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        let package = folder.appendingPathComponent("AudioEncoder.mlpackage")
        return fm.fileExists(atPath: compiled.path) || fm.fileExists(atPath: package.path)
    }

    private static func transcript(from results: [TranscriptionResult]) -> Transcript {
        var text = ""
        var segments: [TranscriptSegment] = []
        for result in results {
            let piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !piece.isEmpty {
                text += " "
            }
            text += piece
            for segment in result.segments {
                let line = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                segments.append(TranscriptSegment(start: Double(segment.start), text: line))
            }
        }
        return Transcript(text: text, segments: segments)
    }
}
