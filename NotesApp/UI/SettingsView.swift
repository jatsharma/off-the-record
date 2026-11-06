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
    @AppStorage(AppSettings.engineKey) private var engine = AppSettings.defaultEngine.rawValue
    @AppStorage(AppSettings.meetingLanguageKey) private var meetingLanguage = AppSettings.hinglish ? "hinglish" : "english"
    @AppStorage(AppSettings.whisperModelKey) private var whisperModel = AppSettings.defaultWhisperModel
    @AppStorage(AppSettings.languageKey) private var language = ""
    @AppStorage(AppSettings.scriptsKey) private var scripts = AppSettings.defaultScripts
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.urlKey) private var url = AppSettings.defaultURL
    @AppStorage(AppSettings.contextKey) private var contextTokens = AppSettings.defaultContextTokens

    @AppStorage(AppSettings.accentKey) private var accent = AccentTheme.ocean.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance = Appearance.system.rawValue
    @AppStorage("captions.live") private var liveCaptions = true
    @AppStorage(Microphones.key) private var microphone = ""
    @State private var microphones = Microphones.available
    @AppStorage(NotesPipeline.byPartsKey) private var notesByParts = false
    @State private var advancedSpeech = false
    @State private var advancedNotes = false

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Microphone", selection: $microphone) {
                    Text("System default").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                }
                .onAppear { microphones = Microphones.available }
                Text("Headphones give the cleanest transcript: the other side of the call is not picked up again by your microphone.")
                    .font(.caption).foregroundStyle(.secondary)
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
                            .accessibilityLabel("\(theme.name) accent")
                        }
                    }
                }
                Text("Recording controls stay red in every accent.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech recognition") {
                Picker("Meetings are in", selection: Binding(get: { meetingLanguage }, set: { value in
                    AppSettings.setMeetingLanguage(hinglish: value == "hinglish")
                    meetingLanguage = value
                    engine = AppSettings.engine.rawValue
                })) {
                    Text("English").tag("english")
                    Text("Hindi and English").tag("hinglish")
                }
                .pickerStyle(.segmented)
                Text(meetingLanguage == "hinglish"
                     ? "Hindi parts are written in romanized Hinglish, English terms and numbers exactly. About 7 minutes per 30-minute call." + installNote(.apex)
                     : "Fastest: about a minute per 30-minute call. Hindi would come out as English-sounding words.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced: pick the speech engine", isExpanded: $advancedSpeech) {
                    Picker("Engine", selection: $engine) {
                        ForEach(ASREngine.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Text(engineHelp).font(.caption).foregroundStyle(.secondary)
                    if engine == ASREngine.whisper.rawValue {
                        TextField("Whisper model", text: $whisperModel, prompt: Text(AppSettings.defaultWhisperModel))
                    }
                    if ASREngine(rawValue: engine)?.takesLanguageHint == true {
                        TextField("Language code (blank = auto-detect)", text: $language, prompt: Text("auto"))
                        TextField("Scripts your meetings use", text: $scripts, prompt: Text(AppSettings.defaultScripts))
                        Text("Lines written in other scripts are dropped; short quiet stretches otherwise come back as Chinese or Korean. Options: latin, devanagari, arabic, cyrillic, gujarati, gurmukhi, tamil, telugu, kannada, malayalam, bengali, japanese, korean, chinese.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Parakeet (English) and Mix (Hinglish) are what the language choice above picks. The others are slower and were less accurate in testing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notes") {
                TextField("Model", text: $model, prompt: Text(AppSettings.defaultModel))
                Text("Any Ollama model. \(AppSettings.defaultModel) is the default for this Mac's memory: gemma4:e4b wrote the most complete and accurate notes in testing (about 6.5 GB in memory while writing); gemma4:e2b is lighter for 8 GB Macs. Models that are not installed are downloaded on first use.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $advancedNotes) {
                    TextField("Ollama server", text: $url, prompt: Text(AppSettings.defaultURL))
                    Stepper("Longest meeting: \(contextTokens) tokens (about \(contextTokens / 360) minutes)", value: $contextTokens, in: 4096...131_072, step: 4096)
                    Toggle("Write long meetings part by part", isOn: $notesByParts)
                    Text("For meetings over 15 minutes: notes for each 8-minute part, then combined. Catches more points, but small models also make more mistakes this way, and it takes about four times as long.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var engineHelp: String {
        switch ASREngine(rawValue: engine) ?? AppSettings.defaultEngine {
        case .parakeet: return "Fastest and most accurate for English. Hindi comes out as English sounds. About 70 s per 30 minutes of audio."
        case .whisper: return "99 languages. Slower (about 7 minutes per 30 minutes of audio) and drops speech on mixed-language calls."
        case .tara: return "Whisper large-v3 tuned for Hinglish, Hindi in Devanagari and English terms in Latin script. Most accurate in Python tests, but on this Mac it runs at about real time (30 minutes per 30-minute call) and garbles some long Hindi stretches. Experimental." + installNote(.tara)
        case .apex: return "Whisper turbo tuned for Hinglish. Writes romanized Hinglish with English terms spelled normally (\"postgres mein time scale daal denge\"). Best on technical Hinglish calls in testing; about 8 minutes per 30 minutes of audio." + installNote(.apex)
        case .mix: return "Apex reads every turn and Parakeet reads it too; turns that are almost all English keep Parakeet's exact spelling of terms and numbers, the rest keep Apex. Gave the best notes on both test meetings; about the same time as Apex and about 0.5 GB more memory while transcribing." + installNote(.apex)
        }
    }

    private func installNote(_ engine: ASREngine) -> String {
        HinglishWhisper.isInstalled(engine) ? "" : " Downloads \(HinglishWhisper.downloadSize[engine] ?? "") once, the first time a meeting is processed (or now, under Models)."
    }
}

/// The team glossary and the two features that use or grow it.
struct VocabularySettings: View {
    @AppStorage(Vocabulary.termsKey) private var terms = ""
    @AppStorage(Vocabulary.cleanupKey) private var cleanup = true
    @AppStorage(Vocabulary.screenKey) private var readScreen = false
    @AppStorage(Vocabulary.correctionsKey) private var corrections = ""
    @AppStorage(Vocabulary.notesFixesKey) private var notesFixes = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $terms)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
            } header: {
                Text("Names and terms your meetings use (\(Vocabulary.parse(terms).count))")
            } footer: {
                Text("One per line, spelled the way you want them written: Solana, TimescaleDB, DexScreener, people's names. The clean-up pass restores them where the sound matches, and the notes use these spellings. Words you type when correcting a transcript line are added here automatically.")
            }
            Section {
                TextEditor(text: $corrections)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
            } header: {
                Text("Learned corrections (\(Vocabulary.corrections.count))")
            } footer: {
                Text("What the recognizer heard → what it should be, e.g. \"dixcheck → DexScreener\". Added automatically when you correct a transcript line and replace a misheard name or term; applied to every new transcript. Delete a line to forget it.")
            }
            Section {
                TextEditor(text: $notesFixes)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
            } header: {
                Text("Fixes from your notes edits (\(Vocabulary.notesFixes.count))")
            } footer: {
                Text("Wrong word → right word, e.g. \"cash flow → Kafka\". Added when you change a few words in a meeting's notes; the notes model then writes the right word whenever the transcript has the wrong one in that sense. Delete a line to forget it.")
            }
            Section("Transcript") {
                Toggle("Clean up the transcript with the notes model", isOn: $cleanup)
                Text("After recognition, fixes misheard terms using this list (romanized lines only get term fixes; Devanagari lines are also romanized). The recognizer's original text is kept on every changed line. Adds a few minutes per 30 minutes of audio.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Read on-screen text while recording", isOn: $readScreen)
                Text(ScreenReader.explanation + " This app's own windows are skipped. Off unless you turn it on; uses the Screen & System Audio Recording permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PromptSettings: View {
    @AppStorage(AppSettings.promptKey) private var prompt = AppSettings.defaultPrompt
    @State private var pendingTemplate: NoteTemplate?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 340)
            } header: {
                Text("What the model is asked to write")
            } footer: {
                Text("Placeholders: {{title}}, {{date}}, {{days}} (what today, tomorrow, aaj, kal mean for this meeting), {{glossary}}. The transcript is always sent first, before these instructions, so refer to it as \"the transcript above\". A fixed system line also tells the model to stay inside the transcript and never invent.")
            }
            Section {
                HStack {
                    Menu("Start from a template") {
                        ForEach(NoteTemplate.allCases) { template in
                            Button(template.name) { pendingTemplate = template }
                        }
                    }
                    .fixedSize()
                    Button("Reset to default") { prompt = AppSettings.defaultPrompt }
                    Spacer()
                    Text("Changes apply to new meetings and the next Regenerate.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace the prompt with the \(pendingTemplate?.name ?? "") template?",
                            isPresented: Binding(get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } }),
                            titleVisibility: .visible) {
            Button("Replace") { if let t = pendingTemplate { prompt = t.prompt }; pendingTemplate = nil }
        } message: { Text("Your current prompt text is replaced.") }
    }
}

/// Every downloaded model with its size and a delete button. Deleting frees disk only:
/// whichever engine is selected downloads what it needs again on next use.
struct ModelsSettings: View {
    @AppStorage(AppSettings.engineKey) private var engine = AppSettings.defaultEngine.rawValue
    @State private var sizes: [String: Int64?] = [:]
    @State private var pendingDelete: ModelEntry?
    @State private var busy: Set<String> = []
    @State private var downloading: [String: Double] = [:]
    @State private var downloadError: String?

    private var total: Int64 { sizes.values.compactMap { $0 }.reduce(0, +) }

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.entries) { entry in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.name).font(.body.weight(.medium))
                                if inUse(entry) {
                                    Text("in use").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                                }
                            }
                            Text(entry.purpose).font(.caption).foregroundStyle(.secondary)
                            Text(entry.location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let fraction = downloading[entry.id] {
                            ProgressView(value: fraction).frame(width: 90)
                            Text("\(Int(fraction * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        } else if busy.contains(entry.id) {
                            ProgressView().controlSize(.small)
                        } else if (sizes[entry.id] ?? nil) == nil, let model = entry.engine, HinglishWhisper.repos[model] != nil {
                            Text(HinglishWhisper.downloadSize[model] ?? "").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                            Button("Download") { download(entry, model) }
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
                VStack(alignment: .leading, spacing: 4) {
                    if let downloadError { Text(downloadError).foregroundStyle(.red) }
                    Text("Deleting only frees disk space. The selected engine downloads its models again the next time a meeting is processed; the first run after that is slower.")
                }
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

    /// The selected engine's models, and the ones every engine shares. Mix uses Apex and Parakeet.
    private func inUse(_ entry: ModelEntry) -> Bool {
        guard let model = entry.engine else { return entry.id != "nemotron" }
        if model.rawValue == engine { return true }
        return engine == ASREngine.mix.rawValue && (model == .apex || model == .parakeet)
    }

    private func download(_ entry: ModelEntry, _ model: ASREngine) {
        downloadError = nil
        downloading[entry.id] = 0
        Task {
            do {
                try await HinglishWhisper.download(model) { f in Task { @MainActor in downloading[entry.id] = f } }
            } catch {
                downloadError = "\(entry.name): \(error.localizedDescription)"
            }
            downloading[entry.id] = nil
            await refresh()
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
