import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct NotesApp: App {
    @StateObject private var recorder: AudioRecorder
    @StateObject private var store: MeetingStore
    @StateObject private var recording: RecordingController

    init() {
        let recorder = AudioRecorder()
        let store = MeetingStore.shared
        _recorder = StateObject(wrappedValue: recorder)
        _store = StateObject(wrappedValue: store)
        _recording = StateObject(wrappedValue: RecordingController(recorder: recorder, store: store))
        Notifier.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            Themed {
                ContentView()
                    .environmentObject(recorder)
                    .environmentObject(store)
                    .environmentObject(recording)
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Audio…") { ImportAudio.present(store: store) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Recording") {
                Button(recording.isRecording ? "Stop Recording" : "Start Recording") { recording.toggle() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            if recording.isRecording {
                Text("Recording · \(Summarizer.clock(recorder.elapsed))")
                Button("Stop Recording") { recording.toggle() }
            } else {
                Button("Start Recording") { recording.toggle() }
            }
            Divider()
            Button("Open Meeting Notes") { NSApp.activate(ignoringOtherApps: true) }
        } label: {
            Image(systemName: recording.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(recording.isRecording ? .multicolor : .monochrome)
        }

        Settings {
            Themed { SettingsView() }
        }
    }
}

enum ImportAudio {
    @MainActor
    static func present(store: MeetingStore) {
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff, .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importAudio(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
