import AVFoundation
import Foundation

/// Plays a meeting's WAV and publishes the playhead so the transcript can follow it.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loadedURL: URL?
    @Published private(set) var isLoading = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Decodes the file off the main thread; a 30-minute WAV takes a second or two.
    func load(_ url: URL?) async {
        guard url != loadedURL else { return }
        stop()
        loadedURL = url
        player = nil
        duration = 0
        guard let url else { return }
        isLoading = true
        let loaded: AVAudioPlayer? = await Task.detached(priority: .userInitiated) {
            let p = try? AVAudioPlayer(contentsOf: PlaybackMix.playableURL(for: url))
            p?.prepareToPlay()
            return p
        }.value
        isLoading = false
        guard loadedURL == url else { return }   // a different file was requested meanwhile
        player = loaded
        duration = loaded?.duration ?? 0
    }

    var isLoaded: Bool { player != nil }

    func toggle() { isPlaying ? pause() : play() }

    func play(from time: Double? = nil) {
        guard let player else { return }
        if let time { player.currentTime = max(0, min(time, player.duration)) }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func seek(to time: Double) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? time
    }

    func stop() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }
}

/// Recordings keep you on the left channel and the call on the right, which is right for
/// transcription but means headphones play each person in one ear only, with the
/// microphone much quieter. For playback the two are mixed into one centred track.
enum PlaybackMix {
    private static let prefix = "notes-playback-"

    /// The file to play: the original, or a mono mix of a two-channel recording. One mix is
    /// cached in the temporary folder at a time.
    static func playableURL(for url: URL) -> URL {
        let mixURL = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + url.lastPathComponent)
        removeOtherMixes(keeping: mixURL)
        guard let source = try? AVAudioFile(forReading: url),
              source.processingFormat.channelCount == 2, source.processingFormat.sampleRate == 16_000 else { return url }
        if isFresh(mixURL, comparedTo: url) { return mixURL }
        do {
            try writeMix(of: source, to: mixURL)
            return mixURL
        } catch {
            try? FileManager.default.removeItem(at: mixURL)
            NSLog("Playback mix failed, playing the original: \(error.localizedDescription)")
            return url
        }
    }

    private static func writeMix(of source: AVAudioFile, to target: URL) throws {
        guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try source.read(into: input)
        guard let data = input.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let n = Int(input.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = Array(UnsafeBufferPointer(start: data[1], count: n))
        // Drop the call's echo from the mic (as transcription does) so the far side is not heard twice.
        let mic = SpeechEngine.suppressEcho(mic: left, system: right)
        let micGain = gain(for: mic), callGain = gain(for: right)

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)), let out = output.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<n { out[i] = max(-1, min(1, mic[i] * micGain + right[i] * callGain)) }
        output.frameLength = AVAudioFrameCount(n)

        try? FileManager.default.removeItem(at: target)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: output)
        file.close()
    }

    /// Lifts a quiet side so its loud 5% of 20 ms frames sit near -14 dBFS (like the
    /// transcriber's normalisation), but never past a 0.9 peak, so playback does not clip.
    private static func gain(for samples: [Float]) -> Float {
        let frame = 320
        var rms: [Float] = []
        var peak: Float = 0
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<i + frame { e += samples[j] * samples[j]; peak = max(peak, abs(samples[j])) }
            rms.append((e / Float(frame)).squareRoot())
            i += frame
        }
        guard !rms.isEmpty, peak > 0 else { return 1 }
        let loud = rms.sorted()[Int(Double(rms.count - 1) * 0.95)]
        guard loud > 0.0005 else { return 1 }
        return max(1, min(30, 0.2 / loud, 0.9 / peak))
    }

    private static func isFresh(_ mix: URL, comparedTo source: URL) -> Bool {
        let fm = FileManager.default
        guard let m = (try? fm.attributesOfItem(atPath: mix.path))?[.modificationDate] as? Date,
              let s = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date else { return false }
        return m >= s
    }

    private static func removeOtherMixes(keeping keep: URL) {
        let dir = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name != keep.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
