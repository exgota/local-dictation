"""Single-file Bark 3.0 Pro inference; no training or benchmark dependencies."""
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audio', type=Path)
    parser.add_argument('--model', default='ConwayResearch/Underdog-Bark-3.0-Pro')
    parser.add_argument('--revision', default='main')
    parser.add_argument('--device', choices=['cuda', 'mps', 'cpu'], default='cuda')
    parser.add_argument('--dtype', choices=['bfloat16', 'float16', 'float32'], default='bfloat16')
    args = parser.parse_args()
    if not args.audio.is_file():
        parser.error(f'Audio file not found: {args.audio}')

    import numpy as np
    import soundfile as sf
    import soxr
    import torch
    from transformers import AutoProcessor, ParakeetForTDT

    if args.device == 'cuda':
        if not torch.cuda.is_available():
            parser.error('CUDA unavailable. Install a CUDA-enabled PyTorch and compatible NVIDIA driver, or explicitly use --device cpu --dtype float32.')
        if args.dtype == 'bfloat16' and not torch.cuda.is_bf16_supported():
            parser.error('This GPU does not support BF16. Try --dtype float16; accuracy for this setting must be validated separately.')
    if args.device == 'mps' and not torch.backends.mps.is_available():
        parser.error('MPS is unavailable on this machine.')
    if args.device == 'cpu' and args.dtype != 'float32':
        parser.error('Use --dtype float32 for the CPU fallback.')

    source = Path(args.model)
    kwargs = {'local_files_only': True} if source.is_dir() else {'revision': args.revision}
    dtype = getattr(torch, args.dtype)
    processor = AutoProcessor.from_pretrained(args.model, **kwargs)
    model = ParakeetForTDT.from_pretrained(args.model, dtype=dtype, **kwargs).to(args.device).eval()
    wave, sr = sf.read(args.audio, dtype='float32', always_2d=True)
    wave = wave.mean(axis=1)
    if not len(wave):
        parser.error('Audio is empty.')
    if sr != 16000:
        wave = soxr.resample(wave, sr, 16000)
    wave = np.concatenate([np.zeros(4000, np.float32), wave])
    inputs = processor(wave, sampling_rate=16000, return_tensors='pt').to(args.device, dtype)
    with torch.inference_mode():
        output = model.generate(**inputs)
    ids = output.sequences if hasattr(output, 'sequences') else output
    print(processor.batch_decode(ids, skip_special_tokens=True)[0])


if __name__ == '__main__':
    main()
