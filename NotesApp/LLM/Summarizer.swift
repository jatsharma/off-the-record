import Foundation

/// User-editable settings, stored in UserDefaults.
enum AppSettings {
    static let modelKey = "llm.model"
    static let urlKey = "llm.url"
    static let promptKey = "llm.basePrompt"
    static let contextKey = "llm.contextTokens"

    static let engineKey = "asr.engine"            // "parakeet" | "mix" | advanced: "apex" | "tara" | "whisper"
    static let whisperModelKey = "asr.whisperModel"
    static let languageKey = "asr.language"        // "" = auto-detect (Whisper only)
    static let scriptsKey = "asr.scripts"          // comma list of scripts the meetings may contain
    static let defaultScripts = "latin,devanagari"

    static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo"
    /// gemma4:e4b (6.6 GB, about 6.5 GB in memory while writing) on Macs with 16 GB or more; the
    /// lighter gemma4:e2b (4.6 GB) below that, so notes do not push an 8 GB Mac into swap.
    static var defaultModel: String { hasRoomForLargeModel ? "gemma4:e4b" : "gemma4:e2b" }
    static var hasRoomForLargeModel: Bool { ProcessInfo.processInfo.physicalMemory >= 15 << 30 }
    static let modelDownloadSize = ["gemma4:e4b": "6.6 GB", "gemma4:e2b": "4.6 GB"]

    // MARK: Meeting language

    /// What the user's meetings are in: English, or Hindi and English (Hinglish). Picks the speech
    /// engine and whether the prompts mention Hindi. Before it was asked, the engine decides.
    static let meetingLanguageKey = "meetings.language"     // "english" | "hinglish"
    static var hinglish: Bool {
        if let value = UserDefaults.standard.string(forKey: meetingLanguageKey) { return value == "hinglish" }
        return [.mix, .apex, .tara].contains(engine)
    }
    static func setMeetingLanguage(hinglish: Bool) {
        UserDefaults.standard.set(hinglish ? "hinglish" : "english", forKey: meetingLanguageKey)
        UserDefaults.standard.set((hinglish ? ASREngine.mix : ASREngine.parakeet).rawValue, forKey: engineKey)
    }
    static let defaultURL = "http://127.0.0.1:11434"
    static let defaultContextTokens = 32_768

    static let systemPrompt = """
    You are a meticulous meeting-notes writer. Work only from the transcript you are given. \
    Never invent names, numbers, dates or decisions that are not in it. Output Markdown only, with no preamble.
    """

    /// The default notes instructions (the general template); the Hindi paragraph only for Hinglish meetings.
    static var defaultPrompt: String { defaultPrompt(structure: generalStructure) }

    /// A template's structure followed by the shared rules, dates, Hindi note and glossary.
    static func defaultPrompt(structure: String) -> String {
        let prompt = structure + commonTail
        return hinglish ? prompt.replacingOccurrences(of: "{{hindi}}", with: hindiNote)
                        : prompt.replacingOccurrences(of: "{{hindi}}\n", with: "")
    }

    private static let hindiNote = """
    The transcript may mix Hindi (Devanagari) and English. Write the notes in English and carry over \
    every specific from the Hindi parts: numbers, counts, distances, names of systems, who owns what.
    """

    static let generalStructure = """
    Write meeting notes from the transcript above.

    Structure (omit a section if there is nothing for it):
    ## Summary
    Two or three sentences: what the meeting was about and what came out of it.
    ## Notes
    Organized by topic. Keep the specifics: names, numbers, dates, reasons. Name every system, \
    product, database, library, service and tool that was discussed, with what was said about it.
    ## Decisions
    One line each, ending with the transcript time it was made, like [12:56].
    ## Action items
    - [ ] what — who — when (only if said) [12:56]
    """

    private static let commonTail = """


    Speaker labels like "Speaker 1" are unknown names; keep them as they are.
    {{days}}
    {{hindi}}
    Prefer concrete statements (who decided what, numbers, names, reasons) over generalities. Mention \
    only what the transcript says; do not list glossary terms or topics that did not come up. \
    Never write an empty bullet or an empty checkbox; if there \
    are no action items, omit the section. Never write "[?]" or comment on transcript quality.
    {{glossary}}
    Meeting: {{title}} on {{date}}
    """

