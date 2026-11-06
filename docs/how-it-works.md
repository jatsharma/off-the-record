# How Off the Record works

Notes for contributors: where data lives, how the code is laid out, and why the speech and notes
pipeline is built the way it is. Measurements are from an M1 Pro with models already downloaded.

## The pipeline

1. **Record.** ScreenCaptureKit captures the microphone and the system audio in one stream. The two
   sources are aligned by timestamp into a two-channel 16 kHz WAV: left is you, right is the call.
2. **Clean the audio.** The call's echo is removed from your channel and quiet channels are brought up
   to a working level.
3. **Transcribe.** Your channel is labelled *You*; the call channel is diarized into speakers, and known
   voices are named from earlier meetings.
4. **Clean the transcript.** Learned corrections are applied, and a constrained LLM pass restores
   glossary spellings where a word sounds like a glossary term.
5. **Write notes.** The notes model gets the transcript first, then your typed notes and the
   instructions. Action items are asked for separately as structured lines and checked in code
   against the transcript before they replace the notes' list.
6. **Name the meeting** when it was left untitled.

Meetings are processed one at a time; others wait in line.

## Where things live

| What | Path |
| --- | --- |
| Database | `~/Library/Application Support/Off the Record/notes.sqlite` |
| Recordings | `~/Library/Application Support/Off the Record/Audio/<meeting id>.wav` (two channels, about 230 MB per hour) |
| Speech models | `~/Library/Application Support/FluidAudio/Models` |
| Ollama runtime (if downloaded) | `~/Library/Application Support/Off the Record/Runtime/ollama` |
| App log (no meeting content; the last lines go into Help → Copy Diagnostics) | `~/Library/Application Support/Off the Record/Logs/app.log` |
| Hinglish models | `~/Library/Application Support/Off the Record/Models/hinglish` |
| LLM weights | `~/.ollama/models` |

## Layout

```
NotesApp/
  App/       NotesApp.swift (entry, menus, menu bar), LegacyData (move data from the old "Meeting Notes"),
             MeetingStore.swift (job queue, pipeline, deletes, voices, action items), RecordingController (start/stop/pause, live captions), ModelCatalog,
             Permissions, AudioPlayer, Notifier, GlobalHotKey, AutoRecord/Screenshots (dev hooks),
             AppLog (log file for Copy Diagnostics), Diagnostics
  Capture/   AudioRecorder.swift (ScreenCaptureKit mic + system audio, two-channel aligner, WAV writer),
             ScreenReader.swift (on-screen text for the glossary)
  Speech/    SpeechEngine.swift (Parakeet/Mix, advanced: Apex/Tara/Whisper, diarization, echo gate, voice matching),
             HinglishWhisper.swift (Apex and Tara through WhisperKit)
  LLM/       OllamaClient.swift (local HTTP, auto-start, pull, streaming chat), OllamaRuntime (downloads
             Ollama when it is missing), Summarizer.swift (settings + prompt),
             NotesPipeline.swift (tidy transcript, part-by-part notes, checked action items),
             TranscriptCleaner.swift (glossary clean-up pass), Vocabulary.swift (glossary, learned corrections)
  Store/     Database.swift (GRDB, migrations), Models.swift (Meeting, Segment)
  UI/        ContentView (sidebar), NotesView (notes edited in place), RecordView, MeetingDetailView, ActionItemsView, SetupView,
             SettingsView (General, Prompt, Models, Storage, Voices), Theme, Observers
Tests/NotesAppTests/  unit tests (notes lines, word fixes, action items, echo gate)
project.yml  XcodeGen spec; Makefile wraps gen/build/run/test/setup
.github/workflows/build.yml  tests and a Release build on every push and pull request
```

## Speech engines

The Setup Assistant (and Settings → General) asks what the meetings are in: **English** uses
Parakeet, **Hindi and English** uses Mix. Apex, Tara and Whisper stay available under "Advanced".
Measured on the same real 32-minute Hindi-English meeting on an M1 Pro, models already downloaded:

