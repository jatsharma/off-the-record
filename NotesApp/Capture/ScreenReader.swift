import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import GRDB

/// While a meeting records, reads the text on screen every 20 seconds (shared slides, code,
/// dashboards) with on-device OCR and stores it with the meeting. The transcript pipeline mines
/// it for exact spellings of names and technical terms. Nothing leaves the Mac; this app's own
/// windows are excluded.
@MainActor
final class ScreenReader {
    private var task: Task<Void, Never>?

    func start(meetingId: String) {
        stop()
        guard Vocabulary.readScreenEnabled else { return }
        task = Task.detached(priority: .utility) {
            var last = ""
            while !Task.isCancelled {
                if let text = await Self.readScreen(), Self.differs(text, from: last) {
                    last = text
                    let row = ScreenText(id: UUID().uuidString, meetingId: meetingId, capturedAt: Date(), text: text)
                    _ = try? await AppDatabase.shared.pool.write { try row.insert($0) }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func readScreen() async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return try recognize(image)
        } catch {
            return nil
        }
    }

    nonisolated private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false        // keep "TimescaleDB", do not "fix" it into words
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.4 }
            .map(\.string)
        return lines.joined(separator: "\n")
    }

    /// Skips a capture that is mostly the same text as the previous one.
    nonisolated private static func differs(_ text: String, from previous: String) -> Bool {
        guard text.count >= 20 else { return false }
        let a = Set(text.lowercased().split(whereSeparator: \.isWhitespace))
        let b = Set(previous.lowercased().split(whereSeparator: \.isWhitespace))
        let union = a.union(b).count
        return union == 0 || Double(a.intersection(b).count) / Double(union) < 0.8
    }
}
