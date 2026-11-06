import Foundation
import CoreML
import WhisperKit

/// Two Whisper fine-tunes for Hindi–English (Hinglish) meetings in WhisperKit's Core ML format,
/// downloaded on first use from the converted copies on Hugging Face (or built locally with
/// `make hinglish-models`, see scripts/convert-hinglish.sh):
/// - Tara (Trelis/tara): Whisper large-v3. In its mixed-code mode Hindi stays in Devanagari and
///   English words come out in Latin script ("Postgres में timescale डाल देंगे"). Best accuracy.
/// - Apex (Oriserve/Whisper-Hindi2Hinglish-Apex): Whisper large-v3-turbo. Writes everything in
///   romanized Hinglish ("postgres mein time scale daal denge"). About three times faster.
/// Both read audio in pieces of up to 30 seconds; the app feeds them speaker turns of up to 25 s.
enum HinglishWhisper {
    static let root = AppDatabase.supportDirectory.appendingPathComponent("Models/hinglish", isDirectory: true)

    /// The converted models on Hugging Face (Apache-2.0, like the originals).
    static let repos: [ASREngine: String] = [
        .apex: "jatsharma/whisper-hinglish-apex-coreml",
        .tara: "jatsharma/whisper-hinglish-tara-coreml",
    ]
    static let downloadSize: [ASREngine: String] = [.apex: "1.6 GB", .tara: "3.1 GB"]

    private static var hub: HubApiWrapper { HubApiWrapper(downloadBase: root) }
    private static let completeMarker = ".complete"

    /// Built on this Mac by `make hinglish-models`.
    private static func builtFolder(_ engine: ASREngine) -> URL? {
        switch engine {
        case .tara: return root.appendingPathComponent("tara", isDirectory: true)
        case .apex: return root.appendingPathComponent("apex", isDirectory: true)
        default: return nil
        }
    }

    /// Downloaded from Hugging Face.
    private static func downloadedFolder(_ engine: ASREngine) -> URL? {
        repos[engine].map { hub.localRepoLocation(.init(id: $0)) }
    }

    private static func hasModelFiles(_ folder: URL) -> Bool {
        ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "tokenizer.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Where the model is (or will be downloaded to).
    static func folder(for engine: ASREngine) -> URL? {
        if let built = builtFolder(engine), hasModelFiles(built) { return built }
        return downloadedFolder(engine) ?? builtFolder(engine)
    }

    /// A download counts only once every file arrived (the marker is written last).
    static func isInstalled(_ engine: ASREngine) -> Bool {
        if let built = builtFolder(engine), hasModelFiles(built) { return true }
        guard let folder = downloadedFolder(engine) else { return false }
        return hasModelFiles(folder) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(completeMarker).path)
    }

    /// Downloads the model from Hugging Face. Files already there are skipped, so an interrupted
    /// download continues where it stopped.
    static func download(_ engine: ASREngine, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let repo = repos[engine], let folder = downloadedFolder(engine) else { throw SpeechError.modelMissing(engine) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await hub.snapshot(from: .init(id: repo)) { p in progress(p.fractionCompleted) }
        guard hasModelFiles(folder) else { throw SpeechError.modelMissing(engine) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(completeMarker).path, contents: Data())
    }

    /// Loads a converted model from its folder. The tokenizer ships in the same folder (Tara's has the
    /// extra `<|mixedcode|>` token and a padded vocabulary that WhisperKit's size detection does not
    /// know, so it must not fetch a stock tokenizer).
    static func load(_ engine: ASREngine) async throws -> WhisperKit {
        guard let folder = folder(for: engine), isInstalled(engine) else { throw SpeechError.modelMissing(engine) }
        // Encoder on the GPU: on an M1 the Neural Engine compiler spends an hour or more preparing a
        // large-v3 encoder on first load (and again after macOS updates); the GPU loads it in under
        // a minute. Decoder on the Neural Engine: it compiles in seconds there and runs one token at
        // a time much faster than on the GPU (Tara's 32-layer decoder took 978 s for 6 minutes of
        // audio on the GPU, 567 s on the Neural Engine).
        let compute = ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                          textDecoderCompute: .cpuAndNeuralEngine)
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder, computeOptions: compute,
                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        if engine == .tara, let decoder = kit.textDecoder as? TextDecoder,
           let token = kit.tokenizer?.convertTokenToId("<|mixedcode|>") {
            kit.textDecoder = MixedCodeDecoder(inner: decoder, mixedCodeToken: token)
        }
        return kit
    }

