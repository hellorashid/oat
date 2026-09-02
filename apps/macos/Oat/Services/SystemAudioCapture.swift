import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class SystemAudioCapture {
    private let mixer: Mixer
    private let ioQueue = DispatchQueue(label: "com.raz.oat.system-audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: LinearResampler?
    private var sourceRate: UInt32 = 48_000

    init(mixer: Mixer) {
        self.mixer = mixer
    }

    func start() async throws {
        guard #available(macOS 14.2, *) else {
            throw OatError.message("System audio capture requires macOS 14.2 or later")
        }
        try await startTap()
    }

    func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ioQueue.sync {
            resampler = nil
        }
    }

    @available(macOS 14.2, *)
    private func startTap() async throws {
        await stop()

        var excluded = [AudioObjectID]()
        if let ownProcess = Self.processObjectID(for: getpid()) {
            excluded.append(ownProcess)
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDescription.name = "Oat"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        if #available(macOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier {
            tapDescription.bundleIDs = [bundleID]
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw OatError.message("System audio tap failed (\(tapStatus)). Enable Oat under \(Permissions.systemAudioHelp).")
        }
        tapID = newTapID

        do {
            let format = try tapFormat()
            try createAggregate(tapUUID: tapDescription.uuid)
            await waitUntilAlive()
            try installIOProc(format: format)
        } catch {
            await stop()
            throw error
        }
    }

    static func probe() async -> PermissionState {
        guard #available(macOS 14.2, *) else { return .unavailable }
        let capture = SystemAudioCapture(mixer: Mixer())
        do {
            try await capture.start()
            await capture.stop()
            return .granted
        } catch {
            await capture.stop()
            return .denied
        }
    }

    @available(macOS 14.2, *)
    private func tapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw OatError.message("Couldn't read system audio format (\(status))")
        }
        return format
    }

    @available(macOS 14.2, *)
    private func createAggregate(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oat System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            throw OatError.message("System audio device failed (\(status))")
        }
        aggregateID = newAggregateID
    }

    private func waitUntilAlive() async {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<40 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive)
            if status == noErr, alive != 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        let rate = UInt32(format.sampleRate.rounded())
        ioQueue.sync {
            sourceRate = rate == 0 ? 48_000 : rate
            resampler = LinearResampler(from: sourceRate, to: AudioFormat.sampleRate)
        }

        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let samples = Self.pcmFloats(from: inInputData, format: format)
            guard !samples.isEmpty else { return }
            let resampled = self.resampler?.push(samples) ?? samples
            self.mixer.pushSystem(resampled)
        }
        guard status == noErr, procID != nil else {
            throw OatError.message("System audio IO failed (\(status))")
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw OatError.message("Enable Oat under \(Permissions.systemAudioHelp).")
        }
    }

    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func pcmFloats(from list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> [Float] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else {
            return []
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, channelCount > 0 else { return [] }

        if let planes = buffer.floatChannelData {
            return downmix(
                planes: planes,
                frames: frameCount,
                channels: channelCount,
                interleaved: buffer.format.isInterleaved
            ) { $0 }
        }
        if let planes = buffer.int16ChannelData {
            return downmix(
                planes: planes,
                frames: frameCount,
                channels: channelCount,
                interleaved: buffer.format.isInterleaved
            ) { Float($0) / 32768 }
        }
        return []
    }

    private static func downmix<Sample>(
        planes: UnsafePointer<UnsafeMutablePointer<Sample>>,
        frames: Int,
        channels: Int,
        interleaved: Bool,
        convert: (Sample) -> Float
    ) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        if interleaved {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += convert(planes[0][frame * channels + channel])
                }
                mono[frame] = sum / Float(channels)
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += convert(planes[channel][frame])
                }
                mono[frame] = sum / Float(channels)
            }
        }
        return mono
    }
}
