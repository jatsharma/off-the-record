import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VocabularySettings().tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            PromptSettings().tabItem { Label("Notes prompt", systemImage: "text.alignleft") }
            ModelsSettings().tabItem { Label("Models", systemImage: "internaldrive") }
            StorageSettings().tabItem { Label("Storage", systemImage: "externaldrive") }
            VoicesSettings().tabItem { Label("Voices", systemImage: "person.wave.2") }
        }
        .frame(width: 640, height: 560)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppSettings.engineKey) private var engine = ASREngine.parakeet.rawValue
    @AppStorage(AppSettings.whisperModelKey) private var whisperModel = AppSettings.defaultWhisperModel
    @AppStorage(AppSettings.languageKey) private var language = ""
    @AppStorage(AppSettings.scriptsKey) private var scripts = AppSettings.defaultScripts
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.urlKey) private var url = AppSettings.defaultURL
    @AppStorage(AppSettings.contextKey) private var contextTokens = AppSettings.defaultContextTokens

    @AppStorage(AppSettings.accentKey) private var accent = AccentTheme.ocean.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance = Appearance.system.rawValue
    @AppStorage("captions.live") private var liveCaptions = true

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Live captions while recording", isOn: $liveCaptions)
                Text("Rough text every 12 seconds from the Parakeet model. The final transcript is always made from the whole recording afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    TextField("Scripts your meetings use", text: $scripts, prompt: Text(AppSettings.defaultScripts))
                    Text("Lines written in other scripts are dropped; short quiet stretches otherwise come back as Chinese or Korean. Options: latin, devanagari, arabic, cyrillic, gujarati, gurmukhi, tamil, telugu, kannada, malayalam, bengali, japanese, korean, chinese.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(engineHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes (Ollama)") {
                TextField("Model", text: $model, prompt: Text(AppSettings.defaultModel))
                TextField("Server URL", text: $url, prompt: Text(AppSettings.defaultURL))
                Stepper("Context window: \(contextTokens) tokens", value: $contextTokens, in: 4096...131_072, step: 4096)
                Text("qwen3.5:4b (3.3 GB download) needs about 4 GB of memory while writing and wrote the best notes of the light models in testing. gemma4:e4b (about 6.5 GB in memory) is a close alternative; gemma4:12b is a little more accurate but needs about 10 GB, which slows a 16 GB Mac. 32k tokens covers roughly a 90-minute meeting. Models that are not installed are pulled on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var engineHelp: String {
        switch ASREngine(rawValue: engine) ?? .parakeet {
        case .parakeet: return "Fastest and most accurate for English. Hindi comes out as English sounds. About 70 s per 30 minutes of audio."
        case .whisper: return "99 languages. Slower (about 7 minutes per 30 minutes of audio) and drops speech on mixed-language calls."
        case .qwen3: return "Uses your Vocabulary list as a hint. Hindi comes out in Devanagari and the clean-up pass romanizes it. Slow: about 20 minutes per 30 minutes of audio."
        case .tara: return "Whisper large-v3 tuned for Hinglish, Hindi in Devanagari and English terms in Latin script. Most accurate in Python tests, but on this Mac it runs at about real time (30 minutes per 30-minute call) and garbles some long Hindi stretches. Experimental." + installNote(.tara)
        case .apex: return "Whisper turbo tuned for Hinglish. Writes romanized Hinglish with English terms spelled normally (\"postgres mein time scale daal denge\"). Best on technical Hinglish calls in testing; about 8 minutes per 30 minutes of audio." + installNote(.apex)
        }
    }

    private func installNote(_ engine: ASREngine) -> String {
        HinglishWhisper.isInstalled(engine) ? "" : " Not installed yet: run `make hinglish-models` in the project folder."
    }
}

/// The team glossary and the two features that use or grow it.
struct VocabularySettings: View {
    @AppStorage(Vocabulary.termsKey) private var terms = ""
    @AppStorage(Vocabulary.cleanupKey) private var cleanup = true
    @AppStorage(Vocabulary.screenKey) private var readScreen = true

    var body: some View {
        Form {
            Section {
                TextEditor(text: $terms)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
            } header: {
                Text("Names and terms your meetings use (\(Vocabulary.parse(terms).count))")
            } footer: {
                Text("One per line, spelled the way you want them written: Solana, TimescaleDB, DexScreener, people's names. The recognizer is nudged toward them, the clean-up pass restores them where the sound matches, and the notes use these spellings. Words you type when correcting a transcript line are added here automatically. Keep the most important terms near the top: the recognizer only has room for about 40.")
            }
            Section("Transcript") {
                Toggle("Clean up the transcript with the notes model", isOn: $cleanup)
                Text("After recognition, rewrites each line in romanized Hinglish and fixes misheard terms using this list. The recognizer's original text is kept on every changed line. Adds about a minute per 30 minutes of audio.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Read on-screen text while recording", isOn: $readScreen)
                Text("Every 20 seconds during a recording, text on your screen (shared slides, code, dashboards) is read on this Mac and kept with the meeting, so names spelled there are recognized correctly. This app's own windows are skipped. Needs the Screen & System Audio Recording permission the app already uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Text("Placeholders: {{title}}, {{date}}, {{glossary}}, {{transcript}}. A fixed system line also tells the model to stay inside the transcript and never invent.")
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

/// Audio takes about 230 MB per hour as a two-channel WAV. Transcripts and notes are tiny.
struct StorageSettings: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var totals: (count: Int, bytes: Int64) = (0, 0)
    @State private var days = 30
    @State private var lastDeleted: Int?

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Audio on disk", value: "\(ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file)) in \(totals.count) meeting\(totals.count == 1 ? "" : "s")")
                LabeledContent("Folder", value: AppDatabase.audioDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppDatabase.audioDirectory]) }
            }
            Section {
                HStack {
                    Picker("Delete audio older than", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                    }
                    .frame(maxWidth: 320)
                    Button("Delete now") {
                        lastDeleted = store.deleteAudio(olderThanDays: days)
                        totals = store.audioTotals()
                    }
                }
                if let lastDeleted { Text("Removed audio from \(lastDeleted) meeting\(lastDeleted == 1 ? "" : "s"). Transcripts and notes were kept.").font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Only the WAV files are removed. Notes and transcripts stay; those meetings just cannot be re-transcribed or played back.")
            }
        }
        .formStyle(.grouped)
        .onAppear { totals = store.audioTotals() }
    }
}

/// Names the app has learned for voices. Rename a speaker in any meeting to add one.
struct VoicesSettings: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var voices: [VoicePrint] = []

    var body: some View {
        Form {
            Section {
                if voices.isEmpty {
                    Text("No voices yet. In a meeting's transcript, click a speaker label and give it a name; that voice is then recognised in later meetings.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voices) { vp in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vp.name).font(.body.weight(.medium))
                                Text("Learned from \(vp.samples) meeting\(vp.samples == 1 ? "" : "s") · updated \(vp.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { store.deleteVoicePrint(vp); voices = store.voicePrints() }
                        }
                    }
                }
            } header: {
                Text("Known voices")
            } footer: {
                Text("Matching is by voice similarity and is not perfect. A wrong match is fixed by renaming the speaker again in that meeting, which also improves the stored voice.")
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = store.voicePrints() }
    }
}
