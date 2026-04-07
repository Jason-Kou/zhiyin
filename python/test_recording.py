#!/usr/bin/env python3
"""Test recording replay — load saved WAV files and run through transcription pipeline.

Usage:
    # List saved recordings
    python test_recording.py --list

    # Replay most recent recording
    python test_recording.py

    # Replay specific file
    python test_recording.py path/to/recording.wav

    # Replay with specific language
    python test_recording.py --language zh

    # Replay with different hallucination thresholds
    python test_recording.py --rms-threshold 0.03 --chars-per-sec 10
"""

import argparse
import glob
import os
import sys
import time

import numpy as np

# Monkey-patch mlx_audio model type detection before any imports
import mlx_audio.stt.utils as utils
original_get = utils.get_model_and_args
def patched_get(model_type, model_name):
    return original_get("funasr", model_name)
utils.get_model_and_args = patched_get

import soundfile as sf
import torch
from silero_vad import load_silero_vad, get_speech_timestamps
from mlx_audio.stt.utils import load_model
from huggingface_hub import snapshot_download

SAMPLE_RATE = 16000
MODEL_REPO = "mlx-community/Fun-ASR-MLT-Nano-2512-8bit"
RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/ZhiYin/recordings")


def list_recordings():
    """List all saved recordings."""
    if not os.path.exists(RECORDINGS_DIR):
        print("No recordings directory found.")
        return []
    wavs = sorted(glob.glob(os.path.join(RECORDINGS_DIR, "*.wav")))
    if not wavs:
        print("No recordings found.")
        return []
    print(f"Found {len(wavs)} recording(s):\n")
    for i, path in enumerate(wavs):
        info = sf.info(path)
        print(f"  [{i}] {os.path.basename(path)}  ({info.duration:.1f}s)")
    return wavs


def audio_rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(audio ** 2)))


def run_vad(vad_model, audio: np.ndarray, min_speech_ms=250, min_silence_ms=500, speech_pad_ms=100):
    wav_tensor = torch.from_numpy(audio).float()
    timestamps = get_speech_timestamps(
        wav_tensor,
        vad_model,
        sampling_rate=SAMPLE_RATE,
        min_speech_duration_ms=min_speech_ms,
        min_silence_duration_ms=min_silence_ms,
        speech_pad_ms=speech_pad_ms,
        return_seconds=False,
    )
    return timestamps


