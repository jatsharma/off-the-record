import Foundation
import CryptoKit
import Darwin

/// The notes model runs in Ollama. When Ollama is not installed (Homebrew or Ollama.app), the
/// official macOS build is downloaded once into the app's folder, checked against the checksum
/// Ollama publishes, and run from there. Only the server the app started is stopped on quit.
enum OllamaRuntime {
    /// Pinned so every install runs the same tested build; bump with a release.
    static let version = "0.40.15"
    static let downloadURL = URL(string: "https://github.com/ollama/ollama/releases/download/v\(version)/ollama-darwin.tgz")!
    static let sha256 = "607c79d5d6315ef9d896db83adde736a4c0057196329843544e79b95afb260a8"
    static let downloadSize = "190 MB"

    static let folder = AppDatabase.supportDirectory.appendingPathComponent("Runtime/ollama", isDirectory: true)
    static var bundledBinary: URL { folder.appendingPathComponent("ollama") }

    /// Ollama binaries already on this Mac, most specific first.
    static var candidates: [URL] {
        [bundledBinary.path, "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
         "/Applications/Ollama.app/Contents/Resources/ollama"].map { URL(fileURLWithPath: $0) }
    }

    static var installedBinary: URL? {
        if forceBundled { return FileManager.default.isExecutableFile(atPath: bundledBinary.path) ? bundledBinary : nil }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Developer options for testing the downloaded runtime next to an existing Ollama:
    /// `--bundled-ollama` ignores other installs, `--ollama-models <dir>` keeps its models apart
    /// (with `-llm.url http://127.0.0.1:11435` it also runs on its own port).
    static var forceBundled: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--bundled-ollama")
        #else
        return false
        #endif
    }
    private static var modelsOverride: String? {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ollama-models"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    /// Whether a model is already pulled, read from Ollama's model folder (no server needed).
    static func hasModelOnDisk(_ tag: String) -> Bool {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0], version = parts.count > 1 ? parts[1] : "latest"
        let path = name.contains("/") ? name : "library/" + name
        let manifests = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/models/manifests/registry.ollama.ai")
        return FileManager.default.fileExists(atPath: manifests.appendingPathComponent(path).appendingPathComponent(version).path)
    }

    /// Downloads, verifies and unpacks the runtime. Progress is 0...1 over the download.
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let archive = parent.appendingPathComponent("ollama-darwin.tgz")
        try await Download.file(downloadURL, to: archive, progress: progress)
        defer { try? fm.removeItem(at: archive) }

        guard try Self.digest(of: archive) == sha256 else { throw LLMError.runtimeDownload("the download did not match Ollama's checksum") }
        let staging = parent.appendingPathComponent("ollama.partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: staging.appendingPathComponent("ollama").path) else {
            throw LLMError.runtimeDownload("could not unpack it")
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
    }

    private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The server this app started

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: Process?

    /// Starts `ollama serve` listening on `host` (host:port from the server address in Settings).
    static func launch(_ binary: URL, host: String) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = host
        if let modelsOverride { environment["OLLAMA_MODELS"] = modelsOverride }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.lock(); started = process; lock.unlock()
        // Remembered on disk too: after a crash or force quit the server keeps running, and the next
        // quit stops it.
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private static var pidFile: URL { folder.deletingLastPathComponent().appendingPathComponent("ollama.pid") }

    /// The server a previous session of this app started, if it is still running.
    private static var orphanPID: pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // Only our own downloaded binary: the pid may have been reused by another program.
        return String(cString: buffer) == bundledBinary.path ? pid : nil
    }

    static var startedServerIsRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started?.isRunning ?? true
    }

    /// Stops the server this app started, in this session or one that ended without quitting
    /// properly. A server the user runs (Homebrew, Ollama.app) is never touched. Models stay on disk.
    static func stopStartedServer() {
        lock.lock(); defer { lock.unlock() }
        if let started, started.isRunning { started.terminate() }
        else if let pid = orphanPID { kill(pid, SIGTERM) }
        started = nil
        try? FileManager.default.removeItem(at: pidFile)
    }
}

/// A file download with progress, written to `destination` once complete.
enum Download {
    static func file(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Delegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temporary file is deleted when this returns, so it is moved now.
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { moveError = LLMError.runtimeDownload("the server answered \(code)"); return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { moveError = error }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error ?? moveError { continuation?.resume(throwing: error) } else { continuation?.resume() }
            continuation = nil
        }
    }
}
