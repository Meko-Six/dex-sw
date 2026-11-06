"""
Export a Beat This checkpoint to ONNX and check it against PyTorch.

The model takes a (1, frames, 128) log-mel spectrogram at 50 fps and returns
beat and downbeat logits per frame. Run it in 1500-frame (30 s) chunks, as
Beat This's own split_predict_aggregate does.

    .venv/bin/python -I scripts/beat-this/export_onnx.py small0 [path/to/track.mp3]
"""
import pathlib, subprocess, sys, time

import numpy as np
import onnxruntime as ort
import torch
from beat_this.inference import load_model
from beat_this.preprocessing import LogMelSpect

ROOT = pathlib.Path(__file__).resolve().parents[2]


class Logits(torch.nn.Module):
    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, spect: torch.Tensor):
        out = self.model(spect)
        return out['beat'], out['downbeat']


def main() -> None:
    checkpoint = sys.argv[1] if len(sys.argv) > 1 else 'small0'
    wrapped = Logits(load_model(checkpoint, 'cpu')).eval()
    path = ROOT / 'out' / 'beat-this' / f'beat_this_{checkpoint}.onnx'
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        wrapped, (torch.randn(1, 1500, 128),), str(path),
        input_names=['spect'], output_names=['beat', 'downbeat'],
        dynamic_axes={'spect': {1: 'frames'}, 'beat': {1: 'frames'}, 'downbeat': {1: 'frames'}},
        opset_version=17, dynamo=False,
    )
    print(f'exported {path} ({path.stat().st_size // 1024} KB)')

    if len(sys.argv) > 2:
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', sys.argv[2], '-ac', '1', '-ar', '22050', '-t', '30', '-f', 'f32le', '-'],
                             check=True, capture_output=True).stdout
        signal = torch.tensor(np.frombuffer(raw, dtype=np.float32).copy())
    else:
        signal = torch.randn(22050 * 30) * 0.1
    spect = LogMelSpect()(signal).unsqueeze(0)
    with torch.inference_mode():
        reference = wrapped(spect)
    session = ort.InferenceSession(str(path))
    started = time.time()
    got = session.run(None, {'spect': spect.numpy()})
    print(f'onnxruntime: {1000 * (time.time() - started):.0f} ms for a 30 s chunk')
    for name, a, b in zip(['beat', 'downbeat'], reference, got):
        print(f'{name}: max |logit difference| vs PyTorch {float(np.abs(a.numpy() - b).max()):.1e}')


if __name__ == '__main__':
    main()