def replay_recording(wav_path: str, language: str = "auto", rms_threshold: float = 0.02,
                     chars_per_sec: float = 12, initial_prompt: str = None, verbose: bool = True):
    """Load a WAV file and run the full VAD + transcription pipeline."""
    print(f"\n{'='*60}")
    print(f"Replaying: {os.path.basename(wav_path)}")
    print(f"Language: {language}  |  RMS threshold: {rms_threshold}  |  Max chars/sec: {chars_per_sec}")
    print(f"{'='*60}\n")

    # Load audio
    audio, sr = sf.read(wav_path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        # Simple resample via interpolation
        import scipy.signal
        audio = scipy.signal.resample(audio, int(len(audio) * SAMPLE_RATE / sr))
    duration = len(audio) / SAMPLE_RATE
    rms = audio_rms(audio)
    print(f"Audio: {duration:.2f}s, RMS={rms:.4f}, samples={len(audio)}")

    # Load models
    print("\nLoading models...")
    vad_model = load_silero_vad()
    model_path = snapshot_download(MODEL_REPO)
    asr_model = load_model(model_path)
    asr_model.generate(np.zeros(16000, dtype=np.float32))  # warmup
    print("Models ready.\n")

    # Run VAD
    print("--- VAD Analysis ---")
    timestamps = run_vad(vad_model, audio)
    print(f"VAD found {len(timestamps)} speech segment(s):\n")

    for i, ts in enumerate(timestamps):
        seg_start = ts["start"]
        seg_end = ts["end"]
        seg_dur = (seg_end - seg_start) / SAMPLE_RATE
        seg_audio = audio[seg_start:seg_end]
        seg_rms = audio_rms(seg_audio)
        print(f"  Segment {i}: {seg_start/SAMPLE_RATE:.2f}s - {seg_end/SAMPLE_RATE:.2f}s "
              f"({seg_dur:.2f}s, RMS={seg_rms:.4f})")

    # Transcribe each segment
    print(f"\n--- Transcription (language={language}) ---\n")
    import re

    def clean_text(text):
        text = re.sub(r'\[[^\]]*\]', '', text)
        text = re.sub(r'\(\(\)\)', '', text)
        text = re.sub(r'(.{1,30}?)\s*[/，,。\s]*\s*(\1\s*[/，,。\s]*\s*){3,}', r'\1', text)
        return text.strip()

    all_texts = []
    for i, ts in enumerate(timestamps):
        seg_start = ts["start"]
        seg_end = ts["end"]
        seg_audio = audio[seg_start:seg_end]
        seg_dur = (seg_end - seg_start) / SAMPLE_RATE
        seg_rms = audio_rms(seg_audio)

        # Pre-checks
        if len(seg_audio) < 1600:
            print(f"  Segment {i}: SKIPPED (too short, {len(seg_audio)} samples)")
            continue
        if seg_rms < 0.005:
            print(f"  Segment {i}: SKIPPED (too quiet, RMS={seg_rms:.4f})")
            continue

        max_tokens = max(10, int(seg_dur * 6))
        t0 = time.time()
        result = asr_model.generate(seg_audio, language=language, initial_prompt=initial_prompt, max_tokens=max_tokens)
        elapsed = time.time() - t0
        raw_text = result.text
        text = clean_text(raw_text)

        # Hallucination checks
        is_hallucinated = False
        reason = ""
        if text:
            if seg_rms < rms_threshold:
                is_hallucinated = True
                reason = f"RMS {seg_rms:.4f} < {rms_threshold}"
            elif seg_dur < 0.8 and seg_rms < 0.05:
                is_hallucinated = True
                reason = f"short+quiet ({seg_dur:.2f}s, RMS={seg_rms:.4f})"
            elif seg_dur > 0 and len(text) / seg_dur > chars_per_sec:
                is_hallucinated = True
                reason = f"chars/sec={len(text)/seg_dur:.1f} > {chars_per_sec}"

        status = "HALLUCINATION" if is_hallucinated else "OK"
        print(f"  Segment {i}: [{status}] \"{text}\"")
        if verbose:
            print(f"    raw: \"{raw_text}\"")
            print(f"    dur={seg_dur:.2f}s  RMS={seg_rms:.4f}  tokens={max_tokens}  time={elapsed:.2f}s")
            if is_hallucinated:
                print(f"    reason: {reason}")
        print()

        if not is_hallucinated and text:
            all_texts.append(text)

    final_text = " ".join(all_texts)
    print(f"--- Final Output ---")
    print(f"\"{final_text}\"\n")
    return final_text


def main():
    parser = argparse.ArgumentParser(description="Replay saved recordings through STT pipeline")
    parser.add_argument("wav_path", nargs="?", help="Path to WAV file (default: most recent)")
    parser.add_argument("--list", action="store_true", help="List saved recordings")
    parser.add_argument("--language", default="auto", help="Language code (default: auto)")
    parser.add_argument("--rms-threshold", type=float, default=0.02, help="RMS threshold for hallucination (default: 0.02)")
    parser.add_argument("--chars-per-sec", type=float, default=12, help="Max chars/sec before hallucination flag (default: 12)")
    parser.add_argument("--initial-prompt", default=None, help="Initial prompt for vocabulary biasing")
    parser.add_argument("--quiet", action="store_true", help="Less verbose output")
    args = parser.parse_args()

    if args.list:
        list_recordings()
        return

    wav_path = args.wav_path
    if wav_path is None:
        # Use most recent recording
        wavs = sorted(glob.glob(os.path.join(RECORDINGS_DIR, "*.wav")))
        if not wavs:
            print("No recordings found. Record something first, then replay.")
            sys.exit(1)
        wav_path = wavs[-1]
        print(f"Using most recent: {os.path.basename(wav_path)}")

    if not os.path.exists(wav_path):
        print(f"File not found: {wav_path}")
        sys.exit(1)

    replay_recording(
        wav_path,
        language=args.language,
        rms_threshold=args.rms_threshold,
        chars_per_sec=args.chars_per_sec,
        initial_prompt=args.initial_prompt,
        verbose=not args.quiet,
    )


if __name__ == "__main__":
    main()
