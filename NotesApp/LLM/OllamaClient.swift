import Foundation

enum LLMError: LocalizedError {
    case ollamaMissing, ollamaNotResponding, badResponse(Int)
    var errorDescription: String? {
        switch self {
        case .ollamaMissing: return "Ollama is not installed. Run `brew install ollama` (or `make setup`)."
        case .ollamaNotResponding: return "Ollama did not start. Try `ollama serve` in a terminal."
        case .badResponse(let code): return "Ollama returned HTTP \(code)."
        }
    }
}

/// Thin client for a local Ollama server. Starts the server if it is not running.
struct OllamaClient {
    var baseURL: URL
    private static let binaries = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600      // prompt processing on a long transcript can take minutes
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    func isUp() async -> Bool {
        guard let (_, response) = try? await Self.session.data(from: baseURL.appendingPathComponent("api/version")) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func ensureRunning() async throws {
        if await isUp() { return }
        guard let binary = Self.binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LLMError.ollamaMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            if await isUp() { return }
        }
        throw LLMError.ollamaNotResponding
    }

    func hasModel(_ name: String) async throws -> Bool {
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let (data, _) = try await Self.session.data(from: baseURL.appendingPathComponent("api/tags"))
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.contains { $0.name == name || $0.name == name + ":latest" }
    }

    func pull(_ name: String, progress: @escaping (String) -> Void) async throws {
        struct Line: Decodable { let status: String?; let completed: Int64?; let total: Int64? }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        let (bytes, _) = try await Self.session.bytes(for: request)
        for try await raw in bytes.lines {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            if let total = line.total, let done = line.completed, total > 0 {
                progress("Downloading \(name): \(Int(Double(done) / Double(total) * 100))%")
            } else if let status = line.status {
                progress(status)
            }
        }
    }

    /// Streams assistant tokens for one chat turn.
    func chat(model: String, system: String, user: String, contextTokens: Int,
              temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        struct Chunk: Decodable { struct Message: Decodable { let content: String? }; let message: Message?; let done: Bool? }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                        "options": ["num_ctx": contextTokens, "temperature": temperature],
                    ])
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw LLMError.badResponse(code) }
                    for try await raw in bytes.lines {
                        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(raw.utf8)) else { continue }
                        if let text = chunk.message?.content, !text.isEmpty { continuation.yield(text) }
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
