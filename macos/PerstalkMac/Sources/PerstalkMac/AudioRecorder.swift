import AVFoundation
import Foundation

struct RecordingResult {
    let url: URL
    let durationMs: Int
}

struct MicrophonePreference: Equatable {
    let id: String?
    let label: String

    static let automatic = MicrophonePreference(id: nil, label: "Auto-detect")
    private static let key = "MicrophoneDeviceID"

    static var available: [MicrophonePreference] {
        [automatic] + availableDevices.map {
            MicrophonePreference(id: $0.uniqueID, label: $0.localizedName)
        }
    }

    static var availableDevices: [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
    }

    static var current: MicrophonePreference {
        get {
            guard let id = UserDefaults.standard.string(forKey: key), !id.isEmpty else {
                return automatic
            }
            return available.first { $0.id == id } ?? automatic
        }
        set {
            if let id = newValue.id {
                UserDefaults.standard.set(id, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func selectedDevice() -> AVCaptureDevice? {
        guard let id = current.id else {
            return AVCaptureDevice.default(for: .audio)
        }
        return availableDevices.first { $0.uniqueID == id } ?? AVCaptureDevice.default(for: .audio)
    }
}

@MainActor
final class AudioRecorder: NSObject {
    nonisolated private let sampleStore = AudioSampleStore()
    private var session: AVCaptureSession?
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "ai.perstalk.flow.audio-samples")
    private var outputURL: URL?
    private var startedAt: Date?

    var onLevel: ((Double) -> Void)?

    var isRecording: Bool {
        session?.isRunning ?? false
    }

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() throws {
        cancel()
        sampleStore.reset()

        guard let device = MicrophonePreference.selectedDevice() else {
            throw AudioRecorderError.noInputDevice
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(audioOutput) else {
            throw AudioRecorderError.couldNotStart
        }
        session.addInput(input)

        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        session.addOutput(audioOutput)
        session.commitConfiguration()

        let fileName = "perstalk-\(UUID().uuidString).wav"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        self.session = session
        outputURL = url
        startedAt = Date()

        session.startRunning()
        guard session.isRunning else {
            cleanup()
            throw AudioRecorderError.couldNotStart
        }
    }

    func stop() -> RecordingResult? {
        guard let url = outputURL else {
            cleanup()
            return nil
        }

        session?.stopRunning()
        let snapshot = sampleStore.snapshot()
        cleanup()

        guard !snapshot.samples.isEmpty else {
            return nil
        }

        do {
            let pcm = resampleTo16k(snapshot.samples, sourceRate: snapshot.sampleRate)
            try writeWAV(samples: pcm, to: url)
            let durationMs = Int(Double(pcm.count) / 16_000.0 * 1000)
            return RecordingResult(url: url, durationMs: durationMs)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func cancel() {
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        cleanup()
    }

    private func cleanup() {
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil
        outputURL = nil
        startedAt = nil
        sampleStore.reset()
        onLevel?(0)
    }

    fileprivate func emitLevel(_ level: Double) {
        onLevel?(level)
    }

    nonisolated private static func samples(from sampleBuffer: CMSampleBuffer) -> AudioSampleBatch? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var listSize = 0
        var sizingBlockBuffer: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &sizingBlockBuffer
        )

        guard listSize > 0 else {
            return nil
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawList.deallocate()
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawList.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        let format = streamDescription.pointee
        let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            return nil
        }

        var mono = Array(repeating: Float(0), count: frameCount)
        var channelsMixed = 0
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            rawList.assumingMemoryBound(to: AudioBufferList.self)
        )

        for buffer in audioBuffers {
            guard let data = buffer.mData else {
                continue
            }

            let channels = max(1, Int(buffer.mNumberChannels))
            let availableSamples = Int(buffer.mDataByteSize) / bytesPerSample
            let availableFrames = min(frameCount, availableSamples / channels)
            guard availableFrames > 0 else {
                continue
            }

            if (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0, format.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Float.self, capacity: availableSamples)
                for frame in 0..<availableFrames {
                    for channel in 0..<channels {
                        mono[frame] += samples[frame * channels + channel]
                    }
                }
            } else if format.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: availableSamples)
                for frame in 0..<availableFrames {
                    for channel in 0..<channels {
                        mono[frame] += Float(samples[frame * channels + channel]) / 32768.0
                    }
                }
            } else {
                continue
            }

            channelsMixed += channels
        }

        guard channelsMixed > 0 else {
            return nil
        }

        let divisor = Float(channelsMixed)
        var sumSquares = 0.0
        for index in mono.indices {
            mono[index] /= divisor
            sumSquares += Double(mono[index] * mono[index])
        }

        let rms = sqrt(sumSquares / Double(max(1, mono.count)))
        let level = max(0, min(100, rms * 850))
        return AudioSampleBatch(
            samples: mono,
            sampleRate: format.mSampleRate,
            level: level
        )
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let batch = Self.samples(from: sampleBuffer) else {
            return
        }

        sampleStore.append(samples: batch.samples, sampleRate: batch.sampleRate)
        Task { @MainActor in
            self.emitLevel(batch.level)
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "Could not find a microphone input."
        case .couldNotStart:
            return "Could not start microphone recording."
        }
    }
}

private struct AudioSampleBatch {
    let samples: [Float]
    let sampleRate: Double
    let level: Double
}

private final class AudioSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000

    func append(samples newSamples: [Float], sampleRate newSampleRate: Double) {
        lock.lock()
        if samples.isEmpty {
            sampleRate = newSampleRate
        }
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func snapshot() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        let snapshot = (samples, sampleRate)
        lock.unlock()
        return snapshot
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = 16_000
        lock.unlock()
    }
}

private func resampleTo16k(_ samples: [Float], sourceRate: Double) -> [Float] {
    let targetRate = 16_000.0
    guard !samples.isEmpty, sourceRate > 0 else {
        return []
    }
    guard abs(sourceRate - targetRate) > 1 else {
        return samples
    }

    let duration = Double(samples.count) / sourceRate
    let targetCount = max(1, Int((duration * targetRate).rounded()))
    guard targetCount > 1 else {
        return [samples[0]]
    }

    var resampled = Array(repeating: Float(0), count: targetCount)
    let scale = sourceRate / targetRate
    for index in 0..<targetCount {
        let sourcePosition = Double(index) * scale
        let lower = min(samples.count - 1, Int(sourcePosition))
        let upper = min(samples.count - 1, lower + 1)
        let fraction = Float(sourcePosition - Double(lower))
        resampled[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
    }
    return resampled
}

private func writeWAV(samples: [Float], to url: URL) throws {
    var data = Data()
    let byteRate: UInt32 = 16_000 * 2
    let blockAlign: UInt16 = 2
    let dataByteCount = UInt32(samples.count * 2)

    data.appendASCII("RIFF")
    data.appendUInt32LE(36 + dataByteCount)
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendUInt32LE(16)
    data.appendUInt16LE(1)
    data.appendUInt16LE(1)
    data.appendUInt32LE(16_000)
    data.appendUInt32LE(byteRate)
    data.appendUInt16LE(blockAlign)
    data.appendUInt16LE(16)
    data.appendASCII("data")
    data.appendUInt32LE(dataByteCount)

    for sample in samples {
        let clamped = max(-1, min(1, sample))
        let value = Int16(clamped * Float(Int16.max))
        data.appendUInt16LE(UInt16(bitPattern: value))
    }

    try data.write(to: url, options: .atomic)
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
