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

    static var cleanupEnabled: Bool { UserDefaults.standard.object(forKey: cleanupKey) as? Bool ?? true }
    static var readScreenEnabled: Bool { UserDefaults.standard.object(forKey: screenKey) as? Bool ?? true }

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
