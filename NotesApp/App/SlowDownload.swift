import Foundation

/// Notices a download that has been too slow for too long, so it can start again on a new
/// connection. After heavy packet loss one connection can stay at a few KB/s while a new
/// connection to the same server runs at full speed (seen on a 100 Mbps line: 84 KB/s in the app,
/// 11 MB/s for a new connection). Every model download here resumes from the bytes already on
/// disk, so starting again costs a second or two. Each restart doubles the wait (20 s, 40 s, …
/// up to 5 minutes), so on a network that really is slow the download is not restarted over and over.
struct SlowDownload {
    static let minBytesPerSecond: Double = 512 * 1024
    static let firstWindow: TimeInterval = 20
    static let longestWindow: TimeInterval = 300

    private(set) var window = firstWindow
    private var start: (date: Date, bytes: Int64)?

    /// Called regularly with the bytes downloaded so far. True when the last `window` seconds
    /// brought less than `minBytesPerSecond`. `active` is false while nothing is being transferred
    /// (listing files, loading a model), which is never counted as slow.
    mutating func tooSlow(bytes: Int64, active: Bool, now: Date = Date()) -> Bool {
        guard active, let start, bytes >= start.bytes else {
            self.start = active ? (now, bytes) : nil
            return false
        }
        let elapsed = now.timeIntervalSince(start.date)
        guard elapsed >= window else { return false }
        let slow = Double(bytes - start.bytes) / elapsed < Self.minBytesPerSecond
        if slow {
            window = min(window * 2, Self.longestWindow)
            self.start = nil
        } else {
            self.start = (now, bytes)
        }
        return slow
    }

    /// Runs `work`, a download into `folder` that keeps its partial files when cancelled and
    /// resumes from them, and starts it again when it is too slow while a partial file
    /// (`*.partial` from FluidAudio, `*.incomplete` from WhisperKit) is being written.
    /// `reconnect` runs before each new start, to make sure the next request opens a new connection.
    static func run<T>(watching folder: URL, label: String,
                       reconnect: @escaping @Sendable () async -> Void = {},
                       _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        var rule = SlowDownload()
        while true {
            try Task.checkCancellation()
            let attempt = Task { Unchecked(value: try await work()) }
            let watcher = Task.detached(priority: .utility) { [rule] () -> (rule: SlowDownload, tripped: Bool) in
                var rule = rule
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let (bytes, active) = progress(in: folder)
                    if rule.tooSlow(bytes: bytes, active: active) {
                        attempt.cancel()
                        return (rule, true)
                    }
                }
                return (rule, false)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await attempt.value
                } onCancel: {
                    attempt.cancel()
                }
                watcher.cancel()
                return result.value
            } catch {
                watcher.cancel()
                let outcome = await watcher.value
                guard outcome.tripped, !Task.isCancelled else { throw error }
                rule = outcome.rule
                AppLog.write("Download of \(label) was below \(Int(minBytesPerSecond / 1024)) KB/s; reconnecting")
                await reconnect()
            }
        }
    }

    /// Bytes in `folder` (hidden files included) and whether a partial file is being written.
    static func progress(in folder: URL) -> (bytes: Int64, active: Bool) {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return (0, false) }
        var total: Int64 = 0
        var active = false
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
            if f.pathExtension == "partial" || f.pathExtension == "incomplete" { active = true }
        }
        return (total, active)
    }

    /// Carries a result that is not `Sendable` (Core ML models) out of the download task; it is
    /// handed over once, after the task finished.
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }
}