| Engine | Transcribe + diarize | Words captured | Hinglish handling |
| --- | --- | --- | --- |
| Parakeet TDT 0.6b v3 (English) | 70 s | 3,144 | Hindi comes out as phonetic English; best for English meetings |
| Mix: Apex + Parakeet (Hinglish) | about 7 min | | Hindi captured, English terms and numbers kept exact; best notes in testing |
| Whisper large-v3-turbo (advanced) | 7 min | 1,461 (391 Devanagari) | Flips language per chunk and drops about half the speech; forcing `en` replaces Hindi with "foreign" |

Turn-by-turn engines (Mix, Apex, Tara) diarize first and transcribe each speaker turn on its own;
timing and speaker labels come from the diarizer. On two-channel recordings your side is cut into
speech runs and labelled You. Chunks that are mostly silence are skipped and overlapping duplicate
turns are removed. A Qwen3-ASR engine was tried and dropped: slow (17 minutes for that meeting) and
removed from FluidAudio upstream.

### Hinglish: Apex and the Mix engine (default)

Apex (a Whisper turbo fine-tune that writes romanized Hinglish) and Tara are downloaded on first use
from their Core ML conversions on Hugging Face ([Apex](https://huggingface.co/jatsharma/whisper-hinglish-apex-coreml),
[Tara](https://huggingface.co/jatsharma/whisper-hinglish-tara-coreml)); `make hinglish-models` rebuilds
them from the original weights. Apex is the only engine that captures Hindi-heavy speech, but it turns English terms and
numbers into Hinglish (a product name spelled as Hindi words, "13 thousand" for "thirteen") and
sometimes drops English sentences. Parakeet keeps English exact but turns Hindi into
English-sounding nonsense. The **Mix** engine reads every speaker turn with Apex and with
Parakeet, and keeps Parakeet's reading only where Apex's has almost no Hindi words and Parakeet's
is almost all dictionary English. On a 31-minute technical meeting in testing, Mix + gemma4:e4b notes covered
about 22 of 33 checked facts with about 3 errors (Apex + qwen3.5:4b: about 13 with 8 errors), and
a 94-second Hindi-heavy call stayed fully correct. Mix is the default when Apex is installed.

Both engines normalise a quiet microphone channel before recognition and suppress the call's echo
in it, so a laptop mic across the desk still yields your lines. The echo gate drops mic audio that is
6 dB or more under the call (including echo arriving up to 60 ms late). It measures how strongly
the call leaks into the mic on each recording; with headphones (no leak) the mic is left alone, so
you talking over the other side is kept.

## Settings

- **Model** – any Ollama tag. `gemma4:e4b` by default on Macs with 16 GB or more (about 6.5 GB of memory while writing), `gemma4:e2b` below that; `qwen3.5:4b` (about 4 GB) got more facts wrong on a 31-minute test meeting; `gemma4:12b` needs about 10 GB.
- **Context window** – the most the app will ask for, 32k tokens by default (roughly 90 minutes of
  speech). Each meeting uses the smallest of 8k/16k/32k that fits it, the same size for every call on
  that meeting: gemma4 is reloaded (about 5 s) whenever the size changes.
- **Notes prompt** – the instructions sent to the model. Placeholders `{{title}}`, `{{date}}`, `{{days}}`,
  `{{glossary}}`. The transcript always goes first, ahead of the instructions; the action-item step
  starts with the same text, so Ollama reuses that work (27 s of prompt processing down to 0.2 s on a
  32-minute meeting).
- **Read the screen** – off by default; turn it on during setup or in Settings → Vocabulary. While
  recording, the screen's text is read every 20 s (only when the screen changed) and its names and
  terms join the glossary. The clean-up pass only sends lines that hold a word sounding like a
  glossary term.
