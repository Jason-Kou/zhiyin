#!/usr/bin/env python3
"""ZhiYin STT Server - FunASR MLX + Silero VAD.

Architecture:
- Client sends audio chunks incrementally during recording
- Server runs Silero VAD to detect sentence boundaries (speech end)
- When a sentence ends → transcribe that segment → append to results
- Client polls for newly transcribed text
- On finalize → transcribe any remaining speech → return full text
"""

import asyncio
import re
import time
import uuid
import threading
import concurrent.futures
from typing import Optional

# Monkey-patch mlx_audio model type detection before any imports
import mlx_audio.stt.utils as utils
original_get = utils.get_model_and_args
def patched_get(model_type, model_name):
    return original_get("funasr", model_name)
utils.get_model_and_args = patched_get

# Patch supported languages to include Cantonese
from mlx_audio.stt.models.funasr import funasr as _funasr_mod
_funasr_mod.SUPPORTED_LANGUAGES["yue"] = "Cantonese"

import numpy as np
import torch
from silero_vad import load_silero_vad, get_speech_timestamps
from fastapi import FastAPI, UploadFile, File, Request
from fastapi.responses import JSONResponse
from mlx_audio.stt.utils import load_model
from huggingface_hub import snapshot_download
import uvicorn
import tempfile
import os
import json
import soundfile as sf

import opencc

# Whisper MLX — optional, graceful degradation if not installed
try:
    import mlx_whisper
except ImportError:
    mlx_whisper = None

app = FastAPI(title="ZhiYin STT Server")
asr_model = None
vad_model = None
initial_prompt: str | None = None
asr_language: str = "auto"
s2t_converter: opencc.OpenCC | None = None  # lazy-init on first use
output_traditional: bool = False

SAMPLE_RATE = 16000
SESSION_TIMEOUT = 600  # 10 min auto-cleanup (doubled from 5 min to prevent session expiry during finalization after max-duration recording)

# Single-thread executor for CPU-bound VAD + transcription work.
# Ensures only one transcription runs at a time (MLX is not thread-safe)
# while keeping the FastAPI event loop unblocked.
_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)


def _get_executor() -> concurrent.futures.ThreadPoolExecutor:
    """Return the executor, rebuilding it if its thread has died."""
    global _executor
    threads = _executor._threads
    if threads and all(not t.is_alive() for t in threads):
        print("[WARN] Executor thread died — rebuilding")
        _executor.shutdown(wait=False)
        _executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    return _executor


# --- Session state ---
sessions: dict[str, dict] = {}
sessions_lock = threading.Lock()

# Background transcription thread
transcribe_queue: list[tuple[str, np.ndarray]] = []
transcribe_lock = threading.Lock()

MODEL_REPO = "mlx-community/Fun-ASR-MLT-Nano-2512-8bit"
WHISPER_MODEL_REPO = "mlx-community/whisper-large-v3-turbo-q4"
stt_engine: str = "funasr"  # "funasr" | "whisper"

# --- Model registry & download state ---
MODEL_REGISTRY = {
    "funasr":     {"repo_id": MODEL_REPO, "display_name": "FunASR", "approx_size_mb": 1490},
    "whisper":    {"repo_id": WHISPER_MODEL_REPO, "display_name": "Whisper Q4", "approx_size_mb": 442},
}
_download_lock = threading.Lock()
_download_progress: dict = {}  # repo_id -> {status, progress, error}


def clean_text(text: str) -> str:
    """Remove FunASR special tokens, repetition loops, and standalone fillers."""
    text = re.sub(r'\[[^\]]*\]', '', text)
    text = re.sub(r'\(\(\)\)', '', text)
    text = re.sub(r'\s*/sil\s*', ' ', text)  # Remove /sil silence markers
    text = remove_repetition_loops(text)
    text = remove_filler_words(text)
    return text.strip()


def remove_repetition_loops(text: str) -> str:
    """Detect and collapse LLM repetition loops like 'Create Create Create...'."""
    # Match any token (word or punctuated phrase) repeated 4+ times
    # Handles: "Create" / "Create" / ... and 你好你好你好...
    # Pattern: a chunk of 1-30 chars (with optional separator) repeated 4+ times
    text = re.sub(r'(.{1,30}?)\s*[/，,。\s]*\s*(\1\s*[/，,。\s]*\s*){3,}', r'\1', text)
    return text


# Filler word removal — conservative "standalone only" matching.
#
# Removes 呃/嗯/啊/哦/诶/额 and uh/um/er/erm when they appear as isolated
# tokens — i.e. surrounded by punctuation, whitespace, or string boundaries.
# Does NOT touch fillers embedded in adjacent Chinese characters:
#   - "呃有个问题" → preserved (呃 followed by 有, not a boundary)
#   - "功能啊，" → preserved (啊 preceded by 能, not a boundary)
#   - "你好啊" → preserved (啊 preceded by 好, not a boundary)
#   - "，呃，" → removed
#   - "嗯。" → removed
#   - "uh, hello" → "hello"
_FILLER_BOUNDARY = (
    "，。！？、；：（）《》【】"   # Chinese punctuation
    "\"'“”‘’"                      # ASCII + curly quotes
    ",.!?:;()\\-—…"                # English punctuation (hyphen escaped)
    r"\s"                           # whitespace
)
_ZH_FILLER_PATTERN = re.compile(
    r'(^|[' + _FILLER_BOUNDARY + r'])[呃嗯啊哦诶额]+(?=[' + _FILLER_BOUNDARY + r']|$)'
)
_EN_FILLER_PATTERN = re.compile(
    r'\b(?:uh+|um+|er+|erm+)\b[,.!?]?',
    re.IGNORECASE,
)
_FILLER_WS_CLEANUP = re.compile(r'\s+')
_FILLER_DUP_PUNCT = re.compile(r'([，。！？、；：,.!?:;])\1+')
# Drop weak punctuation (comma-class) immediately followed by any stronger
# punctuation left behind after filler removal — e.g. "王总，。" → "王总。",
# "王总，；好的" → "王总；好的".
_FILLER_WEAK_BEFORE_STRONG = re.compile(r'[，、,]+(?=[。！？；：.!?:;])')
_FILLER_LEADING_WEAK = re.compile(r'^[，、；：,:;\s]+')
_FILLER_TRAILING_WEAK = re.compile(r'[，、；：,:;\s]+$')
_FILLER_ALL_PUNCT = re.compile(r'[\s，。！？、；：（）《》【】"\'“”‘’(),.!?:;\-—…]*$')


