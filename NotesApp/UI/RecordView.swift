import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var store: MeetingStore
    @AppStorage("captions.live") private var liveCaptions = true
    @State private var micState = Permissions.microphone
    @State private var systemState = Permissions.systemAudio
    /// Opens a meeting made from an imported file.
    var onImported: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 28) {
                // Timer + big button
                VStack(spacing: 18) {
                    Text(Summarizer.clock(recorder.elapsed))
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(recorder.isRecording ? .primary : .tertiary)
                        .contentTransition(.numericText())
                    HStack(spacing: 18) {
                        if recorder.isRecording {
                            Button { recording.togglePause() } label: {
                                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").font(.title3).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.bordered).clipShape(Circle())
                            .help(recorder.isPaused ? "Resume" : "Pause (keeps one file)")
                            .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
                        }
                        RecordButton(isRecording: recorder.isRecording, busy: recording.busy) { recording.toggle() }
                            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                        if recorder.isRecording { Color.clear.frame(width: 44, height: 44) }
                    }
                    Text(recorder.isPaused ? "Paused" : (recorder.isRecording ? "Recording. Press to stop." : "Press to start · ⌘R here, ⌃⌥⌘R anywhere"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !recorder.isRecording {
                        Button {
                            if let meeting = ImportAudio.present(store: store) { onImported(meeting.id) }
                        } label: {
                            Label("Import an audio file…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .help("Transcribe a recording you already have (WAV, MP3, M4A, AIFF, CAF, FLAC). You can also drop files on this window.")
                    }
                }

                // Title
                TextField("Meeting title (optional, named automatically if left blank)", text: $recording.title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 460)
                    .disabled(recorder.isRecording)

                // Levels
                VStack(spacing: 10) {
                    MeterRow(label: "You", icon: "mic.fill", level: recorder.level, active: recorder.isRecording)
                    MeterRow(label: "Call", icon: "speaker.wave.2.fill", level: recorder.systemLevel, active: recorder.isRecording)
                }
                .frame(maxWidth: 460)

                // Permissions
                HStack(spacing: 10) {
                    PermissionChip(name: "Microphone", state: micState) { Permissions.openMicrophoneSettings() }
                    PermissionChip(name: "System audio", state: systemState) {
                        // Ask first: macOS lists only apps that asked under Screen & System Audio Recording.
                        Task {
                            if await Permissions.requestSystemAudio() { systemState = .granted } else { Permissions.openSystemAudioSettings() }
                        }
                    }
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                    micState = Permissions.microphone
                    systemState = Permissions.systemAudio
                }

                if recorder.isRecording, liveCaptions {
                    LiveCaptions(lines: store.liveCaptions)
                        .frame(maxWidth: 560)
                }

                if recorder.isRecording {
                    TypedNotesEditor(text: $recording.typedNotes)
                        .frame(maxWidth: 560)
                        .task(id: recording.typedNotes) {
                            // Saved a second after typing stops, so a crash loses at most that.
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, let id = recording.currentId else { return }
                            store.saveTypedNotes(id, recording.typedNotes)
                        }
                }

                if let error = recording.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            Spacer()
            Label("Audio, transcript and notes stay on this Mac. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 32)
        .navigationTitle("New recording")
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let busy: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? AnyShapeStyle(AccentTheme.recording.opacity(0.15)) : AnyShapeStyle(.tint.opacity(0.14)))
                    .frame(width: 112, height: 112)
                    .scaleEffect(isRecording && pulse ? 1.08 : 1)
                    .animation(isRecording ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: pulse)
                Circle()
                    .fill(isRecording ? AnyShapeStyle(AccentTheme.recording) : AnyShapeStyle(.tint))
                    .frame(width: 84, height: 84)
                if busy {
                    ProgressView().controlSize(.regular).tint(.white)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onAppear { pulse = true }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct MeterRow: View {
    let label: String
    let icon: String
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            LevelBar(level: active ? level : 0)
        }
        .opacity(active ? 1 : 0.5)
    }
}

struct PermissionChip: View {
    let name: String
    let state: Permissions.State
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(name).font(.caption)
            if state != .granted {
                Button("Open Settings", action: open).buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(help)
    }

    private var icon: String {
        switch state { case .granted: return "checkmark.circle.fill"; case .denied: return "xmark.circle.fill"; case .unknown: return "questionmark.circle" }
    }
    private var color: Color {
        switch state { case .granted: return .green; case .denied: return .red; case .unknown: return .secondary }
    }
    private var help: String {
        switch state {
        case .granted: return "\(name) access granted"
        case .denied: return "\(name) access was denied. Enable it in System Settings, then relaunch."
        case .unknown: return "macOS asks for \(name) access when you start the first recording."
        }
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// Rolling captions from short chunks while recording. Indicative only; the final
/// transcript is produced from the whole file afterwards.
struct LiveCaptions: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Live captions", systemImage: "captions.bubble").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("rough, every 12 s").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            Text("Listening…").foregroundStyle(.tertiary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line).foregroundStyle(i == lines.count - 1 ? .primary : .secondary).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, n in withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .frame(height: 110)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A plain box for the user's own notes during a recording.
struct TypedNotesEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Your notes", systemImage: "square.and.pencil").font(.callout.weight(.semibold))
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type what matters: decisions, numbers, who owns what. The notes will keep your points and fill in the details from the call.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 2)
            }
            .frame(height: 130)
            .padding(6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
