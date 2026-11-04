import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct NotesApp: App {
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var store = MeetingStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Audio…") { ImportAudio.present(store: store) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
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
