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
/// (macOS 15+), mixes both to 16 kHz mono, and writes a 16-bit WAV.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // microphone
    @Published private(set) var systemLevel: Float = 0    // the other side of the call

    private var stream: SCStream?
    private var sink: CaptureSink?
    private var timer: Timer?
    private var startedAt: Date?

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
        // We never add a .screen output, so keep the video side as small as allowed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sink = try CaptureSink(url: url)
        sink.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        sink.onSystemLevel = { [weak self] value in
            Task { @MainActor in self?.systemLevel = value }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()

        self.stream = stream
        self.sink = sink
        startedAt = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
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
        level = 0
        systemLevel = 0
        return duration
    }
}

/// Receives both audio outputs, converts each to 16 kHz mono float, mixes, writes.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "io.stackera.notes.capture")
    var onLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    private let file: AVAudioFile
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converters: [SCStreamOutputType: AVAudioConverter] = [:]
    private let mixer = Mixer()
    private var framesWritten: Int64 = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let samples = floatSamples(from: sampleBuffer, format: format, type: type) else { return }
        if type == .microphone { onLevel?(Self.rms(samples)) } else { onSystemLevel?(Self.rms(samples)) }
        let hostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        mixer.add(samples, source: type == .microphone ? 0 : 1, at: hostSeconds)
        flush(final: false)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture stream stopped: \(error.localizedDescription)")
    }

    /// Drains everything still buffered. Returns the duration written, in seconds.
    func finish() -> TimeInterval {
        queue.sync { flush(final: true) }
        return Double(framesWritten) / 16_000
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
                guard let made = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
                converters[type] = made
                converter = made
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
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
        let chunk = mixer.drain(lag: final ? 0 : 16_000)
        guard !chunk.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(chunk.count)),
              let data = buffer.floatChannelData else { return }
        for (i, sample) in chunk.enumerated() { data[0][i] = max(-1, min(1, sample)) }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        do {
            try file.write(from: buffer)
            framesWritten += Int64(chunk.count)
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

/// Sums two sample streams, placing each buffer by its presentation timestamp so
/// the mic and system audio stay aligned even though they start at different
/// moments. Within a source, buffers continue contiguously unless the timestamp
/// says a gap or drop happened (more than 50 ms off), in which case we re-anchor.
final class Mixer {
    private let rate = 16_000.0
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var base = 0                  // absolute sample index of buffer[0]
    private var origin: Double?           // host time of absolute sample 0
    private var cursors: [Int?] = [nil, nil]
    private var reach = 0                 // highest absolute index written so far

    func add(_ input: [Float], source: Int, at hostSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { origin = hostSeconds }
        let fromClock = Int(((hostSeconds - origin!) * rate).rounded())
        var start: Int
        if let cursor = cursors[source], abs(fromClock - cursor) <= 800 {
            start = cursor
        } else {
            start = max(0, fromClock)
        }
        var samples = input[...]
        if start < base {
            samples = samples.dropFirst(min(base - start, samples.count))
            start = base
        }
        let needed = start - base + samples.count
        if buffer.count < needed { buffer.append(contentsOf: repeatElement(0, count: needed - buffer.count)) }
        var index = start - base
        for sample in samples {
            buffer[index] += sample
            index += 1
        }
        cursors[source] = start + samples.count
        reach = max(reach, start + samples.count)
    }

    func drain(lag: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let available = min(buffer.count, reach - lag - base)
        guard available > 0 else { return [] }
        let out = Array(buffer[0..<available])
        buffer.removeFirst(available)
        base += available
        return out
    }
}
