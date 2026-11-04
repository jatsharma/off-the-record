import SwiftUI

struct RecordView: View {
    var onFinished: (String) -> Void

    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var store: MeetingStore
    @State private var title = ""
    @State private var current: Meeting?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            TextField("Meeting title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .disabled(recorder.isRecording)

            Text(Summarizer.clock(recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? .primary : .tertiary)

            LevelBar(level: recorder.level)
                .frame(maxWidth: 420)
                .opacity(recorder.isRecording ? 1 : 0.3)

            Button(action: toggle) {
                Label(recorder.isRecording ? "Stop" : "Start recording",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(busy)
            .keyboardShortcut(.space, modifiers: [])

            Text(recorder.isRecording
                 ? "Recording your microphone and system audio. Everything stays on this Mac."
                 : "Records the mic and the other side of the call. First use asks for microphone and system-audio permission.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Spacer()
        }
        .padding()
    }

    private func toggle() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if recorder.isRecording {
                    let duration = try await recorder.stop()
                    if let meeting = current {
                        if duration < 2 {
                            store.discardRecording(meeting)
                        } else {
                            store.finishRecording(meeting, duration: duration)
                            onFinished(meeting.id)
                        }
                    }
                    current = nil
                    title = ""
                } else {
                    let meeting = try store.createMeeting(title: title)
                    current = meeting
                    try await recorder.start(to: meeting.audioURL!)
                }
            } catch {
                self.error = error.localizedDescription
                if let meeting = current, !recorder.isRecording {
                    store.discardRecording(meeting)
                    current = nil
                }
            }
        }
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: geo.size.width * CGFloat(min(1, level)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.1), value: level)
    }
}
