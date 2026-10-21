#!/usr/bin/env python3
"""Rebuild public trigger/full/curated lexicons from pinned data, never user data."""
import argparse
from contextlib import closing, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
REVISION = "525f9b560de45753a5ea01069454e72e9aa541c6"
LIMIT = 200_000
SOURCE_HASHES = {
    "ru": "32dfd94138aea2667ec455dcc8512029e39bd4b8ea70b09410d569b69d511a30",
    "en": "7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506",
}
PATTERNS = {"ru": r"[а-яё]+(?:-[а-яё]+)*", "en": r"[a-z]+(?:['-][a-z]+)*"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def filtered_words(raw, language):
    words = {}
    for line in raw.decode("utf-8").splitlines():
        try:
            word, count = line.rsplit(" ", 1)
            word = unicodedata.normalize("NFC", word.lower())
            count = int(count)
            if count > 0 and 1 <= len(word) <= 40 and re.fullmatch(PATTERNS[language], word):
                words[word] = max(count, words.get(word, 0))
        except ValueError:
            continue
    return words


@contextmanager
def import_lock():
    """One owner for source verification, staging, resources and final manifest."""
    state = ROOT / ".черновики"
    state.mkdir(parents=True, exist_ok=True)
    with (state / "dictionary-import.lock").open("a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another dictionary import is in progress") from error
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def write_full_database(output, language, words, reported_output=None):
    """Stable sorted insertion + VACUUM, no timestamps or machine-local paths."""
    descriptor, filename = tempfile.mkstemp(prefix=output.name + ".", suffix=".partial", dir=output.parent)
    os.close(descriptor)
    temporary = Path(filename)
    try:
        with closing(sqlite3.connect(temporary)) as database:
            database.executescript("""
                PRAGMA page_size=4096;
                PRAGMA journal_mode=OFF;
                PRAGMA synchronous=OFF;
                PRAGMA user_version=1;
                CREATE TABLE frequencies (word TEXT PRIMARY KEY NOT NULL, frequency INTEGER NOT NULL CHECK(frequency > 0)) WITHOUT ROWID;
                CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
            """)
            database.executemany("INSERT INTO frequencies VALUES (?, ?)", sorted(words.items()))
            database.executemany("INSERT INTO metadata VALUES (?, ?)", [("entries", str(len(words))), ("language", language)])
            database.commit()
            database.execute("VACUUM")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    data = output.read_bytes()
    return {"output": str((reported_output or output).relative_to(ROOT)), "output_sha256": digest(data),
            "entries": len(words), "bytes": len(data), "schema": 1,
            "storage": "SQLite frequencies(word TEXT PRIMARY KEY, frequency INTEGER) WITHOUT ROWID; metadata; user_version=1"}


def protected_data(raw):
    terms = {}
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or fields[0] not in PATTERNS or fields[2] not in {"brand", "name", "abbreviation", "word", "place"}:
            raise ValueError(f"Invalid curated term row {number}")
        language, term, category = fields
        term = unicodedata.normalize("NFC", term.lower())
        if not re.fullmatch(PATTERNS[language], term) or not 2 <= len(term) <= 40:
            raise ValueError(f"Invalid curated spelling at row {number}")
        terms[(language, term)] = category
    return "".join(f"{language}\t{term}\t{category}\n" for (language, term), category in sorted(terms.items())).encode("utf-8")


def import_project(source_dir, download=False):
    """All inputs are pinned/validated before publishing; manifest is replaced last."""
    with import_lock():
        source_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".dictionary-import-", dir=ROOT / ".черновики") as directory:
            stage = Path(directory)
            raw_sources = {}
            source_urls = {}
            for language in PATTERNS:
                url = f"https://raw.githubusercontent.com/hermitdave/FrequencyWords/{REVISION}/content/2018/{language}/{language}_full.txt"
                source_urls[language] = url
                source = source_dir / f"{language}_full.txt"
                if download:
                    source = stage / f"{language}_source.txt"
                    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "180", url, "-o", str(source)], check=True)
                raw = source.read_bytes()
                if digest(raw) != SOURCE_HASHES[language]:
                    raise ValueError(f"Pinned upstream SHA-256 mismatch for {language}; refusing import")
                raw_sources[language] = raw
            curated_source = ROOT / "dictionaries/protected-terms-source.tsv"
            curated_raw = curated_source.read_bytes()
            curated = protected_data(curated_raw)
            resources = ROOT / "macos/Sources/RuSwitcher/Resources"
            records = {}
            staged = []
            for language in PATTERNS:
                raw = raw_sources[language]
                words = filtered_words(raw, language)
                selected = sorted(words.items(), key=lambda item: (-item[1], item[0]))[:LIMIT]
                data = "".join(f"{word}\t{count}\n" for word, count in selected).encode("utf-8")
                output = resources / f"{language}.tsv"
                temporary = stage / output.name
                temporary.write_bytes(data)
                staged.append((temporary, output))
                full_output = output.with_name(language + "-full.sqlite")
                full_stage = stage / full_output.name
                full = write_full_database(full_stage, language, words, reported_output=full_output)
                staged.append((full_stage, full_output))
                records[language] = {"source_url": source_urls[language], "source_sha256": digest(raw),
                    "output": str(output.relative_to(ROOT)), "output_sha256": digest(data), "entries": len(selected), "bytes": len(data), "full": full}
                print(f"{language}: {len(selected):,} trigger entries; {len(words):,} full entries; {full['bytes']:,} SQLite bytes")
            output = resources / "protected-terms.tsv"
            temporary = stage / output.name
            temporary.write_bytes(curated)
            staged.append((temporary, output))
            counts = {language: sum(line.startswith(language + "\t") for line in curated.decode().splitlines()) for language in PATTERNS}
            protected = {"source": str(curated_source.relative_to(ROOT)), "source_sha256": digest(curated_raw),
                "output": str(output.relative_to(ROOT)), "output_sha256": digest(curated), "entries": len(curated.splitlines()),
                "counts": counts, "bytes": len(curated),
                "provenance": "Project-curated public spellings of brands, technology, common given/family names, IT words and place names; no personal contacts or user text",
                "license": "CC0-1.0", "license_url": "https://creativecommons.org/publicdomain/zero/1.0/"}
            manifest = {"schema": 2, "upstream": "https://github.com/hermitdave/FrequencyWords", "revision": REVISION,
                "corpus": "OpenSubtitles 2018", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
                "max_trigger_entries_per_language": LIMIT,
                "transformation": "NFC/lowercase/alphabet and length 1...40 filter/max frequency duplicates; top 200k frequency descending then lexical for triggers; all filtered words sorted into read-only exact SQLite",
                "sqlite_builder_version": sqlite3.sqlite_version, "languages": records, "protected_terms": protected}
            manifest_stage = stage / "manifest.json"
            manifest_stage.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            if download:
                # Cache only pinned bytes, using per-file staging on its own volume.
                for language, raw in raw_sources.items():
                    descriptor, filename = tempfile.mkstemp(prefix=language + "_full.", suffix=".partial", dir=source_dir)
                    try:
                        with os.fdopen(descriptor, "wb") as cache:
                            cache.write(raw)
                        Path(filename).replace(source_dir / f"{language}_full.txt")
                    finally:
                        Path(filename).unlink(missing_ok=True)
            # Every artifact is complete before replacing published files. A concurrent
            # importer cannot enter; an interrupted publication is detected against the
            # previous manifest by check_public rather than accepted as a valid set.
            resources.mkdir(parents=True, exist_ok=True)
            for temporary, destination in staged:
                temporary.replace(destination)
            (ROOT / "dictionaries").mkdir(parents=True, exist_ok=True)
            manifest_stage.replace(ROOT / "dictionaries/manifest.json")
            print(f"protected public terms: {protected['entries']:,}; {counts}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=ROOT / ".черновики/dictionary-source")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    import_project(args.source_dir, args.download)


if __name__ == "__main__":
    main()
