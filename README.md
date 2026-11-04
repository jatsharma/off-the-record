# Meeting Notes

A personal meeting recorder for Apple Silicon Macs. Records the mic and the other side of the
call, transcribes on the Neural Engine, writes notes with a local LLM. Nothing leaves the Mac.

## What it does

1. **Record** – one button. Microphone and system audio through ScreenCaptureKit, mixed to a 16 kHz mono WAV.
2. **Transcribe** – Parakeet TDT 0.6b v3 (CoreML, via FluidAudio) plus a pyannote-based diarizer, so lines are labelled Speaker 1, Speaker 2, ...
3. **Notes** – Gemma 4 e4b through Ollama, with an editable base prompt in Settings.
4. **Keep or delete** – every meeting shows the size of its audio and transcript with a delete button for each, and one for the whole meeting.

## Requirements

- macOS 15 or later, Apple Silicon, 16 GB RAM recommended.
- Xcode 26 (for the build) and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Ollama: `brew install ollama`. The app starts `ollama serve` itself if it is not running.

## Build and run

```bash
make setup   # one-time: installs Ollama and pulls gemma4:e4b (about 6.6 GB)
```

```bash
make run     # xcodegen + xcodebuild (Debug, ad-hoc signed) + open the app
```

Or `make gen` and open `NotesApp.xcodeproj` in Xcode and press Run. For a scripted smoke test, `NotesApp --auto-record 30` records for 30 seconds on launch and runs the pipeline. `make deps` vendors FluidAudio into `Vendor/` first (Xcode 26 ignores SwiftPM package traits, so the vendored copy drops the traits manifest to keep the diarizer compiled in).

### Code signing (do this once)

macOS ties the Screen & System Audio Recording permission to the app's code signature. An
ad-hoc signed app gets a new signature on every build, so the permission would break after each
rebuild. Create a local signing certificate once:

```bash
sh scripts/make-dev-cert.sh
```

It creates a self-signed "Meeting Notes Dev" certificate in your login keychain, trusted for code
signing only (Keychain asks for your password at the trust step). `project.yml` already signs with
that name. If you have an Apple Development certificate instead, put its name in
`CODE_SIGN_IDENTITY` and your team in `DEVELOPMENT_TEAM`.

Hardened runtime is off in `project.yml` because its library validation rejects the app's own
dylibs when the certificate has no Team ID. Turn it on only for a Developer ID build.

If a build still cannot record after a permission change, quit and relaunch the app: a permission
request that was already waiting does not pick up the new setting. If macOS shows the app as
allowed but it still cannot record, remove the entry with the "−" button in System Settings so a
fresh prompt appears.

On first launch macOS asks for Microphone and System Audio Recording permission. The first
transcription downloads about 500 MB of speech models from Hugging Face into
`~/Library/Application Support/FluidAudio/Models`.

## Where things live

| What | Path |
| --- | --- |
| Database | `~/Library/Application Support/Notes/notes.sqlite` |
| Recordings | `~/Library/Application Support/Notes/Audio/<meeting id>.wav` (about 115 MB per hour) |
| Speech models | `~/Library/Application Support/FluidAudio/Models` |
| LLM weights | `~/.ollama/models` |

## Layout

```
NotesApp/
  App/       NotesApp.swift (entry), MeetingStore.swift (record -> transcribe -> notes, deletes)
  Capture/   AudioRecorder.swift (ScreenCaptureKit mic + system audio, mixer, WAV writer)
  Speech/    SpeechEngine.swift (FluidAudio ASR + diarization, token/speaker merge)
  LLM/       OllamaClient.swift (local HTTP, auto-start, pull, streaming chat), Summarizer.swift (settings + prompt)
  Store/     Database.swift (GRDB, migrations), Models.swift (Meeting, Segment)
  UI/        ContentView, RecordView, MeetingDetailView, SettingsView, Observers
project.yml  XcodeGen spec; Makefile wraps gen/build/run/setup
```

## Settings

- **Model** – any Ollama tag. `gemma4:e4b` by default; `gemma4:e2b` if memory is tight.
- **Context window** – 32k tokens by default, enough for roughly 90 minutes of speech.
- **Notes prompt** – the user message sent to the model. Placeholders `{{title}}`, `{{date}}`, `{{transcript}}`.

## Not included on purpose

Live captions, cross-meeting speaker names, screen OCR, calendar, email, action-item tracking,
cloud backends, licensing, auto-update. The store is a plain SQLite file, so any of these can be
added later without migrating data.
