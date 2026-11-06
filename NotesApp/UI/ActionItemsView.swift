import SwiftUI

/// Every checkbox from every meeting's notes, open ones first. Ticking edits the notes.
struct ActionItemsView: View {
    @EnvironmentObject private var store: MeetingStore
    @StateObject private var meetings = MeetingsObserver()
    @State private var showDone = false
    @AppStorage("actions.mineOnly") private var mineOnly = false
    var open: (String) -> Void

    private var items: [MeetingStore.ActionItem] { store.allActionItems() }

    var body: some View {
        let visible = items.filter { (showDone || !$0.done) && (!mineOnly || Self.isMine($0.text)) }
        let grouped = Dictionary(grouping: visible, by: \.meetingId)
        let order = visible.map(\.meetingId).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action items").font(.title.bold())
                    Text("\(items.filter { !$0.done }.count) open across \(grouped.count) meeting\(grouped.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Show", selection: $mineOnly) {
                    Text("Everyone's").tag(false)
                    Text("Mine").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Mine: tasks owned by You, the person recording")
                Toggle("Show completed", isOn: $showDone).toggleStyle(.switch)
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView(mineOnly ? "Nothing open for you" : "Nothing open", systemImage: "checkmark.circle",
                                       description: Text("Action items in notes appear here as checkboxes you can tick."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(order, id: \.self) { mid in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { open(mid) } label: {
                                    HStack(spacing: 6) {
                                        Text(grouped[mid]?.first?.meetingTitle ?? "").font(.headline)
                                        Text(grouped[mid]?.first?.meetingDate.formatted(date: .abbreviated, time: .omitted) ?? "")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                ForEach(grouped[mid] ?? []) { item in
                                    HStack(alignment: .top, spacing: 10) {
                                        Button { store.toggleActionItem(meetingId: item.meetingId, lineIndex: item.lineIndex) } label: {
                                            Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(item.done ? Color.secondary : Color.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
                                        EditableNotes.inline(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                                            // Its time link opens the meeting.
                                            .environment(\.openURL, OpenURLAction { url in
                                                guard url.scheme == "notes-time" else { return ExternalLink.open(url) }
                                                open(item.meetingId)
                                                return .handled
                                            })
                                    }
                                }
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            }
        }
        .id(meetings.items.map { ($0.summary ?? "").hashValue }.reduce(0, ^))   // re-read when any notes change
    }

    /// Items are written "task — owner — when [12:56]"; the person recording is "You".
    static func isMine(_ text: String) -> Bool {
        text.range(of: #"—\s*You\b"#, options: .regularExpression) != nil
    }
}
