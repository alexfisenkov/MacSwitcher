#!/usr/bin/env python3
"""Rebuild public lexicons from pinned FrequencyWords files, never user data."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
REVISION = "525f9b560de45753a5ea01069454e72e9aa541c6"
LIMIT = 200_000


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=ROOT / ".черновики/dictionary-source")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    args.source_dir.mkdir(parents=True, exist_ok=True)
    records = {}
    for lang, pattern in [("ru", r"[а-яё]+(?:-[а-яё]+)*"), ("en", r"[a-z]+(?:['-][a-z]+)*")]:
        source = args.source_dir / f"{lang}_full.txt"
        url = f"https://raw.githubusercontent.com/hermitdave/FrequencyWords/{REVISION}/content/2018/{lang}/{lang}_full.txt"
        if args.download:
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "180", url, "-o", str(source)], check=True)
        raw = source.read_bytes()
        words = {}
        for line in raw.decode("utf-8").splitlines():
            try:
                word, count = line.rsplit(" ", 1)
                word = unicodedata.normalize("NFC", word.lower())
                count = int(count)
                if count > 0 and 1 <= len(word) <= 40 and re.fullmatch(pattern, word):
                    words[word] = max(count, words.get(word, 0))
            except ValueError:
                continue
        selected = sorted(words.items(), key=lambda item: (-item[1], item[0]))[:LIMIT]
        data = "".join(f"{word}\t{count}\n" for word, count in selected).encode("utf-8")
        output = ROOT / f"macos/Sources/RuSwitcher/Resources/{lang}.tsv"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)
        records[lang] = {"source_url": url, "source_sha256": digest(raw), "output": str(output.relative_to(ROOT)), "output_sha256": digest(data), "entries": len(selected), "bytes": len(data)}
        print(f"{lang}: {len(selected)} entries, {len(data)} bytes")
    manifest = {"schema": 1, "upstream": "https://github.com/hermitdave/FrequencyWords", "revision": REVISION, "corpus": "OpenSubtitles 2018", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/", "max_entries_per_language": LIMIT, "transformation": "NFC/lowercase/alphabet filter/max frequency duplicates/frequency descending then lexical", "languages": records}
    (ROOT / "dictionaries/manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
