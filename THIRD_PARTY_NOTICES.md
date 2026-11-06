# Third-party notices

Off the Record is MIT-licensed (see `LICENSE`). It is built on the work below. Libraries are compiled
into the app; models and the Ollama runtime are downloaded on first use from their publishers (or from
the Core ML conversions listed), never bundled in the disk image.

## Libraries in the app

| Project | License | Copyright |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) (vendored, unmodified apart from its traits manifest) | Apache-2.0 | Fluid Inference |
| [WhisperKit / ArgmaxCore](https://github.com/argmaxinc/WhisperKit) | MIT | Copyright (c) 2024 argmax, inc. |
| [swift-transformers](https://github.com/huggingface/swift-transformers) (Hub and Tokenizers, inside ArgmaxCore, modified by Argmax) | Apache-2.0 | Copyright 2022 Hugging Face SAS |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Copyright (C) 2015-2025 Gwendal Roué |

The full Apache-2.0 and MIT license texts ship with each project's source (`Vendor/FluidAudio/LICENSE`,
and the package checkouts Xcode resolves).

## Models downloaded on first use

| Model | Used for | License | Source |
| --- | --- | --- | --- |
| Parakeet TDT 0.6b v3, Core ML conversion by Fluid Inference | English transcription | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) | [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) |
| Speaker diarization (pyannote segmentation and WeSpeaker embeddings; PLDA parameters from BUT Speech@FIT), Core ML conversions by Fluid Inference | Who spoke when | Mixed: CC-BY-4.0 and the upstream licenses listed in the repository's [NOTICE](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md) | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) |
| Silero VAD, Core ML conversion by Fluid Inference | Voice activity | MIT | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml) |
| Apex: Whisper-Hindi2Hinglish-Apex by Oriserve (fine-tune of OpenAI Whisper large-v3-turbo), Core ML conversion | Hinglish transcription | Apache-2.0 | [Oriserve/Whisper-Hindi2Hinglish-Apex](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex), [jatsharma/whisper-hinglish-apex-coreml](https://huggingface.co/jatsharma/whisper-hinglish-apex-coreml) |
| Tara by Trelis (fine-tune of OpenAI Whisper large-v3), Core ML conversion (optional engine) | Hinglish transcription | Apache-2.0 | [Trelis/tara](https://huggingface.co/Trelis/tara), [jatsharma/whisper-hinglish-tara-coreml](https://huggingface.co/jatsharma/whisper-hinglish-tara-coreml) |
| Whisper large-v3-turbo, Core ML by Argmax (optional engine) | Transcription | MIT | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) |
| Gemma 4 (gemma4:e4b or gemma4:e2b) by Google, through Ollama | Writing the notes | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) | [ollama.com/library/gemma4](https://ollama.com/library/gemma4) |

Parakeet, the diarization models and other CC-BY-4.0 works are used as published, converted to Core ML
by their converters; this app does not modify them.

## Software downloaded on first use

| Software | License | Source |
| --- | --- | --- |
| [Ollama](https://github.com/ollama/ollama) (official macOS build, only when Ollama is not already installed; checked against its published SHA-256) | MIT | [GitHub releases](https://github.com/ollama/ollama/releases) |
