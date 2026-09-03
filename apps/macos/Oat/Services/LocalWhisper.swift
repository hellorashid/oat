import Foundation
import WhisperKit

actor LocalWhisper {
    static let shared = LocalWhisper()

    private var cachedModel: LocalWhisperModel?
    private var cachedKit: WhisperKit?

    static var modelsDirectory: URL { LocalWhisperStorage.modelsDirectory }
    static func isDownloaded(_ model: LocalWhisperModel) -> Bool { LocalWhisperStorage.isDownloaded(model) }
    static func downloadedModels() -> [LocalWhisperModel] { LocalWhisperStorage.downloadedModels() }
    static func resolvedModelFolder(for model: LocalWhisperModel) -> URL? {
        LocalWhisperStorage.resolvedModelFolder(for: model)
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

        let folders = LocalWhisperStorage.foldersToDelete(for: model)
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
        guard LocalWhisperStorage.hasCoreML(at: folder) else {
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
