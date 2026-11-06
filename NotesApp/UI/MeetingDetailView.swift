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
    @State private var showPlayer = CommandLine.arguments.contains("--show-player")
    @State private var followedSegment: String?
    @State private var editingNotes = false        // whole note as Markdown
    @State private var notesDraft = ""
    @State private var lesson: Vocabulary.NotesLesson?
    @State private var speakerNames: [String: String] = [:]
    @State private var typedDraft: String?
    @State private var showTyped = false
    @AppStorage("speakers.dismissed") private var dismissedSpeakerCards = ""
    @State private var renaming: String?? = nil   // .some(speaker) while the popover is open
    @State private var newSpeakerName = ""
    @State private var editingSegment: Segment?
    @State private var segmentDraft = ""

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    private enum Confirm: Identifiable { case audio, transcript, meeting, regenerate; var id: Int { hashValue } }

    init(meetingId: String) {
        self.meetingId = meetingId
        _observer = StateObject(wrappedValue: MeetingObserver(id: meetingId))
    }

    var body: some View {
        if let meeting = observer.meeting {
            VStack(spacing: 0) {
                header(meeting)
                // The player sits above both tabs so "Listen" works from Notes too.
                if showPlayer, meeting.audioURL != nil {
                    Divider()
                    PlayerBar(player: player, spaceToggles: !editingNotes && renaming == nil)
                        .task { await player.load(meeting.audioURL) }
                    Divider()
                }
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
            PipelineStrip(meeting: meeting, progress: store.progress[meeting.id], fraction: store.fraction[meeting.id],
                          stageStarted: store.stageStarted[meeting.id], hasTranscript: !observer.segments.isEmpty,
                          retryTranscribe: { store.retranscribe(meeting) },
                          retryNotes: { store.queueSummarize(meetingId: meeting.id) })
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
                if showSpeakerCard(meeting), !editingNotes {
                    speakerCard(meeting).frame(maxWidth: 760).padding(.bottom, 6)
                }
                if !editingNotes, store.liveSummary[meeting.id] == nil {
                    typedNotesSection(meeting).frame(maxWidth: 760, alignment: .leading)
                }
                if editingNotes {
                    TextEditor(text: $notesDraft)
                        .font(.body.monospaced())
                        .frame(maxWidth: 760, minHeight: 420)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Save") { show(store.updateSummary(meeting, to: notesDraft)); editingNotes = false }
                            .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                        Button("Cancel") { editingNotes = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Text("Markdown. Checkboxes: - [ ] task").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 760)
                } else if let text, !text.isEmpty {
                    let writing = store.liveSummary[meeting.id] != nil
                    if let lesson, !writing {
                        LessonBanner(lesson: lesson,
                                     remaining: { store.occurrences(of: $0.heard, inNotesOf: meeting.id) },
                                     replaceAll: { store.replaceInNotes(meetingId: meeting.id, $0.heard, with: $0.wanted) },
                                     undo: { Vocabulary.forget(lesson); self.lesson = nil },
                                     dismiss: { self.lesson = nil })
                            .frame(maxWidth: 760)
                    }
                    EditableNotes(text: text, editable: !writing,
                                  onToggle: { store.toggleActionItem(meetingId: meeting.id, lineIndex: $0) },
                                  onCommit: { show(store.editNotesLine(meetingId: meeting.id, lineIndex: $0, to: $1)) },
                                  onInsert: { store.insertNotesLine(meetingId: meeting.id, after: $0, $1) },
                                  onSeek: meeting.audioURL == nil ? nil : { listen(meeting, from: $0) })
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, -6)       // rows have a hover inset; keep text in line with the title
                    if writing {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Writing…").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Double-click a line to edit it. Words you fix are remembered for future meetings.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                } else if meeting.status == .failed {
                    ContentUnavailableView("No notes yet", systemImage: "exclamationmark.triangle",
                                           description: Text("Processing stopped. Use Retry above to continue."))
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
            if observer.segments.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.quote",
                                       description: Text(meeting.audioPath == nil ? "The audio was deleted, so this meeting cannot be transcribed again." : "Transcription has not produced any lines yet."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if showSpeakerCard(meeting) {
                            speakerCard(meeting).frame(maxWidth: 764).padding(.horizontal, 28).padding(.top, 14)
                        }
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(observer.segments) { segment in
                                TranscriptRow(segment: segment,
                                              isCurrent: player.isPlaying && player.currentTime >= segment.startTime && player.currentTime < segment.endTime,
                                              color: SpeakerPalette.color(for: segment.speaker, in: observer.segments),
                                              canPlay: meeting.audioURL != nil,
                                              onSeek: { listen(meeting, from: segment.startTime) },
                                              onRename: { renaming = .some(segment.speaker); newSpeakerName = segment.speaker ?? "" },
                                              onEdit: { segmentDraft = segment.text; editingSegment = segment })
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                    .onChange(of: player.currentTime) { _, t in
                        // Scroll only when the playhead enters a new line, so the reader can still scroll freely.
                        guard player.isPlaying, let current = observer.segments.first(where: { t >= $0.startTime && t < $0.endTime }),
                              current.id != followedSegment else { return }
                        followedSegment = current.id
                        withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }
        }
        .closedOnQuit { editingSegment = nil; confirm = nil }
        .sheet(item: $editingSegment) { segment in
            VStack(alignment: .leading, spacing: 10) {
                Text("Correct this line").font(.headline)
                if let raw = segment.rawText, raw != segment.text {
                    Text("Recognizer heard: \(raw)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextEditor(text: $segmentDraft)
                    .font(.body)
                    .frame(width: 460, height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                Text("Names and terms you type here are added to Settings ▸ Vocabulary, so later meetings get them right.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { editingSegment = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") { store.editSegment(segment, to: segmentDraft); editingSegment = nil }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
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

    // MARK: Typed notes

    /// What the user typed during the meeting, editable; the notes are written from it with the transcript.
    @ViewBuilder
    private func typedNotesSection(_ meeting: Meeting) -> some View {
        let saved = meeting.typedNotes ?? ""
        if saved.isEmpty && !showTyped {
            Button { showTyped = true; typedDraft = "" } label: { Label("Add your own notes", systemImage: "square.and.pencil") }
                .buttonStyle(.link).font(.callout)
        } else {
            DisclosureGroup(isExpanded: Binding(get: { showTyped || !saved.isEmpty && typedDraft != nil }, set: { open in
                showTyped = open
                typedDraft = open ? (typedDraft ?? saved) : nil
            })) {
                VStack(alignment: .leading, spacing: 6) {
                    TypedNotesEditor(text: Binding(get: { typedDraft ?? saved }, set: { typedDraft = $0 }))
                    HStack {
                        Text("Regenerate the notes to build them from these.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save") { store.saveTypedNotes(meeting.id, typedDraft ?? saved) }
                            .controlSize(.small)
                            .disabled((typedDraft ?? saved) == saved)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Your notes from the meeting", systemImage: "square.and.pencil").font(.callout.weight(.semibold))
            }
        }
    }

    // MARK: Naming speakers

    /// Unnamed speakers with how much they said and where their longest line starts.
    private var unnamedSpeakers: [(label: String, lines: Int, sample: Double)] {
        var stats: [String: (lines: Int, longest: Double, at: Double)] = [:]
        for s in observer.segments {
            guard let label = s.speaker, MeetingStore.isUnnamed(label) else { continue }
            var e = stats[label] ?? (0, 0, s.startTime)
            e.lines += 1
            if s.endTime - s.startTime > e.longest { e.longest = s.endTime - s.startTime; e.at = s.startTime }
            stats[label] = e
        }
        return stats.map { ($0.key, $0.value.lines, $0.value.at) }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func showSpeakerCard(_ meeting: Meeting) -> Bool {
        meeting.status == .done && !dismissedSpeakerCards.split(separator: ",").contains(Substring(meeting.id))
            && !unnamedSpeakers.isEmpty
    }

    /// Asks once per meeting who the unknown voices were. Names go into the transcript and the notes,
    /// and the voices are remembered for later meetings.
    private func speakerCard(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Who was in this meeting?", systemImage: "person.2.wave.2").font(.callout.weight(.semibold))
                Spacer()
                Button("Not now") { dismissedSpeakerCards += (dismissedSpeakerCards.isEmpty ? "" : ",") + meeting.id }
                    .controlSize(.small)
            }
            Text("Name the voices and the notes use real names. Off the Record remembers each voice for next time.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(unnamedSpeakers, id: \.label) { speaker in
                HStack(spacing: 10) {
                    Circle().fill(SpeakerPalette.color(for: speaker.label, in: observer.segments)).frame(width: 8, height: 8)
                    Text(speaker.label).font(.callout).frame(width: 90, alignment: .leading)
                    Text("\(speaker.lines) line\(speaker.lines == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Button {
                        showPlayer = true
                        Task { await player.load(meeting.audioURL); player.playClip(from: speaker.sample, seconds: 6) }
                    } label: { Label("Listen", systemImage: "play.circle") }
                    .controlSize(.small)
                    .disabled(meeting.audioURL == nil)
                    .help("Play six seconds of this voice")
                    TextField("Name", text: Binding(get: { speakerNames[speaker.label] ?? "" }, set: { speakerNames[speaker.label] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        .onSubmit { nameSpeaker(speaker.label, in: meeting) }
                    Button("Save") { nameSpeaker(speaker.label, in: meeting) }
                        .controlSize(.small)
                        .disabled((speakerNames[speaker.label] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nameSpeaker(_ label: String, in meeting: Meeting) {
        let name = (speakerNames[label] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.renameSpeaker(label, to: name, in: meeting.id)
        speakerNames[label] = nil
    }

    /// Shows what an edit taught, if anything.
    private func show(_ learned: Vocabulary.NotesLesson) {
        guard !learned.isEmpty else { return }
        withAnimation { lesson = learned }
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
                if meeting.notesEdited { confirm = .regenerate } else { store.queueSummarize(meetingId: meeting.id) }
            } label: { Label("Regenerate notes", systemImage: "arrow.clockwise") }
            .help("Write the notes again with the current prompt and model")
            .disabled(observer.segments.isEmpty || meeting.status == .summarizing || meeting.status == .transcribing)

            Menu {
                Button("Copy Notes") { copy(ExternalLink.exportable(meeting.summary ?? "")) }.disabled((meeting.summary ?? "").isEmpty)
                Button("Copy Transcript") { copy(Summarizer.transcriptText(observer.segments)) }.disabled(observer.segments.isEmpty)
                Divider()
                Button("Export as Markdown…") { exportMarkdown(meeting) }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .help("Copy or export the notes and transcript")

            Menu {
                Button(editingNotes ? "Stop Editing Markdown" : "Edit Notes as Markdown") {
                    tab = .notes
                    if editingNotes { editingNotes = false } else { notesDraft = meeting.summary ?? ""; editingNotes = true }
                }
                .disabled((meeting.summary ?? "").isEmpty && !editingNotes)
                Button("Name Speakers…") {
                    dismissedSpeakerCards = dismissedSpeakerCards.split(separator: ",").filter { $0 != Substring(meeting.id) }.joined(separator: ",")
                }
                .disabled(unnamedSpeakers.isEmpty)
                Divider()
                Button("Retranscribe") { store.retranscribe(meeting) }
                    .disabled(meeting.audioPath == nil || meeting.status == .transcribing || meeting.status == .summarizing)
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .help("More actions")
        }
    }

    /// Kept on this Mac: not offered to the user's other devices through Universal Clipboard.
    private func copy(_ text: String) {
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(text, forType: .string)
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
        case .regenerate: return "Write the notes again? Your edits to these notes will be replaced. Words you fixed are kept and used for the new notes."
        case nil: return ""
        }
    }
    private var dialogButton: String {
        switch confirm {
        case .audio: return "Delete audio"
        case .transcript: return "Delete transcript"
        case .meeting: return "Delete meeting"
        case .regenerate: return "Regenerate notes"
        case nil: return ""
        }
    }
    private func performConfirm(_ meeting: Meeting) {
        switch confirm {
        case .audio: player.stop(); store.deleteAudio(meeting)
        case .transcript: store.deleteTranscript(meeting)
        case .meeting: player.stop(); store.delete(meeting)
        case .regenerate: lesson = nil; store.queueSummarize(meetingId: meeting.id)
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
    let fraction: Double?
    let stageStarted: Date?
    let hasTranscript: Bool
    let retryTranscribe: () -> Void
    let retryNotes: () -> Void
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            steps
            if meeting.status == .transcribing || meeting.status == .summarizing {
                HStack(spacing: 10) {
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 220)
                        Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(width: 220).controlSize(.small)
                    }
                    if let stageStarted {
                        Text(elapsedText(since: stageStarted)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
            }
        }
    }

    private func elapsedText(since: Date) -> String {
        let s = Int(now.timeIntervalSince(since))
        let typical = meeting.status == .summarizing ? "notes usually take 1–2 min" : "about 1 min per 30 min of audio"
        return "\(s / 60):\(String(format: "%02d", s % 60)) elapsed · \(typical)"
    }

    private var steps: some View {
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
    /// Off while a text field may want the space bar (editing notes, renaming a speaker).
    var spaceToggles = true

    var body: some View {
        HStack(spacing: 12) {
            if player.isLoading {
                ProgressView().controlSize(.small).frame(width: 24)
            } else {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(spaceToggles ? KeyboardShortcut(.space, modifiers: []) : nil)
                .help(player.isLoaded ? "Play / pause (space)" : "This recording could not be opened")
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
    let onEdit: () -> Void
    @State private var hovering = false

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
            .accessibilityLabel("Play from \(Summarizer.clock(segment.startTime))")
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
            VStack(spacing: 6) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .accessibilityLabel("Correct this line")
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Correct this line")
                    .opacity(hovering ? 1 : 0)
                if let raw = segment.rawText, raw != segment.text {
                    Image(systemName: "wand.and.sparkles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Corrected. The recognizer heard: \(raw)")
                }
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { Button("Correct this line…", action: onEdit) }
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
