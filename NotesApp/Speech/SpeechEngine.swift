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

/// Lines plus one averaged voice embedding per speaker label, for voice memory.
struct TranscriptResult {
    var lines: [TranscriptLine]
    var speakerVectors: [String: [Float]]
}

/// A known voice the engine may recognise: name and averaged embedding.
struct KnownVoice {
    let name: String
    let vector: [Float]
}

typealias ProgressReport = @Sendable (_ fraction: Double?, _ status: String) -> Void

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

    func transcribe(file: URL, knownVoices: [KnownVoice] = [], report: @escaping ProgressReport) async throws -> TranscriptResult {
        let engine = AppSettings.engine
        let status: @Sendable (String) -> Void = { report(nil, $0) }
        try await prepare(engine: engine, status: status)
        guard let diarizer else { throw SpeechError.notLoaded }

        status("Reading audio")
        let channels = try Self.loadChannels(file)
        let duration = Double(channels[0].count) / 16_000

        // Two-channel recording (left = you, right = the call): transcribe each side on its own.
        if channels.count == 2, engine == .parakeet, let asr {
            let mic = Self.suppressEcho(mic: channels[0], system: channels[1])
            report(0, "Transcribing your side")
            await asr.setWindowHandler { p in report(0.45 * Double(p.index + 1) / Double(max(1, p.windowCount)), "Transcribing your side") }
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let mine = try await asr.transcribe(mic, decoderState: &state)
            let myPieces = Self.pieces(from: mine)
            let myLines = Self.merge(pieces: myPieces, fullText: mine.text, speakers: [], duration: duration, fixedSpeaker: "You")

            report(0.45, "Transcribing the call")
            await asr.setWindowHandler { p in report(0.45 + 0.45 * Double(p.index + 1) / Double(max(1, p.windowCount)), "Transcribing the call") }
            var state2 = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let theirs = try await asr.transcribe(channels[1], decoderState: &state2)
            await asr.setWindowHandler(nil)

            report(0.92, "Identifying speakers")
            let diar = (try? diarizer.performCompleteDiarization(channels[1], sampleRate: 16_000).segments) ?? []
            let (names, vectors) = Self.nameSpeakers(diar, knownVoices: knownVoices, singleLabel: "Them")
            let theirLines = Self.merge(pieces: Self.pieces(from: theirs), fullText: theirs.text, speakers: diar,
                                        duration: duration, names: names)
            let lines = (myLines + theirLines).sorted { $0.start < $1.start }
            return TranscriptResult(lines: lines, speakerVectors: vectors)
        }

        // Mono recording or imported file: mix channels and run the single-track pipeline.
        let samples = channels.count == 1 ? channels[0] : Self.mixDown(channels)

        if engine == .qwen3 {
            let lines = try await transcribeByTurns(samples: samples, duration: duration, status: status)
            return TranscriptResult(lines: lines, speakerVectors: [:])
        }

        let pieces: [TimedPiece]
        let fullText: String
        switch engine {
        case .qwen3:
            throw SpeechError.notLoaded   // handled above
        case .parakeet:
            guard let asr else { throw SpeechError.notLoaded }
            report(0, "Transcribing with Parakeet")
            await asr.setWindowHandler { p in report(0.9 * Double(p.index + 1) / Double(max(1, p.windowCount)), "Transcribing with Parakeet") }
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &state)
            await asr.setWindowHandler(nil)
            fullText = result.text
            pieces = Self.pieces(from: result)
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

        report(0.92, "Identifying speakers")
        let speakers: [TimedSpeakerSegment]
        do {
            speakers = try diarizer.performCompleteDiarization(samples, sampleRate: 16_000).segments
        } catch {
            NSLog("Diarization failed, continuing without speakers: \(error)")
            speakers = []
        }
        let (names, vectors) = Self.nameSpeakers(speakers, knownVoices: knownVoices, singleLabel: nil)
        let lines = Self.merge(pieces: pieces, fullText: fullText, speakers: speakers, duration: duration, names: names)
        return TranscriptResult(lines: lines, speakerVectors: vectors)
    }

    /// Quick pass over a short mixed chunk for live captions while recording.
    func quickTranscribe(_ samples: [Float]) async -> String {
        guard samples.count >= 8_000 else { return "" }
        do {
            try await prepare(engine: .parakeet, status: { _ in })
            guard let asr else { return "" }
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            return try await asr.transcribe(samples, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    // MARK: - Speaker naming and voice memory

    /// Maps diarizer cluster ids to display names. Clusters whose averaged embedding is close
    /// to a known voice take that name; the rest become Speaker N (or `singleLabel` when the
    /// track has exactly one unknown speaker). Also returns the averaged vector per name.
    private static func nameSpeakers(_ segments: [TimedSpeakerSegment], knownVoices: [KnownVoice],
                                     singleLabel: String?) -> ([String: String], [String: [Float]]) {
        var byCluster: [String: [[Float]]] = [:]
        var order: [String] = []
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if byCluster[seg.speakerId] == nil { order.append(seg.speakerId) }
            byCluster[seg.speakerId, default: []].append(seg.embedding)
        }
        var names: [String: String] = [:]
        var vectors: [String: [Float]] = [:]
        var taken = Set<String>()
        var unknownIndex = 0
        let unknownCount = order.count
        for cluster in order {
            let centroid = Vectors.mean(byCluster[cluster] ?? [])
            var name: String? = nil
            if !centroid.isEmpty {
                let best = knownVoices.filter { !taken.contains($0.name) }
                    .map { ($0.name, Vectors.cosine($0.vector, centroid)) }
                    .max { $0.1 < $1.1 }
                if let best, best.1 >= 0.62 { name = best.0 }
            }
            if name == nil {
                unknownIndex += 1
                name = (singleLabel != nil && unknownCount == 1) ? singleLabel! : "Speaker \(unknownIndex)"
            }
            taken.insert(name!)
            names[cluster] = name!
            if !centroid.isEmpty { vectors[name!] = centroid }
        }
        return (names, vectors)
    }

    private static func pieces(from result: ASRResult) -> [TimedPiece] {
        (result.tokenTimings ?? []).map {
            TimedPiece(text: $0.token.replacingOccurrences(of: "\u{2581}", with: " "), start: $0.startTime, end: $0.endTime)
        }
    }

    private static func mixDown(_ channels: [[Float]]) -> [Float] {
        let n = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        for c in channels { for i in 0..<n { out[i] += c[i] } }
        return out.map { max(-1, min(1, $0)) }
    }

    /// Zeroes 20 ms frames of the microphone where the call is clearly the louder source,
    /// so the far side's echo through speakers is not transcribed as "You".
    static func suppressEcho(mic: [Float], system: [Float]) -> [Float] {
        let frame = 320
        var out = mic
        var i = 0
        while i < min(mic.count, system.count) {
            let end = min(i + frame, mic.count, system.count)
            var m: Float = 0, s: Float = 0
            for j in i..<end { m += mic[j] * mic[j]; s += system[j] * system[j] }
            if s > 0.0001 * Float(end - i), s > 4 * m {      // call at least 6 dB louder than mic
                for j in i..<end { out[j] = 0 }
            }
            i = end
        }
        return out
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

    /// Returns one array per channel at 16 kHz. Two-channel recordings keep (mic, call) apart;
    /// anything else is resampled to a single mono track.
    private static func loadChannels(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechError.unreadableAudio
        }
        try file.read(into: input)
        if source.sampleRate == 16_000, let data = input.floatChannelData, source.channelCount == 1 || source.channelCount == 2 {
            return (0..<Int(source.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(input.frameLength))) }
        }
        return [try loadMono(input, source: source)]
    }

    private static func loadMono(_ input: AVAudioPCMBuffer, source: AVAudioFormat) throws -> [Float] {
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

    private static func merge(pieces: [TimedPiece], fullText: String, speakers: [TimedSpeakerSegment], duration: Double,
                              names: [String: String] = [:], fixedSpeaker: String? = nil) -> [TranscriptLine] {
        func speaker(at time: Double) -> String? {
            if let fixedSpeaker { return fixedSpeaker }
            let t = Float(time)
            func distance(_ s: TimedSpeakerSegment) -> Float { max(0, s.startTimeSeconds - t, t - s.endTimeSeconds) }
            guard let nearest = speakers.min(by: { distance($0) < distance($1) }), distance(nearest) < 2 else { return nil }
            return names[nearest.speakerId]
        }

        guard !pieces.isEmpty else {
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TranscriptLine(start: 0, end: duration, speaker: fixedSpeaker, text: text)]
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
