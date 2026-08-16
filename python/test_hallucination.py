#!/usr/bin/env python3
"""Unit tests for the hallucination filter.

Deliberately dependency-free: no server, no MLX, no model download. Runs in
milliseconds on any platform, which is what lets CI execute it.

    python/test_hallucination.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hallucination import (
    has_repetition,
    is_known_hallucination,
    strip_trailing_hallucinations,
)

REPETITION_CASES = [
    # Repeats that should be rejected
    ("thank you thank you thank you", True),
    ("谢谢谢谢谢谢", True),
    ("好的好的好的", True),
    ("ha ha ha ha ha ha", True),
    ("the the the quick brown fox", True),
    ("subscribe subscribe subscribe", True),
    # Legitimate speech that must survive
    ("I like this", False),
    ("It's really good. I like this.", False),
    ("好，现在我把繁体的功能打开了", False),
    ("Hello, how are you today?", False),
    ("", False),
    # Two repeats is not enough — three consecutive is the threshold
    ("hello hello", False),
    # A word repeating non-consecutively is normal speech
    ("the cat sat on the mat by the door", False),
]

KNOWN_CASES = [
    ("谢谢观看", True),
    ("Thank you for watching", True),
    ("subscribe", True),
    # Case and trailing punctuation are normalized away
    ("SUBSCRIBE.", True),
    ("谢谢观看。", True),
    ("  thanks  ", True),
    # Meta-language self-labels the model emits after real speech
    ("So you're a Chinese", True),
    ("I am Japanese", True),
    # Real content must survive
    ("hello world", False),
    ("I like this product", False),
    ("谢谢你的帮助", False),
    ("", False),
]

STRIP_CASES = [
    # Trailing hallucination peeled off, real speech kept
    ("今天天气不错。谢谢观看。", "今天天气不错。"),
    ("This is the actual content. Thanks for watching.", "This is the actual content."),
    ("我们开始吧。So you're a Chinese.", "我们开始吧。"),
    # Several stacked at the end
    ("有用的内容。谢谢观看。请订阅。", "有用的内容。"),
    # Nothing to strip — unchanged
    ("今天天气不错。", "今天天气不错。"),
    ("Hello there. How are you?", "Hello there. How are you?"),
    ("", ""),
    # A hallucination phrase in the MIDDLE is legitimate content, left alone
    ("他说谢谢观看，然后走了。", "他说谢谢观看，然后走了。"),
    # Everything is hallucination — strips to empty rather than crashing
    ("谢谢观看。", ""),
]


def main() -> int:
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}\n      got:  {got!r}\n      want: {want!r}")
            print(f"  FAIL {label}")
        else:
            print(f"  ok   {label}")

    print("has_repetition")
    for text, want in REPETITION_CASES:
        check(f"has_repetition({text!r})", has_repetition(text), want)

    print("is_known_hallucination")
    for text, want in KNOWN_CASES:
        check(f"is_known_hallucination({text!r})", is_known_hallucination(text), want)

    print("strip_trailing_hallucinations")
    for text, want in STRIP_CASES:
        check(f"strip_trailing_hallucinations({text!r})",
              strip_trailing_hallucinations(text), want)

    total = len(REPETITION_CASES) + len(KNOWN_CASES) + len(STRIP_CASES)
    print()
    if failures:
        print(f"{len(failures)} of {total} failed:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"all {total} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
