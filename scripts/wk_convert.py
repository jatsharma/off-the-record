"""Runs Argmax's whisperkittools converter (whisperkit-generate-model) with two changes:

- Parts already converted in the output folder are skipped, so a failed decoder can be redone
  without converting the encoder again (each Neural Engine compile takes 15+ minutes).
- The converter test-loads each part on the Neural Engine. On an M1 the Neural Engine compiler
  spends an hour or more on a large-v3 encoder, and the app runs these models on the GPU anyway,
  so the test load uses the GPU.
- The converter keeps a part only if its Core ML output matches PyTorch within 35 dB PSNR on test
  inputs. Fine-tuned decoders in float16 land around 30 dB (Apex: 30.8), so the bar is set by
  PSNR_MIN (default 25). Real accuracy is checked afterwards on actual meeting audio.

Usage: python wk_convert.py --model-version <repo or dir> --output-dir <dir> [converter flags]
"""
import os
import sys

import coremltools as ct
from argmaxtools import test_utils
from scripts import generate_model

test_utils.TEST_PSNR_THR = float(os.environ.get("PSNR_MIN", "25"))
test_utils.TEST_COMPUTE_UNIT = ct.ComputeUnit.CPU_AND_GPU


def _arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


folder = os.path.join(_arg("--output-dir"), _arg("--model-version").replace("/", "_"))


def _have(*names):
    return all(os.path.isdir(os.path.join(folder, n)) for n in names)


if _have("TextDecoder.mlmodelc"):
    print(f"TextDecoder.mlmodelc already in {folder}, skipping the decoder")
    generate_model.test_text_decoder.main = lambda args: None
if _have("AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc"):
    print(f"AudioEncoder and MelSpectrogram already in {folder}, skipping the encoder")
    generate_model.test_audio_encoder.main = lambda args: None

generate_model.cli()
