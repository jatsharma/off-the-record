import Foundation
import AVFoundation
import FluidAudio
import WhisperKit

enum ASREngine: String, CaseIterable, Identifiable {
    case parakeet, whisper, qwen3
    var id: String { rawValue }
    var label: String {
        switch self {
        case .parakeet: return "Parakeet v3 (fast, English + European)"
        case .whisper: return "Whisper large-v3-turbo (slower, 99 languages incl. Hindi)"
        case .qwen3: return "Qwen3-ASR 0.6B (30 languages incl. Hindi, experimental)"
        }
    }
    var takesLanguageHint: Bool { self != .parakeet }
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
    private var qwen3: Qwen3AsrManager?

    /// Drops loaded models so the next use re-downloads and re-loads them (after a delete in Settings).
    func unload(_ engine: ASREngine?) {
        switch engine {
        case .parakeet: asr = nil
        case .whisper: whisper = nil; whisperModelName = nil
        case .qwen3: qwen3 = nil
        case nil: asr = nil; whisper = nil; whisperModelName = nil; qwen3 = nil; diarizer = nil
        }
    }

    func prepare(engine: ASREngine, status: @escaping @Sendable (String) -> Void) async throws {
        if engine == .qwen3 {
            if qwen3 == nil {
                status("Loading Qwen3-ASR 0.6B (about 1.2 GB on first run)")
                let directory = try await Qwen3AsrModels.download(variant: .f32)
                let manager = Qwen3AsrManager()
                try await manager.loadModels(from: directory)
                qwen3 = manager
            }
        } else if engine == .whisper {
            let name = AppSettings.whisperModel
            if whisper == nil || whisperModelName != name {
                status("Loading Whisper (\(name), about 1 GB on first run)")
                try? FileManager.default.createDirectory(at: ModelCatalog.whisperRoot, withIntermediateDirectories: true)
                whisper = try await WhisperKit(WhisperKitConfig(model: name, downloadBase: ModelCatalog.whisperRoot, verbose: false, logLevel: .error))
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

        if engine == .qwen3 {
            return try await transcribeByTurns(samples: samples, duration: duration, status: status)
        }

        let pieces: [TimedPiece]
        let fullText: String
        switch engine {
        case .qwen3:
            throw SpeechError.notLoaded   // handled above
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

    // MARK: - Turn-by-turn transcription (engines without timestamps, 30 s max input)

    /// Diarize first, then transcribe each speaker turn (capped at 25 s) on its own.
    /// Timing and speaker come from the diarizer; the recognizer only has to produce text.
    private func transcribeByTurns(samples: [Float], duration: Double,
                                   status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptLine] {
        guard let diarizer, let qwen3 else { throw SpeechError.notLoaded }
        status("Identifying speakers")
        let segments = (try? diarizer.performCompleteDiarization(samples, sampleRate: 16_000).segments) ?? []
        var names: [String: String] = [:]
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where names[seg.speakerId] == nil {
            names[seg.speakerId] = "Speaker \(names.count + 1)"
        }

        // Build chunks: consecutive same-speaker turns joined up to 25 s; silence gaps over 2 s
        // that the diarizer did not label become unlabelled chunks so no speech is skipped.
        struct Chunk { var start: Double; var end: Double; var speaker: String? }
        let maxLen = 25.0
        var chunks: [Chunk] = []
        var cursor = 0.0
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let s = Double(seg.startTimeSeconds), e = Double(seg.endTimeSeconds), who = names[seg.speakerId]
            if s - cursor > 2 { chunks.append(Chunk(start: cursor, end: s, speaker: nil)) }
            if var last = chunks.last, last.speaker == who, s - last.end < 1, e - last.start <= maxLen {
                last.end = e
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(Chunk(start: s, end: e, speaker: who))
            }
            cursor = max(cursor, e)
        }
        if duration - cursor > 2 { chunks.append(Chunk(start: cursor, end: duration, speaker: nil)) }
        if chunks.isEmpty { chunks = [Chunk(start: 0, end: duration, speaker: nil)] }
        // Split anything still longer than the model's window.
        var pieces: [Chunk] = []
        for c in chunks {
            var s = c.start
            while c.end - s > maxLen { pieces.append(Chunk(start: s, end: s + maxLen, speaker: c.speaker)); s += maxLen }
            pieces.append(Chunk(start: s, end: c.end, speaker: c.speaker))
        }

        var lines: [TranscriptLine] = []
        let language = AppSettings.language
        for (i, c) in pieces.enumerated() where c.end - c.start >= 0.4 {
            status("Transcribing with Qwen3 (\(i + 1)/\(pieces.count))")
            let lo = max(0, Int((c.start - 0.2) * 16_000)), hi = min(samples.count, Int((c.end + 0.2) * 16_000))
            guard hi > lo else { continue }
            let text = (try? await qwen3.transcribe(audioSamples: Array(samples[lo..<hi]), language: language)) ?? ""
            let clean = Self.collapseRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard clean.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            lines.append(TranscriptLine(start: c.start, end: c.end, speaker: c.speaker, text: clean))
        }
        return lines
    }

    /// Autoregressive recognizers sometimes loop ("एक existing plaza हैं, और एक existing plaza हैं, ...").
    /// Collapse any run of 1 to 6 words repeated three or more times in a row down to one copy.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < words.count {
            var collapsed = false
            for n in 1...6 where i + 3 * n <= words.count {
                let unit = Array(words[i..<i + n])
                var reps = 1
                while i + (reps + 1) * n <= words.count, Array(words[i + reps * n..<i + (reps + 1) * n]) == unit { reps += 1 }
                if reps >= 3 {
                    words.removeSubrange(i + n..<i + reps * n)
                    collapsed = true
                    break
                }
            }
            if !collapsed { i += 1 }
        }
        return words.joined(separator: " ")
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
