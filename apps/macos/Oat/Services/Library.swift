import AppKit
import Foundation

enum Library {
    static func list(
        in directory: URL,
        transcribing: Set<String>,
        includeDurations: Bool = true
    ) -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [Recording] = []
        for url in entries where url.pathExtension.lowercased() == "wav" {
            let id = url.deletingPathExtension().lastPathComponent
            items.append(
                item(id: id, directory: directory, transcribing: transcribing, includeDuration: includeDurations)
            )
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    static func item(
        id: String,
        directory: URL,
        transcribing: Set<String>,
        includeDuration: Bool = true
    ) -> Recording {
        let wavURL = directory.appendingPathComponent("\(id).wav")
        let mdURL = directory.appendingPathComponent("\(id).md")
        let errorURL = directory.appendingPathComponent("\(id).error")
        let hasMarkdown = FileManager.default.fileExists(atPath: mdURL.path)
        let errorText = hasMarkdown
            ? nil
            : (try? String(contentsOf: errorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

        let status: RecordingStatus
        if transcribing.contains(id) {
            status = .transcribing
        } else if hasMarkdown {
            status = .ready
        } else if let errorText, errorText.contains("API key") {
            status = .needsKey
        } else if let errorText, errorText == OatError.needsModel.errorDescription {
            status = .needsModel
        } else if errorText != nil {
            status = .failed
        } else {
            status = .skipped
        }

        let createdAt = RecordingId.date(from: id)
            ?? (try? wavURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date()

        return Recording(
            id: id,
            createdAt: createdAt,
            durationSeconds: includeDuration ? WavIO.durationSeconds(at: wavURL) : nil,
            wavURL: wavURL,
            markdownURL: hasMarkdown ? mdURL : nil,
            status: status,
            error: errorText
        )
    }

    static func writeError(directory: URL, id: String, message: String) {
        let url = directory.appendingPathComponent("\(id).error")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clearError(directory: URL, id: String) {
        let url = directory.appendingPathComponent("\(id).error")
        try? FileManager.default.removeItem(at: url)
    }

    static func revealAudio(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.wavURL])
    }

    static func revealTranscript(_ recording: Recording) {
        guard let url = recording.markdownURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openTranscript(_ recording: Recording) {
        guard let url = recording.markdownURL else { return }
        NSWorkspace.shared.open(url)
    }

    static func delete(_ recording: Recording) {
        let fm = FileManager.default
        try? fm.removeItem(at: recording.wavURL)
        if let markdown = recording.markdownURL {
            try? fm.removeItem(at: markdown)
        }
        let errorURL = recording.wavURL.deletingPathExtension().appendingPathExtension("error")
        try? fm.removeItem(at: errorURL)
    }
}
