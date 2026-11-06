"""
Run Beat This (Foscarin et al. 2024, MIT) on the hand-marked accuracy tracks.

Writes out/beat-this/<checkpoint>.json with each track's beats, downbeats and
per-frame downbeat activation (50 fps), for scripts/beat-this-compare.ts to
score against the marks and Dex's own grids. See scripts/beat-this/README.md.

    .venv/bin/python -I scripts/beat-this/run.py [small0 final0]
"""
import json, pathlib, subprocess, sys, time

import numpy as np
import torch
from beat_this.inference import Audio2Frames
from beat_this.model.postprocessor import Postprocessor

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'out' / 'beat-this'
SR = 22050  # Beat This's own input rate


def decode(path: pathlib.Path) -> np.ndarray:
    raw = subprocess.run(
        ['ffmpeg', '-v', 'error', '-nostdin', '-i', str(path), '-ac', '1', '-ar', str(SR), '-f', 'f32le', '-'],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def main() -> None:
    checkpoints = sys.argv[1:] or ['small0', 'final0']
    manifest = json.loads((ROOT / 'accuracy' / 'manifest.json').read_text())
    tracks = [t for t in manifest['tracks'] if t['truth'].get('downbeatsSec')]
    audio = {t['id']: decode(ROOT / 'accuracy' / t['file']) for t in tracks}
    OUT.mkdir(parents=True, exist_ok=True)
    for checkpoint in checkpoints:
        model = Audio2Frames(checkpoint_path=checkpoint, device='cpu')
        post = Postprocessor(type='minimal')
        result = {}
        for track in tracks:
            signal = audio[track['id']]
            started = time.time()
            beat_logits, downbeat_logits = model(signal, SR)
            beats, downbeats = post(beat_logits, downbeat_logits)
            result[track['id']] = {
                'beats': [float(b) for b in beats],
                'downbeats': [float(d) for d in downbeats],
                'downAct': torch.sigmoid(downbeat_logits).numpy().round(4).tolist(),
                'seconds': time.time() - started,
                'durationSec': len(signal) / SR,
            }
            print(f'{checkpoint} {track["id"][:40]:41} {result[track["id"]]["seconds"]:.1f} s', flush=True)
        (OUT / f'{checkpoint}.json').write_text(json.dumps(result))


if __name__ == '__main__':
    main()
