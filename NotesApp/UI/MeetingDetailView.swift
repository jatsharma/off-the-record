import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let meetingId: String

    @StateObject private var observer: MeetingObserver
    @StateObject private var player = AudioPlayer()
    @EnvironmentObject private var store: MeetingStore
    @State private var tab: Tab = CommandLine.arguments.contains("--show-transcript") ? .transcript : .notes
    @State private var draftTitle = ""
    @State private var confirm: Confirm?
    @State private var showPlayer = false
    @State private var renaming: String?? = nil   // .some(speaker) while the popover is open
    @State private var newSpeakerName = ""

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    private enum Confirm: Identifiable { case audio, transcript, meeting; var id: Int { hashValue } }

    init(meetingId: String) {
        self.meetingId = meetingId
        _observer = StateObject(wrappedValue: MeetingObserver(id: meetingId))
    }

    var body: some View {
        if let meeting = observer.meeting {
            VStack(spacing: 0) {
                header(meeting)
                switch tab {
                case .notes: notesTab(meeting)
                case .transcript: transcriptTab(meeting)
                }
                Divider()
                footer(meeting)
            }
            .navigationTitle("")
            .toolbar { toolbarContent(meeting) }
            .onAppear { draftTitle = meeting.title }
            .onChange(of: meeting.title) { _, new in draftTitle = new }
            .onChange(of: meeting.audioPath) { _, _ in if meeting.audioPath == nil { showPlayer = false; player.stop() } }
            .onDisappear { player.stop() }
            .confirmationDialog(dialogTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(dialogButton, role: .destructive) { performConfirm(meeting) }
            }
        } else {
            ContentUnavailableView("Meeting deleted", systemImage: "trash")
        }
    }

    // MARK: Header

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.title.bold())
                .onSubmit { store.rename(meeting, to: draftTitle) }
            HStack(spacing: 14) {
                Label(meeting.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(Summarizer.clock(meeting.durationSeconds), systemImage: "clock")
                if !observer.segments.isEmpty {
                    let speakers = Set(observer.segments.compactMap(\.speaker)).count
                    Label("\(speakers) speaker\(speakers == 1 ? "" : "s")", systemImage: "person.2")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            PipelineStrip(meeting: meeting, progress: store.progress[meeting.id], hasTranscript: !observer.segments.isEmpty,
                          retryTranscribe: { store.retranscribe(meeting) },
                          retryNotes: { Task { await store.summarize(meetingId: meeting.id) } })
            UnderlineTabs(items: [
                .init(value: Tab.notes, title: "Notes", detail: nil),
                .init(value: Tab.transcript, title: "Transcript", detail: observer.segments.isEmpty ? nil : "\(observer.segments.count)"),
            ], selection: $tab)
            .padding(.top, 10)
        }
        .padding(.horizontal, 28).padding(.top, 20)
    }

    // MARK: Notes

    private func notesTab(_ meeting: Meeting) -> some View {
        ScrollView {
            let text = store.liveSummary[meeting.id] ?? meeting.summary
            VStack(alignment: .leading, spacing: 12) {
                if let text, !text.isEmpty {
                    MarkdownText(text)
                        .frame(maxWidth: 760, alignment: .leading)
                    if store.liveSummary[meeting.id] != nil {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Writing…").font(.caption).foregroundStyle(.secondary) }
                    }
                } else if meeting.status == .done {
                    ContentUnavailableView("No notes", systemImage: "doc.text",
                                           description: Text(observer.segments.isEmpty ? "There is no transcript to write notes from." : "Use Regenerate to write notes from the transcript."))
                } else {
                    ContentUnavailableView("Notes are on their way", systemImage: "sparkles",
                                           description: Text("They appear here as soon as the transcript is ready."))
                }
            }
            .padding(28)
        }
    }

    // MARK: Transcript

    private func transcriptTab(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            if showPlayer, meeting.audioURL != nil {
                PlayerBar(player: player)
                    .task { await player.load(meeting.audioURL) }
                Divider()
            }
            if observer.segments.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote",
                                       description: Text(meeting.audioPath == nil ? "The audio was deleted, so this meeting cannot be transcribed again." : "Transcription has not produced any lines yet."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(observer.segments) { segment in
                                TranscriptRow(segment: segment,
                                              isCurrent: player.isPlaying && player.currentTime >= segment.startTime && player.currentTime < segment.endTime,
                                              color: SpeakerPalette.color(for: segment.speaker, in: observer.segments),
                                              canPlay: meeting.audioURL != nil,
                                              onSeek: { listen(meeting, from: segment.startTime) },
                                              onRename: { renaming = .some(segment.speaker); newSpeakerName = segment.speaker ?? "" })
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                    .onChange(of: player.currentTime) { _, t in
                        guard player.isPlaying, let current = observer.segments.first(where: { t >= $0.startTime && t < $0.endTime }) else { return }
                        withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }
        }
        .popover(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename speaker").font(.headline)
                Text("Applies to every line by this voice in this meeting.").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $newSpeakerName).textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { applyRename(meeting) }
                HStack { Spacer(); Button("Cancel") { renaming = nil }; Button("Rename") { applyRename(meeting) }.buttonStyle(.borderedProminent) }
            }
            .padding(16)
        }
    }

    /// Shows the player (loading the file if needed) and starts from a point in the meeting.
    private func listen(_ meeting: Meeting, from time: Double? = nil) {
        showPlayer = true
        Task {
            await player.load(meeting.audioURL)
            if let time { player.play(from: time) }
        }
    }

    private func applyRename(_ meeting: Meeting) {
        if case .some(let old) = renaming { store.renameSpeaker(old, to: newSpeakerName, in: meeting.id) }
        renaming = nil
    }

    // MARK: Footer and toolbar

    private func footer(_ meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            Label(meeting.audioPath == nil ? "Audio deleted" : "Audio \(ByteCountFormatter.string(fromByteCount: store.audioBytes(meeting), countStyle: .file))",
                  systemImage: "waveform")
            Label(observer.segments.isEmpty ? "No transcript" : "Transcript \(ByteCountFormatter.string(fromByteCount: store.transcriptBytes(observer.segments), countStyle: .file))",
                  systemImage: "text.quote")
            Spacer()
            Menu {
                Button("Delete audio only…") { confirm = .audio }.disabled(meeting.audioPath == nil)
                Button("Delete transcript only…") { confirm = .transcript }.disabled(observer.segments.isEmpty)
                Divider()
                Button("Delete meeting…", role: .destructive) { confirm = .meeting }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28).padding(.vertical, 8)
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if showPlayer { showPlayer = false; player.stop() } else { listen(meeting) }
            } label: { Label(showPlayer ? "Hide player" : "Listen", systemImage: showPlayer ? "headphones.slash" : "headphones") }
            .help(showPlayer ? "Hide the audio player" : "Play the recording")
            .disabled(meeting.audioPath == nil)

            Button {
                Task { await store.summarize(meetingId: meeting.id) }
            } label: { Label("Regenerate notes", systemImage: "arrow.clockwise") }
            .help("Write the notes again with the current prompt and model")
            .disabled(observer.segments.isEmpty || meeting.status == .summarizing || meeting.status == .transcribing)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab == .notes ? (meeting.summary ?? "") : Summarizer.transcriptText(observer.segments), forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .help(tab == .notes ? "Copy notes as Markdown" : "Copy transcript")
            .disabled(tab == .notes ? (meeting.summary ?? "").isEmpty : observer.segments.isEmpty)

            Button {
                exportMarkdown(meeting)
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .help("Save notes and transcript as a Markdown file")
        }
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.markdown(for: meeting, segments: observer.segments).write(to: url, atomically: true, encoding: .utf8)
    }

    private var dialogTitle: String {
        switch confirm {
        case .audio: return "Delete the audio recording? The transcript and notes stay, but the meeting cannot be transcribed again."
        case .transcript: return "Delete the transcript? The notes stay. Audio can be transcribed again."
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
        case .audio: player.stop(); store.deleteAudio(meeting)
        case .transcript: store.deleteTranscript(meeting)
        case .meeting: player.stop(); store.delete(meeting)
        case nil: break
        }
        confirm = nil
    }
}

