import Foundation

/// How the notes model reads a meeting. Three things small models need help with:
/// 1. Noise: "Haan.", "Thik hai?" lines and one sentence split over several lines. The model reads
///    a tidied transcript (the saved transcript is not changed).
/// 2. Length: in a 30-minute transcript the middle gets skimmed and details flip. Long meetings are
///    written up part by part (about 8 minutes each) and the parts combined.
/// 3. Action items: merged tasks, missing owners, wrong days. They are asked for separately as
///    structured lines and checked in code against the transcript before they replace the list in
///    the notes.
enum NotesPipeline {
    struct Turn {
        var start: Double
        var end: Double
        var speaker: String
        var text: String
    }

    struct ActionItem: Equatable {
        var task: String
        var owner: String
        var when: String
        var time: Double
    }

    // MARK: 1. Tidy transcript

    /// Words that carry no content on their own. A line made only of one or two of these is dropped
    /// for the notes model; anything longer ("Thik hai, chalega" = agreed) is kept.
    static let fillers: Set<String> = [
        "haan", "han", "ha", "haa", "hmm", "hm", "hmmm", "achchha", "achha", "acha", "accha", "thik", "theek",
        "hai", "ok", "okay", "yes", "yeah", "ji", "haanji", "right", "sure", "acchha", "um", "uh", "aa", "main",
        "so", "aur", "to", "toh", "na", "sir",
        "हाँ", "हां", "हम्म", "अच्छा", "ठीक", "है", "जी",
    ]