    /// Mix (Apex + Parakeet) when the Hinglish models are installed, else Parakeet.
    static var defaultEngine: ASREngine { HinglishWhisper.isInstalled(.apex) ? .mix : .parakeet }
    static var engine: ASREngine { ASREngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? defaultEngine }
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

    /// The transcript opens every prompt that reads it, ahead of the instructions. The notes and the
    /// action-item step then start with identical text, and Ollama reuses the first call's work for
    /// the second (on a 32-minute meeting its prompt processing went from 27 s to 0.2 s). Small models
    /// also follow instructions better when they come after a long document.
    static func transcriptBlock(_ transcript: String) -> String {
        "Meeting transcript:\n" + transcript + "\n\n---\n\n"
    }

    static func glossaryBlock(_ glossary: [String]) -> String {
        glossary.isEmpty ? "" : "\nWhen these names and terms come up in the transcript, spell them this way " +
            "(most will not come up; never mention one the transcript does not): " + glossary.joined(separator: ", ") + "\n"
    }

    static func buildPrompt(meeting: Meeting, transcript: String, glossary: [String] = []) -> String {
        transcriptBlock(transcript) + instructions(meeting: meeting, glossary: glossary)
    }

    /// The notes template with its placeholders filled. The glossary and the relative days go where
    /// the template says {{glossary}} and {{days}}, or at the end. Templates saved while the
    /// transcript still came last lose their {{transcript}} slot (it is sent first now).
    static func instructions(meeting: Meeting, glossary: [String]) -> String {
        typedNotesBlock(meeting.typedNotes) + template(meeting: meeting, glossary: glossary)
    }

    /// The user's own notes from the meeting: what mattered to them, to keep and build on.
    static func typedNotesBlock(_ notes: String?) -> String {
        guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return "" }
        return """
        Notes the user typed during the meeting (they show what mattered to the user):
        <<<
        \(notes)
        >>>
        Keep every point the user typed, in their order and close to their wording, and expand each with \
        the specifics from the transcript. Where a typed point is not in the transcript, keep it as the \
        user wrote it; do not invent support for it.

        ---


        """
    }

    private static func template(meeting: Meeting, glossary: [String]) -> String {
        var template = AppSettings.prompt
            .replacingOccurrences(of: "Transcript:\n{{transcript}}", with: "")
            .replacingOccurrences(of: "{{transcript}}", with: "")
            .replacingOccurrences(of: "the transcript below", with: "the transcript above")
        let block = glossaryBlock(glossary)
        if template.contains("{{glossary}}") {
            template = template.replacingOccurrences(of: "{{glossary}}", with: block)
        } else if !block.isEmpty {
            template += "\n" + block
        }
        let fixes = Vocabulary.notesFixesBlock()
        if !fixes.isEmpty { template += "\n" + fixes }
        let days = relativeDays(from: meeting.createdAt)
        if template.contains("{{days}}") {
            template = template.replacingOccurrences(of: "{{days}}", with: days)
        } else {
            template += "\n" + days
        }
        return template
            .replacingOccurrences(of: "{{title}}", with: meeting.title)
            .replacingOccurrences(of: "{{date}}", with: meeting.createdAt.formatted(
                .dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hindi relative days resolved to dates, so the model never does calendar arithmetic (asked to,
    /// small models get the weekday or the offset wrong). "kal" and "parson" point both ways.
    static func relativeDays(from date: Date) -> String {
        let cal = Calendar.current
        func day(_ offset: Int) -> String {
            (cal.date(byAdding: .day, value: offset, to: date) ?? date)
                .formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        guard AppSettings.hinglish else {
            return "Relative days in the transcript: \"today\" = \(day(0)); \"tomorrow\" = \(day(1)); \"yesterday\" = " +
                "\(day(-1)). In action items write the resolved day and date, never \"tomorrow\"."
        }
        return "Relative days in the transcript: \"aaj\" = \(day(0)); \"kal\" = \(day(1)) for work still to do, " +
            "\(day(-1)) for things already done; \"parson\" = \(day(2)) for work still to do, \(day(-2)) for " +
            "things already done. In action items write the resolved day and date, never \"tomorrow\" or \"kal\"."
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