def remove_filler_words(text: str) -> str:
    """Remove standalone filler words (呃嗯啊哦诶额 / uh um er erm).

    Conservative: only matches fillers surrounded by punctuation, whitespace,
    or string boundaries. Never touches fillers embedded in adjacent Chinese
    characters. See comment block above for examples.
    """
    if not text:
        return text
    # Chinese: preserve the leading boundary char (keep the comma before etc.)
    text = _ZH_FILLER_PATTERN.sub(lambda m: m.group(1), text)
    # English: use word boundaries; drop filler + optional trailing punct
    text = _EN_FILLER_PATTERN.sub('', text)
    # Collapse doubled whitespace and doubled consecutive punctuation
    text = _FILLER_WS_CLEANUP.sub(' ', text)
    text = _FILLER_DUP_PUNCT.sub(r'\1', text)
    # Drop orphan weak punctuation left immediately before a stronger one
    text = _FILLER_WEAK_BEFORE_STRONG.sub('', text)
    # Strip leading/trailing WEAK punctuation (commas, semicolons) left behind;
    # keep strong terminators (periods, ?, !)
    text = _FILLER_LEADING_WEAK.sub('', text)
    text = _FILLER_TRAILING_WEAK.sub('', text)
    # If only punctuation/whitespace remains (filler-only input), return empty
    if _FILLER_ALL_PUNCT.fullmatch(text):
        return ""
    return text


# Punctuation set used when joining per-group transcription outputs.
_JOIN_BOUNDARY_PUNCT = set("，。！？、；：,.!?:;")


def join_group_texts(texts: list) -> str:
    """Concatenate per-group transcription outputs, inserting '，' at group
    boundaries when neither side has punctuation.

    Rationale: VAD groups split audio at silence gaps that don't always
    correspond to natural sentence boundaries. FunASR often leaves a group's
    output without a trailing punctuation mark when the audio ends
    mid-clause. A naive ''.join(texts) smashes adjacent groups together
    (e.g. "我加了显示" + "加了标点符号" → "我加了显示加了标点符号").

    This helper inserts a comma ONLY when both sides of the join are punct-
    less, preserving any existing punctuation.
    """
    if not texts:
        return ""
    joined = ""
    for t in texts:
        t = t.strip() if t else ""
        if not t:
            continue
        if joined and joined[-1] not in _JOIN_BOUNDARY_PUNCT and t[0] not in _JOIN_BOUNDARY_PUNCT:
            joined += "，"
        joined += t
    return joined


def load_initial_prompt() -> str | None:
    """Load personal dictionary and build an initial_prompt for vocabulary biasing.

    IMPORTANT: do NOT prefix the vocab list with an English meta-label like
    "Vocabulary:". When combined with the Chinese language hint and a trailing
    Chinese context sentence in _transcribe_funasr, that English label primes
    FunASR's autoregressive decoder into English/translation mode and causes
    it to emit translated or meta-labeled output instead of transcribing the
    actual audio. Use a language-neutral `、` (Chinese enumeration comma)
    separator — the words themselves provide all the biasing the model needs.
    """
    dict_path = os.path.expanduser("~/Library/Application Support/ZhiYin/dictionary.json")
    if not os.path.exists(dict_path):
        return None
    try:
        with open(dict_path) as f:
            entries = json.load(f)
        words = [e["replacement"] for e in entries if e.get("replacement")]
        if not words:
            return None
        prompt = "、".join(words)
        print(f"Loaded initial_prompt: {prompt}")
        return prompt
    except Exception as e:
        print(f"Warning: failed to load dictionary: {e}")
        return None


def _load_language_setting() -> str:
    """Read language preference from UserDefaults via plist."""
    try:
        import subprocess
        result = subprocess.run(
            ["defaults", "read", "com.zhiyin.app", "recognitionLanguage"],
            capture_output=True, text=True, timeout=2
        )
        lang = result.stdout.strip()
        if lang and lang in ("auto", "zh", "yue", "en", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "th", "vi"):
            print(f"Language setting: {lang}")
            return lang
    except Exception:
        pass
    return "auto"


def _load_traditional_setting() -> bool:
    """Read traditional Chinese output preference from UserDefaults."""
    try:
        import subprocess
        result = subprocess.run(
            ["defaults", "read", "com.zhiyin.app", "outputTraditionalChinese"],
            capture_output=True, text=True, timeout=2
        )
        val = result.stdout.strip()
        enabled = val == "1"
        print(f"Traditional Chinese output: {enabled}")
        return enabled
    except Exception:
        return False


def _load_stt_engine_setting() -> str:
    """Read STT engine preference from UserDefaults."""
    try:
        import subprocess
        result = subprocess.run(
            ["defaults", "read", "com.zhiyin.app", "sttEngine"],
            capture_output=True, text=True, timeout=2
        )
        val = result.stdout.strip()
        # Migrate legacy "funasr-asr" to "funasr"
        if val == "funasr-asr":
            val = "funasr"
        if val in ("funasr", "whisper"):
            print(f"STT engine setting: {val}")
            return val
    except Exception:
        pass
    return "funasr"


def convert_to_traditional(text: str) -> str:
    """Convert simplified Chinese to traditional Chinese using OpenCC."""
    global s2t_converter
    if s2t_converter is None:
        s2t_converter = opencc.OpenCC('s2t')
    return s2t_converter.convert(text)


def _load_funasr_model(model_repo: str = None):
    """Load FunASR MLX model — use bundled model if available, otherwise download."""
    global asr_model
    repo = model_repo or MODEL_REPO
    bundled_model = os.environ.get("ZHIYIN_MODEL_PATH")
    if bundled_model and os.path.isdir(bundled_model) and repo == MODEL_REPO:
        print(f"Loading bundled ASR model: {bundled_model}")
        model_path = bundled_model
    else:
        print(f"Downloading ASR model: {repo}")
        model_path = snapshot_download(repo)
    asr_model = load_model(model_path)
    silence = np.zeros(16000, dtype=np.float32)
    asr_model.generate(silence)
    print(f"FunASR MLX model ready ({repo}).")


def _warmup_whisper():
    """Warm up Whisper model — triggers download + load + cache."""
    if mlx_whisper is None:
        print("Warning: mlx-whisper not installed, cannot load Whisper engine")
        return
    print(f"Loading Whisper model: {WHISPER_MODEL_REPO}")
    mlx_whisper.transcribe(
        np.zeros(16000, dtype=np.float32),
        path_or_hf_repo=WHISPER_MODEL_REPO,
        language="en",
        verbose=None,
    )
    print("Whisper model ready.")


def warmup_models():
    global asr_model, vad_model, initial_prompt, asr_language, output_traditional, stt_engine

    # Load Silero VAD (tiny, <1s)
    print("Loading Silero VAD...")
    vad_model = load_silero_vad()
    print("Silero VAD ready.")

    # Load settings
    initial_prompt = load_initial_prompt()
    asr_language = _load_language_setting()
    output_traditional = _load_traditional_setting()
    stt_engine = _load_stt_engine_setting()
    print(f"STT engine: {stt_engine}")

    # Load only the selected engine
    if stt_engine == "whisper":
        _warmup_whisper()
    else:
        _load_funasr_model()

    print(f"Server starting on port 17760 (engine={stt_engine}).")


def audio_rms(audio: np.ndarray) -> float:
    """Compute RMS energy of audio."""
    return float(np.sqrt(np.mean(audio ** 2)))


