import Foundation

enum WavIO {
    static func durationSeconds(at url: URL) -> UInt64? {
        guard let header = try? parseHeader(url) else { return nil }
        guard header.byteRate > 0 else { return nil }
        return UInt64(header.dataSize / header.byteRate)
    }

    struct Chunk {
        var url: URL
        var offsetSeconds: Double
    }

    static func split(url: URL, maxBytes: UInt64) throws -> [Chunk] {
        let header = try parseHeader(url)
        let data = try Data(contentsOf: url)
        let pcm = data.subdata(in: Int(header.dataOffset)..<data.count)
        if UInt64(pcm.count) <= maxBytes {
            return [Chunk(url: url, offsetSeconds: 0)]
        }

        let bytesPerSecond = max(Int(header.byteRate), 1)
        let chunkBytes = max(60 * bytesPerSecond, Int(min(maxBytes, UInt64(20 * 1024 * 1024))))
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        var parts: [Chunk] = []
        var offset = 0
        var index = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            let slice = pcm.subdata(in: offset..<end)
            let partURL = folder.appendingPathComponent("\(stem)-part-\(index).wav")
            try writePCM(slice, sampleRate: header.sampleRate, to: partURL)
            let offsetSeconds = header.byteRate > 0 ? Double(offset) / Double(header.byteRate) : 0
            parts.append(Chunk(url: partURL, offsetSeconds: offsetSeconds))
            offset = end
            index += 1
        }
        return parts
    }

    static func writePCM(_ pcm: Data, sampleRate: UInt32, to url: URL) throws {
        let writer = try WavWriter(url: url, sampleRate: sampleRate)
        try writer.write(data: pcm)
        try writer.finalize()
    }

    struct Header {
        var sampleRate: UInt32
        var byteRate: UInt32
        var dataSize: UInt32
        var dataOffset: UInt32
    }

    static func parseHeader(_ url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count == 12,
              String(data: prefix.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: prefix.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
        else {
            throw OatError.message("Not a WAV file")
        }

        var sampleRate: UInt32 = AudioFormat.sampleRate
        var byteRate: UInt32 = AudioFormat.sampleRate * 2
        var dataSize: UInt32 = 0
        var dataOffset: UInt32 = 44

        while let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 {
            let id = String(data: chunkHeader.subdata(in: 0..<4), encoding: .ascii) ?? ""
            let size = chunkHeader.leU32(at: 4)
            let position = try handle.offset()
            if id == "fmt " {
                let fmt = try handle.read(upToCount: Int(size)) ?? Data()
                if fmt.count >= 16 {
                    sampleRate = fmt.leU32(at: 4)
                    byteRate = fmt.leU32(at: 8)
                }
            } else if id == "data" {
                dataSize = size
                dataOffset = UInt32(position)
                break
            } else {
                try handle.seek(toOffset: position + UInt64(size))
            }
        }

        return Header(sampleRate: sampleRate, byteRate: byteRate, dataSize: dataSize, dataOffset: dataOffset)
    }

    static func waveformPeaks(at url: URL, barCount: Int = 48) -> [Float] {
        let quiet = [Float](repeating: 0.14, count: barCount)
        guard let header = try? parseHeader(url),
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return quiet
        }
        defer { try? handle.close() }

        let bytesPerSample = 2
        let totalSamples = Int(header.dataSize) / bytesPerSample
        guard totalSamples > barCount else { return quiet }

        var peaks = [Float](repeating: 0, count: barCount)
        let samplesPerBar = max(totalSamples / barCount, 1)
        for bar in 0..<barCount {
            let start = bar * samplesPerBar
            let sampleCount = min(samplesPerBar, totalSamples - start)
            let take = min(sampleCount, 1024)
            let offset = UInt64(header.dataOffset) + UInt64(start * bytesPerSample)
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: take * bytesPerSample),
                  data.count >= 2
            else {
                continue
            }
            var maxAmp: Float = 0
            let step = max((data.count / 2) / 64, 1) * 2
            var index = 0
            while index + 1 < data.count {
                let sample = Int16(truncatingIfNeeded: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
                maxAmp = max(maxAmp, abs(Float(sample) / 32768))
                index += step
            }
            peaks[bar] = maxAmp
        }

        let loudest = peaks.max() ?? 0
        if loudest > 0.02 {
            return peaks.map { max(0.04, min(1, $0 / loudest)) }
        }
        return quiet
    }
}

final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: UInt32
    private var dataBytes: UInt32 = 0

    init(url: URL, sampleRate: UInt32 = AudioFormat.sampleRate) throws {
        self.sampleRate = sampleRate
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try writeHeader(dataSize: 0)
    }

    func write(samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for index in samples.indices {
            let clipped = max(-1, min(1, samples[index]))
            pcm[index] = Int16((clipped * 32767).rounded())
        }
        try write(data: pcm.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    func write(data: Data) throws {
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    func finalize() throws {
        try handle.seek(toOffset: 0)
        try writeHeader(dataSize: dataBytes)
        try handle.close()
    }

    private func writeHeader(dataSize: UInt32) throws {
        var payload = Data()
        payload.append(contentsOf: Array("RIFF".utf8))
        payload.append(utf32: 36 + dataSize)
        payload.append(contentsOf: Array("WAVE".utf8))
        payload.append(contentsOf: Array("fmt ".utf8))
        payload.append(utf32: 16)
        payload.append(utf16: 1)
        payload.append(utf16: AudioFormat.channels)
        payload.append(utf32: sampleRate)
        payload.append(utf32: sampleRate * UInt32(AudioFormat.channels) * UInt32(AudioFormat.bitsPerSample / 8))
        payload.append(utf16: AudioFormat.channels * AudioFormat.bitsPerSample / 8)
        payload.append(utf16: AudioFormat.bitsPerSample)
        payload.append(contentsOf: Array("data".utf8))
        payload.append(utf32: dataSize)
        try handle.write(contentsOf: payload)
    }
}

private extension Data {
    func leU32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    mutating func append(utf16 value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func append(utf32 value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
