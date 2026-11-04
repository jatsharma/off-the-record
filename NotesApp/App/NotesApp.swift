import SwiftUI

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
        Settings {
            SettingsView()
        }
    }
}
