import AppKit
import GRDB

/// Help ▸ Copy Diagnostics: versions, settings, model and runtime state and recent processing
/// errors, for a bug report. No meeting titles, transcripts or notes.
enum Diagnostics {
    @MainActor
    static func copy() async {
        let text = await report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Diagnostics copied"
        alert.informativeText = "Paste them into your bug report. They contain versions, settings and error messages, but no meeting titles, transcripts or notes."
        alert.runModal()
    }

    static func report() async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo
        var lines: [String] = []
        func add(_ key: String, _ value: String) { lines.append("\(key): \(value)") }

        add("App", "Off the Record \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        add("macOS", process.operatingSystemVersionString)
        add("Mac", "\(sysctl("hw.model")), \(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory)) memory")
        if let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage {
            add("Free disk", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        }
        add("Meetings are in", AppSettings.hinglish ? "Hindi and English" : "English")
        add("Speech engine", AppSettings.engine.rawValue)
        add("Notes model", AppSettings.model)
        add("Prompt", UserDefaults.standard.string(forKey: AppSettings.promptKey) == nil ? "default" : "customized")
        add("Permissions", "microphone \(Permissions.microphone), system audio \(Permissions.systemAudio)")

        let client = OllamaClient(baseURL: AppSettings.baseURL)
        var ollama = "not running"
        if let (data, _) = try? await URLSession.shared.data(from: AppSettings.baseURL.appendingPathComponent("api/version")),
           let version = String(data: data, encoding: .utf8) {
            ollama = "running \(version.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let has = try? await client.hasModel(AppSettings.model) { ollama += has ? ", model installed" : ", model missing" }
        }
        let binary = OllamaRuntime.installedBinary?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "none"
        add("Ollama", "\(ollama); binary \(binary)")

        for entry in ModelCatalog.entries {
            if case .folder = entry.kind {
                add("Model \(entry.id)", ModelCatalog.format(await ModelCatalog.sizeOnDisk(entry)))
            }
        }

        let failures = (try? await AppDatabase.shared.pool.read { db in
            try String.fetchAll(db, sql: "select errorMessage from meeting where status = 'failed' and errorMessage is not null order by createdAt desc limit 5")
        }) ?? []
        let count = (try? await AppDatabase.shared.pool.read { try Meeting.fetchCount($0) }) ?? 0
        add("Meetings", "\(count), \(failures.count) failed recently")
        for message in failures { lines.append("  - \(message)") }
        return lines.joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }
}
