import Foundation
import AVFoundation
import FluidAudio
import WhisperKit
import AppKit

enum ASREngine: String, CaseIterable, Identifiable {
    case parakeet, whisper, qwen3, tara, apex, mix
    var id: String { rawValue }
    var label: String {
        switch self {
        case .parakeet: return "Parakeet v3 (fast, English + European)"
        case .whisper: return "Whisper large-v3-turbo (slower, 99 languages incl. Hindi)"
        case .qwen3: return "Qwen3-ASR 0.6B (30 languages incl. Hindi, experimental)"
        case .tara: return "Tara (Hinglish, experimental: slow)"
        case .apex: return "Apex (Hinglish, romanized)"
        case .mix: return "Mix: Apex for Hindi, Parakeet for English (recommended)"
        }
    }
    /// Tara and Apex are Hindi–English models and always run in Hindi mode.
    var takesLanguageHint: Bool { self == .whisper || self == .qwen3 }
    /// Engines that read the audio one speaker turn at a time (they take at most 30 s per call).
    var readsByTurns: Bool { self == .qwen3 || self == .tara || self == .apex || self == .mix }
    /// The Hinglish model a turn-by-turn engine reads with (the mix uses Apex).
    var hinglishModel: ASREngine { self == .mix ? .apex : self }
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
    /// A second reading of the same audio made with the glossary as context (Qwen3 only). It spells
    /// terms better but can drop words or invent glossary terms, so the clean-up pass weighs both.
    var altText: String? = nil
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
    case notLoaded, unreadableAudio, modelMissing(ASREngine)
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Speech models are not loaded."
        case .unreadableAudio: return "Could not read the recording."
        case .modelMissing(let engine):
            return "\(engine.label) is not installed. Run `make hinglish-models` in the project folder, or pick another engine in Settings."
        }
    }
}

