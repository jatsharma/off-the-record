import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.urlKey) private var url = AppSettings.defaultURL
    @AppStorage(AppSettings.contextKey) private var contextTokens = AppSettings.defaultContextTokens
    @AppStorage(AppSettings.promptKey) private var prompt = AppSettings.defaultPrompt

    var body: some View {
        Form {
            Section("Language model (Ollama)") {
                TextField("Model", text: $model, prompt: Text(AppSettings.defaultModel))
                TextField("Server URL", text: $url, prompt: Text(AppSettings.defaultURL))
                Stepper("Context window: \(contextTokens) tokens", value: $contextTokens, in: 4096...131_072, step: 4096)
                Text("Gemma 4 e4b needs about 6.6 GB on disk and 6 GB of memory while writing notes. 32k tokens of context covers roughly a 90-minute meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes prompt") {
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
                Text("Placeholders: {{title}}, {{date}}, {{transcript}}. The model also gets a fixed system line telling it to stay inside the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to default prompt") { prompt = AppSettings.defaultPrompt }
            }
            Section("Storage") {
                LabeledContent("Data folder", value: AppDatabase.supportDirectory.path)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppDatabase.supportDirectory]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
    }
}
