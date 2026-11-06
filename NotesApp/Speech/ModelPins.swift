import Foundation
import FluidAudio
import WhisperKit

/// Every speech model downloads from an exact Hugging Face commit, so a change to a model repo
/// cannot change what the app runs (the Hinglish models are pinned in `HinglishWhisper`).
/// Bump these with a release after checking the new models.
enum ModelPins {
    static let host = "https://huggingface.co"

    /// FluidAudio's models. The speaker model is pinned by FluidAudio itself.
    static let fluidAudio: [String: String] = [
        "FluidInference/parakeet-tdt-0.6b-v3-coreml": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        "FluidInference/silero-vad-coreml": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
    ]

    /// WhisperKit's stock Whisper models (Settings ▸ Speech engine ▸ Whisper).
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    static let whisperRevision = "0f63a7800b00dd0226abd051b906c246e1907482"

    /// Call once at launch, before any model is downloaded. Setting the host here also means the
    /// REGISTRY_URL / MODEL_REGISTRY_URL environment variables cannot send downloads elsewhere.
    static func apply() {
        ModelRegistry.baseURL = host
        ModelRegistry.revisionOverrides = fluidAudio
    }

    /// Downloads (once) and returns the folder of a stock Whisper model at the pinned commit,
    /// finding its folder the way WhisperKit does ("large-v3" → "openai_whisper-large-v3").
    static func whisperFolder(_ name: String, downloadBase: URL) async throws -> URL {
        let hub = HubApiWrapper(downloadBase: downloadBase, endpoint: host)
        let repo = HubApiWrapper.Repo(id: whisperRepo)
        var folder: String?
        for pattern in ["*\(name)/*", "*openai*\(name)/*"] {
            let files = try await hub.getFilenames(from: repo, revision: whisperRevision, matching: [pattern])
            let folders = Set(files.compactMap { $0.components(separatedBy: "/").first })
            if folders.count == 1 { folder = folders.first; break }
        }
        guard let folder else { throw WhisperError.modelsUnavailable("No Whisper model named \"\(name)\" in \(whisperRepo)") }
        let root = try await hub.snapshot(from: repo, revision: whisperRevision, matching: ["\(folder)/*"])
        return root.appendingPathComponent(folder)
    }
}
