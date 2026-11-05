import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finishes an in-progress recording before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var recording: RecordingController?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recording = Self.recording, recording.isRecording else { return .terminateNow }
        Task { @MainActor in
            await recording.stopForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct NotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder: AudioRecorder
    @StateObject private var store: MeetingStore
    @StateObject private var recording: RecordingController

    init() {
        let recorder = AudioRecorder()
        let store = MeetingStore.shared
        _recorder = StateObject(wrappedValue: recorder)
        _store = StateObject(wrappedValue: store)
        let recording = RecordingController(recorder: recorder, store: store)
        _recording = StateObject(wrappedValue: recording)
        AppDelegate.recording = recording
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
                Button(recorder.isPaused ? "Resume" : "Pause") { recording.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!recording.isRecording)
            }
            CommandGroup(replacing: .help) {
                Button("Setup Assistant…") { store.showSetup = true }
            }
        }

        MenuBarExtra {
            if recording.isRecording {
                Text(recorder.isPaused ? "Paused · \(Summarizer.clock(recorder.elapsed))" : "Recording · \(Summarizer.clock(recorder.elapsed))")
                Button(recorder.isPaused ? "Resume" : "Pause") { recording.togglePause() }
                Button("Stop Recording") { recording.toggle() }
            } else {
                Button("Start Recording  ⌃⌥⌘R") { recording.toggle() }
            }
            Divider()
            Button("Open Meeting Notes") { NSApp.activate(ignoringOtherApps: true) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: recording.isRecording ? (recorder.isPaused ? "pause.circle.fill" : "record.circle.fill") : "waveform.circle")
                    .symbolRenderingMode(recording.isRecording && !recorder.isPaused ? .multicolor : .monochrome)
                if recording.isRecording { Text(Summarizer.clock(recorder.elapsed)).monospacedDigit() }
            }
        }

        Settings {
            Themed { SettingsView() }
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(recording)
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
