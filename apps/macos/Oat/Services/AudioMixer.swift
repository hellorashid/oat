import Foundation

final class LinearResampler {
    private let step: Double
    private var pos: Double = 0
    private var last: Float = 0
    private var primed = false

    init(from: UInt32, to: UInt32) {
        let source = Double(max(from, 1))
        let target = Double(max(to, 1))
        step = source / target
    }

    func push(_ input: [Float]) -> [Float] {
        if input.isEmpty { return [] }
        if abs(step - 1) < Double.ulpOfOne {
            return input
        }

        var output: [Float] = []
        output.reserveCapacity(max(Int((Double(input.count) / step).rounded(.up)) + 2, 1))
        var index = 0

        if !primed {
            last = input[0]
            primed = true
            index = 1
            if input.count == 1 {
                return []
            }
        }

        while pos < 1 {
            let next = index < input.count ? input[index] : last
            let t = Float(pos)
            output.append(last * (1 - t) + next * t)
            pos += step
        }

        while index < input.count {
            while pos >= 1 {
                last = input[index]
                index += 1
                pos -= 1
                if index >= input.count {
                    return output
                }
            }
            let next = input[index]
            let t = Float(pos)
            output.append(last * (1 - t) + next * t)
            pos += step
        }

        return output
    }
}

final class Mixer {
    private let lock = NSLock()
    private var mic: [Float] = []
    private var system: [Float] = []
    private var micStart = 0
    private var systemStart = 0
    private(set) var micActive = false
    private(set) var systemActive = false

    private let backlogBeforeSolo = Int(AudioFormat.sampleRate) / 10
    private let maxBufferSamples = Int(AudioFormat.sampleRate) * 30

    func pushMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        micActive = true
        mic.append(contentsOf: samples)
        compact(&mic, start: &micStart)
        lock.unlock()
    }

    func pushSystem(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        systemActive = true
        system.append(contentsOf: samples)
        compact(&system, start: &systemStart)
        lock.unlock()
    }

    func previewLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return min(1, max(peak(mic, start: micStart), peak(system, start: systemStart)) * 2)
    }

    func flush(allowSolo: Bool) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return mixAvailable(allowSolo: allowSolo)
    }

    func reset() {
        lock.lock()
        mic.removeAll(keepingCapacity: true)
        system.removeAll(keepingCapacity: true)
        micStart = 0
        systemStart = 0
        micActive = false
        systemActive = false
        lock.unlock()
    }

    private func compact(_ buffer: inout [Float], start: inout Int) {
        if start > 0, start > min(buffer.count / 2, Int(AudioFormat.sampleRate)) {
            buffer.removeFirst(start)
            start = 0
        }
        let live = buffer.count - start
        if live > maxBufferSamples {
            start = buffer.count - maxBufferSamples
        }
    }

    private func mixAvailable(allowSolo: Bool) -> [Float] {
        let micCount = mic.count - micStart
        let systemCount = system.count - systemStart
        if micCount <= 0 && systemCount <= 0 {
            return []
        }

        if micCount > 0 && systemCount > 0 {
            let count = min(micCount, systemCount)
            var output = [Float]()
            output.reserveCapacity(count)
            for index in 0..<count {
                output.append(max(-1, min(1, mic[micStart + index] + system[systemStart + index])))
            }
            micStart += count
            systemStart += count
            compact(&mic, start: &micStart)
            compact(&system, start: &systemStart)
            return output
        }

        if !allowSolo {
            return []
        }

        if systemCount <= 0 && micCount >= backlogBeforeSolo {
            let output = Array(mic[micStart...])
            mic.removeAll(keepingCapacity: true)
            micStart = 0
            return output
        }
        if micCount <= 0 && systemCount >= backlogBeforeSolo {
            let output = Array(system[systemStart...])
            system.removeAll(keepingCapacity: true)
            systemStart = 0
            return output
        }

        return []
    }

    private func peak(_ buffer: [Float], start: Int) -> Float {
        let live = buffer.count - start
        guard live > 0 else { return 0 }
        let slice = buffer.suffix(min(320, live))
        var loudest: Float = 0
        for sample in slice {
            loudest = max(loudest, abs(sample))
        }
        return loudest
    }
}
