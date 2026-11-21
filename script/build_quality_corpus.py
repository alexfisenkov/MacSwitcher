#!/usr/bin/env python3
"""Build the autocorrection quality corpus from open Tatoeba sentences.

Output is a test resource (not bundled in the app). Every case is a phrase made
of tokens ``[typed, expected, layout]`` (a typo word carries a fourth item, ``"typo"``): what the user's keys produced, what the
text should end up as, and the language of the layout the token was typed in.
Wrong-layout text is produced with the transcribed physical-key table below,
never with the app's own tables, so the corpus is an independent oracle.
Punctuation is dropped on purpose: its keys differ between layout variants.
"""
import argparse
import bz2
import hashlib
import json
from pathlib import Path
import random
import re
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "macos/Tests/RuSwitcherTests/Resources/quality-corpus.json"
BASE_URL = "https://downloads.tatoeba.org/exports/per_language"
FILES = {"ru": ("rus", "rus_sentences.tsv.bz2"), "en": ("eng", "eng_sentences.tsv.bz2")}
LICENSE = "CC BY 2.0 FR"
CATEGORIES = ["wrong-layout", "typo", "caps", "caps-correct", "mixed", "correct"]
DEFAULT_COUNTS = {"wrong-layout": 1200, "typo": 600, "caps": 400, "caps-correct": 300, "mixed": 700, "correct": 1300}

EN_LOWER = "qwertyuiop[]asdfghjkl;'zxcvbnm,.`"
EN_UPPER = 'QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>~'
RU_LOWER = "йцукенгшщзхъфывапролджэячсмитьбюё"
RU_UPPER = RU_LOWER.upper()
EN_TO_RU = dict(zip(EN_LOWER + EN_UPPER, RU_LOWER + RU_UPPER))
RU_TO_EN = dict(zip(RU_LOWER + RU_UPPER, EN_LOWER + EN_UPPER))
CAPS_UNSAFE = {"ru": set("хъжэбюёХЪЖЭБЮЁ"), "en": set("'")}  # keys that are not letters on the other layout
ALLOWED = {"ru": re.compile(r"^[А-Яа-яЁё]+(?:-[А-Яа-яЁё]+)*$"), "en": re.compile(r"^[A-Za-z]+(?:['-][A-Za-z]+)*$")}
PUNCTUATION = re.compile(r"[.,!?;:\"«»“”„—–…()\[\]]")


def to_other_layout(text, language):
    """What the same physical keys give on the opposite layout; ``language`` is the text's own."""
    table = RU_TO_EN if language == "ru" else EN_TO_RU
    return "".join(table.get(ch, ch) for ch in text)


def clean_sentence(raw, language):
    text = PUNCTUATION.sub(" ", raw.replace("’", "'").replace(" ", " "))
    tokens = [t.strip("'") for t in text.split()]
    if not 4 <= len(tokens) <= 10 or len(" ".join(tokens)) > 80:
        return None
    if not all(ALLOWED[language].match(t) for t in tokens):
        return None
    return " ".join(tokens)


def read_sentences(path, language):
    code = FILES[language][0]
    seen, result = set(), []
    with bz2.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3 or parts[1] != code:
                continue
            cleaned = clean_sentence(parts[2], language)
            if cleaned and cleaned.lower() not in seen:
                seen.add(cleaned.lower())
                result.append(cleaned)
    return result


def swap_candidates(word):
    return [i for i in range(1, len(word) - 2)
            if word[i].isalpha() and word[i + 1].isalpha() and word[i].lower() != word[i + 1].lower()]


def has_typo_slot(sentence):
    return any(len(w) >= 5 and swap_candidates(w) for w in sentence.split())


def caps_safe(sentence, language):
    return not any(ch in CAPS_UNSAFE[language] for ch in sentence)


def has_mixed_slot(sentence):
    words = sentence.split()
    return len(words) >= 4 and sum(len(w) >= 3 for w in words) >= 1


def other(language):
    return "en" if language == "ru" else "ru"