def is_hallucination(text: str, audio: np.ndarray) -> bool:
    """Detect likely hallucinated output using energy checks and pattern matching.

    Avoids hard char/sec thresholds — instead detects actual hallucination patterns:
    repetition, known phantom phrases, and energy mismatch.
    """
    duration_sec = len(audio) / SAMPLE_RATE
    rms = audio_rms(audio)

    # Very quiet audio producing text is suspicious
    # 0.01 balances: catches silence hallucinations but allows soft speech
    if rms < 0.01 and text:
        print(f"Hallucination: rms={rms:.4f} too low for text '{text}'")
        return True

    # Short segment (<0.8s) with low energy is very suspicious.
    # Threshold 0.02: speech at normal conversational volume has RMS 0.03+;
    # only reject if energy is truly noise-level (breath, click, ambient).
    if duration_sec < 0.8 and rms < 0.02 and text:
        print(f"Hallucination: short+quiet seg ({duration_sec:.2f}s, rms={rms:.4f}) '{text}'")
        return True

    # Repetition detection: hallucinations often repeat the same phrase
    if _has_repetition(text):
        print(f"Hallucination: repetitive text '{text}'")
        return True

    # Known hallucination phrases — only reject when audio energy is low.
    # If RMS is clearly speech-level (>0.02), the user genuinely said it.
    if rms < 0.02 and _is_known_hallucination(text):
        print(f"Hallucination: known phantom phrase '{text}' (rms={rms:.4f})")
        return True

    return False


# Phrases that ASR models commonly hallucinate from silence/noise
_HALLUCINATION_PHRASES = {
    "谢谢观看", "谢谢收看", "字幕由", "请订阅", "感谢观看", "感谢收听",
    "字幕提供", "订阅频道", "thank you for watching", "thanks for watching",
    "subscribe", "please subscribe", "like and subscribe",
    "字幕组", "翻译", "校对",
    # Common single-word phantom outputs from breath/noise at end of recording
    "okay", "ok", "bye", "yeah", "yes", "no", "嗯", "啊", "哦",
    "thank you", "thanks",
    # Meta-language hallucinations — model self-labels the speaker's language.
    # These leak in from training data (captioned/annotated speech corpora) and
    # get appended after legitimate Chinese/Japanese/etc. speech. No real speaker
    # ever says "So you're a Chinese" about themselves. Covers both contracted
    # ("you're") and full ("you are") forms.
    "so you're a chinese", "so you're chinese",
    "so you are a chinese", "so you are chinese",
    "you're a chinese", "you're chinese",
    "you are a chinese", "you are chinese",
    "i'm chinese", "i am chinese",
    "this is chinese", "this is in chinese", "in chinese",
    "speaking in chinese", "chinese speaker",
    "so you're japanese", "so you are japanese",
    "i'm japanese", "i am japanese",
    "so you're korean", "so you are korean",
    "i'm korean", "i am korean",
}


def _is_known_hallucination(text: str) -> bool:
    """Check if text matches known hallucination patterns."""
    clean = text.strip().lower().rstrip("。.!！")
    return clean in _HALLUCINATION_PHRASES


def _strip_trailing_hallucinations(text: str) -> str:
    """Peel known hallucination phrases off the END of a transcription.

    FunASR/Whisper sometimes append spurious "closing remarks" after legitimate
    speech — e.g., "So you're a Chinese." at the end of a Chinese utterance, or
    "Thanks for watching." at the end of lecture audio. The overall-segment RMS
    check in is_hallucination() does not catch these because the segment has
    real speech energy from the legitimate part.

    This function splits the output by sentence-ending punctuation (both CJK
    and ASCII) and pops trailing sentences whose entire content matches a
    known hallucination phrase. Middle/leading hallucinations and legitimate
    mixed-language content are untouched.
    """
    import re
    # Split right AFTER each sentence-ending punctuation (zero-width lookbehind).
    # We intentionally don't consume the following whitespace, so joining back
    # with "" preserves the original spacing for space-separated languages.
    sentences = re.split(r'(?<=[。！？.!?])', text)
    while sentences:
        last = sentences[-1]
        # Pop artifact empty/whitespace tail from the split
        if not last.strip():
            sentences.pop()
            continue
        clean = last.strip().lower().rstrip("。.!！？?")
        if clean in _HALLUCINATION_PHRASES:
            sentences.pop()
            continue
        break
    return "".join(sentences).rstrip()


