import AVFoundation

/// Microphone capture: AVAudioEngine input tap → 16 kHz mono → VAD chunker →
/// WAV utterances delivered on `onUtterance`.
final class MicRecorder: @unchecked Sendable {
    var onUtterance: (@Sendable (Data) -> Void)? {
        get { chunker.onUtterance }
        set { chunker.onUtterance = newValue }
    }
    var onLevel: (@Sendable (Float) -> Void)? {
        get { chunker.onLevel }
        set { chunker.onLevel = newValue }
    }

    enum MicError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            "No microphone input available."
        }
    }

    private let engine = AVAudioEngine()
    private let converter = PCMConverter()
    private let chunker = VoiceActivityChunker()
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        guard !isRunning else { return }
        chunker.reset()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MicError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [converter, chunker] buffer, _ in
            if let floats = converter.convert(buffer) {
                chunker.push(floats)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunker.flush()
        isRunning = false
    }
}
