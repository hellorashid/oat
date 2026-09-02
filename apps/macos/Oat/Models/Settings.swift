import Foundation

enum OatError: LocalizedError, Sendable {
    case message(String)
    case needsAPIKey
    case needsModel

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        case .needsAPIKey:
            return "Add an API key in Settings to transcribe recordings"
        case .needsModel:
            return "Download a Whisper model in Settings to transcribe recordings"
        }
    }
}

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case openai
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "On this Mac"
        case .openai: return "OpenAI"
        case .off: return "Off"
        }
    }
}

enum LocalWhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case tiny
    case tinyEn = "tiny.en"
    case base
    case baseEn = "base.en"
    case small
    case smallEn = "small.en"
    case medium
    case mediumEn = "medium.en"
    case largeV2 = "large-v2"
    case largeV3 = "large-v3"

    var id: String { rawValue }

    static let multilingual: [LocalWhisperModel] = [.tiny, .base, .small, .medium, .largeV2, .largeV3]
    static let english: [LocalWhisperModel] = [.tinyEn, .baseEn, .smallEn, .mediumEn]

    /// WhisperKit download / init variant. Large models use the full folder name so Hub globbing is unique.
    var variant: String {
        switch self {
        case .largeV2: return "openai_whisper-large-v2"
        case .largeV3: return "openai_whisper-large-v3"
        default: return rawValue
        }
    }

    var folderName: String {
        "openai_whisper-\(rawValue)"
    }

    var label: String {
        switch self {
        case .tiny: return "Tiny"
        case .tinyEn: return "Tiny (English)"
        case .base: return "Base"
        case .baseEn: return "Base (English)"
        case .small: return "Small"
        case .smallEn: return "Small (English)"
        case .medium: return "Medium"
        case .mediumEn: return "Medium (English)"
        case .largeV2: return "Large v2"
        case .largeV3: return "Large v3"
        }
    }

    var hint: String {
        switch self {
        case .tiny: return "Fastest · ~75 MB"
        case .tinyEn: return "English · fastest · ~75 MB"
        case .base: return "Balanced · ~145 MB"
        case .baseEn: return "English · balanced · ~145 MB"
        case .small: return "More accurate · ~466 MB"
        case .smallEn: return "English · more accurate · ~466 MB"
        case .medium: return "High accuracy · ~1.5 GB"
        case .mediumEn: return "English · high accuracy · ~1.5 GB"
        case .largeV2: return "Very accurate · ~3 GB"
        case .largeV3: return "Best accuracy · ~3 GB"
        }
    }
}

/// Labels stay in sync with `apps/tauri/src/App.tsx` `OPENAI_MODELS`.
enum OpenAIModel: String, CaseIterable, Identifiable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case whisper1 = "whisper-1"

    static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpt4oTranscribe: return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe: return "GPT-4o Mini Transcribe"
        case .whisper1: return "Whisper"
        }
    }

    var hint: String {
        switch self {
        case .gpt4oTranscribe: return "Best accuracy"
        case .gpt4oMiniTranscribe: return "Fast & affordable"
        case .whisper1: return "Classic Whisper"
        }
    }
}

/// Kept so older settings.json files still decode; the app always persists `.openai`.
enum Provider: String, Codable, Sendable {
    case openai
    case groq
    case custom
}

struct Settings: Codable, Equatable, Sendable {
    var storageDir: String?
    var apiKey: String
    var provider: Provider
    var model: String
    var baseURL: String
    var engine: TranscriptionEngine
    var localModel: LocalWhisperModel

    enum CodingKeys: String, CodingKey {
        case storageDir = "storage_dir"
        case apiKey = "api_key"
        case provider
        case model
        case baseURL = "base_url"
        case engine
        case localModel = "local_model"
    }

    init(
        storageDir: String? = nil,
        apiKey: String = "",
        provider: Provider = .openai,
        model: String = OpenAIModel.gpt4oMiniTranscribe.rawValue,
        baseURL: String = "",
        engine: TranscriptionEngine = .local,
        localModel: LocalWhisperModel = .base
    ) {
        self.storageDir = storageDir
        self.apiKey = apiKey
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.engine = engine
        self.localModel = localModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageDir = try container.decodeIfPresent(String.self, forKey: .storageDir)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .openai
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? OpenAIModel.gpt4oMiniTranscribe.rawValue
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        // Existing settings.json has no engine; keep OpenAI so saved API keys still work.
        engine = try container.decodeIfPresent(TranscriptionEngine.self, forKey: .engine) ?? .openai
        localModel = try container.decodeIfPresent(LocalWhisperModel.self, forKey: .localModel) ?? .base
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var storageURL: URL? {
        guard let storageDir, !storageDir.isEmpty else { return nil }
        return URL(fileURLWithPath: storageDir, isDirectory: true)
    }
}

enum RecordingId {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static func make(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    static func date(from id: String) -> Date? {
        formatter.date(from: id)
    }
}
