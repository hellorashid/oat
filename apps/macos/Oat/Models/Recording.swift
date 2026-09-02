import Foundation

enum RecordingStatus: String, Equatable, Sendable {
    case ready
    case transcribing
    case needsKey = "needs_key"
    case needsModel = "needs_model"
    case failed
    case skipped
}

struct Recording: Identifiable, Equatable, Sendable {
    var id: String
    var createdAt: Date
    var durationSeconds: UInt64?
    var wavURL: URL
    var markdownURL: URL?
    var status: RecordingStatus
    var error: String?
}

struct MixStats: Sendable {
    var frames: UInt64
    var microphone: Bool
    var system: Bool

    var durationSeconds: UInt64 {
        frames / UInt64(AudioFormat.sampleRate)
    }
}

enum AudioFormat {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16
}

struct TranscriptSegment: Sendable {
    var start: Double
    var text: String
}

struct Transcript: Sendable {
    var text: String
    var segments: [TranscriptSegment]
}

struct TranscriptContext: Sendable {
    var id: String
    var recordedAt: Date
    var durationSeconds: UInt64
    var audioFilename: String
    var microphone: Bool?
    var system: Bool?
}
