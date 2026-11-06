# Meeting Notes

A personal meeting recorder for Apple Silicon Macs. Records the mic and the other side of the
call, transcribes on the Neural Engine, writes notes with a local LLM. Nothing leaves the Mac.

## What it does

1. **Record** – one button, ⌘R, ⌃⌥⌘R from any app, or the menu bar item. Microphone and system audio
   through ScreenCaptureKit into a two-channel 16 kHz WAV (left = you, right = the call). Pause and
   resume keep one file. Rough live captions appear while you record. If capture stops on its own
   (permission change, audio device gone), the audio so far is saved and transcribed.
2. **Transcribe** – Parakeet TDT 0.6b v3 (CoreML, via FluidAudio) on each channel: your lines are
   labelled **You**; the call is diarized into speakers. Echo of the call picked up by the mic is
   suppressed before transcription. Rename a speaker once and that voice is recognised in later
   meetings (Settings → Voices). Naming a second label after a speaker already in the meeting
   merges the two. Meetings are processed one at a time; others wait in line.
3. **Notes** – Gemma 4 e4b through Ollama, with an editable prompt. Notes are editable in place,
   checkboxes are tickable, and an Action items view collects open ones across meetings. Meetings
   left untitled are named by the model.
4. **Keep or delete** – every meeting shows audio and transcript sizes with per-item delete;
   Settings → Storage deletes audio older than N days; Settings → Models deletes model downloads
   (they come back on next use).

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

On first launch a Setup Assistant walks through Microphone and System Audio permission and the model
downloads (Help → Setup Assistant to reopen it). The first
transcription downloads about 500 MB of speech models from Hugging Face into
`~/Library/Application Support/FluidAudio/Models`.

## Where things live

| What | Path |
| --- | --- |
| Database | `~/Library/Application Support/Notes/notes.sqlite` |
| Recordings | `~/Library/Application Support/Notes/Audio/<meeting id>.wav` (two channels, about 230 MB per hour) |
| Speech models | `~/Library/Application Support/FluidAudio/Models` |
| LLM weights | `~/.ollama/models` |

## Layout

```
NotesApp/
  App/       NotesApp.swift (entry, menus, menu bar), MeetingStore.swift (job queue, pipeline, deletes,
             voices, action items), RecordingController (start/stop/pause, live captions), ModelCatalog,
             Permissions, AudioPlayer, Notifier, GlobalHotKey, AutoRecord/Screenshots (dev hooks)
  Capture/   AudioRecorder.swift (ScreenCaptureKit mic + system audio, two-channel aligner, WAV writer),
             ScreenReader.swift (on-screen text for the glossary)
  Speech/    SpeechEngine.swift (Parakeet/Whisper/Qwen3/Mix, diarization, echo gate, voice matching),
             HinglishWhisper.swift (Apex and Tara through WhisperKit)
  LLM/       OllamaClient.swift (local HTTP, auto-start, pull, streaming chat), Summarizer.swift (settings + prompt),
             NotesPipeline.swift (tidy transcript, part-by-part notes, checked action items),
             TranscriptCleaner.swift (glossary clean-up pass), Vocabulary.swift (glossary, learned corrections)
  Store/     Database.swift (GRDB, migrations), Models.swift (Meeting, Segment)
  UI/        ContentView (sidebar), RecordView, MeetingDetailView, ActionItemsView, SetupView,
             SettingsView (General, Prompt, Models, Storage, Voices), Theme, Observers
project.yml  XcodeGen spec; Makefile wraps gen/build/run/setup
```

## Speech engines

Settings → Speech recognition switches between three engines. Measured on the same real
32-minute Hindi-English meeting on an M1 Pro, models already downloaded:

| Engine | Transcribe + diarize | Words captured | Hinglish handling |
| --- | --- | --- | --- |
| Parakeet TDT 0.6b v3 (default) | 70 s | 3,144 | Hindi comes out as phonetic English; best for English meetings |
| Whisper large-v3-turbo | 7 min | 1,461 (391 Devanagari) | Flips language per chunk and drops about half the speech; forcing `en` replaces Hindi with "foreign" |
| Qwen3-ASR 0.6B | 17 min | 6,070 (1,890 Devanagari) | Proper code-switched output: Hindi in Devanagari, English terms in Latin script. Occasional repetition loops (collapsed automatically) and misdetected short chunks |

Qwen3 has a 30-second window and no timestamps, so the app diarizes first and transcribes each
speaker turn on its own; timing and speaker labels come from the diarizer. On two-channel
recordings your side is cut into speech runs and labelled You. Chunks that are mostly silence are
skipped, lines in scripts you do not use (Settings → "Scripts your meetings use", default Latin +
Devanagari) are dropped, and overlapping duplicate turns are removed. Use it for Hindi or Hinglish
meetings; it runs at roughly 2x real time. Parakeet for English.

### Hinglish: Apex and the Mix engine (default)

`make hinglish-models` adds Apex (a Whisper turbo fine-tune that writes romanized Hinglish) and
Tara. Apex is the only engine that captures Hindi-heavy speech, but it turns English terms and
numbers into Hinglish ("Confidence par" for Confluence, "13 thousand" for thirteen screens) and
sometimes drops English sentences. Parakeet keeps English exact but turns Hindi into
English-sounding nonsense. The **Mix** engine reads every speaker turn with Apex and with
Parakeet, and keeps Parakeet's reading only where Apex's has almost no Hindi words and Parakeet's
is almost all dictionary English. On a 31-minute technical meeting, Mix + gemma4:e4b notes covered
about 22 of 33 checked facts with about 3 errors (Apex + qwen3.5:4b: about 13 with 8 errors), and
a 94-second Hindi-heavy call stayed fully correct. Mix is the default when Apex is installed.

Both engines normalise a quiet microphone channel before recognition and suppress the call's echo
in it, so a laptop mic across the desk still yields your lines. The echo gate drops mic audio that is
6 dB or more under the call (including echo arriving up to 60 ms late). It measures how strongly
the call leaks into the mic on each recording; with headphones (no leak) the mic is left alone, so
you talking over the other side is kept.

Qwen3 was removed from FluidAudio upstream in June 2026 (#676). `scripts/fluidaudio-qwen3.patch`
restores it into the vendored copy and ports its downloader to the current API.

## Settings

- **Model** – any Ollama tag. `gemma4:e4b` by default (about 6.5 GB of memory while writing); `qwen3.5:4b` is lighter (about 4 GB) but got more facts wrong on a 31-minute test meeting; `gemma4:12b` needs about 10 GB.
- **Context window** – the most the app will ask for, 32k tokens by default (roughly 90 minutes of
  speech). Each meeting uses the smallest of 8k/16k/32k that fits it, the same size for every call on
  that meeting: gemma4 is reloaded (about 5 s) whenever the size changes.
- **Notes prompt** – the instructions sent to the model. Placeholders `{{title}}`, `{{date}}`, `{{days}}`,
  `{{glossary}}`. The transcript always goes first, ahead of the instructions; the action-item step
  starts with the same text, so Ollama reuses that work (27 s of prompt processing down to 0.2 s on a
  32-minute meeting).
- **Read the screen** – on by default: while recording, the screen's text is read every 20 s (only when
  the screen changed) and its names and terms join the glossary. The clean-up pass only sends lines
  that hold a word sounding like a glossary term.

## Not included on purpose

Calendar, email, cloud backends, licensing, auto-update. The store is a plain SQLite file, so any of these can be
added later without migrating data.
