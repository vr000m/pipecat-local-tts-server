import AVFoundation
import PipecatToolbarCore

/// Plays the server's pcm16 stream through `AVAudioEngine`.
///
/// Frames arrive every 20 ms; they are coalesced into ~100 ms buffers before
/// scheduling. The player node runs at the server's advertised rate and the main
/// mixer resamples to the output device, so there is no manual resampling.
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var pending: [Float] = []
    private var scheduled = 0
    private var finishing = false
    /// Bumped on every stop so completions from flushed buffers are ignored.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    /// Called once the last scheduled buffer of a finished response has played.
    var onDrained: (() -> Void)?
    /// Called when the output device changed mid-utterance: the engine stopped
    /// itself and the utterance is lost, so its owner must end it.
    var onInterrupted: (() -> Void)?

    init() {
        engine.attach(node)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Output device changed: the engine stopped itself. Drop this utterance
            // and reconnect at the next begin() (the device's format may differ).
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stop()
                self.format = nil
                self.onInterrupted?()
            }
        }
    }

    /// Prepares for a new response at `rate` Hz (mono).
    func begin(rate: Int) throws {
        stop()
        if format?.sampleRate != Double(rate) {
            // Also after a configuration change, which leaves `format` nil.
            engine.stop()
            engine.disconnectNodeOutput(node)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            format = fmt
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        node.play()
    }

    func enqueue(pcm16: Data) {
        // A stopped engine never plays (or completes) a buffer.
        guard let format, engine.isRunning else { return }
        pending.append(contentsOf: PCM16.floats(from: pcm16))
        if Double(pending.count) >= format.sampleRate * 0.1 { flush() }
    }

    /// The response is complete; `onDrained` fires once playback catches up.
    func finish() {
        finishing = true
        flush()
        if scheduled == 0 { drained() }
    }

    /// Silence now and discard everything queued.
    func stop() {
        generation += 1
        pending.removeAll()
        scheduled = 0
        finishing = false
        // Whether or not the engine runs: `node.stop()` is what clears the node's
        // scheduled buffers, and after a configuration change the engine has
        // already stopped itself, so an `isRunning` guard would leave the lost
        // utterance queued for the next play(). (Skipped only before the node was
        // ever connected, when nothing can be queued.)
        if format != nil { node.stop() }
    }

    private func flush() {
        guard let format, !pending.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pending.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(pending.count)
        pending.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        pending.removeAll(keepingCapacity: true)
        scheduled += 1
        let gen = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: gen) }
        }
    }

    private func bufferPlayed(generation gen: Int) {
        guard gen == generation else { return }
        scheduled = max(0, scheduled - 1)
        if finishing && scheduled == 0 { drained() }
    }

    private func drained() {
        finishing = false
        onDrained?()
    }
}
