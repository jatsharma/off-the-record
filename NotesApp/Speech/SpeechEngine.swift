import Foundation
import AVFoundation
import FluidAudio
import WhisperKit

enum ASREngine: String, CaseIterable, Identifiable {
    case parakeet, whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .parakeet: return "Parakeet v3 (fast, English + European)"
        case .whisper: return "Whisper large-v3-turbo (slower, 99 languages incl. Hindi)"
        }
    }
}

/// One timed unit of recognized text: a Parakeet token or a Whisper word.
struct TimedPiece {
    var text: String
    var start: Double
    var end: Double
}

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
    private var whisper: WhisperKit?
    private var whisperModelName: String?

    func prepare(engine: ASREngine, status: @escaping @Sendable (String) -> Void) async throws {
        if engine == .whisper {
            let name = AppSettings.whisperModel
            if whisper == nil || whisperModelName != name {
                status("Loading Whisper (\(name), about 1 GB on first run)")
                whisper = try await WhisperKit(WhisperKitConfig(model: name, verbose: false, logLevel: .error))
                whisperModelName = name
            }
        } else if asr == nil {
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
        let engine = AppSettings.engine
        try await prepare(engine: engine, status: status)
        guard let diarizer else { throw SpeechError.notLoaded }

        status("Reading audio")
        let samples = try Self.loadSamples(file)
        let duration = Double(samples.count) / 16_000

        let pieces: [TimedPiece]
        let fullText: String
        switch engine {
        case .parakeet:
            guard let asr else { throw SpeechError.notLoaded }
            status("Transcribing with Parakeet")
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &state)
            fullText = result.text
            pieces = (result.tokenTimings ?? []).map {
                TimedPiece(text: $0.token.replacingOccurrences(of: "\u{2581}", with: " "), start: $0.startTime, end: $0.endTime)
            }
        case .whisper:
            guard let whisper else { throw SpeechError.notLoaded }
            status("Transcribing with Whisper")
            var options = DecodingOptions()
            options.language = AppSettings.language
            options.detectLanguage = AppSettings.language == nil
            options.wordTimestamps = true
            options.skipSpecialTokens = true
            options.chunkingStrategy = .vad
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            let strip: (String) -> String = { $0.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression) }
            fullText = strip(results.map(\.text).joined(separator: " "))
            var collected: [TimedPiece] = []
            for result in results {
                for segment in result.segments {
                    if let words = segment.words, !words.isEmpty {
                        collected += words.map { TimedPiece(text: strip($0.word), start: Double($0.start), end: Double($0.end)) }
                    } else {
                        collected.append(TimedPiece(text: " " + strip(segment.text).trimmingCharacters(in: .whitespaces),
                                                    start: Double(segment.start), end: Double(segment.end)))
                    }
                }
            }
            pieces = collected.sorted { $0.start < $1.start }
        }

        status("Identifying speakers")
        let speakers: [TimedSpeakerSegment]
        do {
            speakers = try diarizer.performCompleteDiarization(samples, sampleRate: 16_000).segments
        } catch {
            NSLog("Diarization failed, continuing without speakers: \(error)")
            speakers = []
        }
        return Self.merge(pieces: pieces, fullText: fullText, speakers: speakers, duration: duration)
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
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, let data = output.floatChannelData else { throw SpeechError.unreadableAudio }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: - Merge tokens with speaker turns

    private static func merge(pieces: [TimedPiece], fullText: String, speakers: [TimedSpeakerSegment], duration: Double) -> [TranscriptLine] {
        // Name speakers in order of first appearance.
        var names: [String: String] = [:]
        for segment in speakers.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where names[segment.speakerId] == nil {
            names[segment.speakerId] = "Speaker \(names.count + 1)"
        }
        func speaker(at time: Double) -> String? {
            let t = Float(time)
            func distance(_ s: TimedSpeakerSegment) -> Float { max(0, s.startTimeSeconds - t, t - s.endTimeSeconds) }
            guard let nearest = speakers.min(by: { distance($0) < distance($1) }), distance(nearest) < 2 else { return nil }
            return names[nearest.speakerId]
        }

        guard !pieces.isEmpty else {
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptLine(start: 0, end: duration, speaker: nil, text: text)]
        }

        var lines: [TranscriptLine] = []
        var current: TranscriptLine?
        var lastEnd = 0.0
        for token in pieces {
            let piece = token.text
            let gap = token.start - lastEnd
            var who = speaker(at: (token.start + token.end) / 2)
            let isPunctuation = piece.trimmingCharacters(in: .whitespaces).allSatisfy { $0.isPunctuation }
            // Punctuation sticks to the line it closes; an unlabelled token right after
            // a line keeps that line's speaker instead of starting an orphan.
            if let line = current, isPunctuation || (who == nil && gap < 1.5) { who = line.speaker }
            let endsSentence = current.map { $0.text.count > 300 && $0.text.last.map { ".?!".contains($0) } == true } ?? false
            if var line = current, line.speaker == who, gap < 1.2 || isPunctuation, !endsSentence {
                line.text += piece
                line.end = token.end
                current = line
            } else {
                if let line = current { lines.append(line) }
                current = TranscriptLine(start: token.start, end: token.end, speaker: who, text: piece)
            }
            lastEnd = token.end
        }
        if let line = current { lines.append(line) }
        return lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return TranscriptLine(start: line.start, end: line.end, speaker: line.speaker, text: text)
        }
    }
}
