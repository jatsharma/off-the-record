import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum RecorderError: LocalizedError {
    case noDisplay, notRecording, alreadyRecording
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for system audio capture."
        case .notRecording: return "Not recording."
        case .alreadyRecording: return "Already recording."
        }
    }
}

/// Records the microphone and system audio through one ScreenCaptureKit stream
/// (macOS 15+) into a two-channel 16 kHz WAV: left = microphone (you), right = the call.
/// Keeping the channels apart lets the transcript label lines You / Them and lets the
/// speech engine suppress the far side's echo in the microphone channel.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // microphone
    @Published private(set) var systemLevel: Float = 0    // the other side of the call

    private var stream: SCStream?
    private var sink: CaptureSink?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    func start(to url: URL) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.captureMicrophone = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sink = try CaptureSink(url: url)
        sink.onLevel = { [weak self] value in Task { @MainActor in self?.level = value } }
        sink.onSystemLevel = { [weak self] value in Task { @MainActor in self?.systemLevel = value } }
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()

        self.stream = stream
        self.sink = sink
        startedAt = Date()
        pausedTotal = 0
        pausedAt = nil
        elapsed = 0
        isRecording = true
        isPaused = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, !self.isPaused else { return }
                self.elapsed = Date().timeIntervalSince(startedAt) - self.pausedTotal
            }
        }
    }

    /// Pausing drops incoming audio; the file continues seamlessly on resume.
    func pause() {
        guard isRecording, !isPaused, let sink else { return }
        sink.setPaused(true)
        pausedAt = Date()
        isPaused = true
        level = 0
        systemLevel = 0
    }

    func resume() {
        guard isRecording, isPaused, let sink else { return }
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        sink.setPaused(false)
        isPaused = false
    }

    /// Stops capture and returns the recorded duration in seconds.
    func stop() async throws -> TimeInterval {
        guard isRecording, let stream, let sink else { throw RecorderError.notRecording }
        timer?.invalidate()
        timer = nil
        try await stream.stopCapture()
        let duration = sink.finish()
        self.stream = nil
        self.sink = nil
        isRecording = false
        isPaused = false
        level = 0
        systemLevel = 0
        return duration
    }

    /// Mixed mono audio recorded since the last call, for live captions.
    func takeLiveSamples() -> [Float] { sink?.takeLive() ?? [] }
}

/// Receives both audio outputs, converts each to 16 kHz mono float, aligns them by
/// timestamp into two channels, and writes a stereo WAV.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "io.stackera.notes.capture")
    var onLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    private let file: AVAudioFile
    private let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!
    private var converters: [SCStreamOutputType: AVAudioConverter] = [:]
    private let aligner = ChannelAligner()
    private var framesWritten: Int64 = 0
    private var paused = false
    private var pauseStartedAt: Double?
    private let liveLock = NSLock()
    private var live: [Float] = []

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        super.init()
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            if value {
                paused = true
                pauseStartedAt = CACurrentMediaTime()
            } else if let since = pauseStartedAt {
                aligner.shiftOrigin(by: CACurrentMediaTime() - since)
                pauseStartedAt = nil
                paused = false
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !paused, type == .audio || type == .microphone, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let samples = floatSamples(from: sampleBuffer, format: format, type: type) else { return }
        if type == .microphone { onLevel?(Self.rms(samples)) } else { onSystemLevel?(Self.rms(samples)) }
        let hostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        aligner.add(samples, channel: type == .microphone ? 0 : 1, at: hostSeconds)
        flush(final: false)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture stream stopped: \(error.localizedDescription)")
    }

    func finish() -> TimeInterval {
        queue.sync { flush(final: true) }
        return Double(framesWritten) / 16_000
    }

    func takeLive() -> [Float] {
        liveLock.lock(); defer { liveLock.unlock() }
        let out = live
        live.removeAll(keepingCapacity: true)
        return out
    }

    // MARK: - Private

    private func floatSamples(from sampleBuffer: CMSampleBuffer, format: CMFormatDescription, type: SCStreamOutputType) -> [Float]? {
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: format)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }
        return try? sampleBuffer.withAudioBufferList { audioBufferList, _ -> [Float]? in
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: audioBufferList.unsafePointer) else { return nil }
            input.frameLength = frames
            if sourceFormat.sampleRate == 16_000, sourceFormat.channelCount == 1, sourceFormat.commonFormat == .pcmFormatFloat32,
               let data = input.floatChannelData {
                return Array(UnsafeBufferPointer(start: data[0], count: Int(frames)))
            }
            let converter: AVAudioConverter
            if let existing = converters[type] {
                converter = existing
            } else {
                guard let made = AVAudioConverter(from: sourceFormat, to: monoFormat) else { return nil }
                converters[type] = made
                converter = made
            }
            let ratio = monoFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, let data = output.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        }
    }

    private func flush(final: Bool) {
        let (left, right) = aligner.drain(lag: final ? 0 : 16_000)
        guard !left.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(left.count)),
              let data = buffer.floatChannelData else { return }
        var mixed = [Float](repeating: 0, count: left.count)
        for i in 0..<left.count {
            data[0][i] = max(-1, min(1, left[i]))
            data[1][i] = max(-1, min(1, right[i]))
            mixed[i] = max(-1, min(1, left[i] + right[i]))
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        do {
            try file.write(from: buffer)
            framesWritten += Int64(left.count)
            liveLock.lock(); live.append(contentsOf: mixed); liveLock.unlock()
        } catch {
            NSLog("WAV write failed: \(error.localizedDescription)")
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0) { $0 + $1 * $1 }
        return min(1, sqrt(sum / Float(samples.count)) * 4)
    }
}

