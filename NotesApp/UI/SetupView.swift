import SwiftUI

/// First-run checklist: permissions and model downloads, done before the first meeting
/// instead of discovered during it. Reopen any time from Help › Setup Assistant.
struct SetupView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    @State private var mic = Permissions.microphone
    @State private var systemAudio = Permissions.systemAudio
    @State private var speechState: StepState = .idle
    @State private var speechStatus = ""
    @State private var llmState: StepState = .idle
    @State private var llmStatus = ""

    enum StepState { case idle, working, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Meeting Notes").font(.title.bold())
                Text("Four things, once. Everything runs on this Mac; nothing is uploaded.")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            VStack(spacing: 14) {
                step(icon: "mic.fill", title: "Microphone", detail: micDetail, state: mic == .granted ? .done : (mic == .denied ? .failed : .idle)) {
                    if mic == .denied { Button("Open System Settings") { Permissions.openMicrophoneSettings() } }
                    else if mic != .granted { Button("Allow") { Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone } } }
                }
                step(icon: "speaker.wave.2.fill", title: "System audio (the other side of the call)",
                     detail: systemAudio == .granted ? "Allowed." : "macOS asks the first time you record. If it does not, turn on Meeting Notes under Screen & System Audio Recording, then relaunch.",
                     state: systemAudio == .granted ? .done : .idle) {
                    if systemAudio != .granted { Button("Open System Settings") { Permissions.openSystemAudioSettings() } }
                }
                step(icon: "waveform", title: "Speech models (about 500 MB)", detail: speechStatus.isEmpty ? "Parakeet transcription and the speaker diarizer." : speechStatus, state: speechState) {
                    if speechState != .done { Button(speechState == .working ? "Downloading…" : "Download") { downloadSpeech() }.disabled(speechState == .working) }
                }
                step(icon: "sparkles", title: "Notes model (Ollama + \(AppSettings.model), about 6.6 GB)", detail: llmStatus.isEmpty ? "Installed with Homebrew: brew install ollama. The model is pulled on first use or here." : llmStatus, state: llmState) {
                    if llmState != .done { Button(llmState == .working ? "Working…" : "Check & download") { prepareLLM() }.disabled(llmState == .working) }
                }
            }

            Spacer(minLength: 16)
            HStack {
                Text("You can record before the downloads finish; transcription waits for them.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Later") { dismiss(); store.showSetup = false }
                Button("Done") { store.finishSetup(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 620, height: 520)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            mic = Permissions.microphone; systemAudio = Permissions.systemAudio
        }
        .task { await checkExisting() }
    }

    private var micDetail: String {
        switch mic { case .granted: return "Allowed."; case .denied: return "Denied. Enable it in System Settings, then relaunch."; case .unknown: return "Needed to record your side of the meeting." }
    }

    @ViewBuilder
    private func step<A: View>(icon: String, title: String, detail: String, state: StepState, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(.quaternary.opacity(0.5)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    switch state {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .working: ProgressView().controlSize(.mini)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .idle: EmptyView()
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func checkExisting() async {
        if ModelCatalog.folderSize(ModelCatalog.fluidRoot.appendingPathComponent("parakeet-tdt-0.6b-v3")) ?? 0 > 100_000_000,
           ModelCatalog.folderSize(ModelCatalog.fluidRoot.appendingPathComponent("speaker-diarization")) ?? 0 > 1_000_000 {
            speechState = .done; speechStatus = "Downloaded."
        }
        let client = OllamaClient(baseURL: AppSettings.baseURL)
        if await client.isUp(), (try? await client.hasModel(AppSettings.model)) == true {
            llmState = .done; llmStatus = "Ollama is running and \(AppSettings.model) is installed."
        }
    }

    private func downloadSpeech() {
        speechState = .working
        Task {
            do {
                try await SpeechEngine.shared.prepare(engine: .parakeet) { text in Task { @MainActor in speechStatus = text } }
                speechState = .done; speechStatus = "Downloaded and loaded."
            } catch {
                speechState = .failed; speechStatus = error.localizedDescription
            }
        }
    }

    private func prepareLLM() {
        llmState = .working
        Task {
            do {
                let client = OllamaClient(baseURL: AppSettings.baseURL)
                llmStatus = "Starting Ollama"
                try await client.ensureRunning()
                if try await !client.hasModel(AppSettings.model) {
                    try await client.pull(AppSettings.model) { text in Task { @MainActor in llmStatus = text } }
                }
                llmState = .done; llmStatus = "Ollama is running and \(AppSettings.model) is installed."
            } catch {
                llmState = .failed; llmStatus = error.localizedDescription
            }
        }
    }
}
