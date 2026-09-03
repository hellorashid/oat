import Foundation

enum Transcriber {
    private static let maxUploadBytes: UInt64 = 24 * 1024 * 1024

    static func transcribe(
        wav url: URL,
        settings: Settings
    ) async throws -> Transcript {
        switch settings.engine {
        case .local:
            return try await LocalWhisper.shared.transcribe(
                wav: url,
                model: settings.localModel
            )
        case .openai:
            return try await transcribeRemote(wav: url, settings: settings)
        case .off:
            throw OatError.message("Transcription is turned off in Settings")
        }
    }

    private static func transcribeRemote(wav url: URL, settings: Settings) async throws -> Transcript {
        guard settings.hasAPIKey else {
            throw OatError.needsAPIKey
        }

        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        if size <= maxUploadBytes {
            return try await transcribeChunk(url, settings: settings, offsetSeconds: 0)
        }

        let chunks = try WavIO.split(url: url, maxBytes: maxUploadBytes)
        var combined = Transcript(text: "", segments: [])
        defer {
            for chunk in chunks where chunk.url != url {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        for chunk in chunks {
            let part = try await transcribeChunk(chunk.url, settings: settings, offsetSeconds: chunk.offsetSeconds)
            if !combined.text.isEmpty && !part.text.isEmpty {
                combined.text += " "
            }
            combined.text += part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            combined.segments.append(contentsOf: part.segments)
        }
        return combined
    }

    private static func transcribeChunk(_ url: URL, settings: Settings, offsetSeconds: Double) async throws -> Transcript {
        let endpoint = OpenAIModel.transcriptionURL
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? OpenAIModel.gpt4oMiniTranscribe.rawValue
            : settings.model
        let responseFormat = supportsVerboseJSON(model) ? "verbose_json" : "json"
        let filename = url.lastPathComponent
        let fileData = try Data(contentsOf: url)

        let boundary = "OatBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        appendField("model", model)
        appendField("response_format", responseFormat)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw OatError.message("Transcription failed (\(status)): \(truncate(text, 280))")
        }

        guard let parsed = try? JSONDecoder().decode(VerboseTranscript.self, from: data) else {
            throw OatError.message("Transcription failed: unexpected response")
        }
        let segments = (parsed.segments ?? []).compactMap { segment -> TranscriptSegment? in
            let piece = segment.text ?? ""
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptSegment(start: (segment.start ?? 0) + offsetSeconds, text: piece)
        }
        let combined = parsed.text.isEmpty
            ? segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            : parsed.text
        return Transcript(text: combined, segments: segments)
    }

    private static func supportsVerboseJSON(_ model: String) -> Bool {
        let lowered = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(lowered.contains("gpt-4o") && lowered.contains("transcribe"))
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "…"
    }
}

private struct VerboseTranscript: Decodable {
    var text: String
    var segments: [VerboseSegment]?
}

private struct VerboseSegment: Decodable {
    var start: Double?
    var text: String?
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
