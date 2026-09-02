import Foundation

final class Recorder: @unchecked Sendable {
    private let mixQueue = DispatchQueue(label: "com.raz.oat.mixer")
    private let mixer = Mixer()
    private var writer: WavWriter?
    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var timer: DispatchSourceTimer?
    private var frames: UInt64 = 0
    private var writeError: Error?
    private let meterLock = NSLock()
    private var meterValue: Float = 0

    /// Starts capture. Returns a non-fatal warning when system audio could not start.
    func start(to url: URL) async throws -> String? {
        await stopCapture()
        mixer.reset()
        resetMeter()
        frames = 0
        writeError = nil
        writer = try WavWriter(url: url)

        let microphone = MicrophoneCapture(mixer: mixer)
        do {
            try microphone.start()
        } catch {
            try? writer?.finalize()
            writer = nil
            throw error
        }
        mic = microphone

        var warning: String?
        let systemCapture = SystemAudioCapture(mixer: mixer)
        do {
            try await systemCapture.start()
            system = systemCapture
            Permissions.markSystemAudio(.granted)
        } catch {
            NSLog("oat system audio: \(error.localizedDescription)")
            system = nil
            warning = "Microphone only — enable Oat under \(Permissions.systemAudioHelp)."
            Permissions.markSystemAudio(.denied)
        }

        let timer = DispatchSource.makeTimerSource(queue: mixQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.flush(allowSolo: false)
        }
        timer.resume()
        self.timer = timer
        return warning
    }

    func stop() async throws -> MixStats {
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        timer?.cancel()
        timer = nil

        let result: (MixStats, Error?) = mixQueue.sync {
            flush(allowSolo: true)
            let captured = MixStats(
                frames: frames,
                microphone: mixer.micActive,
                system: mixer.systemActive
            )
            let error = writeError
            try? writer?.finalize()
            writer = nil
            frames = 0
            writeError = nil
            return (captured, error)
        }
        mixer.reset()
        resetMeter()
        if let error = result.1 {
            throw error
        }
        return result.0
    }

    func meterLevel() -> Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return meterValue
    }

    private func stopCapture() async {
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        timer?.cancel()
        timer = nil
        mixQueue.sync {
            try? writer?.finalize()
            writer = nil
            writeError = nil
        }
    }

    private func flush(allowSolo: Bool) {
        let samples = mixer.flush(allowSolo: allowSolo)
        if samples.isEmpty {
            pushMeter(mixer.previewLevel())
            return
        }
        pushMeter(peak(samples))
        do {
            try writer?.write(samples: samples)
            frames += UInt64(samples.count)
        } catch {
            if writeError == nil {
                writeError = error
            }
            NSLog("oat wav write: \(error.localizedDescription)")
        }
    }

    private func peak(_ samples: [Float]) -> Float {
        var loudest: Float = 0
        let step = max(samples.count / 48, 1)
        var index = 0
        while index < samples.count {
            loudest = max(loudest, abs(samples[index]))
            index += step
        }
        return min(1, loudest * 2.2)
    }

    private func pushMeter(_ level: Float) {
        meterLock.lock()
        meterValue = max(level, meterValue * 0.62)
        meterLock.unlock()
    }

    private func resetMeter() {
        meterLock.lock()
        meterValue = 0
        meterLock.unlock()
    }
}
