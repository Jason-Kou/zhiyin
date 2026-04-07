#!/usr/bin/env python3
"""Test streaming transcription pipeline with recorded audio files.

Usage:
    python test_streaming.py [WAV_FILE]

If no WAV_FILE is given, uses the most recent recording from
~/Library/Application Support/ZhiYin/recordings/.

Tests:
1. Full-file transcription (baseline)
2. Streaming simulation (chunked upload + finalize)
3. Hallucination detection unit tests

Requires: server running on port 17760
"""

import os
import sys
import glob
import time
import json
import requests
import numpy as np
import soundfile as sf

BASE = "http://127.0.0.1:17760"
RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/ZhiYin/recordings")


def find_latest_recording():
    """Find the most recent WAV file."""
    files = glob.glob(os.path.join(RECORDINGS_DIR, "*.wav"))
    if not files:
        print("No recordings found.")
        sys.exit(1)
    return max(files, key=os.path.getmtime)


def test_full_file(wav_path):
    """Test 1: Upload full WAV to /transcribe (bypasses streaming/VAD)."""
    print("=" * 60)
    print("TEST 1: Full-file transcription (baseline)")
    print("=" * 60)
    r = requests.post(f"{BASE}/transcribe", files={"file": open(wav_path, "rb")})
    result = r.json()
    print(f"  Text: {result.get('text', 'EMPTY')}")
    print(f"  Time: {result.get('time', 0):.2f}s")
    return result.get("text", "")


def test_streaming(wav_path):
    """Test 2: Simulate streaming (chunked upload + VAD + finalize)."""
    print()
    print("=" * 60)
    print("TEST 2: Streaming simulation (chunked + finalize)")
    print("=" * 60)
    audio, sr = sf.read(wav_path, dtype="float32")
    print(f"  Audio: {len(audio)/sr:.1f}s, {sr}Hz")

    # Start session
    r = requests.post(f"{BASE}/stream/start")
    sid = r.json()["session_id"]
    print(f"  Session: {sid}")

    # Send 0.2s chunks (matches Swift app behavior)
    chunk_size = int(sr * 0.2)
    for i in range(0, len(audio), chunk_size):
        chunk = audio[i:i + chunk_size]
        requests.post(
            f"{BASE}/stream/chunk/{sid}",
            data=chunk.tobytes(),
            headers={"Content-Type": "application/octet-stream"},
        )
        time.sleep(0.05)

    # Wait for streaming VAD to finish processing
    time.sleep(3)

    # Check state before finalize
    r = requests.get(f"{BASE}/stream/poll/{sid}")
    poll = r.json()
    print(f"  Before finalize: {poll.get('segments')} segments")
    print(f"    Text: {poll.get('text', '')}")

    # Finalize
    r = requests.post(f"{BASE}/stream/finalize/{sid}")
    result = r.json()
    print(f"  After finalize:")
    print(f"    Text: {result.get('text', 'EMPTY')}")
    if "_debug" in result:
        d = result["_debug"]
        print(f"    Debug: transcribed_end={d.get('already_transcribed_end')}, "
              f"vad_segs={d.get('vad_segments')}, "
              f"vad_end={d.get('vad_covered_end')}, "
              f"new={d.get('remaining_new')}")
    return result.get("text", "")


def test_hallucination_detection():
    """Test 3: Unit tests for hallucination detection functions."""
    print()
    print("=" * 60)
    print("TEST 3: Hallucination detection")
    print("=" * 60)

    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    import importlib
    import stt_server
    importlib.reload(stt_server)
    from stt_server import _has_repetition, _is_known_hallucination

    repetition_cases = [
        ("thank you thank you thank you", True),
        ("谢谢谢谢谢谢", True),
        ("好的好的好的", True),
        ("ha ha ha ha ha ha", True),
        ("the the the quick brown fox", True),
        ("subscribe subscribe subscribe", True),
        ("I like this", False),
        ("It's really good. I like this.", False),
        ("好，现在我把繁体的功能打开了", False),
        ("Hello, how are you today?", False),
    ]

    known_cases = [
        ("谢谢观看", True),
        ("Thank you for watching", True),
        ("subscribe", True),
        ("hello world", False),
        ("I like this product", False),
    ]

    all_pass = True
    for text, expected in repetition_cases:
        result = _has_repetition(text)
        ok = result == expected
        if not ok:
            all_pass = False
        print(f"  {'✓' if ok else '✗'} repetition('{text}') = {result}")

    for text, expected in known_cases:
        result = _is_known_hallucination(text)
        ok = result == expected
        if not ok:
            all_pass = False
        print(f"  {'✓' if ok else '✗'} known('{text}') = {result}")

    return all_pass


def compare_results(full_text, streaming_text):
    """Compare full-file vs streaming results."""
    print()
    print("=" * 60)
    print("COMPARISON")
    print("=" * 60)

    # Find words in full that are missing from streaming
    full_words = set(full_text.lower().split())
    stream_words = set(streaming_text.lower().split())
    missing = full_words - stream_words

    if not missing:
        print("  ✓ Streaming captured all content from full-file transcription")
    else:
        print(f"  ✗ Missing from streaming: {missing}")

    return len(missing) == 0


if __name__ == "__main__":
    # Check server is running
    try:
        r = requests.get(f"{BASE}/health", timeout=2)
        if r.status_code != 200:
            print("Server not healthy")
            sys.exit(1)
    except requests.ConnectionError:
        print(f"Server not running at {BASE}")
        sys.exit(1)

    # Get WAV file
    wav_path = sys.argv[1] if len(sys.argv) > 1 else find_latest_recording()
    print(f"Testing with: {wav_path}")
    print()

    # Run tests
    full_text = test_full_file(wav_path)
    streaming_text = test_streaming(wav_path)
    hallucination_ok = test_hallucination_detection()
    comparison_ok = compare_results(full_text, streaming_text)

    # Summary
    print()
    print("=" * 60)
    results = {
        "Full-file transcription": bool(full_text),
        "Streaming transcription": bool(streaming_text),
        "Hallucination detection": hallucination_ok,
        "Streaming matches full": comparison_ok,
    }
    all_pass = all(results.values())
    for name, passed in results.items():
        print(f"  {'✓' if passed else '✗'} {name}")
    print()
    print(f"{'All tests passed!' if all_pass else 'Some tests FAILED'}")
    sys.exit(0 if all_pass else 1)