def _has_repetition(text: str) -> bool:
    """Detect if text contains repeated phrases (strong hallucination signal).

    Works at the word level for robustness across languages.
    Detects patterns like "thank you thank you thank you" or "谢谢谢谢谢谢".
    Strips punctuation before comparing so "I'm king, I'm king. I'm king" is caught.
    """
    import re
    # Strip punctuation for comparison
    clean = re.sub(r'[,.!?;:，。！？；：、]', '', text)

    # Word-level repetition: split into words, check for 3+ consecutive repeats
    words = clean.split()
    if len(words) >= 3:
        for window in range(1, len(words) // 3 + 1):
            for start in range(len(words) - window * 3 + 1):
                group = " ".join(words[start:start + window])
                group2 = " ".join(words[start + window:start + window * 2])
                group3 = " ".join(words[start + window * 2:start + window * 3])
                if group == group2 == group3:
                    return True

    # Character-level repetition: for Chinese (no spaces between chars)
    # Check if same 2+ char pattern repeats 3+ times consecutively
    for plen in range(2, len(clean) // 3 + 1):
        pat = clean[:plen]
        if pat * 3 in clean:
            return True

    return False


def _transcribe_funasr(audio: np.ndarray, context: str = "", tokens_per_sec: int = 18,
                       vad_confirmed: bool = False) -> str:
    """Transcribe using FunASR MLX engine.

    Args:
        audio: Audio samples (float32, 16kHz). Pre-checks already passed.
        context: Previous transcription text for continuity.
        tokens_per_sec: Max tokens per second of audio.
        vad_confirmed: If True, VAD already confirmed speech — skip RMS hallucination gate.
    """
    rms = audio_rms(audio)

    # Build prompt: base vocabulary + recent context for continuity.
    # IMPORTANT: Keep prompt in the target language — English text in the prompt
    # primes the LLM decoder to output English (translating instead of
    # transcribing). And avoid meta-linguistic words like "翻译" entirely:
    # FunASR's decoder is autoregressive and LLM-like, so saying "不翻译"
    # ("don't translate") primes it toward translation/language-labeling even
    # though the instruction is negated. Combined with a trailing Chinese
    # context sentence, it reliably causes the model to drop the real audio
    # transcription and emit "So you're a Chinese." or similar meta-labels.
    # See the investigation in archive-pre-public for the full diagnosis.
    prompt = initial_prompt or ""
    if asr_language in ("zh", "auto"):
        prompt = f"以下是中文语音。{prompt}".strip()
    if context:
        ctx_tail = context[-200:]
        prompt = f"{prompt} {ctx_tail}".strip()

    # Cap max_tokens to prevent repetition loops.
    duration_sec = len(audio) / SAMPLE_RATE
    max_tokens = max(20, int(duration_sec * tokens_per_sec))
    result = asr_model.generate(audio, language=asr_language, initial_prompt=prompt, max_tokens=max_tokens, task="transcribe")
    text = clean_text(result.text)

    # Peel spurious closing remarks off the tail (meta-language self-labels etc.)
    original = text
    text = _strip_trailing_hallucinations(text)
    if text != original:
        print(f"Stripped trailing hallucination: '{original}' -> '{text}'")

    # Post-check: reject hallucinated output (skip RMS gate if VAD confirmed speech)
    if text and not vad_confirmed and is_hallucination(text, audio):
        print(f"Rejected hallucination: '{text}' (rms={rms:.4f}, dur={duration_sec:.2f}s)")
        return ""

    if text and output_traditional:
        text = convert_to_traditional(text)

    return text


def _transcribe_whisper(audio: np.ndarray, context: str = "",
                        vad_confirmed: bool = False) -> str:
    """Transcribe using Whisper Large V3 Turbo (MLX) engine.

    Args:
        audio: Audio samples (float32, 16kHz). Pre-checks already passed.
        context: Previous transcription text for continuity.
        vad_confirmed: If True, VAD already confirmed speech — skip RMS hallucination gate.
    """
    rms = audio_rms(audio)

    # Whisper uses initial_prompt to learn output style (punctuation, formatting).
    # A prompt with punctuation primes the model to output punctuation.
    # NOTE: English vocabulary hints cause Whisper to translate Chinese → English,
    # so we only use punctuation-priming text + context, not the vocab dictionary.
    punctuation_prime = "以下是普通话的句子，请加上标点符号。"
    prompt = punctuation_prime
    if context:
        ctx_tail = context[-200:]
        prompt = f"{prompt} {ctx_tail.strip()}"

    # Map language: "auto" -> None for Whisper auto-detect
    lang = None if asr_language == "auto" else asr_language

    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=WHISPER_MODEL_REPO,
        language=lang,
        initial_prompt=prompt or None,
        temperature=0.0,
        verbose=None,
        no_speech_threshold=0.6,
        condition_on_previous_text=True,
    )
    text = result["text"].strip()
    # Whisper bypasses clean_text (which only handles FunASR tokens),
    # so call filler removal explicitly here to keep both engines consistent.
    text = remove_filler_words(text)

    # Peel spurious closing remarks off the tail (meta-language self-labels etc.)
    original = text
    text = _strip_trailing_hallucinations(text)
    if text != original:
        print(f"Stripped trailing hallucination (whisper): '{original}' -> '{text}'")

    # Post-check: reject hallucinated output (skip RMS gate if VAD confirmed speech)
    if text and not vad_confirmed and is_hallucination(text, audio):
        print(f"Rejected Whisper hallucination: '{text}' (rms={rms:.4f})")
        return ""

    if text and output_traditional:
        text = convert_to_traditional(text)

    return text


def transcribe_segment(audio: np.ndarray, context: str = "", tokens_per_sec: int = 18,
                       skip_prefilter: bool = False, vad_confirmed: bool = False) -> str:
    """Transcribe a single audio segment, dispatching to the active STT engine.

    Args:
        audio: Audio samples (float32, 16kHz).
        context: Previous transcription text for continuity (reduces cross-language errors).
        tokens_per_sec: Max tokens per second of audio. Use 18 for streaming,
                        higher (e.g. 25) for finalize where concurrency isn't an issue.
        skip_prefilter: Skip RMS/VAD pre-checks (for file uploads where audio has
                        silence padding that dilutes overall RMS).
        vad_confirmed: VAD already confirmed speech — skip RMS-based hallucination rejection.
    """
    if len(audio) < 1600:  # < 0.1s
        return ""

    rms = audio_rms(audio)

    if not skip_prefilter:
        # Skip quiet segments — likely noise, not real speech.
        if rms < 0.03:
            return ""

        # VAD check: confirm there's actual speech before sending to model.
        wav_tensor = torch.from_numpy(audio).float()
        speech_ts = get_speech_timestamps(wav_tensor, vad_model, sampling_rate=SAMPLE_RATE, threshold=0.5)
        if not speech_ts:
            print(f"VAD filter: no speech detected in {len(audio)/SAMPLE_RATE:.1f}s segment (rms={rms:.4f})")
            return ""

    # Dispatch to active engine
    if stt_engine == "whisper":
        return _transcribe_whisper(audio, context, vad_confirmed=vad_confirmed)
    else:
        return _transcribe_funasr(audio, context, tokens_per_sec, vad_confirmed=vad_confirmed)


def run_vad(audio: np.ndarray) -> list[dict]:
    """Run Silero VAD on audio, return speech timestamps in samples."""
    wav_tensor = torch.from_numpy(audio).float()
    timestamps = get_speech_timestamps(
        wav_tensor,
        vad_model,
        sampling_rate=SAMPLE_RATE,
        threshold=0.5,                 # Speech probability threshold (default 0.5, raise to reduce hallucinations)
        min_speech_duration_ms=250,
        min_silence_duration_ms=300,   # 300ms silence = sentence boundary
        speech_pad_ms=100,
        return_seconds=False,
    )
    return timestamps


def process_vad_for_session(session: dict):
    """Check if VAD detected completed speech segments, queue them for transcription.

    Uses incremental VAD: only scans audio from the last transcribed end
    (with 1s overlap for boundary accuracy) instead of rescanning from the start.
    """
    samples = session["samples"]
    processed_up_to = session["vad_processed_up_to"]

    if len(samples) - processed_up_to < SAMPLE_RATE * 0.3:
        # Need at least 0.3s of new audio to run VAD
        return

    # Incremental VAD: start from last transcribed position with 1s overlap
    scan_start = max(0, session["last_transcribed_end"] - SAMPLE_RATE)
    scan_audio = samples[scan_start:]
    timestamps = run_vad(scan_audio)

    if not timestamps:
        session["vad_processed_up_to"] = len(samples)
        return

    # Find segments that are complete (have both start and end)
    # and haven't been transcribed yet
    already_transcribed_end = session["last_transcribed_end"]

    for ts in timestamps:
        # Convert back to absolute positions
        seg_start = ts["start"] + scan_start
        seg_end = ts["end"] + scan_start

        # Skip segments we've already transcribed
        if seg_end <= already_transcribed_end:
            continue

        # Check if this segment is "complete" - there must be enough silence after it
        # A segment is complete if there's audio data beyond seg_end + silence margin
        silence_margin = int(SAMPLE_RATE * 0.2)  # 200ms margin
        if seg_end + silence_margin < len(samples):
            # This segment is complete, transcribe it
            seg_start = max(seg_start, already_transcribed_end)
            segment_audio = samples[seg_start:seg_end]
            text = transcribe_segment(segment_audio, context=session["full_text"])
            if text:
                session["transcribed_segments"].append({
                    "start": seg_start,
                    "end": seg_end,
                    "text": text,
                })
                session["last_transcribed_end"] = seg_end
                # Update full text
                session["full_text"] = " ".join(
                    seg["text"] for seg in session["transcribed_segments"]
                )

    session["vad_processed_up_to"] = len(samples)


def cleanup_stale_sessions():
    now = time.time()
    with sessions_lock:
        stale = [sid for sid, s in sessions.items() if now - s["last_active"] > SESSION_TIMEOUT]
        for sid in stale:
            del sessions[sid]


RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/ZhiYin/recordings")


def _save_recording(samples: np.ndarray, session_id: str):
    """Save session audio as WAV for test replay."""
    try:
        os.makedirs(RECORDINGS_DIR, exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        path = os.path.join(RECORDINGS_DIR, f"{timestamp}_{session_id}.wav")
        sf.write(path, samples, SAMPLE_RATE)
        print(f"Saved recording: {path} ({len(samples)/SAMPLE_RATE:.1f}s)")
    except Exception as e:
        print(f"Warning: failed to save recording: {e}")


# --- Endpoints ---

@app.get("/health")
def health():
    if stt_engine == "whisper":
        asr_loaded = mlx_whisper is not None
    else:
        asr_loaded = asr_model is not None
    return {"status": "ok", "asr_loaded": asr_loaded, "vad_loaded": vad_model is not None, "engine": stt_engine}


@app.post("/reload-settings")
def reload_settings():
    """Reload dictionary, language, and engine settings without restarting server."""
    global initial_prompt, asr_language, output_traditional, stt_engine
    initial_prompt = load_initial_prompt()
    asr_language = _load_language_setting()
    output_traditional = _load_traditional_setting()

    # Check for engine change
    new_engine = _load_stt_engine_setting()
    if new_engine != stt_engine:
        print(f"Engine switch: {stt_engine} -> {new_engine}")
        if new_engine == "whisper" and mlx_whisper is None:
            return {"ok": False, "error": "mlx-whisper not installed", "engine": stt_engine}
        # Check if model is cached before switching
        new_repo = MODEL_REGISTRY.get(new_engine, {}).get("repo_id")
        if new_repo and not _is_model_cached(new_repo):
            return {"ok": False, "error": "model_not_cached", "engine": stt_engine}
        old_engine = stt_engine
        stt_engine = new_engine
        # Preload the new engine in the executor so first transcription is fast
        if new_engine == "whisper":
            _get_executor().submit(_warmup_whisper)
        elif new_engine == "funasr":
            if asr_model is None:
                _get_executor().submit(_load_funasr_model)

    return {"ok": True, "language": asr_language, "traditional": output_traditional,
            "initial_prompt": initial_prompt, "engine": stt_engine}


def _transcribe_file_sync(audio: np.ndarray) -> str:
    """Run file transcription in executor (serialized with streaming inference).

    Uses VAD to split audio at silence gaps, then transcribes each group
    independently. This prevents FunASR from emitting EOS at long silence gaps
    and dropping subsequent speech segments.

    Whisper handles silence internally (no_speech_threshold) and benefits from
    longer context for punctuation, so it skips VAD splitting entirely.
    """
    # Pad with 0.2s silence so the model can recognize words at the very end
    audio = np.concatenate([audio, np.zeros(int(SAMPLE_RATE * 0.2), dtype=np.float32)])

    # Whisper handles silence gaps internally — skip VAD splitting to preserve
    # context length, which is needed for reliable punctuation output.
    # But still check VAD first to reject silence/noise (Whisper hallucinates on empty audio).
    if stt_engine == "whisper":
        wav_tensor = torch.from_numpy(audio).float()
        speech_ts = get_speech_timestamps(wav_tensor, vad_model, sampling_rate=SAMPLE_RATE, threshold=0.5)
        if not speech_ts:
            return ""
        text = transcribe_segment(audio, tokens_per_sec=25, skip_prefilter=True, vad_confirmed=True)
        if text and output_traditional:
            text = convert_to_traditional(text)
        return text

    # FunASR: Use VAD to split at silence gaps (FunASR EOS triggers at ~1.5s silence)
    SILENCE_GAP_SEC = 1.0
    MAX_CHUNK_SEC = 30
    MAX_CHUNK_SAMPLES = int(SAMPLE_RATE * MAX_CHUNK_SEC)

    wav_tensor = torch.from_numpy(audio).float()
    speech_ts = get_speech_timestamps(wav_tensor, vad_model, sampling_rate=SAMPLE_RATE, threshold=0.5)

    if not speech_ts:
        # No speech detected, try transcribing the whole thing anyway
        text = transcribe_segment(audio, tokens_per_sec=25, skip_prefilter=True)
        if text and output_traditional:
            text = convert_to_traditional(text)
        return text

    # Group speech segments: split at silence gaps > SILENCE_GAP_SEC
    groups = []
    current_group_start = speech_ts[0]["start"]
    current_group_end = speech_ts[0]["end"]

    for i in range(1, len(speech_ts)):
        gap = (speech_ts[i]["start"] - current_group_end) / SAMPLE_RATE
        if gap > SILENCE_GAP_SEC:
            groups.append((current_group_start, current_group_end))
            current_group_start = speech_ts[i]["start"]
        current_group_end = speech_ts[i]["end"]
    groups.append((current_group_start, current_group_end))

    # Transcribe each group with padding.
    #
    # NOTE: we intentionally pass context="" (empty initial_prompt) instead of
    # stitching together previously-transcribed texts. FunASR's initial_prompt
    # parameter is designed for vocabulary biasing, NOT conversational context.
    # When previous text is fed in, FunASR produces truncated output — for
    # example, a 5.5s chunk containing a full clause will be reduced to just
    # the last word of the prompt. Empty context produces complete transcripts.
    # See .planning/notes/funasr-context-prompt-bug.md for evidence and
    # regression test case.
    PAD_SAMPLES = int(SAMPLE_RATE * 0.3)  # 300ms padding around each group
    texts = []
    for start, end in groups:
        pad_start = max(0, start - PAD_SAMPLES)
        pad_end = min(len(audio), end + PAD_SAMPLES)
        chunk = audio[pad_start:pad_end]

        if len(chunk) < 1600:
            continue

        # If chunk exceeds max, split by size (rare for VAD-grouped segments)
        if len(chunk) > MAX_CHUNK_SAMPLES:
            for j in range(0, len(chunk), MAX_CHUNK_SAMPLES):
                sub = chunk[j:j + MAX_CHUNK_SAMPLES]
                if len(sub) < 1600:
                    continue
                t = transcribe_segment(sub, context="", tokens_per_sec=25, skip_prefilter=True, vad_confirmed=True)
                if t:
                    texts.append(t)
        else:
            t = transcribe_segment(chunk, context="", tokens_per_sec=25, skip_prefilter=True, vad_confirmed=True)
            if t:
                texts.append(t)

    # Smart join: insert '，' at group boundaries where neither side has punct.
    # Avoids smashing adjacent groups together (e.g. "我加了显示" + "加了标点符号"
    # → "我加了显示加了标点符号"). See join_group_texts docstring for rationale.
    text = join_group_texts(texts)

    if text and output_traditional:
        text = convert_to_traditional(text)
    return text


@app.post("/transcribe")
async def transcribe_file(file: UploadFile = File(...)):
    """Legacy: upload full WAV file, get transcription."""
    # Check that the active engine is ready
    if stt_engine == "whisper":
        if mlx_whisper is None:
            return JSONResponse(status_code=503, content={"error": "Whisper not installed"})
    else:
        if asr_model is None:
            return JSONResponse(status_code=503, content={"error": "Model not loaded"})

    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name
    try:
        audio, sr = sf.read(tmp_path, dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        # Resample to 16kHz if needed (model expects 16kHz)
        if sr != SAMPLE_RATE:
            import numpy as np
            duration = len(audio) / sr
            target_len = int(duration * SAMPLE_RATE)
            indices = np.linspace(0, len(audio) - 1, target_len).astype(np.int64)
            audio = audio[indices]
            print(f"Resampled audio: {sr}Hz -> {SAMPLE_RATE}Hz ({duration:.1f}s)")
        if len(audio) < 200:
            return {"text": "", "time": 0.0}
        t0 = time.time()

        # Run inference in executor — serialized with streaming to avoid
        # concurrent MLX model access (which causes crashes)
        loop = asyncio.get_event_loop()
        text = await loop.run_in_executor(_get_executor(), _transcribe_file_sync, audio)

        elapsed = time.time() - t0
        return {"text": text, "time": round(elapsed, 3)}
    finally:
        os.unlink(tmp_path)


@app.post("/stream/start")
async def stream_start():
    """Start a new streaming session."""
    cleanup_stale_sessions()
    session_id = uuid.uuid4().hex[:12]
    with sessions_lock:
        sessions[session_id] = {
            "samples": np.array([], dtype=np.float32),
            "last_active": time.time(),
            "created": time.time(),
            "vad_processed_up_to": 0,
            "last_transcribed_end": 0,
            "transcribed_segments": [],
            "full_text": "",
            "version": 0,  # increments when new text is available
        }
    return {"session_id": session_id}


@app.post("/stream/chunk/{session_id}")
async def stream_chunk(session_id: str, request: Request):
    """Append raw PCM float32 audio chunk, kick off background VAD, return immediately.

    VAD + transcription runs fire-and-forget in a background thread.
    The chunk endpoint never blocks — it appends audio and returns current state.
    """
    with sessions_lock:
        session = sessions.get(session_id)
    if session is None:
        return JSONResponse(status_code=404, content={"error": "Session not found"})

    raw = await request.body()
    if len(raw) == 0:
        return {"ok": True, "text": session["full_text"], "version": session["version"]}

    chunk = np.frombuffer(raw, dtype=np.float32)

    with sessions_lock:
        session["samples"] = np.concatenate([session["samples"], chunk])
        session["last_active"] = time.time()

    # Fire-and-forget: submit VAD work if not already running for this session
    if not session.get("_processing"):
        session["_processing"] = True
        _get_executor().submit(_process_and_update, session)

    return {
        "ok": True,
        "text": session["full_text"],
        "version": session["version"],
        "segments": len(session["transcribed_segments"]),
        "duration": round(len(session["samples"]) / SAMPLE_RATE, 2),
    }


def _process_and_update(session: dict):
    """Run VAD + transcription (called from thread pool, fire-and-forget)."""
    try:
        old_version = session["version"]
        process_vad_for_session(session)
        if session["full_text"] and len(session["transcribed_segments"]) > old_version:
            session["version"] = len(session["transcribed_segments"])
    finally:
        session["_processing"] = False


@app.get("/stream/poll/{session_id}")
async def stream_poll(session_id: str, since_version: int = 0):
    """Poll for new transcribed text."""
    with sessions_lock:
        session = sessions.get(session_id)
    if session is None:
        return JSONResponse(status_code=404, content={"error": "Session not found"})

    return {
        "text": session["full_text"],
        "version": session["version"],
        "segments": len(session["transcribed_segments"]),
        "has_new": session["version"] > since_version,
    }


@app.post("/stream/finalize/{session_id}")
async def stream_finalize(session_id: str, mode: str = "full"):
    """Finalize: transcribe remaining speech, return complete text, close session.

    Args:
        mode: "full" = re-transcribe entire audio (accurate, ~1-3s)
              "quick" = only transcribe remaining untranscribed audio (fast, <0.5s)

    Runs in thread pool so it doesn't block if a chunk is being processed.
    """
    # Check that the active engine is ready
    if stt_engine == "whisper":
        if mlx_whisper is None:
            return JSONResponse(status_code=503, content={"error": "Whisper not installed"})
    else:
        if asr_model is None:
            return JSONResponse(status_code=503, content={"error": "Model not loaded"})

    with sessions_lock:
        session = sessions.pop(session_id, None)
    if session is None:
        return JSONResponse(status_code=404, content={"error": "Session not found"})

    samples = session["samples"]
    if len(samples) < 1600:
        return {"text": "", "time": 0}

    # Save recording for test replay
    _save_recording(samples, session_id)

    loop = asyncio.get_event_loop()
    if mode == "quick":
        result = await loop.run_in_executor(_get_executor(), _finalize_quick, session, samples)
    else:
        # Always use full re-transcription. The previous "longer wins" heuristic
        # designed for rap/dense audio (where full might truncate) backfired:
        # when streaming hallucinated extra English garbage at the tail
        # ("Waiver Machine") it made quick "win" on character count, polluting
        # the final output. Full now delegates to _transcribe_file_sync, which
        # uses VAD-based grouping (SILENCE_GAP_SEC=1.0) to merge short adjacent
        # segments — this is the same code path the working /transcribe endpoint
        # uses and it correctly handles the short-isolated-segment case.
        result = await loop.run_in_executor(_get_executor(), _finalize_full, session, samples)
    return result


def _finalize_quick(session: dict, samples: np.ndarray) -> dict:
    """Quick finalize: streaming segments + transcribe remaining audio.

    Recording has ended — transcribe everything from last_transcribed_end
    to the end. No silence check needed because we KNOW recording is done.
    """
    segments = session["transcribed_segments"]
    MAX_SEG_SAMPLES = int(SAMPLE_RATE * 10)  # segments > 10s need re-splitting
    MAX_CHUNK = int(SAMPLE_RATE * 5)          # split into 5s chunks

    # Re-split any streaming segment that's too long (model stops early on >10s)
    texts = []
    for seg in segments:
        seg_len = seg["end"] - seg["start"]
        if seg_len > MAX_SEG_SAMPLES:
            # This segment is too long — split and re-transcribe
            print(f"  Re-splitting long segment ({seg_len/SAMPLE_RATE:.1f}s) into ~5s chunks")
            seg_audio = samples[seg["start"]:seg["end"]]
            for i in range(0, len(seg_audio), MAX_CHUNK):
                chunk = seg_audio[i:i + MAX_CHUNK]
                if len(chunk) < 1600:
                    continue
                # context="" — FunASR's initial_prompt gets poisoned by
                # previous-text stitching (see _transcribe_file_sync).
                chunk_text = transcribe_segment(chunk, context="", tokens_per_sec=25)
                if chunk_text and not is_hallucination(chunk_text, chunk):
                    texts.append(chunk_text)
        else:
            texts.append(seg["text"])

    # Transcribe tail (remaining audio after last streaming segment)
    # Pad with 0.2s silence so the model can recognize words at the very end
    samples = np.concatenate([samples, np.zeros(int(SAMPLE_RATE * 0.2), dtype=np.float32)])
    already_transcribed_end = session["last_transcribed_end"]
    remaining = samples[already_transcribed_end:]
    remaining_dur = len(remaining) / SAMPLE_RATE
    print(f"Quick finalize: remaining={remaining_dur:.1f}s from={already_transcribed_end}")

    if len(remaining) >= 1600:
        # Use VAD to find speech in the remaining audio, then transcribe each
        # speech region. This avoids the RMS prefilter rejecting tail audio
        # where real speech is surrounded by silence (overall RMS drops below
        # threshold even though speech is present).
        tail_timestamps = run_vad(remaining)
        if tail_timestamps:
            for ts in tail_timestamps:
                seg_audio = remaining[ts["start"]:ts["end"]]
                if len(seg_audio) < 1600:
                    continue
                seg_text = transcribe_segment(seg_audio, context="",
                                              tokens_per_sec=25, skip_prefilter=True)
                if seg_text and not is_hallucination(seg_text, seg_audio):
                    texts.append(seg_text)
                    print(f"  Tail segment: '{seg_text}'")
        elif audio_rms(remaining) >= 0.01:
            # VAD found nothing but there's some energy — try direct transcription
            # with skip_prefilter since recording has ended
            tail_text = transcribe_segment(remaining, context="",
                                           tokens_per_sec=25, skip_prefilter=True)
            if tail_text and not is_hallucination(tail_text, remaining):
                texts.append(tail_text)
                print(f"  Tail: '{tail_text}'")

    full_text = " ".join(texts)
    if full_text and output_traditional:
        full_text = convert_to_traditional(full_text)

    return {
        "text": full_text,
        "segments": len(texts),
        "duration": round(len(samples) / SAMPLE_RATE, 2),
    }


def _finalize_full(session: dict, samples: np.ndarray) -> dict:
    """Full finalize: re-transcribe full audio via the VAD-grouped pipeline.

    Delegates to _transcribe_file_sync for VAD-based grouping (SILENCE_GAP_SEC=1.0)
    that merges short adjacent segments into longer chunks before transcription.
    This ensures short trailing segments (e.g. a 1.1s "Whisper模型" tail) get
    transcribed WITH adjacent context audio rather than in isolation, avoiding
    the FunASR hallucination where short isolated segments emit English garbage.

    The previous implementation used streaming-derived segment boundaries and
    re-transcribed each one individually — which inherited the same isolation
    bug. By delegating to _transcribe_file_sync (the same code path /transcribe
    uses) we get correct behavior without duplicating the grouping logic.
    """
    duration_sec = len(samples) / SAMPLE_RATE
    rms = audio_rms(samples)
    print(f"Full finalize: {duration_sec:.1f}s, rms={rms:.4f}")

    if duration_sec < 0.3 or rms < 0.005:
        full_text = session.get("full_text", "")
    else:
        full_text = _transcribe_file_sync(samples)
        # Fall back to streaming text if the file-sync path returned nothing
        # (e.g., VAD found no speech but streaming did).
        if not full_text:
            full_text = session.get("full_text", "")
        print(f"  Final ({len(full_text)} chars): '{full_text[:80]}'")

    return {
        "text": full_text,
        "segments": len(session.get("transcribed_segments", [])),
        "duration": round(duration_sec, 2),
    }


@app.delete("/stream/{session_id}")
async def stream_cancel(session_id: str):
    with sessions_lock:
        sessions.pop(session_id, None)
    return {"ok": True}


# --- Model management endpoints ---

def _dir_size(path: str) -> int:
    """Get total size of directory in bytes."""
    total = 0
    for dirpath, _, filenames in os.walk(path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def _is_model_cached(repo_id: str) -> bool:
    """Check if a HuggingFace model is already cached locally."""
    # Check bundled model path for FunASR variants
    bundled = os.environ.get("ZHIYIN_MODEL_PATH")
    if bundled and os.path.isdir(bundled):
        if repo_id == MODEL_REPO:
            return True
    try:
        snapshot_download(repo_id, local_files_only=True)
        return True
    except Exception:
        return False


def _get_model_size_mb(repo_id: str) -> int:
    """Get on-disk size of a cached model in MB."""
    try:
        from huggingface_hub import scan_cache_dir
        cache_info = scan_cache_dir()
        for repo in cache_info.repos:
            if repo.repo_id == repo_id:
                return round(repo.size_on_disk / (1024 * 1024))
    except Exception:
        pass
    return 0


@app.get("/model/list")
def model_list():
    """Return all available models with cached/downloading status."""
    results = []
    for engine, info in MODEL_REGISTRY.items():
        repo_id = info["repo_id"]
        cached = _is_model_cached(repo_id)
        size_mb = _get_model_size_mb(repo_id) if cached else info["approx_size_mb"]

        with _download_lock:
            dl = _download_progress.get(repo_id, {})

        results.append({
            "engine": engine,
            "repo_id": repo_id,
            "display_name": info["display_name"],
            "cached": cached,
            "size_mb": size_mb,
            "downloading": dl.get("status") == "downloading",
            "progress": dl.get("progress", 0),
        })
    return {"models": results}


def _download_model_worker(engine: str, repo_id: str):
    """Download a model repo in a background thread (not the MLX executor)."""
    try:
        # Get expected total size from HF API
        total_bytes = 0
        try:
            from huggingface_hub import HfApi
            api = HfApi()
            info = api.repo_info(repo_id, files_metadata=True)
            total_bytes = sum(s.size for s in info.siblings if s.size)
        except Exception:
            total_bytes = MODEL_REGISTRY.get(engine, {}).get("approx_size_mb", 500) * 1024 * 1024

        # Monitor cache directory size for progress
        cache_dir = os.path.expanduser("~/.cache/huggingface/hub")
        model_dir = os.path.join(cache_dir, f"models--{repo_id.replace('/', '--')}")
        stop_monitor = threading.Event()

        def monitor_progress():
            while not stop_monitor.is_set():
                try:
                    if os.path.isdir(model_dir):
                        size = _dir_size(model_dir)
                        pct = min(99, int(size * 100 / total_bytes)) if total_bytes > 0 else 0
                        with _download_lock:
                            if _download_progress.get(repo_id, {}).get("status") == "downloading":
                                _download_progress[repo_id]["progress"] = pct
                except Exception:
                    pass
                stop_monitor.wait(1.0)

        mon = threading.Thread(target=monitor_progress, daemon=True)
        mon.start()

        # Actual download (blocking)
        snapshot_download(repo_id)

        stop_monitor.set()
        mon.join(timeout=2)

        with _download_lock:
            _download_progress[repo_id] = {"status": "done", "progress": 100, "error": None}
        print(f"Model download complete: {repo_id}")

    except Exception as e:
        with _download_lock:
            _download_progress[repo_id] = {"status": "error", "progress": 0, "error": str(e)}
        print(f"Model download failed: {repo_id}: {e}")


@app.post("/model/download")
def model_download(engine: str):
    """Start downloading a model in the background."""
    if engine not in MODEL_REGISTRY:
        return JSONResponse(status_code=400, content={"error": f"Unknown engine: {engine}"})

    repo_id = MODEL_REGISTRY[engine]["repo_id"]

    # Already cached?
    if _is_model_cached(repo_id):
        return {"ok": True, "message": "Already cached"}

    with _download_lock:
        if repo_id in _download_progress and _download_progress[repo_id].get("status") == "downloading":
            return {"ok": True, "message": "Already downloading"}
        _download_progress[repo_id] = {"status": "downloading", "progress": 0, "error": None}

    thread = threading.Thread(target=_download_model_worker, args=(engine, repo_id), daemon=True)
    thread.start()
    return {"ok": True}


@app.get("/model/progress")
def model_progress():
    """Return download progress for all models."""
    with _download_lock:
        return {"downloads": dict(_download_progress)}


@app.post("/model/delete")
def model_delete(engine: str):
    """Delete a cached model to free disk space."""
    if engine not in MODEL_REGISTRY:
        return JSONResponse(status_code=400, content={"error": f"Unknown engine: {engine}"})

    repo_id = MODEL_REGISTRY[engine]["repo_id"]

    if engine == stt_engine:
        return JSONResponse(status_code=400, content={"error": "Cannot delete the currently active engine's model"})

    try:
        from huggingface_hub import scan_cache_dir
        cache_info = scan_cache_dir()
        revisions_to_delete = []
        for repo in cache_info.repos:
            if repo.repo_id == repo_id:
                for rev in repo.revisions:
                    revisions_to_delete.append(rev.commit_hash)
                break

        if not revisions_to_delete:
            return {"ok": True, "message": "Model not in cache"}

        strategy = cache_info.delete_revisions(*revisions_to_delete)
        freed = strategy.expected_freed_size
        strategy.execute()

        with _download_lock:
            _download_progress.pop(repo_id, None)

        return {"ok": True, "freed_mb": round(freed / (1024 * 1024))}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


# --- Usage tracking endpoints (shared with Swift UsageTracker via UserDefaults) ---

USAGE_COUNT_KEY = "dailyTranscriptionCount"
USAGE_DATE_KEY = "dailyTranscriptionDate"
USAGE_DAILY_LIMIT = 50


def _read_defaults(key: str) -> str:
    try:
        result = subprocess.run(
            ["defaults", "read", "com.zhiyin.app", key],
            capture_output=True, text=True, timeout=2
        )
        return result.stdout.strip()
    except Exception:
        return ""


def _write_defaults(key: str, value: str, dtype: str = "-string"):
    try:
        subprocess.run(
            ["defaults", "write", "com.zhiyin.app", key, dtype, value],
            capture_output=True, timeout=2
        )
    except Exception:
        pass


def _read_usage_count() -> int:
    """Read daily usage count, reset if date changed."""
    import datetime
    today = datetime.date.today().isoformat()
    stored_date = _read_defaults(USAGE_DATE_KEY)
    if stored_date != today:
        _write_defaults(USAGE_DATE_KEY, today)
        _write_defaults(USAGE_COUNT_KEY, "0", "-integer")
        return 0
    count_str = _read_defaults(USAGE_COUNT_KEY)
    return int(count_str) if count_str.isdigit() else 0


def _increment_usage_count() -> int:
    """Increment and return the new count."""
    import datetime
    today = datetime.date.today().isoformat()
    stored_date = _read_defaults(USAGE_DATE_KEY)
    if stored_date != today:
        _write_defaults(USAGE_DATE_KEY, today)
        _write_defaults(USAGE_COUNT_KEY, "1", "-integer")
        return 1
    count = _read_usage_count() + 1
    _write_defaults(USAGE_COUNT_KEY, str(count), "-integer")
    return count


def _read_is_pro() -> bool:
    val = _read_defaults("isPro")
    return val == "1"


@app.get("/usage")
def usage_status():
    """Return current usage count and limits."""
    count = _read_usage_count()
    is_pro = _read_is_pro()
    remaining = max(0, USAGE_DAILY_LIMIT - count) if not is_pro else -1
    return {"count": count, "limit": USAGE_DAILY_LIMIT, "is_pro": is_pro, "remaining": remaining}


@app.post("/usage/record")
def usage_record():
    """Increment usage count. Returns whether within limit."""
    is_pro = _read_is_pro()
    if is_pro:
        return {"ok": True, "is_pro": True}
    count = _increment_usage_count()
    return {"ok": count <= USAGE_DAILY_LIMIT, "count": count, "limit": USAGE_DAILY_LIMIT}


def _find_available_port(start_port: int = 17760, max_tries: int = 10) -> int:
    """Find an available port, starting from start_port.

    If start_port is occupied by a stale ZhiYin server, kill it and reuse.
    If occupied by another process, try the next port.
    """
    import socket
    import urllib.request

    for offset in range(max_tries):
        port = start_port + offset
        # Check if port is in use
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.bind(("127.0.0.1", port))
            sock.close()
            return port  # Port is free
        except OSError:
            sock.close()

        # Port is occupied — check if it's our server
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2)
            data = json.loads(resp.read())
            if data.get("status") == "ok" and data.get("vad_loaded") is not None:
                # It's a stale ZhiYin server — kill it
                print(f"Port {port}: stale ZhiYin server detected, will reuse after shutdown")
                try:
                    # Find and kill the process on this port
                    import subprocess
                    result = subprocess.run(["lsof", "-ti", f":{port}"], capture_output=True, text=True)
                    for pid in result.stdout.strip().split("\n"):
                        if pid:
                            os.kill(int(pid), 9)
                    import time
                    time.sleep(1)
                    return port
                except Exception:
                    pass
        except Exception:
            pass

        print(f"Port {port}: occupied by another process, trying next...")

    print(f"ERROR: No available port found in range {start_port}-{start_port + max_tries - 1}")
    return start_port  # Fall back to default


PORT_FILE = os.path.expanduser("~/.zhiyin/server.port")


if __name__ == "__main__":
    port = _find_available_port()
    # Write port to file so Swift app can discover it
    os.makedirs(os.path.dirname(PORT_FILE), exist_ok=True)
    with open(PORT_FILE, "w") as f:
        f.write(str(port))
    warmup_models()
    print(f"Server starting on port {port}")
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
