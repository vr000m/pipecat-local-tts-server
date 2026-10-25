import AVFoundation

/// The stt wire audio format (`pipecat-local-stt-server` docs/protocol.md):
/// pcm16 LE, 16 kHz mono. The one definition: the Apple Speech server
/// advertises it, the converters produce it, and the STT clients send it.
public enum STTWire {
    public static let encoding = "pcm16"
    public static let rate = 16000
    public static let channels = 1
    public static let bytesPerSecond = rate * channels * 2
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: AVAudioChannelCount(channels), interleaved: true)!
}

/// Converts a stream of audio buffers (microphone taps) to
/// the stt wire format (pcm16 LE, 16 kHz mono) through one `AVAudioConverter`.
///
/// The resampler keeps filter state between buffers, so consecutive buffers
/// join seamlessly; a fresh converter per buffer resets that state and ends each
/// buffer as a stream of its own, leaving an artifact at every buffer edge.
/// Call `finish()` after the last buffer for the samples the filter still holds.
public final class PCMStreamConverter: @unchecked Sendable {
    public static var wireFormat: AVAudioFormat { STTWire.format }

    private let lock = NSLock()
    private var converter: AVAudioConverter?

    public init() {}

    /// The pcm16 bytes `input` completes (the resampler may hold a few back).
    public func pcm16(from input: AVAudioPCMBuffer) throws -> Data {
        try lock.withLock {
            if converter?.inputFormat != input.format {
                // A new input format (the first buffer, an input device change) starts a new stream.
                guard let fresh = AVAudioConverter(from: input.format, to: Self.wireFormat) else { throw ConversionError() }
                converter = fresh
            }
            return try drain(input)
        }
    }

    /// The samples still in the resampler; the stream then starts afresh.
    public func finish() throws -> Data {
        try lock.withLock {
            defer { converter = nil }
            return try drain(nil)
        }
    }

    private func drain(_ input: AVAudioPCMBuffer?) throws -> Data {
        guard let converter else { return Data() }
        let ratio = Self.wireFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: capacity) else { throw ConversionError() }
        var pending = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let buffer = pending else {
                // More input may follow (`.noDataNow`), unless this is `finish()`.
                status.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            pending = nil
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let channel = output.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }

    public struct ConversionError: LocalizedError {
        public init() {}
        public var errorDescription: String? { "Audio conversion failed." }
    }
}
