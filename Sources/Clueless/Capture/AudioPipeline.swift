@preconcurrency import AVFoundation

/// Mutable flag that can cross into the converter's @Sendable input block.
/// Safe here: AVAudioConverter drives the block synchronously on the caller's
/// thread, so access is strictly serialized.
private final class InputConsumedFlag: @unchecked Sendable {
    var value = false
}

/// 16-bit PCM mono WAV encoder.
enum WAV {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        func string(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func u16(_ v: UInt16) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 2)) }

        string("RIFF")
        u32(36 + dataSize)
        string("WAVE")
        string("fmt ")
        u32(16)                 // PCM chunk size
        u16(1)                  // PCM format
        u16(1)                  // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)                  // block align
        u16(16)                 // bits per sample
        string("data")
        u32(dataSize)
        for var sample in samples {
            sample = sample.littleEndian
            data.append(Data(bytes: &sample, count: 2))
        }
        return data
    }

    static func quantize(_ floats: [Float]) -> [Int16] {
        floats.map { Int16(max(-1, min(1, $0)) * 32767) }
    }
}

/// Converts arbitrary AVAudioPCMBuffer input to 16 kHz mono Float32.
final class PCMConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter?

    init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    /// Returns nil if the input format is unusable or conversion produced nothing.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = 16000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let consumed = InputConsumedFlag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed.value {
                status.pointee = .endOfStream
                return nil
            }
            consumed.value = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Voice-activity chunker: accumulates 16 kHz mono Float32 audio and emits a
/// WAV file whenever a speech segment ends (silence hangover) or hits the max
/// duration. Shared by the mic and system-audio recorders.
final class VoiceActivityChunker: @unchecked Sendable {
    struct Tunables {
        var rmsThreshold: Float = 0.012
        var silenceHangover: TimeInterval = 0.9
        var minimumDuration: TimeInterval = 0.5
        var maximumDuration: TimeInterval = 28
    }

    var tunables = Tunables()
    var onUtterance: (@Sendable (Data) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?

    private let sampleRate = 16000
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isVoiced = false
    private var silenceDuration: TimeInterval = 0

    func push(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var completed: Data?

        lock.lock()
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let chunkDuration = Double(chunk.count) / Double(sampleRate)

        if rms > tunables.rmsThreshold {
            isVoiced = true
            silenceDuration = 0
            samples.append(contentsOf: chunk)
        } else if isVoiced {
            silenceDuration += chunkDuration
            samples.append(contentsOf: chunk)
            if silenceDuration >= tunables.silenceHangover {
                completed = finishLocked()
            }
        }

        if isVoiced, Double(samples.count) / Double(sampleRate) >= tunables.maximumDuration {
            completed = finishLocked()
        }
        lock.unlock()

        onLevel?(min(rms * 8, 1))
        if let completed { onUtterance?(completed) }
    }

    /// Emits any in-flight utterance (called when recording stops).
    func flush() {
        lock.lock()
        let completed = isVoiced ? finishLocked() : nil
        lock.unlock()
        if let completed { onUtterance?(completed) }
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        isVoiced = false
        silenceDuration = 0
        lock.unlock()
    }

    private func finishLocked() -> Data? {
        defer {
            samples.removeAll()
            isVoiced = false
            silenceDuration = 0
        }
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= tunables.minimumDuration else { return nil }
        return WAV.encode(samples: WAV.quantize(samples), sampleRate: sampleRate)
    }
}
