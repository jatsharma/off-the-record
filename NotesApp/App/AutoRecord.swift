import Foundation

/// Developer hook: `NotesApp --auto-record 20` starts a recording on launch,
/// stops after 20 seconds and runs the normal transcribe + notes pipeline.
/// Lets the pipeline be exercised from a script without clicking the UI.
enum AutoRecord {
    static var requestedSeconds: TimeInterval? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--auto-record"), i + 1 < args.count else { return nil }
        return TimeInterval(args[i + 1])
    }

    @MainActor
    static func run(recorder: AudioRecorder, store: MeetingStore, select: @escaping (String) -> Void) async {
        guard let seconds = requestedSeconds else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            let meeting = try store.createMeeting(title: "Auto test \(Date().formatted(date: .omitted, time: .standard))")
            try await recorder.start(to: meeting.audioURL!)
            NSLog("AutoRecord: recording \(meeting.id) for \(Int(seconds))s")
            try await Task.sleep(for: .seconds(seconds))
            let duration = try await recorder.stop()
            NSLog("AutoRecord: stopped after \(duration)s")
            store.finishRecording(meeting, duration: duration)
            select(meeting.id)
        } catch {
            NSLog("AutoRecord failed: \(error.localizedDescription)")
        }
    }
}
