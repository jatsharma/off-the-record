import SwiftUI

struct ContentView: View {
    @StateObject private var meetings = MeetingsObserver()
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var recording: RecordingController
    @State private var selection: String?
    @State private var search = ""
    @State private var pendingDelete: Meeting?
    @Environment(\.openSettings) private var openSettings
    @State private var hotKey: GlobalHotKey?
    @State private var dropTargeted = false
    /// Meetings whose transcript contains the search text.
    @State private var transcriptMatches: Set<String> = []
    static let actionItemsId = "__action-items"

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings.items }
        return meetings.items.filter {
            $0.title.lowercased().contains(q) || ($0.summary ?? "").lowercased().contains(q) || transcriptMatches.contains($0.id)
        }
    }

    private var groups: [(String, [Meeting])] {
        let cal = Calendar.current
        var buckets: [(String, [Meeting])] = [("Today", []), ("Yesterday", []), ("This week", []), ("Earlier", [])]
        for m in filtered {
            let idx: Int
            if cal.isDateInToday(m.createdAt) { idx = 0 }
            else if cal.isDateInYesterday(m.createdAt) { idx = 1 }
            else if let week = cal.dateInterval(of: .weekOfYear, for: Date()), week.contains(m.createdAt) { idx = 2 }
            else { idx = 3 }
            buckets[idx].1.append(m)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if meetings.items.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Press ⌘R or the record button to capture your first meeting."))
                } else {
                    List(selection: $selection) {
                        Label("Action items", systemImage: "checklist")
                            .tag(Self.actionItemsId)
                        ForEach(groups, id: \.0) { name, items in
                            Section(name) {
                                ForEach(items) { meeting in
                                    MeetingRow(meeting: meeting, progress: store.progress[meeting.id])
                                        .tag(meeting.id)
                                        .contextMenu {
                                            if let url = meeting.audioURL {
                                                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                            }
                                            Button("Delete…", role: .destructive) { pendingDelete = meeting }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onDeleteCommand {
                        if let id = selection, let m = meetings.items.first(where: { $0.id == id }) { pendingDelete = m }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
            .task(id: search) {
                // Transcripts are searched in the database, after a short pause in typing.
                let q = search.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { transcriptMatches = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                transcriptMatches = store.meetingsWithTranscript(containing: q)
            }
            .navigationTitle("Meetings")
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button {
                        selection = nil
                    } label: {
                        Label("New recording", systemImage: "plus")
                    }
                    .help("New recording")
                }
            }
        } detail: {
            if selection == Self.actionItemsId {
                ActionItemsView { id in selection = id }
            } else if let id = selection {
                MeetingDetailView(meetingId: id)
                    .id(id)
            } else {
                RecordView(onImported: { selection = $0 })
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["wav", "mp3", "m4a", "aiff", "aif", "caf", "flac"].contains(url.pathExtension.lowercased()) else { return }
                    Task { @MainActor in if let m = try? store.importAudio(from: url) { selection = m.id } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Rectangle().fill(.tint.opacity(0.08))
                    Label("Drop an audio file to import it", systemImage: "square.and.arrow.down")
                        .font(.title3).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $store.showSetup) { SetupView() }
        .onAppear {
            if hotKey == nil { hotKey = GlobalHotKey { Task { @MainActor in recording.toggle() } } }
        }
        .onAppear { recording.onFinished = { id in selection = id } }
        .confirmationDialog("Delete \"\(pendingDelete?.title ?? "")\" with its audio, transcript and notes?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                if let m = pendingDelete { if selection == m.id { selection = nil }; store.delete(m) }
                pendingDelete = nil
            }
        }
        #if DEBUG
        // Developer launch options (--auto-record, --import, --summarize, --screenshots, --diagnostics);
        // not in releases.
        .task { await AutoRecord.run(recorder: recorder, store: store) { selection = $0 } }
        .task { await Screenshots.run(select: { selection = $0 }, openSettings: { openSettings() }) }
        .task { await Diagnostics.writeIfAsked() }
        #endif
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let progress: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: meeting.status)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if let preview = Self.preview(meeting.summary) {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(meeting.createdAt.formatted(.dateTime.hour().minute()))
                    if meeting.durationSeconds > 0 {
                        Text("·")
                        Text(Summarizer.clock(meeting.durationSeconds))
                    }
                    if let progress, meeting.status == .transcribing || meeting.status == .summarizing {
                        Text("·")
                        Text(progress).lineLimit(1)
                    } else if meeting.status == .failed {
                        Text("· Needs attention").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

extension MeetingRow {
    /// First sentence of the summary, skipping headings.
    static func preview(_ summary: String?) -> String? {
        guard let summary else { return nil }
        for raw in summary.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let clean = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "- [ ] ", with: "")
            return clean.isEmpty ? nil : clean
        }
        return nil
    }
}

struct StatusDot: View {
    let status: MeetingStatus
    var body: some View {
        switch status {
        case .done: Color.clear.frame(width: 8, height: 8)          // finished meetings need no marker
        case .failed: Circle().fill(.orange).frame(width: 8, height: 8).accessibilityLabel("Needs attention")
        case .recording: Circle().fill(.red).frame(width: 8, height: 8)
        case .transcribing, .summarizing: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        }
    }
}
