import Foundation

/// A constrained LLM pass between recognition and notes. Recognizers write Hinglish English terms
/// phonetically ("बोस क्रेस" for Postgres) or mishear them; this pass rewrites each line in
/// romanized Hinglish and restores terms from the glossary where the sound matches. It edits
/// line by line with numbered ids, so every result maps back to its segment; anything that does
/// not come back cleanly keeps the recognizer's text.
enum TranscriptCleaner {
    struct Line {
        let id: Int
        let speaker: String?
        let text: String
        /// The recognizer's reading with glossary hints, when it differed from `text`.
        var hinted: String? = nil
    }

    static let system = """
    You correct speech-recognition transcripts of Indian software teams. You never add, drop or \
    summarise content; you only fix how words are written. Output only the numbered lines.
    """

    /// Returns corrected text by line id. Lines missing from the model's answer are absent.
    ///
    /// Small models do not reliably refuse a glossary term the audio did not support, so each
    /// result is checked in code: a glossary term that appears in the output must sound like a
    /// word the plain recognizer reading has (`Phonetic.supports`). A line that fails is redone
    /// from the plain reading only, and if it still fails, without the glossary at all.
    @MainActor
    static func clean(_ lines: [Line], glossary: [String], client: OllamaClient, model: String, contextTokens: Int,
                      progress: (Double) -> Void) async throws -> [Int: String] {
        var out: [Int: String] = [:]
        let byId = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let position = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element.id, $0.offset) })
        // Only lines the pass could change go to the model; the rest would come back as they are.
        let todo = lines.filter { mayChange($0, glossary: glossary) }
        AppLog.write(String(format: "[clean-up] %d of %d lines can change", todo.count, lines.count))
        let ask = { (batch: [Line], context: [Line], glossary: [String]) in
            try await Self.ask(batch, context: context, glossary: glossary, client: client, model: model, contextTokens: contextTokens)
        }
        let batches = stride(from: 0, to: todo.count, by: 25).map { Array(todo[$0..<min($0 + 25, todo.count)]) }
        for (i, batch) in batches.enumerated() {
            progress(Double(i) / Double(max(1, batches.count)))
            // A little earlier context helps with words split across lines; it is not rewritten.
            let first = batch.first.flatMap { position[$0.id] } ?? 0
            let before = Array(lines[max(0, first - 3)..<first])
            var result = try await ask(batch, before, glossary)

            var failing = batch.filter { line in result[line.id].map { !supported($0, by: line, glossary: glossary) } ?? false }
            if !failing.isEmpty {
                let plainOnly = failing.map { Line(id: $0.id, speaker: $0.speaker, text: $0.text) }
                result.merge(try await ask(plainOnly, [], glossary)) { $1 }
                failing = failing.filter { line in result[line.id].map { !supported($0, by: line, glossary: glossary) } ?? false }
            }
            if !failing.isEmpty {
                let plainOnly = failing.map { Line(id: $0.id, speaker: $0.speaker, text: $0.text) }
                result.merge(try await ask(plainOnly, [], [])) { $1 }
            }
            for (id, text) in result {
                guard let line = byId[id] else { continue }
                if isLatin(line.text) {
                    // Already romanized (Apex, Parakeet, Whisper): only glossary spellings may change.
                    // Small models otherwise "fix" Hinglish ("beech beech mein" became "backend mein").
                    let merged = termsOnly(original: line.text, cleaned: text, glossary: glossary)
                    if merged != line.text { out[id] = merged }
                } else {
                    // Devanagari is rewritten whole, but never shortened: small models sometimes return
                    // a fragment of a long line. Keep the original then.
                    let before = line.text.split(whereSeparator: \.isWhitespace).count
                    let after = text.split(whereSeparator: \.isWhitespace).count
                    if Double(after) >= Double(before) * 0.7 { out[id] = text }
                }
            }
        }
        progress(1)
        return out
    }

    /// Whether the pass can change a line. Lines in Latin script (Apex, Parakeet, Whisper) only take
    /// glossary terms that sound like words already in them (`termsOnly`); a line with no such word
    /// would come back unchanged, so it is not sent. Other scripts are rewritten whole.
    static func mayChange(_ line: Line, glossary: [String]) -> Bool {
        guard isLatin(line.text) else { return true }
        guard !glossary.isEmpty else { return false }
        let heard = Phonetic.keys(of: line.text)
        return glossary.contains { Phonetic.supports(term: $0, heardKeys: heard) }
    }

    @MainActor
    private static func ask(_ batch: [Line], context: [Line], glossary: [String],
                            client: OllamaClient, model: String, contextTokens: Int) async throws -> [Int: String] {
        var text = ""
        for try await token in client.chat(model: model, system: system,
                                           user: prompt(batch, context: context, glossary: glossary),
                                           contextTokens: contextTokens, temperature: 0) {
            text += token
        }
        return parse(text, expected: Set(batch.map(\.id)))
    }

    /// Mostly Latin letters (romanized Hinglish or English).
    static func isLatin(_ text: String) -> Bool {
        var latin = 0, other = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            if s.value < 0x0250 { latin += 1 } else { other += 1 }
        }
        return latin > 0 && Double(other) / Double(latin + other) < 0.2
    }

    /// Keeps the original words except where the cleaned line put a glossary term in place of a
    /// stretch of them ("desk screener" → "DexScreener", "post crash" → "Postgres"). Word lists are
    /// aligned by longest common subsequence (case and punctuation ignored); a differing stretch is
    /// taken from the cleaned line only if it contains a glossary term that sounds like the original.
    static func termsOnly(original: String, cleaned: String, glossary: [String]) -> String {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 400 else { return original }
        let key: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let ka = a.map(key), kb = b.map(key)
        let terms = glossary.map { ($0, key($0)) }.filter { !$0.1.isEmpty }
        var lcs = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        var gapA: [String] = [], gapB: [String] = []
        func flush() {
            // Take the cleaned words only if they hold a glossary term that sounds like the words
            // they replace ("post crash" ~ Postgres), never for an inserted term or a "Solback" → Solana.
            let joined = gapB.map(key).joined()
            let heard = Phonetic.keys(of: gapA.joined(separator: " "))
            let useCleaned = !gapA.isEmpty && !gapB.isEmpty && terms.contains { term, k in
                joined.contains(k) && Phonetic.supports(term: term, heardKeys: heard)
            }
            out += useCleaned ? gapB : gapA
            gapA = []; gapB = []
        }
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] {
                flush(); out.append(a[i]); i += 1; j += 1
            } else if j < kb.count, (i == ka.count || lcs[i][j + 1] >= lcs[i + 1][j]) {
                gapB.append(b[j]); j += 1
            } else {
                gapA.append(a[i]); i += 1
            }
        }
        flush()
        return out.joined(separator: " ")
    }

    /// True when every glossary term in `output` is backed by the plain reading (`line.text`), so it
    /// was spoken rather than suggested by the glossary: either a similar-sounding word anywhere in
    /// the plain reading, or, when the hinted reading has the term, the plain reading's words at the
    /// same place start with the same sound ("फाइव वेक की" where the hinted reading has "failover
    /// की", but not "database queries" where it has "Redis के queries").
    static func supported(_ output: String, by line: Line, glossary: [String]) -> Bool {
        let lowered = output.lowercased()
        let heard = Phonetic.keys(of: line.text)
        for term in glossary where lowered.contains(term.lowercased()) {
            if line.text.lowercased().contains(term.lowercased()) { continue }
            if Phonetic.supports(term: term, heardKeys: heard) { continue }
            if let hinted = line.hinted, Phonetic.aligned(term: term, plain: line.text, hinted: hinted) { continue }
            return false
        }
        return true
    }

    static func prompt(_ batch: [Line], context: [Line], glossary: [String]) -> String {
        let render: (Line) -> String = { line in
            let who = line.speaker ?? "Unknown"
            guard let hinted = line.hinted else { return "\(line.id)| \(who): \(line.text)" }
            return "\(line.id)| \(who): A: \(line.text)  ||  B: \(hinted)"
        }
        var p = """
        These lines come from a speech recognizer on a Hinglish (Hindi + English) call. Hindi is often \
        written in Devanagari, and English technical words are spelled by sound and often misheard \
        (for example "बोस क्रेस" for "Postgres", "डेस्क्रीनर" for "DexScreener").

        Rewrite every line:
        - Write it in romanized Hinglish (Latin script). Keep Hindi words as Hindi, in Latin letters.
        - Write English words, product names and technical terms in their normal English spelling.
        - Use a glossary term only where the line has a word that sounds like it; most lines contain \
        none. Never insert a term that was not spoken.
        - Do not translate, summarise, merge or drop lines, and do not add notes or question marks for \
        unclear words; write your best reading.
        - Keep each line's number and speaker exactly. Output one line per input line, in the form \
        "number| speaker: text".
        - Some lines have two readings of the same audio, "A: ... || B: ...". A is the recognizer on its \
        own: trust it for what was said. B was made with the glossary as a hint: it spells terms better \
        but sometimes drops words or puts in a glossary term that was not said. Write one line with A's \
        full content; take a term from B only where A has a word at that point that sounds like it. \
        Output only the merged text, never "A:" or "B:".

        """
        if !glossary.isEmpty {
            p += "\nGlossary (spellings this team uses):\n" + glossary.joined(separator: ", ") + "\n"
        }
        if !context.isEmpty {
            p += "\nEarlier lines, for context only (do not output these):\n" + context.map(render).joined(separator: "\n") + "\n"
        }
        p += "\nLines to rewrite:\n" + batch.map(render).joined(separator: "\n")
        return p
    }

    /// Parses "12| Speaker: text" lines, keeping only expected ids and dropping the speaker part.
    static func parse(_ answer: String, expected: Set<Int>) -> [Int: String] {
        var out: [Int: String] = [:]
        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*`"))
            guard let bar = line.firstIndex(of: "|"), let id = Int(line[..<bar].trimmingCharacters(in: .whitespaces)),
                  expected.contains(id) else { continue }
            var body = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            if let colon = body.firstIndex(of: ":"), body.distance(from: body.startIndex, to: colon) <= 24 {
                body = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            body = body.replacingOccurrences(of: "[?]", with: "").replacingOccurrences(of: "  ", with: " ")
            if !body.isEmpty { out[id] = body }
        }
        return out
    }
}

/// Rough sound-alike matching between a glossary term (Latin) and recognizer text (Devanagari or
/// Latin): both are reduced to consonant skeletons with sound classes merged (b/p/f/v, t/d, k/g/q/c,
/// s/z/sh/j, r/l), so "सलाना" and "Solana" both become S-L-N. Good enough to tell "Redis" apart
/// from "database queries"; it is a guard against invented terms, not a recognizer.
enum Phonetic {
    /// Skeletons of each word in the text and of each adjacent word pair (for "elastic search").
    static func keys(of text: String) -> [String] {
        // Split on spaces and punctuation only: Devanagari vowel signs and viramas are not "letters".
        let words = text.split(whereSeparator: { $0.isWhitespace || ($0.isPunctuation && $0 != "-") }).map { skeleton(String($0)) }.filter { !$0.isEmpty }
        var out = words
        for i in 0..<max(0, words.count - 1) { out.append(words[i] + words[i + 1]) }
        return out
    }

    /// A term is supported when some heard word shares its skeleton, or one skeleton starts with
    /// the other over at least three consonants ("times" for TimescaleDB), allowing one mismatch.
    static func supports(term: String, heardKeys: [String]) -> Bool {
        let t = skeleton(term)
        guard t.count >= 2 else { return true }      // too short to judge
        for h in heardKeys where h.count >= 2 {
            if h == t { return true }
            guard h.count >= 3 else { continue }
            // Whole term ("पोस्क्रेस" ~ Postgres), or the start of a compound ("times" ~ TimescaleDB).
            let d = min(mismatches(Array(h), Array(t)), mismatches(Array(h), Array(t.prefix(h.count))))
            let allowed = h.count >= 8 ? 2 : h.count >= 5 ? 1 : 0
            if d <= allowed { return true }
        }
        return false
    }

    /// The hinted reading contains `term`; find the plain reading's words between the same
    /// neighbouring words and accept when they begin with the same consonant class and have a
    /// skeleton of similar length.
    static func aligned(term: String, plain: String, hinted: String) -> Bool {
        let a = words(plain), b = words(hinted)
        let first = term.lowercased().split(separator: " ").first.map(String.init) ?? term.lowercased()
        guard let i = b.firstIndex(where: { $0.contains(first) }) else { return false }
        var lo = -1
        if i > 0 {
            guard let prev = b[..<i].last, let at = a.lastIndex(of: prev) else { return false }
            lo = at
        }
        var hi = a.count
        if i + 1 < b.count {
            guard let at = a[(lo + 1)...].firstIndex(of: b[i + 1]) else { return false }
            hi = at
        }
        guard hi - lo - 1 >= 1, hi - lo - 1 <= 3 else { return false }
        let span = skeleton(a[(lo + 1)..<hi].joined())
        let t = skeleton(term)
        guard t.count >= 3, let s0 = span.first, s0 == t.first else { return false }
        return abs(span.count - t.count) <= 2
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || ($0.isPunctuation && $0 != "-") }).map(String.init)
    }

    private static func mismatches(_ a: [Character], _ b: [Character]) -> Int {
        // Edit distance, small inputs only.
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Works on Unicode scalars, not Characters: a Devanagari conjunct such as "स्क्र" is one
    /// Character but three consonants.
    static func skeleton(_ word: String) -> String {
        var out = ""
        func add(_ c: Character) { if out.last != c { out.append(c) } }
        let scalars = Array(word.lowercased().unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = Character(scalars[i])
            let next: Character? = i + 1 < scalars.count ? Character(scalars[i + 1]) : nil
            if c == "s" || c == "c", next == "h" { add("S"); i += 2; continue }
            if c == "p", next == "h" { add("P"); i += 2; continue }
            if c == "c", let n = next, "eiy".contains(n) { add("S"); i += 1; continue }
            if let mapped = latin[c] { add(mapped) }
            else if let mapped = devanagari[scalars[i].value] { add(mapped) }
            i += 1
        }
        return out
    }

    private static let latin: [Character: Character] = [
        "b": "P", "p": "P", "f": "P", "v": "P", "w": "P",
        "t": "T", "d": "T",
        "k": "K", "g": "K", "q": "K", "c": "K", "x": "K",
        "s": "S", "z": "S", "j": "S",
        "r": "R", "l": "R",
        "m": "M", "n": "N", "y": "Y",
        // A plain "h" is left out: in romanized Hindi it is mostly aspiration or a silent vowel
        // marker ("solahna", "bhi", "kahna"), not a consonant the recognizer heard.
    ]

    private static let devanagari: [UInt32: Character] = {
        var m: [UInt32: Character] = [:]
        func set(_ chars: String, _ v: Character) { for s in chars.unicodeScalars { m[s.value] = v } }
        set("कखगघक़ख़ग़", "K"); set("चछजझज़", "S"); set("टठडढतथदधड़ढ़", "T"); set("णन", "N")
        set("पफबभफ़व", "P"); set("म", "M"); set("य", "Y"); set("रलळ", "R"); set("शषस", "S"); set("ह", "H")
        return m
    }()
}
