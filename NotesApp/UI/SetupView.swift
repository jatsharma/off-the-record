import SwiftUI

/// First-run setup: what language the meetings are in (which picks the speech engine), the two
/// permissions, the opt-in screen reading, and every download with its size, checked against free disk space and memory, in
/// one click. Reopen any time from Help › Setup Assistant.
struct SetupView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    @State private var hinglish = AppSettings.hinglish
    @State private var mic = Permissions.microphone
    @State private var systemAudio = Permissions.systemAudio
    @State private var systemAudioAsked = false
    @State private var items: [Item.ID: ItemState] = [:]
    @State private var running = false
    @State private var freeBytes: Int64?
    @AppStorage(Vocabulary.screenKey) private var readScreen = false

    enum StepState { case idle, working, done, failed }

    /// One thing to download.
    struct Item: Identifiable {
        enum ID: Hashable { case speech, apex, ollama, model }
        let id: ID
        let title: String
        let detail: String
        let bytes: Int64
        let size: String
    }

    struct ItemState {
        var state: StepState = .idle
        var status = ""
        /// 0...1 while the download's size is known.
        var fraction: Double?
    }

    /// The whole download run, for the overall bar and the time left.
    @State private var runStarted: Date?
    @State private var runTotal: Int64 = 0
    @State private var runFinished: Int64 = 0

    private var model: String { AppSettings.model }

    /// What this Mac needs for the chosen language.
    private var downloads: [Item] {
        var list = [Item(id: .speech, title: "Speech recognition", detail: "Parakeet and the speaker model",
                         bytes: 520_000_000, size: "520 MB")]
        if hinglish {
            list.append(Item(id: .apex, title: "Hinglish model", detail: "Apex, for the Hindi parts",
                             bytes: 1_630_000_000, size: HinglishWhisper.downloadSize[.apex] ?? "1.6 GB"))
        }
        list.append(Item(id: .ollama, title: "Ollama", detail: "Runs the notes model on this Mac",
                         bytes: 770_000_000, size: OllamaRuntime.downloadSize))   // download plus unpacked
        list.append(Item(id: .model, title: "Notes model", detail: model,
                         bytes: model == "gemma4:e2b" ? 4_590_000_000 : 6_580_000_000,
                         size: AppSettings.modelDownloadSize[model] ?? "about 6.6 GB"))
        return list
    }

    private var pending: [Item] { downloads.filter { items[$0.id]?.state != .done } }
    private var pendingBytes: Int64 { pending.reduce(0) { $0 + $1.bytes } }
    private var allReady: Bool { pending.isEmpty }
    /// Room for the downloads plus 2 GB to spare for recordings and the system.
    private var enoughDisk: Bool { freeBytes.map { $0 > pendingBytes + 2_000_000_000 } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Off the Record").font(.title.bold())
                Text("Once, about five minutes. Everything runs on this Mac; nothing is uploaded.")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Your meetings are in") { languageCards }
                    section("Permissions") {
                        step(icon: "mic.fill", title: "Microphone", detail: micDetail,
                             state: mic == .granted ? .done : (mic == .denied ? .failed : .idle)) {
                            if mic == .denied { Button("Open System Settings") { Permissions.openMicrophoneSettings() } }
                            else if mic != .granted { Button("Allow") { Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone } } }
                        }
                        step(icon: "speaker.wave.2.fill", title: "System audio (the other side of the call)",
                             detail: systemAudio == .granted ? "Allowed." : (systemAudioAsked ? "Turn on Off the Record under Screen & System Audio Recording, then quit and reopen the app." : "Needed to hear the other side of your calls. Click Allow and confirm the macOS prompt."),
                             state: systemAudio == .granted ? .done : .idle) {
                            if systemAudio != .granted {
                                Button(systemAudioAsked ? "Open System Settings" : "Allow") {
                                    if systemAudioAsked { Permissions.openSystemAudioSettings(); return }
                                    Task {
                                        let ok = await Permissions.requestSystemAudio()
                                        systemAudioAsked = true
                                        systemAudio = ok ? .granted : Permissions.systemAudio
                                        if !ok { Permissions.openSystemAudioSettings() }
                                    }
                                }
                            }
                        }
                    }
                    section("Optional") {
                        step(icon: "text.viewfinder", title: "Read text on screen during recordings",
                             detail: ScreenReader.explanation + " Change it any time in Settings ▸ Vocabulary.",
                             state: .idle) {
                            Toggle("Read text on screen during recordings", isOn: $readScreen)
                                .toggleStyle(.switch).labelsHidden()
                        }
                    }
                    section("Downloads") {
                        VStack(spacing: 8) {
                            ForEach(downloads) { item in downloadRow(item) }
                        }
                        if running, runTotal > 0 { overallProgress }
                        storageAndMemory
                    }
                }
                .padding(.bottom, 8)
            }

            Divider().padding(.vertical, 12)
            HStack {
                if !allReady {
                    Text("You can record now; meetings are transcribed once the downloads finish.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later") { dismiss(); store.showSetup = false }
                if allReady {
                    Button("Start") { store.finishSetup(); dismiss() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(running ? "Downloading…" : "Download \(format(pendingBytes))") { downloadAll() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(running || !enoughDisk)
                }
            }
        }
        .padding(28)
        .frame(width: 640, height: 700)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            mic = Permissions.microphone; systemAudio = Permissions.systemAudio
        }
        .task { await checkExisting() }
    }

    // MARK: Language

    private var languageCards: some View {
        HStack(spacing: 12) {
            languageCard(title: "English", detail: "Fastest. English speech and terms spelled exactly.", selected: !hinglish) { choose(false) }
            languageCard(title: "Hindi and English", detail: "Hinglish calls. Adds the Apex model (1.6 GB); about 7 minutes per 30-minute call.", selected: hinglish) { choose(true) }
        }
    }

    private func languageCard(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(running)
    }

    private func choose(_ value: Bool) {
        hinglish = value
        AppSettings.setMeetingLanguage(hinglish: value)
    }

    // MARK: Downloads

    private func downloadRow(_ item: Item) -> some View {
        let s = items[item.id] ?? ItemState()
        return HStack(spacing: 12) {
            Group {
                switch s.state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .working: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .idle: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium))
                Text(s.status.isEmpty ? item.detail : s.status)
                    .font(.caption).foregroundStyle(s.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if s.state == .working, let f = s.fraction {
                    HStack(spacing: 8) {
                        ProgressView(value: f).frame(maxWidth: .infinity)
                        Text("\(Int(f * 100))% · \(format(Int64(Double(item.bytes) * f))) of \(format(item.bytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            Spacer()
            if s.state != .working || s.fraction == nil {
                Text(s.state == .done ? "Ready" : item.size)
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var storageAndMemory: some View {
        let memory = ProcessInfo.processInfo.physicalMemory
        return VStack(alignment: .leading, spacing: 4) {
            if let freeBytes {
                Label(enoughDisk ? "\(format(freeBytes)) free on this Mac." :
                        "Only \(format(freeBytes)) free; these downloads need \(format(pendingBytes + 2_000_000_000)). Free some space first.",
                      systemImage: enoughDisk ? "internaldrive" : "exclamationmark.triangle.fill")
                    .foregroundStyle(enoughDisk ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Label(AppSettings.hasRoomForLargeModel
                    ? "\(format(Int64(memory), memory: true)) of memory: notes use \(model)."
                    : "\(format(Int64(memory), memory: true)) of memory: notes use the lighter \(model), so the Mac stays responsive.",
                  systemImage: "memorychip")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func set(_ id: Item.ID, _ state: StepState, _ status: String = "", _ fraction: Double? = nil) {
        items[id] = ItemState(state: state, status: status, fraction: fraction)
    }

    /// Bytes done across the whole run: finished items plus the share of the one downloading.
    private var runDone: Int64 {
        runFinished + downloads.reduce(Int64(0)) { sum, item in
            guard let s = items[item.id], s.state == .working, let f = s.fraction else { return sum }
            return sum + Int64(Double(item.bytes) * f)
        }
    }

    private var overallProgress: some View {
        let done = min(runDone, runTotal)
        let fraction = Double(done) / Double(max(1, runTotal))
        var left = ""
        if let runStarted, fraction > 0.03 {
            let elapsed = Date().timeIntervalSince(runStarted)
            let remaining = elapsed / fraction * (1 - fraction)
            left = remaining < 60 ? " · less than a minute left" : " · about \(Int(remaining / 60) + 1) min left"
        }
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
            Text("\(Int(fraction * 100))% · \(format(done)) of \(format(runTotal))\(left)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// Everything still missing, one after another (each also resumes where it stopped).
    private func downloadAll() {
        running = true
        let work = pending
        runStarted = Date(); runTotal = work.reduce(0) { $0 + $1.bytes }; runFinished = 0
        Task {
            for item in work {
                set(item.id, .working, "Starting…")
                let update: @Sendable (Double?, String) -> Void = { f, text in Task { @MainActor in set(item.id, .working, text, f) } }
                do {
                    switch item.id {
                    case .speech:
                        try await SpeechEngine.shared.prepare(engine: .parakeet, report: update)
                    case .apex:
                        try await HinglishWhisper.download(.apex) { f in update(f, "Downloading from Hugging Face") }
                    case .ollama:
                        try await OllamaClient(baseURL: AppSettings.baseURL).ensureRunning(status: update)
                    case .model:
                        let client = OllamaClient(baseURL: AppSettings.baseURL)
                        try await client.ensureRunning()
                        if try await !client.hasModel(model) {
                            try await client.pull(model) { f, text in update(f, text) }
                        }
                    }
                    set(item.id, .done)
                } catch {
                    set(item.id, .failed, error.localizedDescription)
                }
                runFinished += item.bytes
            }
            running = false
            freeBytes = Self.freeSpace()
        }
    }

    private func checkExisting() async {
        freeBytes = Self.freeSpace()
        if ModelCatalog.folderSize(ModelCatalog.fluidRoot.appendingPathComponent("parakeet-tdt-0.6b-v3")) ?? 0 > 100_000_000,
           ModelCatalog.folderSize(ModelCatalog.fluidRoot.appendingPathComponent("speaker-diarization")) ?? 0 > 1_000_000 {
            set(.speech, .done)
        }
        if HinglishWhisper.isInstalled(.apex) { set(.apex, .done) }
        let client = OllamaClient(baseURL: AppSettings.baseURL)
        let up = await client.isUp()
        if up || OllamaRuntime.installedBinary != nil { set(.ollama, .done) }
        if up ? (try? await client.hasModel(model)) == true : OllamaRuntime.hasModelOnDisk(model) { set(.model, .done) }
    }

    private static func freeSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func format(_ bytes: Int64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: memory ? .memory : .file)
    }

    private var micDetail: String {
        switch mic { case .granted: return "Allowed."; case .denied: return "Denied. Enable it in System Settings, then relaunch."; case .unknown: return "Needed to record your side of the meeting." }
    }

    // MARK: Layout pieces

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func step<A: View>(icon: String, title: String, detail: String, state: StepState, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(.quaternary.opacity(0.5)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.medium))
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
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
