import Foundation

enum Markdown {
    static func render(context: TranscriptContext, transcript: Transcript) -> String {
        var lines = [
            "# Recording \(context.id)",
            "",
            "- **Recorded:** \(humanDatetime(context.recordedAt))",
            "- **Duration:** \(formatDuration(context.durationSeconds))",
            "- **Audio:** [\(context.audioFilename)](./\(context.audioFilename))",
            "- **Sources:** \(sourceLabel(microphone: context.microphone, system: context.system))",
            "",
            "---",
            "",
            "## Transcript",
            "",
        ]

        if transcript.segments.isEmpty {
            lines.append(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            for segment in transcript.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("[\(formatTimestamp(segment.start))] \(text)")
            }
        }

        if lines.last?.isEmpty != true {
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func formatElapsed(_ ms: Int) -> String {
        let total = max(ms, 0) / 1000
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func formatDuration(_ seconds: UInt64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(pad(minutes))m \(pad(secs))s"
        }
        return "\(minutes)m \(pad(secs))s"
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = UInt64(max(seconds, 0))
        let minutes = total / 60
        let secs = total % 60
        return "\(pad(minutes)):\(pad(secs))"
    }

    private static func sourceLabel(microphone: Bool?, system: Bool?) -> String {
        guard let microphone, let system else { return "unknown" }
        switch (microphone, system) {
        case (true, true): return "microphone + system audio"
        case (true, false): return "microphone"
        case (false, true): return "system audio"
        case (false, false): return "unknown"
        }
    }

    private static func humanDatetime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }

    private static func pad(_ value: UInt64) -> String {
        String(format: "%02d", value)
    }
}
