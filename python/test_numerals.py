#!/usr/bin/env python3
"""Unit tests for Chinese numeral conversion.

No model, no server — runs anywhere in milliseconds, which is what lets CI
execute it.

    python/test_numerals.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from numerals import convert_chinese_numerals as conv

CONVERT = [
    # The case this was written for
    ("三点五", "3.5"),
    ("那我想是不是又可以用千问三点五", "那我想是不是又可以用千问3.5"),
    # Integer part using 十
    ("十二点五", "12.5"),
    ("二十三点八", "23.8"),
    ("十点五", "10.5"),
    # Multi-digit fraction, read digit by digit
    ("三点一四", "3.14"),
    ("零点九九", "0.99"),
    # Several in one sentence
    ("从三点五涨到四点二", "从3.5涨到4.2"),
    # Surrounded by other text
    ("版本三点五发布了", "版本3.5发布了"),
]

LEAVE_ALONE = [
    # 一 as part of ordinary words — converting these corrupts the sentence
    "等一下再说",
    "我们一起走",
    "跟这个一样",
    "他一直在等",
    "万一出问题呢",
    "第一个问题",
    # 十分 means "very", not "ten minutes"
    "这个十分重要",
    # Weekday, not a quantity
    "星期三开会",
    # 一点 alone is "a little", with no digit after it
    "有一点问题",
    "差一点就成了",
    # Clock time: 三点五十分 is 3:50, not 3.50
    "三点五十分开始",
    "两点半到",
    # Bare integers are out of scope by design
    "三个人",
    "二十三号",
    # Nothing numeric at all
    "今天天气不错",
    "",
]


def main() -> int:
    failures = []

    def check(label, got, want):
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
            print(f"  FAIL {label}")
        else:
            print(f"  ok   {label}")

    print("converts")
    for src, want in CONVERT:
        check(f"{src!r} -> {want!r}", conv(src), want)

    print("leaves alone")
    for src in LEAVE_ALONE:
        check(f"{src!r} unchanged", conv(src), src)

    total = len(CONVERT) + len(LEAVE_ALONE)
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
