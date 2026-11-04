import Foundation

/// User-editable settings, stored in UserDefaults.
enum AppSettings {
    static let modelKey = "llm.model"
    static let urlKey = "llm.url"
    static let promptKey = "llm.basePrompt"
    static let contextKey = "llm.contextTokens"

    static let engineKey = "asr.engine"            // "parakeet" | "whisper"
    static let whisperModelKey = "asr.whisperModel"
    static let languageKey = "asr.language"        // "" = auto-detect (Whisper only)
    static let scriptsKey = "asr.scripts"          // comma list of scripts the meetings may contain
    static let defaultScripts = "latin,devanagari"

    static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo"
    static let defaultModel = "gemma4:e4b"
    static let defaultURL = "http://127.0.0.1:11434"
    static let defaultContextTokens = 32_768

    static let systemPrompt = """
    You are a meticulous meeting-notes writer. Work only from the transcript you are given. \
    Never invent names, numbers, dates or decisions that are not in it. Output Markdown only, with no preamble.
    """

    static let defaultPrompt = """
    Write meeting notes from the transcript below.

    Structure (omit a section if there is nothing for it):
    ## Summary
    Two or three sentences: what the meeting was about and what came out of it.
    ## Notes
    Organized by topic. Keep the specifics: names, numbers, dates, reasons.
    ## Decisions
    One line each.
    ## Action items
    - [ ] what — who — when (only if said)

    Speaker labels like "Speaker 1" are unknown names; keep them as they are.
    The transcript may mix Hindi (Devanagari) and English. Write the notes in English and carry over \
    every specific from the Hindi parts: numbers, counts, distances, names of systems, who owns what.
    Prefer concrete statements ("two local servers per plaza, failover on crash") over generalities \
    ("the system is designed to be robust"). Never write an empty bullet or an empty checkbox; if there \
    are no action items, omit the section.

    Meeting: {{title}} on {{date}}

    Transcript:
    {{transcript}}
    """

    static var engine: ASREngine { ASREngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .parakeet }
    static var whisperModel: String { UserDefaults.standard.string(forKey: whisperModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWhisperModel }
    static var expectedScripts: Set<String> {
        let raw = UserDefaults.standard.string(forKey: scriptsKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultScripts
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }
    static var language: String? { UserDefaults.standard.string(forKey: languageKey).flatMap { $0.isEmpty ? nil : $0 } }
    static var model: String { UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel }
    static var baseURL: URL { URL(string: UserDefaults.standard.string(forKey: urlKey) ?? "") ?? URL(string: defaultURL)! }
    static var prompt: String { UserDefaults.standard.string(forKey: promptKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultPrompt }
    static var contextTokens: Int {
        let v = UserDefaults.standard.integer(forKey: contextKey)
        return v > 0 ? v : defaultContextTokens
    }
}

enum Summarizer {
    static func transcriptText(_ segments: [Segment]) -> String {
        segments.map { s in
            let stamp = Self.clock(s.startTime)
            let who = s.speaker ?? "Unknown"
            return "[\(stamp)] \(who): \(s.text)"
        }.joined(separator: "\n")
    }

    static func buildPrompt(meeting: Meeting, segments: [Segment]) -> String {
        AppSettings.prompt
            .replacingOccurrences(of: "{{title}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: meeting.createdAt.formatted(date: .long, time: .shortened))
            .replacingOccurrences(of: "{{transcript}}", with: transcriptText(segments))
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
