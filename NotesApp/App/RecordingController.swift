import Foundation
import SwiftUI

/// One place that starts and stops recordings, shared by the window, the menu bar item and ⌘R.
@MainActor
final class RecordingController: ObservableObject {
    @Published var title = ""
    @Published private(set) var current: Meeting?
    @Published var error: String?
    @Published private(set) var busy = false

    let recorder: AudioRecorder
    let store: MeetingStore
    var onFinished: ((String) -> Void)?

    init(recorder: AudioRecorder, store: MeetingStore) {
        self.recorder = recorder
        self.store = store
    }

    var isRecording: Bool { recorder.isRecording }
    private var captionTimer: Timer?
    private let screenReader = ScreenReader()

    func togglePause() {
        recorder.isPaused ? recorder.resume() : recorder.pause()
    }

    private func startCaptions() {
        store.liveCaptions = []
        captionTimer?.invalidate()
        captionTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recorder.isRecording, !self.recorder.isPaused else { return }
                let samples = self.recorder.takeLiveSamples()
                guard samples.count >= 16_000 else { return }
                let text = await SpeechEngine.shared.quickTranscribe(samples)
                if !text.isEmpty { self.store.liveCaptions.append(text) }
            }
        }
    }

    private func stopCaptions() {
        captionTimer?.invalidate()
        captionTimer = nil
    }

    /// Closes the WAV properly before the app exits; without this the file header is never
    /// written and the recording reads as empty.
    func stopForQuit() async {
        guard recorder.isRecording else { return }
        stopCaptions()
        screenReader.stop()
        let duration = (try? await recorder.stop()) ?? 0
        // `current` is nil when the recording was started outside this controller (--auto-record).
        if let meeting = current ?? store.meetingBeingRecorded() { store.saveInterruptedRecording(meeting, duration: duration) }
        current = nil
    }

    func toggle() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if recorder.isRecording {
                    stopCaptions()
                    screenReader.stop()
                    let duration = try await recorder.stop()
                    if let meeting = current {
                        if duration < 2 {
                            store.discardRecording(meeting)
                        } else {
                            store.finishRecording(meeting, duration: duration)
                            onFinished?(meeting.id)
                        }
                    }
                    current = nil
                    title = ""
                } else {
                    if Permissions.microphone == .unknown { _ = await Permissions.requestMicrophone() }
                    let meeting = try store.createMeeting(title: title)
                    current = meeting
                    try await recorder.start(to: meeting.audioURL!)
                    screenReader.start(meetingId: meeting.id)
                    if UserDefaults.standard.object(forKey: "captions.live") as? Bool ?? true { startCaptions() }
                }
            } catch {
                self.error = error.localizedDescription
                if let meeting = current, !recorder.isRecording {
                    screenReader.stop()
                    store.discardRecording(meeting)
                    current = nil
                }
            }
        }
    }
}
