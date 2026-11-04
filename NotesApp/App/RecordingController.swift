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

    func toggle() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if recorder.isRecording {
                    stopCaptions()
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
                    if UserDefaults.standard.object(forKey: "captions.live") as? Bool ?? true { startCaptions() }
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