// MARK: - Pieces

/// Recorded → Transcribed → Notes, with the live status line and retry buttons.
struct PipelineStrip: View {
    let meeting: Meeting
    let progress: String?
    let hasTranscript: Bool
    let retryTranscribe: () -> Void
    let retryNotes: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            step("Recorded", done: meeting.status != .recording, active: meeting.status == .recording)
            arrow
            step("Transcribed", done: hasTranscript && meeting.status != .transcribing, active: meeting.status == .transcribing)
            arrow
            step("Notes", done: meeting.status == .done && !(meeting.summary ?? "").isEmpty, active: meeting.status == .summarizing)
            if let progress, meeting.status == .transcribing || meeting.status == .summarizing {
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 6)
            }
            if meeting.status == .failed {
                Label(meeting.errorMessage ?? "Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.leading, 6)
                if meeting.audioPath != nil { Button("Retry transcription", action: retryTranscribe).controlSize(.small) }
                if hasTranscript { Button("Retry notes", action: retryNotes).controlSize(.small) }
            }
            Spacer()
        }
    }

    private var arrow: some View { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary) }

    private func step(_ name: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 5) {
            if active { ProgressView().controlSize(.mini) }
            else { Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary.opacity(0.5)) }
            Text(name)
        }
        .font(.caption.weight(active ? .semibold : .regular))
        .foregroundStyle(done || active ? .primary : .secondary)
    }
}

struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            if player.isLoading {
                ProgressView().controlSize(.small).frame(width: 24)
            } else {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 24)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.isLoaded)
            }
            Text(Summarizer.clock(player.currentTime)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
            Text(Summarizer.clock(player.duration)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(.bar)
    }
}

struct TranscriptRow: View {
    let segment: Segment
    let isCurrent: Bool
    let color: Color
    let canPlay: Bool
    let onSeek: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSeek) {
                Text(Summarizer.clock(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? "Play from here" : "")
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onRename) {
                    Text(segment.speaker ?? "Unknown")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .help("Rename this speaker")
                Text(segment.text).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
    }
}

enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
    static func color(for speaker: String?, in segments: [Segment]) -> Color {
        guard let speaker else { return .secondary }
        var seen: [String] = []
        for s in segments { if let n = s.speaker, !seen.contains(n) { seen.append(n) } }
        let i = seen.firstIndex(of: speaker) ?? 0
        return colors[i % colors.count]
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
                    inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    inline(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 10)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2))).font(.title2.bold()).padding(.top, 10)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: line.hasPrefix("- [ ] ") ? "square" : "checkmark.square")
                            .foregroundStyle(.secondary).padding(.top, 2)
                        inline(String(line.dropFirst(6)))
                    }
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                    .padding(.leading, 4)
                } else {
                    inline(line)
                }
            }
        }
        .textSelection(.enabled)
        .lineSpacing(3)
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }
}
