import Foundation
import Testing

@testable import PipecatToolbarCore

@Suite struct STTSampleClipTests {
    @Test func clipIsAWholeNumberOfSixteenKilohertzMonoSamplesAndLoud() {
        let pcm = STTSampleClip.pcm16
        #expect(pcm.count % 2 == 0)
        let seconds = Double(pcm.count) / 2 / 16_000
        #expect((2.0...4.0).contains(seconds), "clip is \(seconds) s")
        let peak = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0
        }
        #expect(peak > 5_000, "the clip is silent (peak \(peak))")
    }

    @Test func clipHasHalfASecondOfSilenceOnEachSide() {
        // Kyutai STT 2.6B drops the first word when the speech starts at sample 0.
        let pcm = STTSampleClip.pcm16
        let half = STTWire.rate  // bytes in 0.5 s of 16-bit samples
        #expect(pcm.prefix(half).allSatisfy { $0 == 0 })
        #expect(pcm.suffix(half).allSatisfy { $0 == 0 })
        #expect(pcm.dropFirst(half).dropLast(half).contains { $0 != 0 })
    }

    @Test(arguments: [
        "The quick brown fox jumps over the lazy dog.",
        "the quick brown fox jumps over the lazy dog",
        "The quick brown fox, jumps over the lazy dog!",
        "  The quick brown fox jumps over the lazy dogs.  ",  // one stray character
    ])
    func acceptsTheSentenceAndOneSlip(_ transcript: String) {
        #expect(STTSampleClip.matches(transcript))
    }

    @Test(arguments: [
        "",
        "(no speech detected)",
        "Hello from Pipecat.",
        "The quick brown fox jumps",  // truncated
        "The quick brown socks jumps over the lazy dog.",  // a wrong word
        "Something else entirely about the weather today.",
    ])
    func rejectsOtherText(_ transcript: String) {
        #expect(!STTSampleClip.matches(transcript))
    }
}
