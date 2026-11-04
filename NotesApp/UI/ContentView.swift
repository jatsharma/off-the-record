import SwiftUI

struct ContentView: View {
    @StateObject private var meetings = MeetingsObserver()
    @EnvironmentObject private var recorder: AudioRecorder
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(meetings.items) { meeting in
                    MeetingRow(meeting: meeting).tag(meeting.id)
                }
            }
            .navigationTitle("Notes")
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                Button {
                    selection = nil
                } label: {
                    Label("New recording", systemImage: "record.circle")
                }
                .disabled(recorder.isRecording)
            }
        } detail: {
            if let id = selection {
                MeetingDetailView(meetingId: id)
                    .id(id)
            } else {
                RecordView { newId in selection = newId }
            }
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                if meeting.durationSeconds > 0 { Text("·"); Text(Summarizer.clock(meeting.durationSeconds)) }
                Spacer()
                StatusBadge(status: meeting.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: MeetingStatus
    var body: some View {
        switch status {
        case .done: EmptyView()
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .transcribing, .summarizing: ProgressView().controlSize(.mini)
        }
    }
}
