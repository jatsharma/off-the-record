import SwiftUI

struct MeetingDetailView: View {
    let meetingId: String

    @StateObject private var observer: MeetingObserver
    @EnvironmentObject private var store: MeetingStore
    @State private var confirm: Confirm?
    @State private var draftTitle = ""

    private enum Confirm: Identifiable {
        case audio, transcript, meeting
        var id: Int { hashValue }
    }

    init(meetingId: String) {
        self.meetingId = meetingId
        _observer = StateObject(wrappedValue: MeetingObserver(id: meetingId))
    }

    var body: some View {
        if let meeting = observer.meeting {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(meeting)
                    statusLine(meeting)
                    summarySection(meeting)
                    transcriptSection
                    storageSection(meeting)
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .confirmationDialog(dialogTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(dialogButton, role: .destructive) { performConfirm(meeting) }
            }
        } else {
            ContentUnavailableView("Meeting deleted", systemImage: "trash")
        }
    }

    // MARK: Sections

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $draftTitle, onCommit: { store.rename(meeting, to: draftTitle) })
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
                .onAppear { draftTitle = meeting.title }
            Text("\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(Summarizer.clock(meeting.durationSeconds))")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusLine(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .transcribing, .summarizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(store.progress[meeting.id] ?? (meeting.status == .transcribing ? "Transcribing" : "Writing notes"))
                    .foregroundStyle(.secondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Label(meeting.errorMessage ?? "Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    if meeting.audioPath != nil {
                        Button("Retry transcription") { store.retranscribe(meeting) }
                    }
                    if !observer.segments.isEmpty {
                        Button("Retry notes") { Task { await store.summarize(meetingId: meeting.id) } }
                    }
                }
            }
        case .done:
            EmptyView()
        }
    }

    private func summarySection(_ meeting: Meeting) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                let live = store.liveSummary[meeting.id]
                let text = live ?? meeting.summary
                if let text, !text.isEmpty {
                    MarkdownText(text)
                } else if meeting.status == .done {
                    Text("No notes yet.").foregroundStyle(.secondary)
                } else {
                    Text("Notes will appear here when the transcript is ready.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Regenerate notes") { Task { await store.summarize(meetingId: meeting.id) } }
                        .disabled(observer.segments.isEmpty || meeting.status == .summarizing || meeting.status == .transcribing)
                    if let summary = meeting.summary, !summary.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Notes", systemImage: "doc.text")
        }
    }

    private var transcriptSection: some View {
        GroupBox {
            if observer.segments.isEmpty {
                Text("No transcript.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(observer.segments) { segment in
                        HStack(alignment: .top, spacing: 10) {
                            Text(Summarizer.clock(segment.startTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                if let speaker = segment.speaker {
                                    Text(speaker).font(.caption.bold()).foregroundStyle(.secondary)
                                }
                                Text(segment.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(6)
            }
        } label: {
            Label("Transcript", systemImage: "text.quote")
        }
    }

    private func storageSection(_ meeting: Meeting) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                storageRow("Audio recording", bytes: store.audioBytes(meeting), present: meeting.audioPath != nil,
                           note: "Needed only to transcribe again.") { confirm = .audio }
                storageRow("Transcript", bytes: store.transcriptBytes(observer.segments), present: !observer.segments.isEmpty,
                           note: "Needed to regenerate notes.") { confirm = .transcript }
                Divider()
                Button("Delete meeting", role: .destructive) { confirm = .meeting }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Storage", systemImage: "internaldrive")
        }
    }

    private func storageRow(_ name: String, bytes: Int64, present: Bool, note: String, delete: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(present ? note : "Deleted").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(present ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "—")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Delete", role: .destructive, action: delete).disabled(!present)
        }
    }

    // MARK: Confirmations

    private var dialogTitle: String {
        switch confirm {
        case .audio: return "Delete the audio recording? The transcript and notes stay."
        case .transcript: return "Delete the transcript? The notes stay; audio can be transcribed again."
        case .meeting: return "Delete this meeting, its audio, transcript and notes?"
        case nil: return ""
        }
    }
    private var dialogButton: String {
        switch confirm {
        case .audio: return "Delete audio"
        case .transcript: return "Delete transcript"
        case .meeting: return "Delete meeting"
        case nil: return ""
        }
    }
    private func performConfirm(_ meeting: Meeting) {
        switch confirm {
        case .audio: store.deleteAudio(meeting)
        case .transcript: store.deleteTranscript(meeting)
        case .meeting: store.delete(meeting)
        case nil: break
        }
        confirm = nil
    }
}

/// Just enough Markdown for notes: headings, bullets, checkboxes, inline styles.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("### ") {
                    inline(String(line.dropFirst(4))).font(.headline)
                } else if line.hasPrefix("## ") {
                    inline(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 6)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2))).font(.title2.bold()).padding(.top, 6)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: line.hasPrefix("- [ ] ") ? "square" : "checkmark.square")
                            .foregroundStyle(.secondary).padding(.top, 2)
                        inline(String(line.dropFirst(6)))
                    }
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                } else {
                    inline(line)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }
}
