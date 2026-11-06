import Foundation

/// The app's own log. Each line goes to the system log (Console.app) and to a small file in the
/// data folder (Logs/app.log, the previous one kept as app.log.1), so Copy Diagnostics can include
/// the last lines, also after a crash or a relaunch.
///
/// Never write meeting content here (titles, transcript text, notes, screen text): these lines end
/// up in bug reports. Debug output that quotes a transcript goes to NSLog inside `#if DEBUG`
/// only: the system log keeps NSLog text unredacted.
enum AppLog {
    static let directory = AppDatabase.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    static let file = directory.appendingPathComponent("app.log")
    private static let previous = directory.appendingPathComponent("app.log.1")
    /// Past this size the file starts over; the old one is kept as app.log.1.
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "io.stackera.offtherecord.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        NSLog("%@", message)
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: file, to: previous)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// The last `count` lines, oldest first, with the home folder shown as "~".
    static func recent(_ count: Int) -> [String] {
        queue.sync {
            let text = [previous, file].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            return text.split(separator: "\n").suffix(count)
                .map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        }
    }
}
