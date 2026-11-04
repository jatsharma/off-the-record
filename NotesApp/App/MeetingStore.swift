import Foundation
import AVFoundation
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
        Task { await process(meetingId: meeting.id) }
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
        Task { await process(meetingId: id) }
        return meeting
    }

    // MARK: Pipeline

    func process(meetingId: String) async {
        guard let meeting = fetch(meetingId), let audio = meeting.audioURL else { return }
        do {
            update(meetingId) { $0.status = .transcribing }
            stageStarted[meetingId] = Date()
            fraction[meetingId] = 0
            let known = knownVoices()
            let result = try await SpeechEngine.shared.transcribe(file: audio, knownVoices: known) { [weak self] fraction, text in
                Task { @MainActor in self?.progress[meetingId] = text; self?.fraction[meetingId] = fraction }
            }
            fraction[meetingId] = nil
            try saveTranscript(result.lines, for: meetingId)
            saveSpeakerVectors(result.speakerVectors, for: meetingId)
            await summarize(meetingId: meetingId)
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
            progress[meetingId] = "Writing notes with \(model)"
            let prompt = Summarizer.buildPrompt(meeting: meeting, segments: segments)
            var text = ""
            for try await token in client.chat(model: model, system: AppSettings.systemPrompt, user: prompt,
                                               contextTokens: AppSettings.contextTokens) {
                text += token
                liveSummary[meetingId] = text
            }
            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
            update(meetingId) { $0.summary = final; $0.status = .done }
            liveSummary[meetingId] = nil
            if Self.isAutoTitle(meeting.title) {
                progress[meetingId] = "Naming the meeting"
                if let title = try? await suggestTitle(notes: final, client: client, model: model) {
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

    func retranscribe(_ meeting: Meeting) {
        Task { await process(meetingId: meeting.id) }
    }

    // MARK: Titles

    static func autoTitle(_ kind: String) -> String {
        "\(kind) · \(Date().formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }

    static func isAutoTitle(_ title: String) -> Bool {
        title.hasPrefix("Meeting · ") || title.hasPrefix("Imported · ") || title.hasPrefix("Auto test")
            || title.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil
    }

    private func suggestTitle(notes: String, client: OllamaClient, model: String) async throws -> String? {
        let prompt = "Give this meeting a title of three to seven words that says what it was about. Output only the title, no quotes, no punctuation at the end.\n\n\(notes.prefix(3000))"
        var text = ""
        for try await token in client.chat(model: model, system: "You name meetings.", user: prompt, contextTokens: 4096) { text += token }
        let title = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
        return (3...80).contains(title.count) ? title : nil
    }

    // MARK: Speakers and export

    /// Renames a speaker in one meeting and teaches the name to voice memory, so the same
    /// voice is labelled automatically in later meetings.
    func renameSpeaker(_ old: String?, to new: String, in meetingId: String) {
        let clean = new.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        try? db.pool.write { db in
            if let old {
                try db.execute(sql: "update segment set speaker = ? where meetingId = ? and speaker = ?", arguments: [clean, meetingId, old])
                if var ms = try MeetingSpeaker.filter(Column("meetingId") == meetingId && Column("speaker") == old).fetchOne(db) {
                    ms.speaker = clean
                    try ms.update(db)
                    let vector = Vectors.floats(ms.vector)
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

    func updateSummary(_ meeting: Meeting, to text: String) {
        update(meeting.id) { $0.summary = text }
    }

    /// Flips the checkbox on one `- [ ]` / `- [x]` line of the notes.
    func toggleActionItem(meetingId: String, lineIndex: Int) {
        guard let meeting = fetch(meetingId), let summary = meeting.summary else { return }
        var lines = summary.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }
        let line = lines[lineIndex]
        if line.hasPrefix("- [ ] ") { lines[lineIndex] = "- [x] " + line.dropFirst(6) }
        else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { lines[lineIndex] = "- [ ] " + line.dropFirst(6) }
        else { return }
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
                let open = line.hasPrefix("- [ ] "), done = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
                guard open || done else { continue }
                out.append(ActionItem(id: "\(m.id)#\(i)", meetingId: m.id, meetingTitle: m.title, meetingDate: m.createdAt,
                                      lineIndex: i, text: String(line.dropFirst(6)), done: done))
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
                            speaker: line.speaker, text: line.text).insert(db)
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
