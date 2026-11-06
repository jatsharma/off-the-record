import Foundation
import GRDB

/// The team glossary: names and technical terms the recognizer, the clean-up pass and the
/// notes writer should spell exactly. Three sources, most specific first:
/// 1. terms read off the screen during this meeting (slides, code, dashboards),
/// 2. the list in Settings ▸ Vocabulary, which also collects words the user typed when
///    correcting a transcript line.
enum Vocabulary {
    static let termsKey = "vocab.terms"
    static let cleanupKey = "vocab.cleanup"        // run the LLM clean-up pass (default on)
    static let screenKey = "vocab.readScreen"      // read on-screen text while recording (default on)
    static let correctionsKey = "vocab.corrections" // "heard → wanted" lines learned from line edits
    static let notesFixesKey = "vocab.notesFixes"   // "wrong → right" lines learned from notes edits

    static var cleanupEnabled: Bool { flag(cleanupKey, default: true) }
    static var readScreenEnabled: Bool { flag(screenKey, default: true) }

    /// `bool(forKey:)` also understands "NO"/"YES" strings from launch arguments, which `as? Bool` does not.
    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    /// The Settings list: one term per line (commas also separate).
    static var manual: [String] {
        parse(UserDefaults.standard.string(forKey: termsKey) ?? "")
    }

    static func parse(_ raw: String) -> [String] {
        unique(raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Adds terms to the Settings list, keeping the user's order and skipping ones already there.
    static func learn(_ terms: [String]) {
        let existing = manual
        let known = Set(existing.map { $0.lowercased() })
        let added = unique(terms).filter { !known.contains($0.lowercased()) }
        guard !added.isEmpty else { return }
        UserDefaults.standard.set((existing + added).joined(separator: "\n"), forKey: termsKey)
    }

    /// Terms for one meeting: this meeting's screen terms, then the Settings list.
    static func terms(for meetingId: String) -> [String] {
        let texts = (try? AppDatabase.shared.pool.read { db in
            try ScreenText.filter(Column("meetingId") == meetingId).fetchAll(db).map(\.text)
        }) ?? []
        return unique(screenTerms(texts) + manual)
    }

    /// Context for the recognizer: a short comma-separated list. The recognizer has little room
    /// (a few dozen tokens), so the most specific terms come first and the list is capped.
    static func recognizerContext(for meetingId: String) -> String? {
        let list = terms(for: meetingId).prefix(40)
        return list.isEmpty ? nil : list.joined(separator: ", ")
    }

    // MARK: Learned corrections

    /// Recognizer mishearings and what they should be ("dixcheck → DexScreener"), one per line.
    /// Learned when a transcript line is corrected; editable in Settings ▸ Vocabulary.
    static var corrections: [(heard: String, wanted: String)] { pairs(forKey: correctionsKey) }

    private static func pairs(forKey key: String) -> [(heard: String, wanted: String)] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .components(separatedBy: .newlines)
            .compactMap { line in
                let arrow: String = line.contains("→") ? "→" : "->"
                let parts: [String] = line.components(separatedBy: arrow)
                guard parts.count == 2 else { return nil }
                let heard = parts[0].trimmingCharacters(in: .whitespaces), wanted = parts[1].trimmingCharacters(in: .whitespaces)
                return heard.isEmpty || wanted.isEmpty ? nil : (heard, wanted)
            }
    }

    /// Records the misheard stretches a hand correction replaced with a name or term: up to three
    /// words each side, where the new words contain a term ("desk screener" → "DexScreener").
    /// Ordinary rewording is not learned.
    static func learnCorrections(from old: String, to new: String) {
        var pairs: [String] = []
        for (heard, wanted) in wordDiff(words(old), words(new)) {
            guard (1...3).contains(heard.count), (1...3).contains(wanted.count) else { continue }
            let h = heard.joined(separator: " ").lowercased(), w = wanted.joined(separator: " ")
            guard h.count >= 3, h != w.lowercased(),
                  wanted.contains(where: { looksLikeTerm($0, strict: false) }) || manual.contains(where: { $0.lowercased() == w.lowercased() })
            else { continue }
            pairs.append("\(h) → \(w)")
        }
        guard !pairs.isEmpty else { return }
        let existing = UserDefaults.standard.string(forKey: correctionsKey) ?? ""
        let known = Set(corrections.map { $0.heard.lowercased() })
        let added = pairs.filter { pair in !known.contains(pair.components(separatedBy: " → ")[0]) }
        guard !added.isEmpty else { return }
        let lines: [String] = existing.isEmpty ? added : [existing] + added
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: correctionsKey)
    }