    static func options(for engine: ASREngine) -> DecodingOptions {
        var options = DecodingOptions()
        options.language = "hi"
        options.detectLanguage = false
        options.usePrefillPrompt = true
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.skipSpecialTokens = true
        options.chunkingStrategy = ChunkingStrategy.none   // the caller hands over pieces under 30 s
        // WhisperKit re-decodes a piece with sampling when its average token log-probability is below
        // -1. Devanagari is spelled with several byte-level tokens per letter and scores lower, so
        // Tara's Hindi tripped this on most pieces (up to six decodes each, and slower). For Tara only a
        // repetitive result is retried. Apex writes Latin script and keeps the retry: it recovers
        // pieces where the first greedy pass stops after a few words.
        if engine == .tara {
            options.logProbThreshold = nil
            options.firstTokenLogProbThreshold = nil
            options.noSpeechThreshold = nil
            options.temperatureFallbackCount = 2
        }
        return options
    }

    /// Reads one piece of audio (under 30 s). Nil when nothing usable came back.
    static func read(_ kit: WhisperKit, _ samples: [Float], engine: ASREngine) async -> String? {
        guard let results = try? await kit.transcribe(audioArray: samples, decodeOptions: options(for: engine)) else { return nil }
        let text = results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }), text.lowercased() != "nan" else { return nil }
        return text
    }
}

/// Tara switches to mixed-code output when `<|mixedcode|>` follows the language token:
/// <|startoftranscript|><|hi|><|mixedcode|><|transcribe|><|notimestamps|>. WhisperKit builds the
/// prefix itself and drops special tokens from caller-supplied prefixes, so this wrapper takes the
/// stock prefix and inserts the token. Everything else goes to the stock decoder.
final class MixedCodeDecoder: TextDecoding, WhisperMLModel {
    let inner: TextDecoder
    let mixedCodeToken: Int

    init(inner: TextDecoder, mixedCodeToken: Int) {
        self.inner = inner
        self.mixedCodeToken = mixedCodeToken
    }

    var model: MLModel? {
        get { inner.model }
        set { inner.model = newValue }
    }
    func unloadModel() { inner.unloadModel() }

    var tokenizer: WhisperTokenizer? {
        get { inner.tokenizer }
        set { inner.tokenizer = newValue }
    }
    var isModelMultilingual: Bool {
        get { inner.isModelMultilingual }
        set { inner.isModelMultilingual = newValue }
    }
    var logitsFilters: [any LogitsFiltering]? {
        get { inner.logitsFilters }
        set { inner.logitsFilters = newValue }
    }
    var supportsWordTimestamps: Bool { inner.supportsWordTimestamps }
    var logitsSize: Int? { inner.logitsSize }
    var kvCacheEmbedDim: Int? { inner.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { inner.kvCacheMaxSequenceLength }
    var windowSize: Int? { inner.windowSize }
    var embedSize: Int? { inner.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await inner.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try inner.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType,
                              withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        var inputs = try await inner.prefillDecoderInputs(decoderInputs, withOptions: options)
        var prompt = inputs.initialPrompt
        if let sot = tokenizer?.specialTokens.startOfTranscriptToken, let at = prompt.firstIndex(of: sot),
           at + 1 < prompt.count, !prompt.contains(mixedCodeToken) {
            prompt.insert(mixedCodeToken, at: at + 2)          // after <|sot|><|hi|>
            inputs.initialPrompt = prompt
        }
        return inputs
    }

    func decodeText(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                    sampler tokenSampler: TokenSampling, options decoderOptions: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        try await inner.decodeText(from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
                                   options: decoderOptions, callback: callback)
    }

    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                        sampler tokenSampler: TokenSampling, options: DecodingOptions,
                        temperature: FloatType) async throws -> DecodingResult {
        try await inner.detectLanguage(from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
                                       options: options, temperature: temperature)
    }

    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray, valueTensor: MLMultiArray,
                              valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice, valueTensor: valueTensor,
                                  valueSlice: valueSlice, insertAtIndex: index)
    }
}
