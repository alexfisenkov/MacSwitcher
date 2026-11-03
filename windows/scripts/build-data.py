#!/usr/bin/env python3
"""Build the Windows MSLEXW01 dictionary bundle from the pinned MacSwitcher sources."""
from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import os
import shutil
import sqlite3
import struct
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "macos/Sources/RuSwitcher/Resources"
SOURCE_MANIFEST = ROOT / "dictionaries/manifest.json"
STRIDE = 128
MAGIC = b"MSLEXW01"


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def sha_info(path: Path) -> dict:
    return {"sha256": digest(path), "size": path.stat().st_size}


def check_pinned(path: Path, expected_hash: str) -> None:
    actual = digest(path)
    if actual != expected_hash:
        raise ValueError(f"Pinned hash mismatch for {path.relative_to(ROOT)}: {actual}")


def db_rows(path: Path, query: str):
    uri = "file:" + path.as_posix() + "?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    cursor = connection.execute(query)
    try:
        for row in cursor:
            yield row
    finally:
        cursor.close()
        connection.close()


def terms(path: Path, language: str):
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[0] == language:
            yield fields[1], fields[2]


def build_language(language: str, output: Path, manifest: dict) -> tuple[Path, int, int]:
    source_language = manifest["languages"][language]
    full_path = RES / f"{language}-full.sqlite"
    spell_path = RES / f"{language}-spellings.sqlite"
    protected_path = RES / "protected-terms.tsv"
    check_pinned(RES / f"{language}.tsv", source_language["output_sha256"])
    check_pinned(full_path, source_language["full"]["output_sha256"])
    check_pinned(spell_path, manifest["supplemental_spellings"]["languages"][language]["output_sha256"])
    check_pinned(protected_path, manifest["protected_terms"]["output_sha256"])

    full = ((word, 0, frequency) for word, frequency in db_rows(full_path, "SELECT word, frequency FROM frequencies ORDER BY word"))
    spellings = ((word, 1, 0) for (word,) in db_rows(spell_path, "SELECT word FROM spellings ORDER BY word"))
    protected = ((word, 2, 0) for word, _ in terms(protected_path, language))
    merged = heapq.merge(full, spellings, protected, key=lambda row: row[0])

    temp_records = output.with_suffix(output.suffix + ".records.tmp")
    sparse = []
    record_count = 0
    protected_only_count = 0
    try:
        with temp_records.open("wb") as records:
            current_word = None
            frequency = 0
            flags = 0

            def emit(word: str, freq: int, word_flags: int) -> None:
                nonlocal record_count, protected_only_count
                encoded = word.encode("utf-8", "strict")
                if not encoded or len(encoded) > 160:
                    raise ValueError(f"Word UTF-8 size invalid: {word!r}")
                if word != unicodedata.normalize("NFC", word).lower():
                    raise ValueError(f"Word is not normalized lowercase NFC: {word!r}")
                if record_count % STRIDE == 0:
                    sparse.append((encoded, records.tell()))
                if word_flags == 2 and freq == 0:
                    protected_only_count += 1
                records.write(struct.pack("<H", len(encoded)))
                records.write(encoded)
                records.write(struct.pack("<iB", freq, word_flags))
                record_count += 1

            for word, kind, value in merged:
                if current_word is not None and word != current_word:
                    emit(current_word, frequency, flags)
                    frequency = 0
                    flags = 0
                if word != current_word:
                    current_word = word
                if kind == 2:
                    flags |= 2
                elif kind == 1:
                    flags |= 1
                else:
                    frequency = max(frequency, int(value))
            if current_word is not None:
                emit(current_word, frequency, flags)

        index_size = sum(2 + len(word) + 8 + 4 for word, _ in sparse)
        header_size = 24
        with output.open("wb") as target, temp_records.open("rb") as records:
            target.write(MAGIC)
            target.write(struct.pack("<IIQ", STRIDE, len(sparse), record_count))
            for block_number, (word, relative_offset) in enumerate(sparse):
                target.write(struct.pack("<H", len(word)))
                target.write(word)
                target.write(struct.pack("<QI", header_size + index_size + relative_offset, min(STRIDE, record_count - block_number * STRIDE)))
            shutil.copyfileobj(records, target, 1024 * 1024)
    finally:
        temp_records.unlink(missing_ok=True)
    return output, record_count, protected_only_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "windows/data")
    args = parser.parse_args()
    pinned = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    source_files = {
        "ru.tsv": (RES / "ru.tsv", pinned["languages"]["ru"]["output_sha256"]),
        "en.tsv": (RES / "en.tsv", pinned["languages"]["en"]["output_sha256"]),
        "protected-terms.tsv": (RES / "protected-terms.tsv", pinned["protected_terms"]["output_sha256"]),
        "prediction-benchmark.json": (RES / "prediction-benchmark.json", None),
    }
    for name, (source, expected) in source_files.items():
        if expected:
            check_pinned(source, expected)
        shutil.copyfile(source, output / name)
    shutil.copyfile(SOURCE_MANIFEST, output / "dictionary-source-manifest.json")
    for name in ("LICENSE-CC-BY-SA-3.0.txt", "LICENSE-CC-BY-SA-4.0.txt", "LICENSE-ESDB-Copyright.txt", "NOTICE.md"):
        shutil.copyfile(ROOT / "dictionaries" / name, output / name)

    counts = {}
    protected_only = {}
    for language in ("ru", "en"):
        _, counts[language], protected_only[language] = build_language(language, output / f"{language}.lex", pinned)
    expected_base = sum(pinned["supplemental_spellings"]["languages"][lang]["union_with_frequency"] for lang in ("ru", "en"))
    actual_base = sum(counts.values()) - sum(protected_only.values())
    if expected_base != 5_198_408 or actual_base != expected_base:
        raise ValueError(f"Frequency+spelling source union mismatch: expected {expected_base}, got {actual_base}; records={counts}, protected_only={protected_only}")

    tracked = {name: sha_info(output / name) for name in ("ru.tsv", "en.tsv", "protected-terms.tsv", "ru.lex", "en.lex")}
    provenance_names = list(source_files) + ["dictionary-source-manifest.json", "ru.lex", "en.lex", "LICENSE-CC-BY-SA-3.0.txt", "LICENSE-CC-BY-SA-4.0.txt", "LICENSE-ESDB-Copyright.txt", "NOTICE.md"]
    provenance = {name: sha_info(output / name) for name in provenance_names}
    document = {
        "schema": 1,
        "format": "MSLEXW01",
        "recordStride": STRIDE,
        "files": tracked,
        "source": {
            "repository": "MacSwitcher dictionaries/manifest.json",
            "manifestSha256": digest(SOURCE_MANIFEST),
            "counts": counts,
            "baseFrequencySpellingUnion": expected_base,
            "protectedOnlyEntries": protected_only,
            "protectedInclusiveBinaryCount": sum(counts.values()),
            "sourceFiles": provenance,
            "upstreamRevision": pinned["revision"],
            "frequencyCorpus": pinned["corpus"],
            "provenance": "Generated from pinned MacSwitcher frequency, spelling, and protected-term sources; no user text or inferred frequencies.",
            "licenses": {
                "frequency": pinned["license"],
                "protectedTerms": pinned["protected_terms"]["license"],
                "notices": ["LICENSE-CC-BY-SA-3.0.txt", "LICENSE-CC-BY-SA-4.0.txt", "LICENSE-ESDB-Copyright.txt", "NOTICE.md"]
            }
        }
    }
    (output / "dictionary-manifest.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(output), "binaryCounts": counts, "baseFrequencySpellingUnion": expected_base, "protectedOnlyEntries": protected_only, "protectedInclusiveBinaryCount": sum(counts.values()), "manifest": sha_info(output / "dictionary-manifest.json")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
