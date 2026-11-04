import Foundation
import AVFoundation
import GRDB

/// Orchestrates record -> transcribe -> summarize, and owns deletes.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// One status line per meeting while it is being processed.
    @Published var progress: [String: String] = [:]
    /// Summary text as it streams in, before it is saved.
    @Published var liveSummary: [String: String] = [:]

    private let db = AppDatabase.shared

    // MARK: Recording

    func createMeeting(title: String) throws -> Meeting {
        let id = UUID().uuidString
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let meeting = Meeting(
            id: id,
            title: cleanTitle.isEmpty ? Date().formatted(date: .abbreviated, time: .shortened) : cleanTitle,
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
        let meeting = Meeting(
            id: id,
            title: title ?? source.deletingPathExtension().lastPathComponent,
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
            let lines = try await SpeechEngine.shared.transcribe(file: audio) { [weak self] text in
                Task { @MainActor in self?.progress[meetingId] = text }
            }
            try saveTranscript(lines, for: meetingId)
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
            progress[meetingId] = nil
        } catch {
            liveSummary[meetingId] = nil
            fail(meetingId, error)
        }
    }

    func retranscribe(_ meeting: Meeting) {
        Task { await process(meetingId: meeting.id) }
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
    }
}