def tokens_for(category, sentence, language, rng):
    words, wrong = sentence.split(), other(language)

    def swapped(word):
        return [to_other_layout(word, language), word, wrong]
    if category == "correct":
        return [[w, w, language] for w in words]
    if category == "caps-correct":
        return [[w.upper(), w.upper(), language] for w in words]
    if category == "caps":
        return [[to_other_layout(w.upper(), language), w.upper(), wrong] for w in words]
    if category == "wrong-layout":
        return [swapped(w) for w in words]
    if category == "typo":
        slots = [i for i, w in enumerate(words) if len(w) >= 5 and swap_candidates(w)]
        index = rng.choice(slots)
        position = rng.choice(swap_candidates(words[index]))
        chars = list(words[index])
        chars[position], chars[position + 1] = chars[position + 1], chars[position]
        result = [swapped(w) for w in words]
        result[index][0] = to_other_layout("".join(chars), language)
        result[index].append("typo")  # fourth element marks the word that carries the typo
        return result
    eligible = [i for i, w in enumerate(words) if len(w) >= 3]
    count = 1 if len(eligible) < 2 or rng.random() < 0.5 else 2
    chosen = set(rng.sample(eligible, min(count, len(eligible), len(words) - 1)))
    return [swapped(w) if i in chosen else [w, w, language] for i, w in enumerate(words)]


PREDICATES = {
    "typo": lambda s, lang: has_typo_slot(s),
    "caps": caps_safe,
    "mixed": lambda s, lang: has_mixed_slot(s),
}


def take(pool, count, predicate):
    chosen, rest = [], []
    for sentence in pool:
        if len(chosen) < count and predicate(sentence):
            chosen.append(sentence)
        else:
            rest.append(sentence)
    if len(chosen) < count:
        raise ValueError("not enough source sentences for the requested corpus size")
    pool[:] = rest
    return chosen


def build_corpus(ru_sentences, en_sentences, seed, counts=None):
    counts = counts or DEFAULT_COUNTS
    rng = random.Random(seed)
    cases = []
    for language, sentences in (("ru", ru_sentences), ("en", en_sentences)):
        pool = list(dict.fromkeys(sentences))
        rng.shuffle(pool)
        for category in CATEGORIES:
            check = PREDICATES.get(category)
            picked = take(pool, counts[category], (lambda s: check(s, language)) if check else (lambda s: True))
            for number, sentence in enumerate(picked, 1):
                cases.append({"id": f"qc-{category}-{language}-{number:04d}", "category": category,
                              "language": language, "tokens": tokens_for(category, sentence, language, rng)})
    return {"schema": 1, "seed": seed, "cases": cases}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def download(directory):
    for code, name in FILES.values():
        urllib.request.urlretrieve(f"{BASE_URL}/{code}/{name}", Path(directory) / name)


def write_corpus(corpus, path):
    head = {k: v for k, v in corpus.items() if k != "cases"}
    lines = [json.dumps(case, ensure_ascii=False, separators=(",", ":")) for case in corpus["cases"]]
    body = json.dumps(head, ensure_ascii=False, indent=2)[:-2]
    Path(path).write_text(body + ',\n  "cases": [\n    ' + ",\n    ".join(lines) + "\n  ]\n}\n", encoding="utf-8")


def run(source_dir, output, seed):
    sources = {lang: Path(source_dir) / name for lang, (_, name) in FILES.items()}
    corpus = build_corpus(read_sentences(sources["ru"], "ru"), read_sentences(sources["en"], "en"), seed)
    corpus = {"schema": 1, "seed": seed, "source": {
        "name": "Tatoeba sentences, per-language exports (rus, eng)", "url": "https://tatoeba.org",
        "license": LICENSE, "licenseUrl": "https://creativecommons.org/licenses/by/2.0/fr/",
        "attribution": "Tatoeba contributors",
        "sha256": {lang: sha256(path) for lang, path in sources.items()}}, "cases": corpus["cases"]}
    write_corpus(corpus, output)
    return corpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", help="folder with rus_sentences.tsv.bz2 and eng_sentences.tsv.bz2")
    parser.add_argument("--download", action="store_true", help="fetch the exports into a temporary folder")
    parser.add_argument("--output", default=str(OUTPUT))
    parser.add_argument("--seed", type=int, default=20261121)
    args = parser.parse_args()
    if args.download:
        with tempfile.TemporaryDirectory() as tmp:
            download(tmp)
            corpus = run(tmp, args.output, args.seed)
    elif args.source_dir:
        corpus = run(args.source_dir, args.output, args.seed)
    else:
        parser.error("give --source-dir or --download")
    print(f"{len(corpus['cases'])} cases -> {args.output}")


if __name__ == "__main__":
    main()
