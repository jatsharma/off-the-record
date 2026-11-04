import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PromptSettings().tabItem { Label("Notes prompt", systemImage: "text.alignleft") }
            ModelsSettings().tabItem { Label("Models", systemImage: "internaldrive") }
        }
        .frame(width: 640, height: 560)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppSettings.engineKey) private var engine = ASREngine.parakeet.rawValue
    @AppStorage(AppSettings.whisperModelKey) private var whisperModel = AppSettings.defaultWhisperModel
    @AppStorage(AppSettings.languageKey) private var language = ""
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.urlKey) private var url = AppSettings.defaultURL
    @AppStorage(AppSettings.contextKey) private var contextTokens = AppSettings.defaultContextTokens

    @AppStorage(AppSettings.accentKey) private var accent = AccentTheme.ocean.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance = Appearance.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent") {
                    HStack(spacing: 10) {
                        ForEach(AccentTheme.allCases) { theme in
                            Button { accent = theme.rawValue } label: {
                                Circle().fill(theme.color).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(.primary.opacity(accent == theme.rawValue ? 0.9 : 0), lineWidth: 2))
                                    .overlay(Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white).opacity(accent == theme.rawValue ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                            .help(theme.name)
                        }
                    }
                }
                Text("Recording controls stay red in every accent.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech recognition") {
                Picker("Engine", selection: $engine) {
                    ForEach(ASREngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if engine == ASREngine.whisper.rawValue {
                    TextField("Whisper model", text: $whisperModel, prompt: Text(AppSettings.defaultWhisperModel))
                }
                if ASREngine(rawValue: engine)?.takesLanguageHint == true {
                    TextField("Language code (blank = auto-detect)", text: $language, prompt: Text("auto"))
                }
                Text(engineHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes (Ollama)") {
                TextField("Model", text: $model, prompt: Text(AppSettings.defaultModel))
                TextField("Server URL", text: $url, prompt: Text(AppSettings.defaultURL))
                Stepper("Context window: \(contextTokens) tokens", value: $contextTokens, in: 4096...131_072, step: 4096)
                Text("Gemma 4 e4b needs about 6 GB of memory while writing. 32k tokens covers roughly a 90-minute meeting. Models that are not installed are pulled on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var engineHelp: String {
        switch ASREngine(rawValue: engine) ?? .parakeet {
        case .parakeet: return "Fastest and most accurate for English. Hindi comes out as English sounds. About 70 s per 30 minutes of audio."
        case .whisper: return "99 languages. Slower (about 7 minutes per 30 minutes of audio) and drops speech on mixed-language calls."
        case .qwen3: return "Writes Hindi in Devanagari and keeps English terms. Slow: about 17 minutes per 30 minutes of audio, transcribed one speaker turn at a time."
        }
    }
}

struct PromptSettings: View {
    @AppStorage(AppSettings.promptKey) private var prompt = AppSettings.defaultPrompt

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 340)
            } header: {
                Text("What the model is asked to write")
            } footer: {
                Text("Placeholders: {{title}}, {{date}}, {{transcript}}. A fixed system line also tells the model to stay inside the transcript and never invent.")
            }
            Section {
                HStack {
                    Button("Reset to default") { prompt = AppSettings.defaultPrompt }
                    Spacer()
                    Text("Changes apply to the next Regenerate.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Every downloaded model with its size and a delete button. Deleting frees disk only:
/// whichever engine is selected downloads what it needs again on next use.
struct ModelsSettings: View {
    @AppStorage(AppSettings.engineKey) private var engine = ASREngine.parakeet.rawValue
    @State private var sizes: [String: Int64?] = [:]
    @State private var pendingDelete: ModelEntry?
    @State private var busy: Set<String> = []

    private var total: Int64 { sizes.values.compactMap { $0 }.reduce(0, +) }

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.entries) { entry in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.name).font(.body.weight(.medium))
                                if entry.engine?.rawValue == engine || (entry.engine == nil && entry.id != "nemotron") {
                                    Text("in use").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                                }
                            }
                            Text(entry.purpose).font(.caption).foregroundStyle(.secondary)
                            Text(entry.location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if busy.contains(entry.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(ModelCatalog.format(sizes[entry.id] ?? nil))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle((sizes[entry.id] ?? nil) == nil ? .tertiary : .secondary)
                            Button("Delete") { pendingDelete = entry }
                                .disabled((sizes[entry.id] ?? nil) == nil)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Downloaded models")
                    Spacer()
                    Text("Total \(ModelCatalog.format(total))").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Deleting only frees disk space. The selected engine downloads its models again the next time a meeting is processed; the first run after that is slower.")
            }
            Section {
                HStack {
                    Button("Refresh sizes") { Task { await refresh() } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ModelCatalog.fluidRoot]) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")? It is downloaded again on next use.",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await delete(entry) } }
                pendingDelete = nil
            }
        }
    }

    private func refresh() async {
        for entry in ModelCatalog.entries {
            sizes[entry.id] = await ModelCatalog.sizeOnDisk(entry)
        }
    }

    private func delete(_ entry: ModelEntry) async {
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        try? await ModelCatalog.delete(entry)
        sizes[entry.id] = await ModelCatalog.sizeOnDisk(entry)
    }
}
