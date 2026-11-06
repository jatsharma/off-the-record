import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finishes an in-progress recording before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var recording: RecordingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit's own handler for quit requests from scripts, other apps and log out refuses while
        // a sheet is open, without calling `terminate`; this one goes through `QuittableApplication`.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitRequested(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @MainActor @objc private func quitRequested(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        OllamaRuntime.stopStartedServer()
        PlaybackMix.removeAll()
    }

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

/// Starts the app. Under unit tests it starts only a bare process for the tests to run in: no
/// windows, no meetings database, no Ollama, and the user's settings are left alone.
@main
enum Launcher {
    static var isTesting: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
    }

    static func main() {
        if isTesting {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            _ = QuittableApplication.shared   // must come first: the app object is created once
            NotesApp.main()
        }
    }
}

/// AppKit refuses to quit while a window shows a sheet (the setup assistant, a confirmation): Cmd-Q
/// only beeps, a quit from a script or another app is answered "User cancelled", and the app
/// delegate is never asked. So a quit first asks the open sheets to close (`closedOnQuit`; closing
/// one in AppKit alone does not last, SwiftUI shows it again while its state says so) and goes ahead
/// once they are gone, as usual from there on, including `AppDelegate`, which finishes a recording
/// first. Downloads that are cut off resume on the next launch.
final class QuittableApplication: NSApplication {
    static let closeSheets = Notification.Name("QuittableApplication.closeSheets")

    override func terminate(_ sender: Any?) {
        quit(sender, triesLeft: 20)
    }

    private func quit(_ sender: Any?, triesLeft: Int) {
        guard windows.contains(where: { $0.attachedSheet != nil }), triesLeft > 0 else { return super.terminate(sender) }
        NotificationCenter.default.post(name: Self.closeSheets, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.quit(sender, triesLeft: triesLeft - 1) }
    }
}

extension View {
    /// Closes this view's sheet or dialog when the app quits, by clearing the state that shows it.
    /// Needed for every sheet and confirmation dialog: AppKit does not quit while one is open.
    func closedOnQuit(_ close: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: QuittableApplication.closeSheets)) { _ in close() }
    }
}

struct NotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder: AudioRecorder
    @StateObject private var store: MeetingStore
    @StateObject private var recording: RecordingController

    init() {
        LegacyData.migrate()
        ModelPins.apply()
        let info = Bundle.main.infoDictionary ?? [:]
        AppLog.write("Off the Record \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
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
                Button("Acknowledgements…") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
                Button("Copy Diagnostics") { Task { await Diagnostics.copy() } }
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
            Button("Open Off the Record") { NSApp.activate(ignoringOtherApps: true) }
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
    @discardableResult
    static func present(store: MeetingStore) -> Meeting? {
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff, .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try store.importAudio(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }
}