/// Parakeet TDT v3 for text, pyannote-based diarizer for who spoke when.
/// Both run on the Neural Engine via FluidAudio; models download on first use.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var asr: AsrManager?
    private var diarizer: DiarizerManager?
    private var offlineDiarizer: OfflineDiarizerManager?

    /// "Who spoke when" for a whole recording. The offline pipeline (pyannote segmentation, WeSpeaker
    /// embeddings, VBx clustering) sees the full recording at once; FluidAudio reports about 12%
    /// diarization error for it against about 30% for the streaming DiarizerManager. Off by default:
    /// on our test meetings it found one speaker more and switched speakers far more often, and
    /// without knowing who was on those calls it is not clear which is right.
    static let offlineDiarizerKey = "diarizer.offline"
    static var useOfflineDiarizer: Bool { UserDefaults.standard.bool(forKey: offlineDiarizerKey) }

    private func speakerSegments(_ samples: [Float]) async throws -> [TimedSpeakerSegment] {
        if Self.useOfflineDiarizer {
            if offlineDiarizer == nil {
                // One speaker per moment: overlapping turns would be transcribed twice.
                var config = OfflineDiarizerConfig.default
                config.postProcessing.exclusiveSegments = true
                let manager = OfflineDiarizerManager(config: config)
                try await manager.prepareModels()
                offlineDiarizer = manager
            }
            if let offlineDiarizer { return try await offlineDiarizer.process(audio: samples).segments }
        }
        guard let diarizer else { throw SpeechError.notLoaded }
        return try diarizer.performCompleteDiarization(samples, sampleRate: 16_000).segments
    }
    private var whisper: WhisperKit?
    private var whisperModelName: String?
    private var qwen3: Qwen3AsrManager?
    private var hinglish: WhisperKit?
    private var hinglishEngine: ASREngine?

    /// Drops loaded models so the next use re-downloads and re-loads them (after a delete in Settings).
    func unload(_ engine: ASREngine?) {
        switch engine {
        case .parakeet: asr = nil
        case .whisper: whisper = nil; whisperModelName = nil
        case .qwen3: qwen3 = nil
        case .tara, .apex: if hinglishEngine == engine { hinglish = nil; hinglishEngine = nil }
        case .mix: hinglish = nil; hinglishEngine = nil; asr = nil
        case nil: asr = nil; whisper = nil; whisperModelName = nil; qwen3 = nil; hinglish = nil; hinglishEngine = nil; diarizer = nil; offlineDiarizer = nil
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
        } else if engine == .tara || engine == .apex || engine == .mix {
            let model = engine.hinglishModel
            if hinglish == nil || hinglishEngine != model {
                hinglish = nil
                status("Loading \(model == .tara ? "Tara" : "Apex") (the first load after an update takes a few minutes)")
                hinglish = try await HinglishWhisper.load(model)
                hinglishEngine = model
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
        if engine == .mix, asr == nil {
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

    /// - context: glossary text for recognizers that accept it (Qwen3-ASR); see `Vocabulary`.
    func transcribe(file: URL, knownVoices: [KnownVoice] = [], context: String? = nil,
                    report: @escaping ProgressReport) async throws -> TranscriptResult {
        let engine = AppSettings.engine
        let status: @Sendable (String) -> Void = { report(nil, $0) }
        var t = Date()
        try await prepare(engine: engine, status: status)
        NSLog("[timing] load models: %.1fs", Date().timeIntervalSince(t)); t = Date()
        guard let diarizer else { throw SpeechError.notLoaded }

        status("Reading audio")
        let channels = try Self.loadChannels(file)
        let duration = Double(channels[0].count) / 16_000

        // Two-channel recording (left = you, right = the call): transcribe each side on its own.
        if channels.count == 2, engine == .parakeet, let asr {
            let mic = Self.normalize(Self.suppressEcho(mic: channels[0], system: channels[1]))
            let call = Self.normalize(channels[1])
            report(0, "Transcribing your side")
            await asr.setWindowHandler { p in report(0.45 * Double(p.index + 1) / Double(max(1, p.windowCount)), "Transcribing your side") }
            var state = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let mine = try await asr.transcribe(mic, decoderState: &state)
            let myPieces = Self.pieces(from: mine)
            let myLines = Self.merge(pieces: myPieces, fullText: mine.text, speakers: [], duration: duration, fixedSpeaker: "You")

            report(0.45, "Transcribing the call")
            await asr.setWindowHandler { p in report(0.45 + 0.45 * Double(p.index + 1) / Double(max(1, p.windowCount)), "Transcribing the call") }
            var state2 = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let theirs = try await asr.transcribe(call, decoderState: &state2)
            await asr.setWindowHandler(nil)

            report(0.92, "Identifying speakers")
            let diar = (try? await speakerSegments(call)) ?? []
            let (names, vectors) = Self.nameSpeakers(diar, knownVoices: knownVoices, singleLabel: "Them")
            let theirLines = Self.merge(pieces: Self.pieces(from: theirs), fullText: theirs.text, speakers: diar,
                                        duration: duration, names: names)
            let lines = (myLines + theirLines).sorted { $0.start < $1.start }
            return TranscriptResult(lines: lines, speakerVectors: vectors)
        }

        // Mono recording or imported file: mix channels and run the single-track pipeline.
        let samples = channels.count == 1 ? channels[0] : Self.mixDown(channels)

        if engine.readsByTurns {
            if channels.count == 2 {
                let mic = Self.normalize(Self.suppressEcho(mic: channels[0], system: channels[1]))
                let call = Self.normalize(channels[1])
                t = Date()
                defer { NSLog("[timing] call side (speakers + text): %.1fs", Date().timeIntervalSince(t)) }
                let mine = try await transcribeByTurns(samples: mic, duration: duration, fixedSpeaker: "You",
                                                       knownVoices: [], context: context, status: status)
                NSLog("[timing] your side (text): %.1fs", Date().timeIntervalSince(t)); t = Date()
                let theirs = try await transcribeByTurns(samples: call, duration: duration, fixedSpeaker: nil,
                                                         knownVoices: knownVoices, singleLabel: "Them", context: context, status: status)
                let lines = (mine.lines + theirs.lines).sorted { $0.start < $1.start }
                return TranscriptResult(lines: lines, speakerVectors: theirs.speakerVectors)
            }
            return try await transcribeByTurns(samples: samples, duration: duration, fixedSpeaker: nil,
                                               knownVoices: knownVoices, singleLabel: nil, context: context, status: status)
        }

        let pieces: [TimedPiece]
        let fullText: String
        switch engine {
        case .qwen3, .tara, .apex, .mix:
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
            // Whisper conditions on prompt tokens as "previous text"; a glossary there nudges spellings.
            if let context, let tokenizer = whisper.tokenizer {
                let ids = tokenizer.encode(text: " " + context).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                options.promptTokens = Array(ids.suffix(150))
                options.usePrefillPrompt = true
            }
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
            speakers = try await speakerSegments(samples)
        } catch {
            NSLog("Diarization failed, continuing without speakers: \(error)")
            speakers = []
        }
        let (names, vectors) = Self.nameSpeakers(speakers, knownVoices: knownVoices, singleLabel: nil)
        var lines = Self.merge(pieces: pieces, fullText: fullText, speakers: speakers, duration: duration, names: names)
        if engine == .whisper { lines = lines.filter { Self.matchesExpectedScripts($0.text) } }
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

    /// Diarize first, then transcribe each speaker turn (capped at 15 s, split at pauses) on its own.
    /// Timing and speaker come from the diarizer; the recognizer only has to produce text.
    private func transcribeByTurns(samples: [Float], duration: Double, fixedSpeaker: String?, knownVoices: [KnownVoice],
                                   singleLabel: String? = nil, context: String? = nil,
                                   status: @escaping @Sendable (String) -> Void) async throws -> TranscriptResult {
        let engine = AppSettings.engine
        guard let diarizer else { throw SpeechError.notLoaded }
        var segments: [TimedSpeakerSegment] = []
        var names: [String: String] = [:]
        var vectors: [String: [Float]] = [:]
        var energyTurns: [(Double, Double)] = []
        if fixedSpeaker == nil {
            status("Identifying speakers")
            let td = Date()
            segments = (try? await speakerSegments(samples)) ?? []
            NSLog("[timing] speakers: %.1fs", Date().timeIntervalSince(td))
            (names, vectors) = Self.nameSpeakers(segments, knownVoices: knownVoices, singleLabel: singleLabel)
        } else {
            energyTurns = Self.speechRuns(samples)
        }

        // Build chunks: consecutive same-speaker turns joined up to 15 s; silence gaps over 2 s
        // that the diarizer did not label become unlabelled chunks so no speech is skipped.
        // Qwen3's decoder holds 512 tokens and audio takes 13 per second: a 25 s chunk left about
        // 170 tokens for text, so long Hindi turns came back cut off mid-sentence. 15 s leaves
        // room for the glossary and about 200 tokens of text. WhisperKit stops each read at 223
        // tokens: Tara's Devanagari needs about 8 tokens a second (18 s pieces), Apex's romanized
        // text about 5 (25 s).
        struct Chunk { var start: Double; var end: Double; var speaker: String? }
        let maxLen = engine == .qwen3 ? 15.0 : engine == .tara ? 18.0 : 25.0
        var chunks: [Chunk] = []
        var cursor = 0.0
        if let fixedSpeaker {
            for (s, e) in energyTurns {
                if var last = chunks.last, s - last.end < 1, e - last.start <= maxLen {
                    last.end = e; chunks[chunks.count - 1] = last
                } else {
                    chunks.append(Chunk(start: s, end: e, speaker: fixedSpeaker))
                }
            }
            cursor = duration
        }
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
        if fixedSpeaker == nil, duration - cursor > 2 { chunks.append(Chunk(start: cursor, end: duration, speaker: nil)) }
        if chunks.isEmpty, fixedSpeaker == nil { chunks = [Chunk(start: 0, end: duration, speaker: nil)] }
        // Split anything still longer than the window at its quietest moment, not mid-word.
        var pieces: [Chunk] = []
        for c in chunks {
            var s = c.start
            while c.end - s > maxLen {
                let cut = Self.quietestPoint(in: samples, from: s + maxLen * 0.4, to: s + maxLen)
                pieces.append(Chunk(start: s, end: cut, speaker: c.speaker))
                s = cut
            }
            pieces.append(Chunk(start: s, end: c.end, speaker: c.speaker))
        }

        var lines: [TranscriptLine] = []
        let language = AppSettings.language
        let name = engine == .qwen3 ? "Qwen3" : engine == .tara ? "Tara" : engine == .mix ? "Apex + Parakeet" : "Apex"
        for (i, c) in pieces.enumerated() where c.end - c.start >= 0.8 {
            status("Transcribing with \(name) (\(i + 1)/\(pieces.count))")
            let lo = max(0, Int((c.start - 0.2) * 16_000)), hi = min(samples.count, Int((c.end + 0.2) * 16_000))
            guard hi > lo else { continue }
            let chunk = Array(samples[lo..<hi])
            guard Self.voicedRatio(chunk) >= 0.25 else { continue }          // mostly silence: skip
            if engine != .qwen3 {
                // Tara and Apex spell English terms well on their own; a glossary prompt made Whisper
                // insert terms that were not said, so they read the audio once, without one.
                guard let hinglish, let raw = await HinglishWhisper.read(hinglish, Self.boost(chunk), engine: engine.hinglishModel) else { continue }
                var clean = Self.collapseRepeats(raw)
                guard Self.matchesExpectedScripts(clean) else { continue }
                if engine == .mix, let english = await englishReading(of: chunk, apex: clean) { clean = english }
                lines.append(TranscriptLine(start: c.start, end: c.end, speaker: c.speaker, text: clean))
                continue
            }
            guard let qwen3 else { throw SpeechError.notLoaded }
            // Two readings when there is a glossary: plain (faithful) and hinted (better spellings).
            let plain = await readQwen3(qwen3, chunk, language: language, context: nil)
            let hinted = context == nil ? nil : await readQwen3(qwen3, chunk, language: language, context: context)
            guard let text = plain ?? hinted else { continue }
            lines.append(TranscriptLine(start: c.start, end: c.end, speaker: c.speaker, text: text,
                                        altText: plain == nil || hinted == plain ? nil : hinted))
        }
        return TranscriptResult(lines: Self.dedupeOverlaps(lines), speakerVectors: vectors)
    }

    // MARK: - Mix: Parakeet for English stretches

    /// Mix engine: Parakeet's reading of a piece when that piece is English. Apex romanizes English
    /// terms and numbers into Hinglish ("Confidence par" for Confluence, "13 thousand" for thirteen
    /// screens); Parakeet keeps them exact but turns Hindi into English-sounding nonsense. A piece is
    /// taken as English when Apex's reading has almost no Hindi words and Parakeet's reading is
    /// almost all dictionary English and not much shorter. Nil keeps Apex's reading.
    private func englishReading(of chunk: [Float], apex: String) async -> String? {
        let hindi = Self.hindiShare(apex)
        guard hindi <= 0.12, let asr, chunk.count >= 8_000,
              let state = try? TdtDecoderState(decoderLayers: await asr.decoderLayerCount) else { return nil }
        var decoder = state
        guard let result = try? await asr.transcribe(chunk, decoderState: &decoder) else { return nil }
        let parakeet = Self.collapseRepeats(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let english = await MainActor.run { Self.englishShare(parakeet) }
        let words = { (t: String) in t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count }
        let take = english >= 0.8 && words(parakeet) * 10 >= words(apex) * 7
        NSLog("[mix] %@ hindi=%.2f english=%.2f | apex: %@ | parakeet: %@", take ? "PARAKEET" : "apex", hindi, english, apex, parakeet)
        return take ? parakeet : nil
    }

    /// Common Hindi words as Apex romanizes them. Words that are also everyday English ("to", "do",
    /// "main", "so", "hi", "me", "the") are left out.
    static let hindiWords: Set<String> = [
        "hai", "hain", "ho", "hoga", "hogi", "honge", "hota", "hoti", "hote", "tha", "thi", "ka", "ki", "ke",
        "ko", "se", "mein", "men", "pe", "aur", "toh", "bhi", "nahin", "nahi", "kya", "kyon", "kyonki", "jo", "jab",
        "vah", "yah", "ye", "vo", "voh", "ham", "hamen", "hamaara", "hamaari", "hamaare", "aap", "aapka", "aapki",
        "aapke", "aapko", "mera", "mere", "meri", "mujhe", "tum", "tumhe", "usko", "uska", "uski", "uske", "unka",
        "iska", "iski", "iske", "isko", "ismen", "usmen", "kar", "karna", "karke", "karenge", "karte", "karta",
        "karo", "kiya", "raha", "rahi", "rahe", "rahega", "gaya", "gai", "gaye", "jaega", "jaata", "jaati", "lagta",
        "lekin", "agar", "phir", "abhi", "sab", "saare", "saari", "ek", "thik", "theek", "haan", "achchha", "matlab",
        "vahaan", "yahaan", "jaise", "waisa", "kuchh", "kaise", "kitna", "kitne", "lie", "liye", "sakte", "sakta",
        "chaahie", "chahiye", "dekho", "dekhna", "bolo", "baad", "pahle", "saath", "hisaab", "vaala", "vaali", "vaale",
    ]

    static func hindiShare(_ text: String) -> Double {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return 1 }
        return Double(words.filter { hindiWords.contains($0) }.count) / Double(words.count)
    }

    /// Share of words the English spell checker accepts. Acronyms (RFID) and words with digits count
    /// as English; Parakeet's renderings of Hindi ("Pele", "gantri vanti") mostly do not.
    @MainActor static func englishShare(_ text: String) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return 0 }
        let checker = NSSpellChecker.shared
        let ok = words.filter { word in
            if word.contains(where: \.isNumber) || (word.count > 1 && word == word.uppercased()) { return true }
            return checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }.count
        return Double(ok) / Double(words.count)
    }

    /// One recognizer pass over a chunk, cleaned and filtered; nil when nothing usable came back.
    private func readQwen3(_ qwen3: Qwen3AsrManager, _ chunk: [Float], language: String?, context: String?) async -> String? {
        let text = (try? await qwen3.transcribe(audioSamples: chunk, language: language, context: context)) ?? ""
        let clean = Self.collapseRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard clean.contains(where: { $0.isLetter || $0.isNumber }), Self.matchesExpectedScripts(clean) else { return nil }
        return clean
    }

    /// Rejects recognizer output written in a script the meeting is not expected to contain
    /// (short, near-silent chunks make autoregressive models hallucinate Chinese, Korean, ...).
    static func matchesExpectedScripts(_ text: String) -> Bool {
        let allowed = AppSettings.expectedScripts
        var ok = 0, bad = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            let v = scalar.value
            let script: String
            switch v {
            case 0x0041...0x024F, 0x1E00...0x1EFF: script = "latin"
            case 0x0900...0x097F: script = "devanagari"
            case 0x0600...0x06FF: script = "arabic"
            case 0x0400...0x04FF: script = "cyrillic"
            case 0x0A80...0x0AFF: script = "gujarati"
            case 0x0A00...0x0A7F: script = "gurmukhi"
            case 0x0B80...0x0BFF: script = "tamil"
            case 0x0C00...0x0C7F: script = "telugu"
            case 0x0C80...0x0CFF: script = "kannada"
            case 0x0D00...0x0D7F: script = "malayalam"
            case 0x0980...0x09FF: script = "bengali"
            case 0x3040...0x30FF: script = "japanese"
            case 0xAC00...0xD7AF: script = "korean"
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: script = "chinese"
            default: script = "other"
            }
            if allowed.contains(script) { ok += 1 } else { bad += 1 }
        }
        return ok + bad == 0 || Double(bad) / Double(ok + bad) < 0.3
    }

    /// The start (in seconds) of the quietest 300 ms between two times, where a cut loses the least.
    static func quietestPoint(in samples: [Float], from start: Double, to end: Double) -> Double {
        let frame = 320, window = 15                     // 20 ms frames, 300 ms window
        let lo = max(0, Int(start * 16_000) / frame), hi = min(samples.count / frame, Int(end * 16_000) / frame)
        guard hi - lo > window else { return end }
        var energy = [Float](repeating: 0, count: hi - lo)
        for k in lo..<hi {
            var e: Float = 0
            for j in k * frame..<(k + 1) * frame { e += samples[j] * samples[j] }
            energy[k - lo] = e
        }
        var sum = energy[0..<window].reduce(0, +), best = sum, bestAt = 0
        for k in window..<energy.count {
            sum += energy[k] - energy[k - window]
            if sum < best { best = sum; bestAt = k - window + 1 }
        }
        return Double(lo + bestAt + window / 2) * 0.02
    }

    /// Fraction of 20 ms frames with speech energy, used to skip chunks that are mostly silence.
    static func voicedRatio(_ samples: [Float]) -> Double {
        let frame = 320
        guard samples.count >= frame else { return 0 }
        var voiced = 0, total = 0
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<i + frame { e += samples[j] * samples[j] }
            if e / Float(frame) > 0.0004 { voiced += 1 }
            total += 1
            i += frame
        }
        return Double(voiced) / Double(total)
    }

    /// Drops a line that largely repeats an overlapping earlier line (overlapping diarizer turns).
    static func dedupeOverlaps(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let words = Set(line.text.lowercased().split(separator: " "))
            var duplicate = false
            for prev in out.suffix(3) {
                let overlap = min(line.end, prev.end) - max(line.start, prev.start)
                guard overlap > 0, overlap / max(0.1, line.end - line.start) > 0.5 else { continue }
                let other = Set(prev.text.lowercased().split(separator: " "))
                let jaccard = Double(words.intersection(other).count) / Double(max(1, words.union(other).count))
                if jaccard > 0.5 { duplicate = true; break }
            }
            if !duplicate { out.append(line) }
        }
        return out
    }

    /// Runs of speech by energy: 20 ms frames above a floor, gaps under 0.8 s bridged, runs under 0.4 s dropped.
    static func speechRuns(_ samples: [Float]) -> [(Double, Double)] {
        let frame = 320
        var active: [Bool] = []
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<i + frame { e += samples[j] * samples[j] }
            active.append(e / Float(frame) > 0.0004)     // about -34 dBFS after normalization
            i += frame
        }
        var runs: [(Double, Double)] = []
        var start: Int? = nil
        var silence = 0
        for (k, on) in active.enumerated() {
            if on {
                if start == nil { start = k }
                silence = 0
            } else if let s = start {
                silence += 1
                if silence >= 40 {                              // 0.8 s of silence closes the run
                    runs.append((Double(s) * 0.02, Double(k - silence + 1) * 0.02))
                    start = nil; silence = 0
                }
            }
        }
        if let s = start { runs.append((Double(s) * 0.02, Double(active.count) * 0.02)) }
        return runs.filter { $0.1 - $0.0 >= 0.4 }
    }

    /// Brings quiet channels up: scales so the loud 5% of 20 ms frames sit near -14 dBFS, gain capped at 30x.
    static func normalize(_ samples: [Float]) -> [Float] {
        let frame = 320
        var rms: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<i + frame { e += samples[j] * samples[j] }
            rms.append((e / Float(frame)).squareRoot())
            i += frame
        }
        guard !rms.isEmpty else { return samples }
        let sorted = rms.sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        guard loud > 0.0005 else { return samples }
        let gain = min(30, 0.2 / loud)
        guard gain > 1.1 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }

    /// Scales one piece so its peak sits at 90% of full scale (gain capped at 30x), the level the
    /// Whisper fine-tunes were tested at.
    static func boost(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let gain = min(30, 0.9 / peak)
        return gain > 1.05 ? samples.map { max(-1, min(1, $0 * gain)) } : samples
    }

    /// Autoregressive recognizers sometimes loop ("एक existing plaza हैं, और एक existing plaza हैं, ...").
    /// Collapse any run of 1 to 12 words repeated three or more times in a row down to one copy.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < words.count {
            var collapsed = false
            for n in 1...12 where i + 3 * n <= words.count {
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
