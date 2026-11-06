import Foundation

enum LLMError: LocalizedError {
    case ollamaMissing, ollamaNotResponding, badResponse(Int), server(String), runtimeDownload(String), portBusy(String), ollamaExited
    case remoteNotResponding(String), notYours(String)
    var errorDescription: String? {
        switch self {
        case .ollamaMissing: return "Ollama is not installed and could not be downloaded. Check the internet connection, or install it from ollama.com."
        case .portBusy(let address): return "Another program is using \(address), where Ollama runs. Quit that program, or set a different Ollama server address in Settings ▸ General ▸ Notes ▸ Advanced."
        case .ollamaExited: return "Ollama stopped right after starting. Another copy may be using its address; quitting Ollama from the menu bar and trying again usually helps."
        case .runtimeDownload(let why): return "Could not download Ollama: \(why). Check the internet connection and try again."
        case .ollamaNotResponding: return "Ollama did not start. Try `ollama serve` in a terminal."
        case .notYours(let address): return "The server at \(address) answers like Ollama but is run by another user or program on this Mac, so transcripts are not sent to it. Quit it, or start Ollama yourself."
        case .remoteNotResponding(let address): return "No Ollama answered at \(address). The app starts Ollama only on this Mac; check that server, or set the address in Settings ▸ General ▸ Notes ▸ Advanced back to \(AppSettings.defaultURL)."
        case .badResponse(let code): return "Ollama returned HTTP \(code)."
        case .server(let message): return "Ollama: \(message)"
        }
    }
}

/// Thin client for a local Ollama server. Starts the server if it is not running.
struct OllamaClient {
    var baseURL: URL
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600      // prompt processing on a long transcript can take minutes
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    func isUp() async -> Bool { await probe() == .ollama }

    enum Probe { case ollama, other, nothing }

    /// What answers at the server address: Ollama, something else, or nothing.
    func probe() async -> Probe {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await Self.session.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
                && (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] != nil
            return ok ? .ollama : .other
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet].contains(error.code) {
            return .nothing
        } catch {
            return .other        // something listens there but does not speak HTTP like Ollama
        }
    }

    /// Starts Ollama if it is not running. With no Ollama on this Mac, downloads the runtime first
    /// (see `OllamaRuntime`); `status` reports that download.
    func ensureRunning(status: (@Sendable (Double?, String) -> Void)? = nil) async throws {
        switch await probe() {
        case .ollama:
            // Any program, also one of another user on this Mac, can listen on a local port before
            // Ollama does and read every transcript sent there. Only a server run by this user is used.
            if isLocal, !Self.listenerIsMine(port: baseURL.port ?? 11434) { throw LLMError.notYours(address) }
            return
        case .other: throw LLMError.portBusy(address)
        case .nothing: break
        }
        // Only a server on this Mac is started here. Starting one for another address would make
        // Ollama listen there (0.0.0.0 is every network the Mac is on) with no password.
        guard isLocal else { throw LLMError.remoteNotResponding(address) }
        if OllamaRuntime.installedBinary == nil {
            status?(0, "Downloading Ollama (\(OllamaRuntime.downloadSize), once)")
            try await OllamaRuntime.install { f in status?(f, "Downloading Ollama (\(OllamaRuntime.downloadSize), once)") }
        }
        guard let binary = OllamaRuntime.installedBinary else { throw LLMError.ollamaMissing }
        status?(nil, "Starting Ollama")
        try OllamaRuntime.launch(binary, host: address)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            if await isUp() { return }
            if !OllamaRuntime.startedServerIsRunning { throw LLMError.ollamaExited }
        }
        throw LLMError.ollamaNotResponding
    }

    /// The server address is on this Mac, so transcripts stay here.
    var isLocal: Bool { Self.isLocal(baseURL) }

    static func isLocal(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// Whether a process of the current user listens on this TCP port. `lsof` run by a normal user
    /// lists only that user's processes, and each listener's user ID is checked as well.
    static func listenerIsMine(port: Int) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fu"]
        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        let uids = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("u") }.compactMap { uid_t($0.dropFirst()) }
        return uids.contains(getuid())
    }

    /// host:port of the server address, as Ollama's OLLAMA_HOST takes it.
    var address: String { "\(baseURL.host ?? "127.0.0.1"):\(baseURL.port ?? 11434)" }

    func hasModel(_ name: String) async throws -> Bool {
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let (data, _) = try await Self.session.data(from: baseURL.appendingPathComponent("api/tags"))
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.contains { $0.name == name || $0.name == name + ":latest" }
    }

    /// Downloads a model; `progress` gets the fraction while Ollama reports sizes.
    func pull(_ name: String, progress: @escaping (Double?, String) -> Void) async throws {
        struct Line: Decodable { let status: String?; let completed: Int64?; let total: Int64? }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        let (bytes, _) = try await Self.session.bytes(for: request)
        for try await raw in bytes.lines {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            if let total = line.total, let done = line.completed, total > 100_000_000 {
                progress(Double(done) / Double(total), "Downloading \(name)")
            } else if let status = line.status, line.total == nil {
                progress(nil, status.prefix(1).uppercased() + status.dropFirst())
            }
        }
    }

    /// Streams assistant tokens for one chat turn.
    func chat(model: String, system: String, user: String, contextTokens: Int,
              temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        struct Chunk: Decodable { struct Message: Decodable { let content: String? }; let message: Message?; let done: Bool?; let error: String? }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "think": false,     // reasoning models (qwen3.5) would otherwise think at length first
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                        "options": ["num_ctx": contextTokens, "temperature": temperature],
                    ])
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 {
                        // The body says why ("model requires more system memory ..."); show that.
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2_000 { break } }
                        if let message = try? JSONDecoder().decode(Chunk.self, from: Data(body.utf8)).error { throw LLMError.server(message) }
                        throw LLMError.badResponse(code)
                    }
                    for try await raw in bytes.lines {
                        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(raw.utf8)) else { continue }
                        if let message = chunk.error { throw LLMError.server(message) }
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
