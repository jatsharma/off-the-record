#!/bin/bash
# Converts the two Hinglish Whisper fine-tunes to WhisperKit's Core ML format and installs them
# where the app looks for them (~/Library/Application Support/Notes/Models/hinglish/{tara,apex}).
#
#   Tara  Trelis/tara                          Whisper large-v3, mixed-script Hinglish (Apache-2.0)
#   Apex  Oriserve/Whisper-Hindi2Hinglish-Apex Whisper large-v3-turbo, romanized Hinglish (Apache-2.0)
#
# Uses Argmax's whisperkittools (the converter behind WhisperKit's own models), pinned to a commit,
# in a throwaway Python environment, through scripts/wk_convert.py. Downloads about 4.7 GB of weights from Hugging Face on the
# first run (cached in ~/.cache/huggingface), needs about 10 GB of free memory and takes 20-60
# minutes per model.
# Nothing is uploaded. Usage: scripts/convert-hinglish.sh [tara|apex|all]
set -euo pipefail

WHICH="${1:-all}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
WKT_COMMIT=84f77a83c8f530022ae55fbb1a64b3351ef63c7a
WORK="${HINGLISH_WORK:-$HOME/Library/Caches/notes-hinglish-convert}"
DEST="$HOME/Library/Application Support/Notes/Models/hinglish"
TURBO_HEADS='[[2,4],[2,11],[3,3],[3,6],[3,11],[3,14]]'   # openai/whisper-large-v3-turbo

command -v uv >/dev/null || { echo "Needs uv (brew install uv)"; exit 1; }
mkdir -p "$WORK" "$DEST"

if [ ! -x "$WORK/venv/bin/whisperkit-generate-model" ]; then
  echo "== Setting up whisperkittools ($WKT_COMMIT)"
  uv venv -q --python 3.11 "$WORK/venv"
  uv pip install -q --python "$WORK/venv/bin/python" \
    "whisperkit @ git+https://github.com/argmaxinc/whisperkittools@$WKT_COMMIT"
fi

convert() {   # name hf-repo [alignment-heads-json]
  local name="$1" repo="$2" heads="${3:-}"
  local out="$WORK/out" source="$repo"
  local snapshot
  snapshot="$("$WORK/venv/bin/python" -c "from huggingface_hub import snapshot_download as s; print(s('$repo'))")"
  if [ -n "$heads" ]; then
    # The converter builds a word-alignment output and needs alignment heads; Apex ships none,
    # so give it the ones of the model it was fine-tuned from (Whisper large-v3-turbo).
    source="$WORK/src-$name"
    rm -rf "$source" && mkdir -p "$source"
    for f in "$snapshot"/*; do ln -s "$f" "$source/"; done
    rm "$source/generation_config.json"
    "$WORK/venv/bin/python" -c "
import json, sys
d = json.load(open('$snapshot/generation_config.json')); d['alignment_heads'] = json.loads('$heads')
json.dump(d, open('$source/generation_config.json', 'w'), indent=2)"
  fi
  local folder="$out/${source//\//_}"
  echo "== Converting $repo"
  # The converter's "tests" are what build and check the encoder and decoder. wk_convert.py runs
  # them on the GPU, with a 25 dB accuracy bar, skipping parts already converted (see its notes).
  # 224 tokens is all WhisperKit decodes per window.
  (cd "$WORK" && "$WORK/venv/bin/python" "$SCRIPTS/wk_convert.py" --model-version "$source" \
     --output-dir "$out" --text-decoder-max-sequence-length 224)
  for m in AudioEncoder TextDecoder MelSpectrogram; do
    [ -d "$folder/$m.mlmodelc" ] || { echo "Missing $m.mlmodelc in $folder"; exit 1; }
  done
  # The tokenizer ships with the model: Tara's adds <|mixedcode|> and pads the vocabulary.
  rm -rf "$DEST/$name.tmp" && mkdir -p "$DEST/$name.tmp"
  cp -R "$folder"/*.mlmodelc "$DEST/$name.tmp/"
  for f in tokenizer.json tokenizer_config.json special_tokens_map.json added_tokens.json vocab.json merges.txt \
           normalizer.json config.json generation_config.json preprocessor_config.json; do
    [ -f "$snapshot/$f" ] && cp "$snapshot/$f" "$DEST/$name.tmp/"
  done
  rm -rf "$DEST/$name" && mv "$DEST/$name.tmp" "$DEST/$name"
  echo "== Installed $name: $(du -sh "$DEST/$name" | cut -f1) in $DEST/$name"
}

case "$WHICH" in
  tara) convert tara Trelis/tara ;;
  apex) convert apex Oriserve/Whisper-Hindi2Hinglish-Apex "$TURBO_HEADS" ;;
  all)  convert tara Trelis/tara; convert apex Oriserve/Whisper-Hindi2Hinglish-Apex "$TURBO_HEADS" ;;
  *) echo "Usage: $0 [tara|apex|all]"; exit 1 ;;
esac
echo "Done. Pick Tara or Apex in Settings ▸ General ▸ Speech recognition."
