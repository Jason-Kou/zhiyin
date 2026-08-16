"""Convert spoken-form Chinese numerals in ASR output to Arabic digits.

The speech model has no inverse text normalization — it transcribes 3.5 as
"三点五" and there is no way to ask it for digits, so this runs afterwards.

Deliberately narrow. Chinese numerals are load-bearing in ordinary words —
一下, 一起, 十分, 星期三, 第一 — and converting them produces nonsense. Every
rule here requires structural evidence that a quantity is meant, and anything
ambiguous is left alone. See test_numerals.py, which pins the cases that must
NOT convert.
"""

from __future__ import annotations

import re

DIGITS = {
    "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}
DIGIT_CHARS = "".join(DIGITS)

# Units that follow a time-of-day reading, so 三点五十分 is 3:50 and not 3.50
TIME_MARKERS = "分刻半"


def _digits_to_int(s: str) -> int:
    """Read a bare digit string: 三五 -> 35. No 十/百/千 handling."""
    n = 0
    for ch in s:
        n = n * 10 + DIGITS[ch]
    return n


def _tens_to_int(s: str) -> int | None:
    """Read an integer 1-99 written with 十: 十 -> 10, 十二 -> 12, 二十三 -> 23.

    Returns None if the string is not one of those shapes, so callers can skip
    rather than guess.
    """
    if s == "十":
        return 10
    m = re.fullmatch(f"([{DIGIT_CHARS}]?)十([{DIGIT_CHARS}]?)", s)
    if m:
        tens = DIGITS[m.group(1)] if m.group(1) else 1
        ones = DIGITS[m.group(2)] if m.group(2) else 0
        return tens * 10 + ones
    if len(s) == 1 and s in DIGITS:
        return DIGITS[s]
    return None


# X点Y — a decimal. The integer part may use 十 (十二点五); the fractional part
# is read digit by digit (三点一四 -> 3.14), which is how decimals are spoken.
_DECIMAL = re.compile(
    f"(?<![{DIGIT_CHARS}十])"                 # not mid-number
    f"([{DIGIT_CHARS}]|[{DIGIT_CHARS}]?十[{DIGIT_CHARS}]?)"   # integer part
    f"点"
    f"([{DIGIT_CHARS}]+)"                     # fractional digits
    f"(?![{DIGIT_CHARS}十百千万])"             # not followed by more number
)


def _decimal_sub(m: re.Match, text: str) -> str:
    whole, frac = m.group(1), m.group(2)
    # 三点五十分 is a clock time, not 3.50
    tail = text[m.end():m.end() + 1]
    if tail and tail in TIME_MARKERS:
        return m.group(0)
    value = _tens_to_int(whole)
    if value is None:
        return m.group(0)
    return f"{value}.{_digits_to_int(frac) if len(frac) == 1 else ''.join(str(DIGITS[c]) for c in frac)}"


# A numeral glued directly to a Latin word is version-speak — Qwen三, GPT四,
# iPhone十五. Chinese prose never attaches a bare numeral to a Latin word —
# except when the numeral opens a measure phrase: English三个月, Python五年.
# So the guard is a measure-word lookahead, not a blanket CJK one; GPT四更强
# converts while English三个月 stays.
_MEASURE_WORDS = "个月年天号次分秒周岁点时刻位名家场页步倍款条张遍回种类件套间只支部台辆颗粒块片段届期轮折成"
_LATIN_ADJACENT = re.compile(
    f"(?<=[A-Za-z0-9])([{DIGIT_CHARS}十]+)(?![{_MEASURE_WORDS}])"
)


def _latin_adjacent_sub(m: re.Match) -> str:
    s = m.group(1)
    v = _tens_to_int(s)
    if v is None and all(c in DIGITS for c in s):
        v = _digits_to_int(s)
    return str(v) if v is not None else m.group(0)


def convert_chinese_numerals(text: str) -> str:
    """Rewrite spoken decimals as digits. Everything else is left untouched.

    ponytail: decimals and Latin-adjacent numerals only. Bare integers are not converted — 一, 十分, 三 carry
    too many non-numeric readings to rewrite safely without context, and getting
    that wrong corrupts ordinary sentences. Extend only with tests for the traps.
    """
    if not text:
        return text
    text = _DECIMAL.sub(lambda m: _decimal_sub(m, text), text)
    return _LATIN_ADJACENT.sub(_latin_adjacent_sub, text)
