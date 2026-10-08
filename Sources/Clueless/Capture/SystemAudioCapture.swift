import AVFoundation
import ScreenCaptureKit

/// System-audio capture ("Listen" mode): ScreenCaptureKit audio-only stream of
/// the display's output, excluding this process, → 16 kHz mono → VAD chunker →
/// WAV utterances. Requires Screen Recording permission (same TCC grant that
/// covers audio capture on macOS 13+).
final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    var onUtterance: (@Sendable (Data) -> Void)? {
        get { chunker.onUtterance }
        set { chunker.onUtterance = newValue }
    }

    enum CaptureError: LocalizedError {
        case screenRecordingPermissionMissing
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionMissing:
                return "Screen Recording permission is required to capture system audio."
            case .noDisplay:
                return "No display found to capture audio from."
            }
        }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.clueless.systemaudio")
    private let converter = PCMConverter()
    private let chunker = VoiceActivityChunker()
    private(set) var isRunning = false

    func start() async throws {
        guard !isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingPermissionMissing
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // Video frames are required by the API but unused — request the minimum.
        configuration.width = 2
        configuration.height = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        chunker.reset()
        self.stream = stream
        isRunning = true
    }

    func stop() {
        guard isRunning, let stream else { return }
        self.stream = nil
        isRunning = false
        Task {
            try? await stream.stopCapture()
            chunker.flush()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer,
                    deallocator: .none
                ) else { return }
                pcm.frameLength = frameCount
                if let floats = converter.convert(pcm) {
                    chunker.push(floats)
                }
            }
        } catch {
            // Malformed buffer — drop it and keep the stream alive.
        }
    }
}
