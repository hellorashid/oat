import AVFoundation

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let mixer: Mixer
    private var resampler: LinearResampler?

    init(mixer: Mixer) {
        self.mixer = mixer
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw OatError.message("No microphone input available")
        }

        resampler = LinearResampler(from: UInt32(format.sampleRate.rounded()), to: AudioFormat.sampleRate)
        let channels = Int(format.channelCount)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += channelData[channel][frame]
                }
                mono[frame] = sum / Float(channels)
            }
            let resampled = self.resampler?.push(mono) ?? mono
            self.mixer.pushMic(resampled)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        resampler = nil
    }
}
