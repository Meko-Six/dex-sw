# Beat This: the ML second opinion

[Beat This](https://github.com/CPJKU/beat_this) (Foscarin, Schlüter, Widmer,
ISMIR 2024; MIT code and weights) is the strongest beat and downbeat tracker
licensed for shipping. These scripts run it on the hand-marked accuracy tracks
and score it against the marks and Dex's own grid. Nothing here is in the app.

## Setup (once per machine)

The system Python may be too new for PyTorch, so the environment pins 3.12.
Keep it outside the repo (it is ~1 GB):

```bash
brew install uv
uv venv --python 3.12 ~/.venvs/beat-this
uv pip install --python ~/.venvs/beat-this/bin/python torch numpy einops rotary-embedding-torch soxr soundfile tqdm onnx onnxruntime onnxscript "beat_this @ https://github.com/CPJKU/beat_this/archive/main.zip"
```

The first run downloads the checkpoints into `~/.cache/torch/hub/checkpoints/`
from the authors' server (cloud.cp.jku.at): `small0` is 8.5 MB, `final0` 81 MB.

## Running it

```bash
~/.venvs/beat-this/bin/python -I scripts/beat-this/run.py          # both checkpoints → out/beat-this/
npm run accuracy:beat-this                                         # score them
~/.venvs/beat-this/bin/python -I scripts/beat-this/export_onnx.py small0 accuracy/audio/Techno/8757915_Traffic_Original_Mix.mp3
```

## What it showed (2026-10-29, 11 marked tracks)

| | Dex (classical) | Beat This small0 | Beat This final0 |
| --- | --- | --- | --- |
| Tempo right | 11 / 11 | 11 / 11 | 11 / 11 |
| Fitted grid within 15 ms | **11 / 11** (worst 2.6 ms) | 1 / 11 (worst 41 ms) | 6 / 11 (worst 40 ms) |
| Bar 1 right | **11 / 11** | 9 / 11 | 8 / 11 |
| Time per 7-minute track | **~0.6 s** | 1.9 s (PyTorch) | 2.6 s (PyTorch) |

- Its beats are framed at 50 fps (20 ms), so its timing can't match the
  kick-attack refinement. Dex's grid stays the product either way.
- Its bar-1 misses are mostly half a bar out (beat 3 for beat 1) on techno.
- What it is good for is an independent tempo reading: it was never fooled
  by the 3:2 lock on Traffic, which the old comb fit fell for.

## In the app, if it is ever wanted

`export_onnx.py` turns a checkpoint into ONNX. The small model is 10 MB and
matches PyTorch to 1e-4 in the logits. Under `onnxruntime-node` 1.22 it takes
~430 ms per 30 s chunk, about 6 s for a seven-minute track. The runtime's macOS
arm64 binary is 33 MB. Shipping it would still need two things:

- the log-mel front end in TypeScript: 22.05 kHz, n_fft 1024, hop 441,
  128 mel bands from 30 Hz to 11 kHz, `log1p(1000·x)`, checked against
  `beat_this.preprocessing.LogMelSpect`;
- a reason, such as a track Dex flags `uncertain` where the ML tempo settles it.
  None of the 52 tracks is flagged today.
