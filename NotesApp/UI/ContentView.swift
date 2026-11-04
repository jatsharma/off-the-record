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

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings.items }
        return meetings.items.filter { $0.title.lowercased().contains(q) || ($0.summary ?? "").lowercased().contains(q) }
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
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search titles and notes")
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
            if let id = selection {
                MeetingDetailView(meetingId: id)
                    .id(id)
            } else {
                RecordView()
            }
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
        .task { await AutoRecord.run(recorder: recorder, store: store) { selection = $0 } }
        .task { await Screenshots.run(select: { selection = $0 }, openSettings: { openSettings() }) }
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
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(2)
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

struct StatusDot: View {
    let status: MeetingStatus
    var body: some View {
        switch status {
        case .done: Circle().fill(.green).frame(width: 8, height: 8)
        case .failed: Circle().fill(.orange).frame(width: 8, height: 8)
        case .recording: Circle().fill(.red).frame(width: 8, height: 8)
        case .transcribing, .summarizing: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        }
    }
}
