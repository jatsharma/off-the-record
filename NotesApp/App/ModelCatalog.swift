import Foundation

/// Every model the app can download, where it lives, and how to remove it.
/// Deleting a model only frees disk: the engine that needs it downloads it again on next use.
struct ModelEntry: Identifiable {
    enum Kind { case folder(URL), ollama(String) }
    let id: String
    let name: String
    let purpose: String
    let kind: Kind
    let engine: ASREngine?      // which speech engine needs it, nil for shared or LLM

    var location: String {
        switch kind {
        case .folder(let url): return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .ollama(let tag): return "Ollama · \(tag)"
        }
    }
}

enum ModelCatalog {
    static let fluidRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }()
    static let whisperRoot = AppDatabase.supportDirectory.appendingPathComponent("Models/whisperkit", isDirectory: true)
    static var parakeetFolder: URL { fluidRoot.appendingPathComponent("parakeet-tdt-0.6b-v3") }
    static var diarizerFolder: URL { fluidRoot.appendingPathComponent("speaker-diarization") }
    /// Sizes on disk once downloaded, for download progress (FluidAudio reports none).
    static let parakeetBytes: Int64 = 483_000_000
    static let diarizerBytes: Int64 = 35_500_000

    static var entries: [ModelEntry] {
        [
            ModelEntry(id: "parakeet", name: "Parakeet TDT 0.6b v3", purpose: "Transcription (default engine)",
                       kind: .folder(fluidRoot.appendingPathComponent("parakeet-tdt-0.6b-v3")), engine: .parakeet),
            ModelEntry(id: "diarizer", name: "Speaker diarization", purpose: "Who spoke when (all engines)",
                       kind: .folder(fluidRoot.appendingPathComponent("speaker-diarization")), engine: nil),
            ModelEntry(id: "vad", name: "Silero VAD", purpose: "Voice activity (all engines)",
                       kind: .folder(fluidRoot.appendingPathComponent("silero-vad")), engine: nil),
            ModelEntry(id: "whisper", name: "Whisper large-v3-turbo", purpose: "Transcription, 99 languages",
                       kind: .folder(whisperRoot), engine: .whisper),
            ModelEntry(id: "tara", name: "Tara (Hinglish Whisper large-v3)", purpose: "Transcription, Hinglish, most faithful but slow (3.1 GB)",
                       kind: .folder(HinglishWhisper.folder(for: .tara)!), engine: .tara),
            ModelEntry(id: "apex", name: "Apex (Hinglish Whisper turbo)", purpose: "Transcription, Hinglish; used by Mix (1.6 GB)",
                       kind: .folder(HinglishWhisper.folder(for: .apex)!), engine: .apex),
            ModelEntry(id: "llm", name: AppSettings.model, purpose: "Notes (language model)",
                       kind: .ollama(AppSettings.model), engine: nil),
        ]
    }

    static func sizeOnDisk(_ entry: ModelEntry) async -> Int64? {
        if let engine = entry.engine, HinglishWhisper.repos[engine] != nil, !HinglishWhisper.isInstalled(engine) { return nil }
        switch entry.kind {
        case .folder(let url):
            return folderSize(url)
        case .ollama(let tag):
            struct Tags: Decodable { struct M: Decodable { let name: String; let size: Int64 }; let models: [M] }
            guard let (data, _) = try? await URLSession.shared.data(from: AppSettings.baseURL.appendingPathComponent("api/tags")),
                  let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
            return tags.models.first { $0.name == tag || $0.name == tag + ":latest" }?.size
        }
    }

    static func delete(_ entry: ModelEntry) async throws {
        switch entry.kind {
        case .folder(let url):
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        case .ollama(let tag):
            var request = URLRequest(url: AppSettings.baseURL.appendingPathComponent("api/delete"))
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": tag])
            _ = try await URLSession.shared.data(for: request)
        }
        await SpeechEngine.shared.unload(entry.engine)
    }

    static func folderSize(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path),
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "not downloaded" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
