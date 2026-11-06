import Foundation
import AVFoundation
import AppKit
import GRDB

/// Orchestrates record -> transcribe -> summarize, and owns deletes.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// One status line per meeting while it is being processed.
    @Published var progress: [String: String] = [:]
    /// 0...1 while transcribing, nil when indeterminate.
    @Published var fraction: [String: Double] = [:]
    /// When the current stage started, for the elapsed/estimate readout.
    @Published var stageStarted: [String: Date] = [:]
    /// Live captions for the meeting currently being recorded.
    @Published var liveCaptions: [String] = []
    @Published var showSetup = !UserDefaults.standard.bool(forKey: "setup.done")
    /// Summary text as it streams in, before it is saved.
    @Published var liveSummary: [String: String] = [:]

    private let db = AppDatabase.shared

    init() {
        recoverInterrupted()
    }

    // MARK: Recovery

    /// A meeting still recording, transcribing or summarizing at launch was cut off by a quit or
    /// crash, and nothing will pick it up again. Mark it failed so the meeting page offers Retry.
    /// A cut-off recording also gets its WAV header repaired, or it would read as 0 seconds.
    private func recoverInterrupted() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        guard others.isEmpty else { return }   // another copy of the app may be working on them
        let stuck = (try? db.pool.read { db in
            try Meeting.filter([MeetingStatus.recording, .transcribing, .summarizing].map(\.rawValue).contains(Column("status"))).fetchAll(db)
        }) ?? []
        for meeting in stuck {
            switch meeting.status {
            case .recording:
                var duration = meeting.durationSeconds
                if let url = meeting.audioURL {
                    WavRepair.fixHeader(url)
                    if let file = try? AVAudioFile(forReading: url) { duration = Double(file.length) / file.processingFormat.sampleRate }
                }
                if duration < 2 { delete(meeting); continue }
                update(meeting.id) {
                    $0.durationSeconds = duration
                    $0.status = .failed
                    $0.errorMessage = "App closed mid-recording; audio kept"
                }
            default:
                update(meeting.id) {
                    $0.status = .failed
                    $0.errorMessage = "App closed before this finished"
                }
            }
        }
    }

    /// Called when the app quits mid-recording: the file is already closed by the recorder,
    /// so keep it and let the user start transcription on the next launch.
    func saveInterruptedRecording(_ meeting: Meeting, duration: TimeInterval) {
        guard duration >= 2 else { delete(meeting); return }
        update(meeting.id) {
            $0.durationSeconds = duration
            $0.status = .failed
            $0.errorMessage = "Recording stopped when the app quit"
        }
    }

    func meetingBeingRecorded() -> Meeting? {
        try? db.pool.read { try Meeting.filter(Column("status") == MeetingStatus.recording.rawValue).order(Column("createdAt").desc).fetchOne($0) }
    }

    // MARK: Recording

    func createMeeting(title: String) throws -> Meeting {
        let id = UUID().uuidString
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let meeting = Meeting(
            id: id,
            title: cleanTitle.isEmpty ? Self.autoTitle("Meeting") : cleanTitle,
            createdAt: Date(),
            durationSeconds: 0,
            audioPath: "\(id).wav",
            summary: nil,
            status: .recording,
            errorMessage: nil)
        try db.pool.write { try meeting.insert($0) }
        return meeting
    }

    func finishRecording(_ meeting: Meeting, duration: TimeInterval) {
        update(meeting.id) { $0.durationSeconds = duration; $0.status = .transcribing; $0.errorMessage = nil }
        enqueue(meeting.id) { await $0.process(meetingId: meeting.id) }
    }

    func discardRecording(_ meeting: Meeting) {
        delete(meeting)
    }

    /// Copies an existing audio file in as a new meeting and runs the pipeline.
    @discardableResult
    func importAudio(from source: URL, title: String? = nil) throws -> Meeting {
        let id = UUID().uuidString
        let destination = AppDatabase.audioDirectory.appendingPathComponent("\(id).wav")
        try FileManager.default.copyItem(at: source, to: destination)
        let duration = (try? AVAudioFile(forReading: destination)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let fileName = source.deletingPathExtension().lastPathComponent
        let looksLikeId = fileName.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil
        let meeting = Meeting(
            id: id,
            title: title ?? (looksLikeId ? Self.autoTitle("Imported") : fileName),
            createdAt: Date(),
            durationSeconds: duration,
            audioPath: "\(id).wav",
            summary: nil,
            status: .transcribing,
            errorMessage: nil)
        try db.pool.write { try meeting.insert($0) }
        enqueue(id) { await $0.process(meetingId: id) }
        return meeting
    }

    // MARK: Queue

    /// Meetings are processed one at a time. Two pipelines at once would share the loaded speech
    /// models (and their progress callbacks), hold two recordings in memory and send Ollama two long
    /// prompts together; queued meetings wait instead.
    private var queueTail: Task<Void, Never>?
    private var queued = 0

    @discardableResult
    func enqueue(_ meetingId: String, _ job: @escaping @MainActor (MeetingStore) async -> Void) -> Task<Void, Never> {
        let previous = queueTail
        if previous != nil, queued > 0 { progress[meetingId] = "Waiting for another meeting to finish" }
        queued += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await job(self)
            self.queued -= 1
        }
        queueTail = task
        return task
    }

    /// Writes the notes again (Regenerate, Retry notes), after any meeting already being processed.
    func queueSummarize(meetingId: String) {
        enqueue(meetingId) { store in
            await store.summarize(meetingId: meetingId)
            store.contextFor[meetingId] = nil
        }
    }

    // MARK: Pipeline

    /// One context size for every model call on a meeting. With llama.cpp models (gemma4) Ollama
    /// reloads the model whenever `num_ctx` changes (about 5 s each time), so the clean-up, notes,
    /// action-item and title calls all use the same value: the smallest of 8k/16k/32k that fits the
    /// transcript with room for instructions and the answer, capped by the Settings value.
    private var contextFor: [String: Int] = [:]

    func contextTokens(for meetingId: String) -> Int {
        if let known = contextFor[meetingId] { return known }
        // About 3.3 characters per token for English; UTF-8 bytes / 3 also covers Devanagari.
        let bytes = segments(for: meetingId).reduce(0) { $0 + $1.text.utf8.count + 20 }
        let needed = bytes / 3 + 6_000
        let cap = AppSettings.contextTokens
        let size = [8_192, 16_384, 32_768].first { $0 >= needed }.map { min($0, cap) } ?? cap
        contextFor[meetingId] = size
        return size
    }

    func process(meetingId: String) async {
        defer { contextFor[meetingId] = nil }
        guard let meeting = fetch(meetingId), let audio = meeting.audioURL else { return }
        do {
            update(meetingId) { $0.status = .transcribing }
            stageStarted[meetingId] = Date()
            fraction[meetingId] = 0
            let known = knownVoices()
            let result = try await SpeechEngine.shared.transcribe(file: audio, knownVoices: known,
                                                                  context: Vocabulary.recognizerContext(for: meetingId)) { [weak self] fraction, text in
                Task { @MainActor in self?.progress[meetingId] = text; self?.fraction[meetingId] = fraction }
            }
            fraction[meetingId] = nil
            try saveTranscript(result.lines, for: meetingId)
            contextFor[meetingId] = nil
            _ = contextTokens(for: meetingId)          // fixed now, before the clean-up shortens lines
            saveSpeakerVectors(result.speakerVectors, for: meetingId)
            applyCorrections(meetingId: meetingId)
            var t = Date()
            if Vocabulary.cleanupEnabled { await cleanTranscript(meetingId: meetingId) }
            NSLog("[timing] clean-up: %.1fs", Date().timeIntervalSince(t)); t = Date()
            await summarize(meetingId: meetingId)
            NSLog("[timing] notes + title: %.1fs", Date().timeIntervalSince(t))
        } catch {
            fail(meetingId, error)
        }
    }

    func summarize(meetingId: String) async {
        guard let meeting = fetch(meetingId) else { return }
        let segments = self.segments(for: meetingId)
        guard !segments.isEmpty else {
            update(meetingId) { $0.status = .done; $0.summary = "_No speech was detected in this recording._" }
            progress[meetingId] = nil
            return
        }
        update(meetingId) { $0.status = .summarizing; $0.errorMessage = nil }
        stageStarted[meetingId] = Date()
        fraction[meetingId] = nil
        liveSummary[meetingId] = ""
        do {
            let client = OllamaClient(baseURL: AppSettings.baseURL)
            progress[meetingId] = "Starting Ollama"
            try await client.ensureRunning()
            let model = AppSettings.model
            if try await !client.hasModel(model) {
                try await client.pull(model) { [weak self] text in Task { @MainActor in self?.progress[meetingId] = text } }
            }
            let glossary = Vocabulary.terms(for: meetingId)
            let turns = NotesPipeline.turns(segments)
            let days = Summarizer.relativeDays(from: meeting.createdAt)
            let context = contextTokens(for: meetingId)
            // Temperature 0 throughout: the same transcript always gives the same notes, with fewer
            // invented details.
            func ask(_ prompt: String, live: Bool) async throws -> String {
                var text = ""
                var shown = Date.distantPast
                for try await token in client.chat(model: model, system: AppSettings.systemPrompt, user: prompt,
                                                   contextTokens: context, temperature: 0) {
                    text += token
                    // Every view watching the store redraws on a change; five updates a second is smooth.
                    if live, Date().timeIntervalSince(shown) >= 0.2 { liveSummary[meetingId] = text; shown = Date() }
                }
                if live { liveSummary[meetingId] = text }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var text: String
            if NotesPipeline.byPartsEnabled, NotesPipeline.isLong(turns) {
                let parts = NotesPipeline.parts(turns)
                var partNotes: [(range: String, notes: String)] = []
                for (i, part) in parts.enumerated() {
                    progress[meetingId] = "Writing notes with \(model) (part \(i + 1) of \(parts.count))"
                    fraction[meetingId] = Double(i) / Double(parts.count + 1)
                    let notes = try await ask(NotesPipeline.partPrompt(part, index: i + 1, count: parts.count,
                                                                       glossary: Summarizer.glossaryBlock(glossary), days: days), live: true)
                    partNotes.append(("\(Summarizer.clock(part.first?.start ?? 0))–\(Summarizer.clock(part.last?.end ?? 0))", notes))
                }
                progress[meetingId] = "Combining the notes"
                fraction[meetingId] = Double(parts.count) / Double(parts.count + 1)
                let instructions = Summarizer.instructions(meeting: meeting, glossary: glossary)
                text = try await ask(NotesPipeline.combinePrompt(instructions: instructions, partNotes: partNotes), live: true)
                fraction[meetingId] = nil
            } else {
                progress[meetingId] = "Writing notes with \(model)"
                text = try await ask(Summarizer.buildPrompt(meeting: meeting, transcript: NotesPipeline.transcript(turns),
                                                           glossary: glossary), live: true)
            }
            // Action items asked for on their own and checked against the transcript; on any failure
            // the notes keep the items the notes model wrote.
            progress[meetingId] = "Checking action items"
            let speakers = Array(Set(turns.map(\.speaker))).sorted()
            if let answer = try? await ask(NotesPipeline.actionPrompt(turns, speakers: speakers, days: days), live: false) {
                let items = NotesPipeline.checkedItems(answer, turns: turns, speakers: Set(speakers), meetingDate: meeting.createdAt)
                NSLog("[actions] notes listed %d, action step returned %d lines, kept %d", NotesPipeline.actionItemCount(in: text),
                      answer.split(separator: "\n").filter { $0.contains("{") }.count, items.count)
                text = NotesPipeline.replaceActionItems(in: text, with: items)
            }
            let final = text.replacingOccurrences(of: " [?]", with: "").replacingOccurrences(of: "[?]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update(meetingId) { $0.summary = final; $0.status = .done; $0.notesEdited = false }
            liveSummary[meetingId] = nil
            if Self.isAutoTitle(meeting.title) {
                progress[meetingId] = "Naming the meeting"
                if let title = try? await suggestTitle(notes: final, client: client, model: model, contextTokens: context) {
                    update(meetingId) { $0.title = title }
                }
            }
            progress[meetingId] = nil
            Notifier.post(title: "Notes ready", body: fetch(meetingId)?.title ?? meeting.title)
        } catch {
            liveSummary[meetingId] = nil
            fail(meetingId, error)
        }
    }

    /// Romanizes the transcript and restores glossary terms (see `TranscriptCleaner`). Keeps the
    /// recognizer's text in `rawText`. A failure here is logged and skipped: notes still get written.
    func cleanTranscript(meetingId: String) async {
        let segments = self.segments(for: meetingId)
        guard !segments.isEmpty else { return }
        let lines = segments.enumerated().map { TranscriptCleaner.Line(id: $0.offset + 1, speaker: $0.element.speaker, text: $0.element.text, hinted: $0.element.altText) }
        do {
            let client = OllamaClient(baseURL: AppSettings.baseURL)
            progress[meetingId] = "Starting Ollama"
            try await client.ensureRunning()
            let model = AppSettings.model
            guard try await client.hasModel(model) else { return }   // notes step pulls it; skip clean-up this once
            progress[meetingId] = "Checking terms with \(model)"
            let fixed = try await TranscriptCleaner.clean(lines, glossary: Vocabulary.terms(for: meetingId), client: client, model: model,
                                                          contextTokens: contextTokens(for: meetingId)) { [weak self] f in
                self?.fraction[meetingId] = f
            }
            fraction[meetingId] = nil
            try await db.pool.write { db in
                for (i, segment) in segments.enumerated() {
                    guard let text = fixed[i + 1], text != segment.text else { continue }
                    var s = segment
                    if s.rawText == nil { s.rawText = segment.text }
                    s.text = text
                    try s.update(db)
                }
            }
        } catch {
            fraction[meetingId] = nil
            NSLog("Transcript clean-up failed, keeping the recognizer's text: \(error.localizedDescription)")
        }
    }

    /// Replaces mishearings learned from earlier hand corrections ("dixcheck" → "DexScreener").
    /// Keeps the recognizer's text in `rawText`.
    func applyCorrections(meetingId: String) {
        guard !Vocabulary.corrections.isEmpty else { return }
        try? db.pool.write { db in
            for segment in try Segment.filter(Column("meetingId") == meetingId).fetchAll(db) {
                let fixed = Vocabulary.applyCorrections(segment.text)
                guard fixed != segment.text else { continue }
                var s = segment
                if s.rawText == nil { s.rawText = segment.text }
                s.text = fixed
                try s.update(db)
            }
        }
    }

    /// A hand correction of one transcript line. New names and terms in it join the glossary, so
    /// later meetings are recognized and cleaned with them.
    func editSegment(_ segment: Segment, to text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != segment.text else { return }
        Vocabulary.learn(Vocabulary.newTerms(from: segment.text, to: clean))
        Vocabulary.learnCorrections(from: segment.rawText ?? segment.text, to: clean)
        try? db.pool.write { db in
            var s = segment
            if s.rawText == nil { s.rawText = segment.text }
            s.text = clean
            try s.update(db)
        }
    }

    func retranscribe(_ meeting: Meeting) {
        update(meeting.id) { $0.status = .transcribing; $0.errorMessage = nil }
        enqueue(meeting.id) { await $0.process(meetingId: meeting.id) }
    }

    // MARK: Titles

    static func autoTitle(_ kind: String) -> String {
        "\(kind) · \(Date().formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }

    static func isAutoTitle(_ title: String) -> Bool {
        title.hasPrefix("Meeting · ") || title.hasPrefix("Imported · ") || title.hasPrefix("Auto test")
            || title.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil
    }

    private func suggestTitle(notes: String, client: OllamaClient, model: String, contextTokens: Int) async throws -> String? {
        let prompt = "Give this meeting a title of three to seven words that says what it was about. Output only the title, no quotes, no punctuation at the end.\n\n\(notes.prefix(3000))"
        var text = ""
        for try await token in client.chat(model: model, system: "You name meetings.", user: prompt, contextTokens: contextTokens) { text += token }
        let title = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
        return (3...80).contains(title.count) ? title : nil
    }

    // MARK: Speakers and export

    /// Renames a speaker in one meeting and teaches the name to voice memory, so the same
    /// voice is labelled automatically in later meetings.
    func renameSpeaker(_ old: String?, to new: String, in meetingId: String) {
        let clean = new.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != old else { return }
        do { try db.pool.write { db in
            if let old {
                try db.execute(sql: "update segment set speaker = ? where meetingId = ? and speaker = ?", arguments: [clean, meetingId, old])
                if var ms = try MeetingSpeaker.filter(Column("meetingId") == meetingId && Column("speaker") == old).fetchOne(db) {
                    let vector = Vectors.floats(ms.vector)
                    // Naming a second label after a speaker already in this meeting merges the two (the
                    // diarizer often splits one person); one row per name, voices averaged.
                    if var existing = try MeetingSpeaker.filter(Column("meetingId") == meetingId && Column("speaker") == clean).fetchOne(db) {
                        existing.vector = Vectors.data(Vectors.mean([Vectors.floats(existing.vector), vector]))
                        try existing.update(db)
                        try ms.delete(db)
                    } else {
                        ms.speaker = clean
                        try ms.update(db)
                    }
                    if clean != "You", clean != "Them", !clean.hasPrefix("Speaker ") {
                        if var vp = try VoicePrint.filter(Column("name") == clean).fetchOne(db) {
                            let merged = zip(Vectors.floats(vp.vector), vector).map { ($0 * Float(vp.samples) + $1) / Float(vp.samples + 1) }
                            vp.vector = Vectors.data(merged); vp.samples += 1; vp.updatedAt = Date()
                            try vp.update(db)
                        } else {
                            try VoicePrint(id: UUID().uuidString, name: clean, vector: ms.vector, samples: 1, updatedAt: Date()).insert(db)
                        }
                    }
                }
            } else {
                try db.execute(sql: "update segment set speaker = ? where meetingId = ? and speaker is null", arguments: [clean, meetingId])
            }
        } } catch {
            NSLog("Speaker rename failed: \(error.localizedDescription)")
        }
    }

    func knownVoices() -> [KnownVoice] {
        (try? db.pool.read { try VoicePrint.fetchAll($0) })?.map { KnownVoice(name: $0.name, vector: Vectors.floats($0.vector)) } ?? []
    }

    func voicePrints() -> [VoicePrint] {
        (try? db.pool.read { try VoicePrint.order(Column("name")).fetchAll($0) }) ?? []
    }

    func deleteVoicePrint(_ vp: VoicePrint) {
        _ = try? db.pool.write { try vp.delete($0) }
    }

    private func saveSpeakerVectors(_ vectors: [String: [Float]], for meetingId: String) {
        try? db.pool.write { db in
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).deleteAll(db)
            for (speaker, v) in vectors where !v.isEmpty {
                try MeetingSpeaker(id: UUID().uuidString, meetingId: meetingId, speaker: speaker, vector: Vectors.data(v)).insert(db)
            }
        }
    }

    // MARK: Notes editing and action items

    /// Saves the whole note edited as Markdown. Lines changed one for one teach fixes as line edits do.
    @discardableResult
    func updateSummary(_ meeting: Meeting, to text: String) -> Vocabulary.NotesLesson {
        let old = (fetch(meeting.id)?.summary ?? "").components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        var lesson = Vocabulary.NotesLesson()
        if old.count == new.count {
            for (a, b) in zip(old, new) where a != b {
                let learned = Vocabulary.learnFromNotesEdit(old: NotesLine(a).content, new: NotesLine(b).content)
                lesson.fixes += learned.fixes; lesson.terms += learned.terms
            }
        }
        update(meeting.id) { $0.summary = text; $0.notesEdited = true }
        return lesson
    }

    /// Replaces one line of the notes (inline editing). An empty line is removed. Returns what the
    /// edit taught for later meetings.
    @discardableResult
    func editNotesLine(meetingId: String, lineIndex: Int, to newLine: String) -> Vocabulary.NotesLesson {
        guard let summary = fetch(meetingId)?.summary else { return .init() }
        var lines = summary.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex), lines[lineIndex] != newLine else { return .init() }
        let lesson = Vocabulary.learnFromNotesEdit(old: NotesLine(lines[lineIndex]).content, new: NotesLine(newLine).content)
        if NotesLine(newLine).content.trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: lineIndex) }
        else { lines[lineIndex] = newLine }
        update(meetingId) { $0.summary = lines.joined(separator: "\n"); $0.notesEdited = true }
        return lesson
    }

    /// Adds a line after `lineIndex` (Return at the end of a bullet starts the next one).
    func insertNotesLine(meetingId: String, after lineIndex: Int, _ line: String) {
        guard let summary = fetch(meetingId)?.summary else { return }
        var lines = summary.components(separatedBy: "\n")
        lines.insert(line, at: min(lines.count, lineIndex + 1))
        update(meetingId) { $0.summary = lines.joined(separator: "\n"); $0.notesEdited = true }
    }

    /// Whole-word, case-insensitive occurrences of `word` in the notes.
    func occurrences(of word: String, inNotesOf meetingId: String) -> Int {
        guard let summary = fetch(meetingId)?.summary, let regex = Self.wordRegex(word) else { return 0 }
        return regex.numberOfMatches(in: summary, range: NSRange(summary.startIndex..., in: summary))
    }

    /// Applies a learned fix to the rest of this meeting's notes.
    func replaceInNotes(meetingId: String, _ word: String, with replacement: String) {
        guard let summary = fetch(meetingId)?.summary, let regex = Self.wordRegex(word) else { return }
        let fixed = regex.stringByReplacingMatches(in: summary, range: NSRange(summary.startIndex..., in: summary),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        update(meetingId) { $0.summary = fixed; $0.notesEdited = true }
    }

    private static func wordRegex(_ word: String) -> NSRegularExpression? {
        let body = word.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    /// Flips the checkbox on one `- [ ]` / `- [x]` line of the notes.
    func toggleActionItem(meetingId: String, lineIndex: Int) {
        guard let meeting = fetch(meetingId), let summary = meeting.summary else { return }
        var lines = summary.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }
        guard let flipped = NotesLine(lines[lineIndex]).toggled else { return }
        lines[lineIndex] = flipped
        update(meetingId) { $0.summary = lines.joined(separator: "\n") }
    }

    struct ActionItem: Identifiable {
        let id: String
        let meetingId: String
        let meetingTitle: String
        let meetingDate: Date
        let lineIndex: Int
        let text: String
        let done: Bool
    }

    func allActionItems() -> [ActionItem] {
        let meetings = (try? db.pool.read { try Meeting.order(Column("createdAt").desc).fetchAll($0) }) ?? []
        var out: [ActionItem] = []
        for m in meetings {
            for (i, line) in (m.summary ?? "").components(separatedBy: "\n").enumerated() {
                let parsed = NotesLine(line)
                guard case .task(let done) = parsed.kind else { continue }
                out.append(ActionItem(id: "\(m.id)#\(i)", meetingId: m.id, meetingTitle: m.title, meetingDate: m.createdAt,
                                      lineIndex: i, text: parsed.content, done: done))
            }
        }
        return out
    }

    // MARK: Storage

    func audioTotals() -> (count: Int, bytes: Int64) {
        let meetings = (try? db.pool.read { try Meeting.filter(Column("audioPath") != nil).fetchAll($0) }) ?? []
        return (meetings.count, meetings.reduce(0) { $0 + audioBytes($1) })
    }

    /// Deletes audio files (not transcripts or notes) of meetings older than `days`.
    @discardableResult
    func deleteAudio(olderThanDays days: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let old = (try? db.pool.read { try Meeting.filter(Column("audioPath") != nil && Column("createdAt") < cutoff).fetchAll($0) }) ?? []
        for m in old { deleteAudio(m) }
        return old.count
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: "setup.done")
        showSetup = false
    }

    func markdown(for meeting: Meeting, segments: [Segment]) -> String {
        var out = "# \(meeting.title)\n\n\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(Summarizer.clock(meeting.durationSeconds))\n\n"
        if let summary = meeting.summary, !summary.isEmpty { out += summary + "\n\n" }
        if !segments.isEmpty { out += "## Transcript\n\n" + Summarizer.transcriptText(segments) + "\n" }
        return out
    }

    // MARK: Deletes

    func deleteAudio(_ meeting: Meeting) {
        if let url = meeting.audioURL { try? FileManager.default.removeItem(at: url) }
        update(meeting.id) { $0.audioPath = nil }
    }

    func deleteTranscript(_ meeting: Meeting) {
        _ = try? db.pool.write { try Segment.filter(Column("meetingId") == meeting.id).deleteAll($0) }
    }

    func delete(_ meeting: Meeting) {
        if let url = meeting.audioURL { try? FileManager.default.removeItem(at: url) }
        _ = try? db.pool.write { try Meeting.deleteOne($0, key: meeting.id) }
        progress[meeting.id] = nil
        liveSummary[meeting.id] = nil
    }

    func rename(_ meeting: Meeting, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        update(meeting.id) { $0.title = clean }
    }

    // MARK: Sizes

    func audioBytes(_ meeting: Meeting) -> Int64 {
        guard let url = meeting.audioURL,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    func transcriptBytes(_ segments: [Segment]) -> Int64 {
        Int64(segments.reduce(0) { $0 + $1.text.utf8.count + 64 })
    }

    // MARK: Helpers

    private func saveTranscript(_ lines: [TranscriptLine], for meetingId: String) throws {
        try db.pool.write { db in
            try Segment.filter(Column("meetingId") == meetingId).deleteAll(db)
            for line in lines {
                try Segment(id: UUID().uuidString, meetingId: meetingId, startTime: line.start, endTime: line.end,
                            speaker: line.speaker, text: line.text, altText: line.altText).insert(db)
            }
        }
    }

    func fetch(_ id: String) -> Meeting? {
        try? db.pool.read { try Meeting.fetchOne($0, key: id) }
    }

    func segments(for id: String) -> [Segment] {
        (try? db.pool.read { try Segment.filter(Column("meetingId") == id).order(Column("startTime")).fetchAll($0) }) ?? []
    }

    private func update(_ id: String, _ change: (inout Meeting) -> Void) {
        try? db.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            change(&meeting)
            try meeting.update(db)
        }
    }

    private func fail(_ id: String, _ error: Error) {
        update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
        progress[id] = nil
        fraction[id] = nil
        Notifier.post(title: "Processing failed", body: error.localizedDescription)
    }
}