    static func turns(_ segments: [Segment]) -> [Turn] {
        var out: [Turn] = []
        for s in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.isEmpty || (words.count <= 2 && words.allSatisfy { fillers.contains(String($0)) }) { continue }
            let who = s.speaker ?? "Unknown"
            if var last = out.last, last.speaker == who, s.startTime - last.end < 3, last.text.count + text.count < 700 {
                last.text += " " + text
                last.end = max(last.end, s.endTime)
                out[out.count - 1] = last
            } else {
                out.append(Turn(start: s.startTime, end: s.endTime, speaker: who, text: text))
            }
        }
        return out
    }

    static func transcript(_ turns: [Turn]) -> String {
        turns.map { "[\(Summarizer.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: 2. Long meetings, part by part

    static let longMeetingSeconds = 15.0 * 60
    static let partSeconds = 8.0 * 60

    /// Off by default. On a 31-minute test meeting part-by-part notes covered more points but also
    /// made more wrong statements (a small model writes something for every part, including
    /// confident readings of garbled lines) and took about four times as long.
    static let byPartsKey = "notes.byParts"
    static var byPartsEnabled: Bool { UserDefaults.standard.bool(forKey: byPartsKey) }

    static func isLong(_ turns: [Turn]) -> Bool {
        guard let first = turns.first, let last = turns.last else { return false }
        return last.end - first.start > longMeetingSeconds
    }

    /// Consecutive parts of about eight minutes, cut between turns. A short tail joins the last part.
    static func parts(_ turns: [Turn]) -> [[Turn]] {
        var parts: [[Turn]] = []
        var current: [Turn] = []
        for turn in turns {
            if let first = current.first, turn.start - first.start >= partSeconds {
                parts.append(current)
                current = []
            }
            current.append(turn)
        }
        if !current.isEmpty {
            if let tailStart = current.first?.start, let tailEnd = current.last?.end, tailEnd - tailStart < 120, !parts.isEmpty {
                parts[parts.count - 1] += current
            } else {
                parts.append(current)
            }
        }
        return parts
    }

    static func partPrompt(_ part: [Turn], index: Int, count: Int, glossary: String, days: String) -> String {
        let from = Summarizer.clock(part.first?.start ?? 0), to = Summarizer.clock(part.last?.end ?? 0)
        return """
        Below is part \(index) of \(count) (\(from)–\(to)) of a meeting transcript. Write detailed notes for \
        this part only, in English, as bullets under short topic headings ("### Topic").
        - Keep every specific: names, numbers, dates, systems and what was said about each, reasons.
        - Write rules and conditions exactly as stated, as "if … then …", including who said them.
        - End each bullet that records a decision or a task with its time from the transcript, like [12:56].
        - The transcript may mix Hindi and English; carry over everything said in Hindi.
        - Mention only what this part says. No summary, no preamble.
        \(glossary)\(days)

        Transcript part:
        \(transcript(part))
        """
    }

    /// The part notes, in order, followed by the template's notes instructions.
    static func combinePrompt(instructions: String, partNotes: [(range: String, notes: String)]) -> String {
        let body = partNotes.enumerated().map { "### Part \($0.offset + 1) (\($0.element.range))\n\($0.element.notes)" }
            .joined(separator: "\n\n")
        return """
        This meeting was long, so it was first written up part by part. The part notes below, in order, \
        take the place of the transcript.

        Part notes:
        \(body)

        ---

        Combine the part notes into the meeting notes: merge repeated points, keep every specific (names, \
        numbers, rules and conditions, times like [12:56]), and drop nothing that matters.

        """ + instructions.replacingOccurrences(of: "the transcript above", with: "the part notes above")
    }

    // MARK: 3. Action items, checked

    /// Starts with the same transcript block as the notes prompt, so Ollama reuses that work.
    static func actionPrompt(_ turns: [Turn], speakers: [String], days: String) -> String {
        Summarizer.transcriptBlock(transcript(turns)) + """
        From the meeting transcript above, list every task that someone agreed to do or was asked to do. Not \
        decisions, facts or discussion: only work someone has to do.
        One task per line, as JSON: {"task": "...", "owner": "...", "when": "...", "time": "mm:ss"}
        - task: what has to be done, in English, short and concrete. One task per line; if one sentence \
        gives two tasks, or the same person takes two tasks with different timings, write two lines.
        - owner: who will do it, exactly one of: \(speakers.joined(separator: ", ")). "You" is the person \
        recording. Someone saying "main ... karta hoon" owns it themself; "tum ... kar dena" gives it to the \
        other person. Empty if unclear.
        - when: the exact word or words said about its timing ("aaj", "kal", "parson", "today", "next week", \
        a date), or empty if nothing was said.
        - time: the time of the transcript line where the task was said.
        Output only the JSON lines, nothing else. If there are no tasks, output nothing.
        \(days)
        """
    }

    /// Parses and checks the model's task lines: the time must fall on a transcript turn, the owner
    /// must be a speaker in this meeting, and spoken relative days are turned into dates here.
    static func checkedItems(_ answer: String, turns: [Turn], speakers: Set<String>, meetingDate: Date) -> [ActionItem] {
        struct Raw: Decodable { let task: String?; let owner: String?; let when: String?; let time: String? }
        var items: [ActionItem] = []
        for line in answer.components(separatedBy: .newlines) {
            guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close,
                  let raw = try? JSONDecoder().decode(Raw.self, from: Data(line[open...close].utf8)),
                  let task = raw.task?.trimmingCharacters(in: .whitespaces), (3...200).contains(task.count),
                  let time = raw.time.flatMap(seconds) else { continue }
            // The task must have been said on a real line (5 s of slack for rounding).
            guard turns.contains(where: { $0.start - 5 <= time && time <= $0.end + 5 }) else { continue }
            let owner = raw.owner.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { speakers.contains($0) ? $0 : nil } ?? ""
            let item = ActionItem(task: task, owner: owner, when: resolve(raw.when ?? "", from: meetingDate), time: time)
            if !items.contains(where: { $0.task.lowercased() == item.task.lowercased() }) { items.append(item) }
        }
        return items
    }

    static func render(_ items: [ActionItem]) -> String {
        items.map { item in
            var line = "- [ ] " + item.task
            if !item.owner.isEmpty { line += " — " + item.owner }
            if !item.when.isEmpty { line += " — " + item.when }
            return line + " [\(Summarizer.clock(item.time))]"
        }.joined(separator: "\n")
    }

    /// Number of checklist lines in the notes' action-item section.
    static func actionItemCount(in notes: String) -> Int {
        let lines = notes.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix("## action item") }) else { return 0 }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
        // Any list line counts: models write "- [ ]", "*   [ ]", "- task" or "1. task".
        return lines[(start + 1)..<end].filter {
            $0.range(of: #"^\s*([-*•]|\d+[.)])\s+\S"#, options: .regularExpression) != nil
        }.count
    }

    /// Puts checked items in place of the notes' action-item section (or adds the section). When the
    /// check kept fewer tasks than the notes model wrote, the notes keep their own list: in testing the
    /// separate step sometimes returned one task where the notes listed three correct ones, while a
    /// merged task in the notes ("create project and send draft") came back as two, so more is better.
    static func replaceActionItems(in notes: String, with items: [ActionItem]) -> String {
        guard !items.isEmpty, items.count >= actionItemCount(in: notes) else { return notes }
        var lines = notes.components(separatedBy: "\n")
        let section = ["## Action items", render(items)]
        if let start = lines.firstIndex(where: { $0.lowercased().hasPrefix("## action item") }) {
            let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
            lines.replaceSubrange(start..<end, with: section + (end < lines.count ? [""] : []))
            return lines.joined(separator: "\n")
        }
        return notes + "\n\n" + section.joined(separator: "\n")
    }

    /// "aaj"/"abhi"/"today" → that day, "kal"/"tomorrow" → the next, "parson" → two days on, "next week" → a
    /// week on; anything else (an explicit date) is kept as said. Tasks are future work, so "kal" and
    /// "parson" point forward here.
    static func resolve(_ when: String, from date: Date) -> String {
        let w = when.lowercased()
        let cal = Calendar.current
        func day(_ offset: Int, by: Bool = false) -> String {
            let d = cal.date(byAdding: .day, value: offset, to: date) ?? date
            return (by ? "by " : "") + d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if w.contains("parson") || w.contains("parso") || w.contains("परसों") || w.contains("day after tomorrow") { return day(2) }
        if w.contains("kal") || w.contains("कल") || w.contains("tomorrow") { return day(1) }
        if w.contains("aaj") || w.contains("आज") || w.contains("today") || w.contains("abhi") || w.contains("अभी")
            || w == "now" || w.contains("right away") { return day(0) }
        if w.contains("week") || w.contains("hafte") || w.contains("हफ्ते") { return day(7, by: true) }
        return when.trimmingCharacters(in: .whitespaces)
    }

    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
