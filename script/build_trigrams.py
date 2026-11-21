#!/usr/bin/env python3
"""Build letter-trigram tables for the autocorrection engine from our own word lists.

Input: the bundled trigger lists macos/Sources/RuSwitcher/Resources/{ru,en}.tsv
(word<TAB>frequency, built by import_dictionaries.py). Output: {ru,en}-trigrams.tsv
next to them, rows ``trigram<TAB>weighted count`` sorted by trigram. A word is padded
as ``^^word$``; each word adds ``int(log2(frequency)) + 1`` to its trigrams (the Swift
``TrigramModel.weight`` uses the same rule). No user data is read.
"""
import argparse
from collections import Counter
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "macos/Sources/RuSwitcher/Resources"
PATTERNS = {"ru": re.compile(r"[а-яё]+(?:-[а-яё]+)*"), "en": re.compile(r"[a-z]+(?:['-][a-z]+)*")}
MAX_BYTES = 2 * 1024 * 1024
MIN_COUNT = 2  # a trigram seen once in one rare word is noise; smoothing covers it


def weight(frequency):
    return 1 if frequency <= 1 else int(math.log2(frequency)) + 1


def trigrams(word):
    padded = "^^" + word + "$"
    return [padded[i:i + 3] for i in range(len(padded) - 2)]


def count_trigrams(rows, language):
    pattern, counts = PATTERNS[language], Counter()
    for word, frequency in rows:
        if frequency > 0 and pattern.fullmatch(word):
            for trigram in trigrams(word):
                counts[trigram] += weight(frequency)
    return counts


def read_rows(path):
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        word, _, value = line.partition("\t")
        rows.append((word, int(value)))
    return rows


def render(counts, min_count=MIN_COUNT):
    lines = [f"{trigram}\t{count}" for trigram, count in sorted(counts.items()) if count >= min_count]
    return "\n".join(lines) + "\n"


def build(resources=RESOURCES, output=None):
    output = output or resources
    sizes = {}
    for language in ("ru", "en"):
        text = render(count_trigrams(read_rows(resources / f"{language}.tsv"), language))
        data = text.encode("utf-8")
        if len(data) > MAX_BYTES:
            raise SystemExit(f"{language} trigram table is {len(data)} bytes, over {MAX_BYTES}")
        (output / f"{language}-trigrams.tsv").write_bytes(data)
        sizes[language] = len(data)
    return sizes


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    for language, size in build(args.resources, args.output).items():
        print(f"{language}-trigrams.tsv: {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
