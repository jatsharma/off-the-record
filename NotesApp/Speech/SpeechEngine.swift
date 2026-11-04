import Foundation
import AVFoundation
import FluidAudio

struct TranscriptLine {
    var start: Double
    var end: Double
    var speaker: String?
    var text: String
}

enum SpeechError: LocalizedError {
    case notLoaded, unreadableAudio
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Speech models are not loaded."
        case .unreadableAudio: return "Could not read the recording."
        }
    }
}

/// Parakeet TDT v3 for text, pyannote-based diarizer for who spoke when.
/// Both run on the Neural Engine via FluidAudio; models download on first use.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var asr: AsrManager?
    private var diarizer: DiarizerManager?

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if asr == nil {
            status("Loading speech model (Parakeet v3, about 500 MB on first run)")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if diarizer == nil {
            status("Loading speaker model")
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager(config: .default)
            manager.initialize(models: models)
            diarizer = manager
        }
    }

    func transcribe(file: URL, status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptLine] {
        try await prepare(status: status)
        guard let asr, let diarizer else { throw SpeechError.notLoaded }

        status("Reading audio")
        let samples = try Self.loadSamples(file)
        let duration = Double(samples.count) / 16_000

        status("Transcribing")
        var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)

        status("Identifying speakers")
        let speakers: [TimedSpeakerSegment]
        do {
            speakers = try diarizer.performCompleteDiarization(samples, sampleRate: 16_000).segments
        } catch {
            NSLog("Diarization failed, continuing without speakers: \(error)")
            speakers = []
        }
        return Self.merge(result, speakers: speakers, duration: duration)
    }

    // MARK: - Audio loading

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechError.unreadableAudio
        }
        try file.read(into: input)
        if source.sampleRate == 16_000, source.channelCount == 1, let data = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw SpeechError.unreadableAudio }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / source.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SpeechError.unreadableAudio }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.floatChannelData else { throw SpeechError.unreadableAudio }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: - Merge tokens with speaker turns

    private static func merge(_ result: ASRResult, speakers: [TimedSpeakerSegment], duration: Double) -> [TranscriptLine] {
        // Name speakers in order of first appearance.
        var names: [String: String] = [:]
        for segment in speakers.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where names[segment.speakerId] == nil {
            names[segment.speakerId] = "Speaker \(names.count + 1)"
        }
        func speaker(at time: Double) -> String? {
            let t = Float(time)
            if let hit = speakers.first(where: { $0.startTimeSeconds <= t && t <= $0.endTimeSeconds }) {
                return names[hit.speakerId]
            }
            let nearest = speakers.min { abs(Float(time) - $0.startTimeSeconds) < abs(Float(time) - $1.startTimeSeconds) }
            if let nearest, abs(t - nearest.startTimeSeconds) < 2 { return names[nearest.speakerId] }
            return nil
        }

        guard let tokens = result.tokenTimings, !tokens.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptLine(start: 0, end: duration, speaker: nil, text: text)]
        }

        var lines: [TranscriptLine] = []
        var current: TranscriptLine?
        var lastEnd = 0.0
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "\u{2581}", with: " ")
            let who = speaker(at: (token.startTime + token.endTime) / 2)
            let gap = token.startTime - lastEnd
            let endsSentence = current.map { $0.text.count > 300 && $0.text.last.map { ".?!".contains($0) } == true } ?? false
            if var line = current, line.speaker == who, gap < 1.2, !endsSentence {
                line.text += piece
                line.end = token.endTime
                current = line
            } else {
                if let line = current { lines.append(line) }
                current = TranscriptLine(start: token.startTime, end: token.endTime, speaker: who, text: piece)
            }
            lastEnd = token.endTime
        }
        if let line = current { lines.append(line) }
        return lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(start: line.start, end: line.end, speaker: line.speaker, text: text)
        }
    }
}
