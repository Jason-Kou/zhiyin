"""Hallucination filtering for ASR output.

Speech models invent text from silence, breath, and noise — "谢谢观看" at the end
of a recording, "Thanks for watching" after a lecture, a phrase repeated three
times. This module decides what gets thrown away before the text reaches the
user's cursor.

Kept free of MLX and model imports on purpose: these are pure string functions,
so they can be tested without a GPU, a 1.5GB model download, or Apple Silicon.
See test_hallucination.py.
"""

import re

# Phrases that ASR models commonly hallucinate from silence/noise
HALLUCINATION_PHRASES = {
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


def is_known_hallucination(text: str) -> bool:
    """Check if text matches known hallucination patterns."""
    clean = text.strip().lower().rstrip("。.!！")
    return clean in HALLUCINATION_PHRASES


def strip_trailing_hallucinations(text: str) -> str:
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
        if clean in HALLUCINATION_PHRASES:
            sentences.pop()
            continue
        break
    return "".join(sentences).rstrip()


def has_repetition(text: str) -> bool:
    """Detect if text contains repeated phrases (strong hallucination signal).

    Works at the word level for robustness across languages.
    Detects patterns like "thank you thank you thank you" or "谢谢谢谢谢谢".
    Strips punctuation before comparing so "I'm king, I'm king. I'm king" is caught.
    """
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
