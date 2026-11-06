import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import GRDB

/// While a meeting records, reads the text on screen every 20 seconds (shared slides, code,
/// dashboards) with on-device OCR and stores it with the meeting. The transcript pipeline mines
/// it for exact spellings of names and technical terms. Nothing leaves the Mac; this app's own
/// windows are excluded.
/// Opt-in: off until the user turns it on in setup or Settings ▸ Vocabulary.
@MainActor
final class ScreenReader {
    private var task: Task<Void, Never>?

    /// What the feature does, in the words setup and Settings both show.
    nonisolated static let explanation = "While you record, text on your screen (shared slides, code, dashboards) is read on this Mac every 20 seconds, so names spelled there come out right in the transcript and notes. It stays with the meeting and is never uploaded."

    func start(meetingId: String) {
        stop()
        guard Vocabulary.readScreenEnabled else { return }
        task = Task.detached(priority: .utility) {
            var last = ""
            var lastThumbnail: [UInt8] = []
            while !Task.isCancelled {
                // A 64×40 grey thumbnail first: when the screen has not changed, the full-resolution
                // capture and OCR would only read the same text again, so they are skipped.
                let thumbnail = await Self.thumbnail()
                let changed = thumbnail.map { Self.changed($0, from: lastThumbnail) } ?? true
                if let thumbnail { lastThumbnail = thumbnail }
                if changed, let text = await Self.readScreen(), Self.differs(text, from: last) {
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

    nonisolated private static func capture(width: Int?, height: Int?) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return nil }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width ?? display.width * 2
        config.height = height ?? display.height * 2
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    nonisolated private static func readScreen() async -> String? {
        guard let image = try? await capture(width: nil, height: nil) else { return nil }
        return try? recognize(image)
    }

    /// Grey levels of a 64×40 capture of the screen.
    nonisolated private static func thumbnail() async -> [UInt8]? {
        let w = 64, h = 40
        guard let image = try? await capture(width: w, height: h) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// More than 0.5% of thumbnail pixels moved noticeably: a slide change, a scroll, a new window.
    /// A ticking clock or a blinking cursor stays under that.
    nonisolated private static func changed(_ a: [UInt8], from b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        let moved = zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 8 ? 1 : 0) }
        return Double(moved) / Double(a.count) > 0.005
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
