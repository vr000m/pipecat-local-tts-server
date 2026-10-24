import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (SpeechAnalyzer + SpeechTranscriber, macOS 26+),
/// wrapped for the toolbar: asset status/install and one-shot transcription of
/// 16 kHz pcm16 utterances (what the stt wire protocol commits).
enum AppleSpeech {
    enum Status: Equatable {
        case unavailable(String)
        case needsDownload
        case downloading
        case installed
    }

    static var isSupportedOS: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func status() async -> Status {
        guard #available(macOS 26, *) else { return .unavailable("Requires macOS 26 or later.") }
        guard SpeechTranscriber.isAvailable else { return .unavailable("Speech transcription isn't available on this Mac.") }
        guard let locale = await locale(for: nil) else { return .unavailable("Your language isn't supported yet.") }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .needsDownload
        default: return .unavailable("Your language isn't supported yet.")
        }
    }

    /// Downloads the speech model for the current language, reporting 0...1.
    static func install(progress: @escaping @MainActor (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unsupported }
        guard let locale = await locale(for: nil) else { throw AppleSpeechError.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return  // already installed
        }
        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        await progress(1)
    }

    /// The installed locale to use: the requested language if supported, else the
    /// user's current locale, else English (US).
    static func locale(for language: String?) async -> Locale? {
        guard #available(macOS 26, *) else { return nil }
        if let language, let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            return match
        }
        if let current = await SpeechTranscriber.supportedLocale(equivalentTo: .current) { return current }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    /// e.g. "English (United States)" (drops `@rg=` and other keywords).
    static var localeDescription: String {
        let id = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? Locale.current.identifier
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Transcribes one utterance of pcm16 LE, 16 kHz mono.
    static func transcribe(pcm16: Data, language: String?) async throws -> String {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unsupported }
        guard !pcm16.isEmpty else { return "" }
        guard let locale = await locale(for: language) else { throw AppleSpeechError.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noAudioFormat
        }
        let buffer = try PCMConverter.buffer(fromPCM16: pcm16, rate: 16000, to: format)
        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: input)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppleSpeechError: LocalizedError {
    case unsupported, unsupportedLanguage, noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupported: "Apple Speech requires macOS 26 or later."
        case .unsupportedLanguage: "Apple Speech doesn't support your language yet."
        case .noAudioFormat: "No audio format is available for speech analysis."
        }
    }
}

/// Audio format conversion to and from the stt wire format (pcm16 LE, 16 kHz mono).
enum PCMConverter {
    static let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Any PCM buffer -> pcm16 16 kHz mono bytes.
    static func pcm16(from buffer: AVAudioPCMBuffer) throws -> Data {
        let out = try convert(buffer, to: wireFormat)
        guard let channel = out.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }

    /// pcm16 bytes -> a buffer in `format`.
    static func buffer(fromPCM16 data: Data, rate: Double, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        let frames = AVAudioFrameCount(data.count / 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { throw ConversionError() }
        input.frameLength = frames
        data.withUnsafeBytes { raw in
            input.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        return try convert(input, to: format)
    }

    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else { throw ConversionError() }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw ConversionError() }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }

    struct ConversionError: LocalizedError {
        var errorDescription: String? { "Audio conversion failed." }
    }
}
