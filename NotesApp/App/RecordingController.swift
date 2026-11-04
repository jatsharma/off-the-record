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

    func toggle() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if recorder.isRecording {
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