    /// Applies the learned corrections to a line: whole words only, any case.
    static func applyCorrections(_ text: String) -> String {
        var out = text
        for (heard, wanted) in corrections {
            let body: String = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            let pattern: String = "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: wanted))
        }
        return out
    }

    /// Differing stretches between two word lists, aligned by longest common subsequence
    /// (case and punctuation ignored).
    static func wordDiff(_ a: [String], _ b: [String]) -> [([String], [String])] {
        guard a.count <= 400, b.count <= 400 else { return [] }
        let key: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let ka = a.map(key), kb = b.map(key)
        var lcs = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var gaps: [([String], [String])] = []
        var gapA: [String] = [], gapB: [String] = []
        var i = 0, j = 0
        func flush() { if !gapA.isEmpty || !gapB.isEmpty { gaps.append((gapA, gapB)) }; gapA = []; gapB = [] }
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] { flush(); i += 1; j += 1 }
            else if j < kb.count, (i == ka.count || lcs[i][j + 1] >= lcs[i + 1][j]) { gapB.append(b[j]); j += 1 }
            else { gapA.append(a[i]); i += 1 }
        }
        flush()
        return gaps
    }

    // MARK: Learning from notes edits

    /// Word fixes made in the notes ("countries → gantries", "thirteen students → thirteen screens"),
    /// editable in Settings ▸ Vocabulary. The notes model gets them as hints for every later meeting;
    /// it applies one only where the transcript uses the word in that sense.
    static var notesFixes: [(heard: String, wanted: String)] { pairs(forKey: notesFixesKey) }

    /// What one notes edit taught, so the page can say so and offer Undo.
    struct NotesLesson: Equatable {
        var fixes: [Fix] = []
        var terms: [String] = []
        var isEmpty: Bool { fixes.isEmpty && terms.isEmpty }
        struct Fix: Equatable, Hashable { var heard: String; var wanted: String }
    }

    /// Learns from one edited line of notes. Only small swaps count (up to three words replaced by
    /// up to three): a rewritten sentence is a content edit, not a mishearing. A fix whose new words
    /// sound like the old ones ("countries" → "gantries") also joins the glossary, so the transcript
    /// clean-up can restore it in later recordings; new names and terms join it as well.
    @discardableResult
    static func learnFromNotesEdit(old: String, new: String) -> NotesLesson {
        var lesson = NotesLesson()
        let a = words(old), b = words(new)
        for (heard, wanted) in wordDiff(a, b) {
            guard (1...3).contains(heard.count), (1...3).contains(wanted.count) else { continue }
            let h = heard.joined(separator: " "), w = wanted.joined(separator: " ")
            guard h.lowercased() != w.lowercased() else {
                // Only the spelling's case changed ("postgres" → "Postgres"): a term, not a fix.
                lesson.terms += wanted.filter { looksLikeTerm($0, strict: false) }
                continue
            }
            // Ignore swaps of short everyday words ("a" → "the") and of numbers alone.
            guard wanted.contains(where: { $0.count >= 4 && $0.contains(where: \.isLetter) }) else { continue }
            lesson.fixes.append(.init(heard: h.lowercased(), wanted: w))
            if Phonetic.supports(term: w, heardKeys: Phonetic.keys(of: h)) { lesson.terms.append(w) }
        }
        lesson.terms += newTerms(from: old, to: new)
        let known = Set(manual.map { $0.lowercased() })
        lesson.terms = unique(lesson.terms).filter { !known.contains($0.lowercased()) }
        let knownFixes = Set(notesFixes.map { $0.heard.lowercased() })
        lesson.fixes = lesson.fixes.filter { !knownFixes.contains($0.heard) }
        guard !lesson.isEmpty else { return lesson }
        learn(lesson.terms)
        if !lesson.fixes.isEmpty {
            let existing = UserDefaults.standard.string(forKey: notesFixesKey) ?? ""
            let added = lesson.fixes.map { "\($0.heard) → \($0.wanted)" }
            UserDefaults.standard.set((existing.isEmpty ? added : [existing] + added).joined(separator: "\n"), forKey: notesFixesKey)
        }
        return lesson
    }

    /// Takes back what one edit taught (the banner's Undo).
    static func forget(_ lesson: NotesLesson) {
        let terms = Set(lesson.terms.map { $0.lowercased() })
        UserDefaults.standard.set(manual.filter { !terms.contains($0.lowercased()) }.joined(separator: "\n"), forKey: termsKey)
        let fixes = Set(lesson.fixes.map(\.heard))
        let kept = (UserDefaults.standard.string(forKey: notesFixesKey) ?? "").components(separatedBy: .newlines)
            .filter { line in !fixes.contains(where: { line.lowercased().hasPrefix($0 + " →") || line.lowercased().hasPrefix($0 + " ->") }) }
        UserDefaults.standard.set(kept.joined(separator: "\n"), forKey: notesFixesKey)
    }

    /// The fixes as a hint block for the notes prompt.
    static func notesFixesBlock() -> String {
        let fixes = notesFixes
        guard !fixes.isEmpty else { return "" }
        return "\nThe speech recognizer is known to mishear some words; earlier notes were corrected like this " +
            "(write the right-hand word where the transcript has the left-hand one in that sense): " +
            fixes.map { "\"\($0.heard)\" → \"\($0.wanted)\"" }.joined(separator: ", ") + "\n"
    }

    // MARK: Learning from edits

    /// Words in a corrected line that were not in the original and look like names or technical
    /// terms (a capital letter or digit inside, or an acronym), e.g. "TimescaleDB", "Solana", "RPC".
    static func newTerms(from old: String, to new: String) -> [String] {
        let before = Set(words(old).map { $0.lowercased() })
        return unique(words(new).filter { !before.contains($0.lowercased()) && looksLikeTerm($0, strict: false) })
    }

    // MARK: Screen text

    /// Candidate terms from OCR text, most frequent first. Keeps tokens that look like product or
    /// technical names (CamelCase, acronyms, words with digits) and capitalised words seen at least
    /// twice; drops common English words.
    static func screenTerms(_ texts: [String], limit: Int = 30) -> [String] {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for text in texts {
            for word in words(text) where looksLikeTerm(word, strict: true) {
                let key = word.lowercased()
                counts[key, default: 0] += 1
                if spelling[key] == nil { spelling[key] = word }
            }
        }
        return counts
            .filter { key, count in
                let word = spelling[key] ?? key
                return count >= 2 || hasInnerCapital(word) || word.contains(where: \.isNumber)
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { spelling[$0.key] }
    }

    // MARK: Helpers

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-_")) }
            .filter { $0.count >= 2 }
    }

    private static func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    private static func looksLikeTerm(_ word: String, strict: Bool) -> Bool {
        guard word.unicodeScalars.allSatisfy({ $0.isASCII }), word.count <= 32, !word.contains("_"),
              word.contains(where: \.isLetter), !common.contains(word.lowercased()) else { return false }
        if hasInnerCapital(word) { return true }                                   // TimescaleDB, DexScreener
        if word.count >= 2, word.count <= 6, word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return true }  // RPC, SQL, S3
        if word.contains(where: \.isNumber), word.count >= 3 { return true }       // web3, gpt4
        if let first = word.first, first.isUppercase, word.count >= 4 { return true }  // Solana, Postgres
        return !strict && word.count >= 4 && word.first?.isUppercase == true
    }

    private static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Words that are capitalised on screens all the time but are not terms.
    private static let common: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "your", "you", "are", "not", "but", "all", "new", "file",
        "edit", "view", "window", "help", "open", "close", "save", "search", "share", "settings", "home", "today",
        "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
        "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
        "meeting", "meetings", "mute", "unmute", "camera", "video", "chat", "participants", "leave", "join", "recording",
        "screen", "more", "options", "done", "cancel", "next", "back", "show", "hide", "start", "stop", "add", "remove",
        "delete", "update", "create", "name", "type", "date", "time", "status", "total", "page", "pages", "inbox",
        "untitled", "welcome", "loading", "error", "warning", "info", "notes", "note", "terminal", "finder", "safari",
        "chrome", "google", "slack", "zoom", "teams", "what", "when", "where", "which", "who", "why", "how", "yes", "no",
        "ok", "am", "pm", "id", "url", "http", "https", "www", "com", "org", "io",
    ]
}