/// Places each source's buffers by presentation timestamp into its own channel so
/// microphone and system audio stay aligned even though they start at different moments.
/// Within a source, buffers continue contiguously unless the timestamp says a gap or
/// drop happened (more than 50 ms off), in which case we re-anchor.
final class ChannelAligner {
    private let rate = 16_000.0
    private let lock = NSLock()
    private var buffers: [[Float]] = [[], []]
    private var base = 0                  // absolute sample index of buffers[c][0]
    private var origin: Double?           // host time of absolute sample 0
    private var cursors: [Int?] = [nil, nil]
    private var reach = 0

    func shiftOrigin(by seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if origin != nil { origin! += seconds }
    }

    func add(_ input: [Float], channel: Int, at hostSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { origin = hostSeconds }
        let fromClock = Int(((hostSeconds - origin!) * rate).rounded())
        var start: Int
        if let cursor = cursors[channel], abs(fromClock - cursor) <= 800 { start = cursor } else { start = max(0, fromClock) }
        var samples = input[...]
        if start < base {
            samples = samples.dropFirst(min(base - start, samples.count))
            start = base
        }
        let needed = start - base + samples.count
        for c in 0..<2 where buffers[c].count < needed {
            buffers[c].append(contentsOf: repeatElement(0, count: needed - buffers[c].count))
        }
        var index = start - base
        for sample in samples {
            buffers[channel][index] += sample
            index += 1
        }
        cursors[channel] = start + samples.count
        reach = max(reach, start + samples.count)
    }

    func drain(lag: Int) -> ([Float], [Float]) {
        lock.lock(); defer { lock.unlock() }
        let available = min(buffers[0].count, reach - lag - base)
        guard available > 0 else { return ([], []) }
        let left = Array(buffers[0][0..<available]), right = Array(buffers[1][0..<available])
        buffers[0].removeFirst(available)
        buffers[1].removeFirst(available)
        base += available
        return (left, right)
    }
}

/// A WAV whose writer never closed (crash, force quit) keeps zero lengths in its header, so
/// every reader sees 0 seconds although the samples are all there. Rewrites the RIFF and
/// data chunk sizes from the file's real length.
enum WavRepair {
    /// Returns true when the header was rewritten.
    @discardableResult
    static func fixHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 44, fileSize < UInt64(UInt32.max) else { return false }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 4096), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return false }

        func u32(_ at: Int) -> UInt32 { head[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        var offset = 12
        var blockAlign: UInt64 = 1
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            if id == "fmt ", offset + 22 <= head.count {
                blockAlign = UInt64(max(1, Int(head[offset + 20]) | Int(head[offset + 21]) << 8))
            }
            if id == "data" {
                let dataStart = UInt64(offset + 8)
                let dataSize = (fileSize - dataStart) / blockAlign * blockAlign
                guard UInt64(size) != dataSize else { return false }    // already correct
                write(UInt32(dataSize), at: UInt64(offset + 4), to: handle)
                write(UInt32(fileSize - 8), at: 4, to: handle)
                return true
            }
            offset += 8 + size + (size & 1)
        }
        return false
    }

    private static func write(_ value: UInt32, at offset: UInt64, to handle: FileHandle) {
        var le = value.littleEndian
        try? handle.seek(toOffset: offset)
        handle.write(Data(bytes: &le, count: 4))
    }
}
