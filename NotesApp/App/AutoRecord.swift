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

    /// `NotesApp --import /path/to/file.wav` imports a file and runs the pipeline.
    static var importPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--import"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `NotesApp --summarize <meeting id>` regenerates notes for an existing meeting.
    static var summarizeId: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--summarize"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `NotesApp --download-model apex|tara` downloads a Hinglish model from Hugging Face, as the
    /// app does on first use, and logs the result.
    static var downloadModel: ASREngine? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--download-model"), i + 1 < args.count else { return nil }
        return ASREngine(rawValue: args[i + 1])
    }

    @MainActor
    static func run(recorder: AudioRecorder, store: MeetingStore, select: @escaping (String) -> Void) async {
        if let model = downloadModel {
            let started = Date()
            do {
                var last = -1
                try await HinglishWhisper.download(model) { f in
                    let p = Int(f * 100)
                    if p / 10 != last / 10 { last = p; AppLog.write(String(format: "[download] %@ %d%%", model.rawValue, p)) }
                }
                AppLog.write(String(format: "[download] %@ done in %.0fs: installed=%d at %@", model.rawValue, Date().timeIntervalSince(started),
                      HinglishWhisper.isInstalled(model) ? 1 : 0, HinglishWhisper.folder(for: model)?.path ?? "-"))
            } catch {
                AppLog.write(String(format: "[download] %@ failed: %@", model.rawValue, error.localizedDescription))
            }
        }
        if let id = summarizeId {
            select(id)
            await store.enqueue(id) { await $0.summarize(meetingId: id) }.value
        }
        if let path = importPath {
            do {
                let meeting = try store.importAudio(from: URL(fileURLWithPath: path))
                select(meeting.id)
            } catch {
                AppLog.write("Import failed: \(error.localizedDescription)")
            }
        }
        guard let seconds = requestedSeconds else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            let meeting = try store.createMeeting(title: "Auto test \(Date().formatted(date: .omitted, time: .standard))")
            try await recorder.start(to: meeting.audioURL!)
            AppLog.write("AutoRecord: recording \(meeting.id) for \(Int(seconds))s")
            try await Task.sleep(for: .seconds(seconds))
            let duration = try await recorder.stop()
            AppLog.write("AutoRecord: stopped after \(duration)s")
            store.finishRecording(meeting, duration: duration)
            select(meeting.id)
        } catch {
            AppLog.write("AutoRecord failed: \(error.localizedDescription)")
        }
    }
}
