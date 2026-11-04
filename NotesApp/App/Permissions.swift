import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    enum State { case granted, denied, unknown }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    /// macOS 15 grants audio-only ScreenCaptureKit capture under "System Audio Recording Only",
    /// which the screen-capture preflight does not see, so this is only ever "granted" or "unknown".
    static var systemAudio: State { CGPreflightScreenCaptureAccess() ? .granted : .unknown }

    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
    static func openSystemAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
