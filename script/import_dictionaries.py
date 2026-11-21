#!/usr/bin/env python3
"""Rebuild public trigger/full/curated lexicons from pinned data, never user data."""
import argparse
from collections import Counter
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
# Second frequency source: Wikipedia word counts by Ilya Semenov (MIT script, data from Wikipedia dumps, CC BY-SA).
SECOND_COMMIT = "d11c4fab211156e96ab5943850dd6f98604707fb"
SECOND_URL = "https://raw.githubusercontent.com/IlyaSemenov/wikipedia-word-frequency/" + SECOND_COMMIT + "/results/{name}.txt"
SECOND_SOURCES = {
    "ru": [{"name": "ruwiki-2022-08-29", "kind": "Wikipedia dump 2022-08-29", "sha256": "48c94b85f17afcb1b1cb432601337579a7188b445c42b9324d52c91dc863cf5a"}],
    "en": [{"name": "enwiki-2023-04-13", "kind": "Wikipedia dump 2023-04-13", "sha256": "e2071140a49a6c40c732bd68c36836ef13c0978233fb3d5e1b2a3c2d34faef59"}],
}
SECOND_WEIGHT = 0.2  # share of the subtitle scale given to the second source's rate
SECOND_MIN_LENGTH = 4  # shorter forms are mostly acronyms; they would swallow wrong-layout text
SECOND_MIN_COUNT = 200  # the Wikipedia lists are ~3x the subtitle volume; rarer words are mostly names and noise
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


def second_source_words(raw, language):
    """Words of one Wikipedia list (`word count` lines): case forms summed, same alphabet/length filter as subtitles."""
    words = Counter()
    for line in raw.decode("utf-8").splitlines():
        try:
            word, count = line.rsplit(" ", 1)
            word = unicodedata.normalize("NFC", word.lower())
            count = int(count)
        except ValueError:
            continue
        if count > 0 and 1 <= len(word) <= 40 and re.fullmatch(PATTERNS[language], word):
            words[word] += count
    return dict(words)


def unweighted_spellings(language):
    """Curated modern spellings: present as exact spellings only, never with a frequency."""
    path = ROOT / "dictionaries/modern-spellings-source.tsv"
    rows = [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")]
    return frozenset(unicodedata.normalize("NFC", row[1].lower()) for row in rows if len(row) == 2 and row[0] == language)


def merge_frequencies(base, extras, unweighted=frozenset()):
    """Subtitle counts stay as they are; a word the second source sees often is lifted to its scaled rate.

    Forms shorter than SECOND_MIN_LENGTH (abbreviations that collide with wrong-layout text) and the curated
    modern spellings (`unweighted`, kept frequency-free by design) are left to the subtitles alone."""
    pooled = Counter()
    for words in extras:
        pooled.update(words)
    merged = dict(base)
    scale = SECOND_WEIGHT * sum(base.values()) / sum(pooled.values())
    for word, count in pooled.items():
        if count >= SECOND_MIN_COUNT and len(word) >= SECOND_MIN_LENGTH and word not in unweighted:
            merged[word] = max(merged.get(word, 0), max(1, round(count * scale)))
    return merged


def trigger_selection(base, merged, limit=LIMIT):
    """Top `limit` by merged frequency, except that short subtitle-only forms of the old trigger set stay in."""
    ranked = sorted(base.items(), key=lambda item: (-item[1], item[0]))[:limit]
    pinned = {word for word, _ in ranked if len(word) < SECOND_MIN_LENGTH}
    rest = sorted(((word, count) for word, count in merged.items() if word not in pinned), key=lambda item: (-item[1], item[0]))
    chosen = [(word, merged[word]) for word in pinned] + rest[:limit - len(pinned)]
    return sorted(chosen, key=lambda item: (-item[1], item[0]))


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
        temporary.chmod(0o644)
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


def refresh_supplemental_counts(manifest, resources, full_stages):
    """Overlap/union figures of the spelling bases depend on the frequency base; keep them true."""
    languages = manifest.get("supplemental_spellings", {}).get("languages", {})
    for language, entry in languages.items():
        with closing(sqlite3.connect(resources / f"{language}-spellings.sqlite")) as database:
            database.execute("ATTACH DATABASE ? AS frequency", (str(full_stages[language]),))
            count = database.execute("SELECT COUNT(*) FROM spellings").fetchone()[0]
            overlap = database.execute("SELECT COUNT(*) FROM spellings s JOIN frequency.frequencies f ON s.word=f.word").fetchone()[0]
            full_count = database.execute("SELECT COUNT(*) FROM frequency.frequencies").fetchone()[0]
        entry.update({"overlap_with_frequency": overlap, "new_unique_against_frequency": count - overlap,
                      "union_with_frequency": full_count + count - overlap})


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
            second_raw = {}
            for language, sources in SECOND_SOURCES.items():
                for item in sources:
                    source = source_dir / "second" / f"{item['name']}.txt"
                    if download:
                        source = stage / f"{item['name']}.txt"
                        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "300",
                                        SECOND_URL.format(name=item["name"]), "-o", str(source)], check=True)
                    raw = source.read_bytes()
                    if digest(raw) != item["sha256"]:
                        raise ValueError(f"Second source SHA-256 mismatch for {item['name']}; refusing import")
                    second_raw[item["name"]] = raw
            curated_source = ROOT / "dictionaries/protected-terms-source.tsv"
            curated_raw = curated_source.read_bytes()
            curated = protected_data(curated_raw)
            resources = ROOT / "macos/Sources/RuSwitcher/Resources"
            records = {}
            full_stages = {}
            staged = []
            for language in PATTERNS:
                raw = raw_sources[language]
                subtitle_words = filtered_words(raw, language)
                words = merge_frequencies(subtitle_words, [second_source_words(second_raw[item["name"]], language)
                                                            for item in SECOND_SOURCES[language]], unweighted_spellings(language))
                selected = trigger_selection(subtitle_words, words)
                data = "".join(f"{word}\t{count}\n" for word, count in selected).encode("utf-8")
                output = resources / f"{language}.tsv"
                temporary = stage / output.name
                temporary.write_bytes(data)
                staged.append((temporary, output))
                full_output = output.with_name(language + "-full.sqlite")
                full_stage = stage / full_output.name
                full = write_full_database(full_stage, language, words, reported_output=full_output)
                staged.append((full_stage, full_output))
                full_stages[language] = full_stage
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
            manifest_path = ROOT / "dictionaries/manifest.json"
            manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
            manifest.update({"schema": 3, "upstream": "https://github.com/hermitdave/FrequencyWords", "revision": REVISION,
                "corpus": "OpenSubtitles 2018", "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
                "max_trigger_entries_per_language": LIMIT,
                "transformation": "NFC/lowercase/alphabet and length 1...40 filter/max frequency duplicates; merged with the second source (see second_sources); top 200k by merged frequency descending then lexical for triggers, short subtitle forms of the old trigger set kept; all filtered words sorted into read-only exact SQLite",
                "sqlite_builder_version": sqlite3.sqlite_version, "languages": records, "protected_terms": protected,
                "second_sources": {
                    "name": "wikipedia-word-frequency", "url": "https://github.com/IlyaSemenov/wikipedia-word-frequency",
                    "commit": SECOND_COMMIT, "code_license": "MIT",
                    "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
                    "merge": f"word frequency = max(subtitle count, round({SECOND_WEIGHT} * subtitle total / second total * second count)); second-source words seen fewer than {SECOND_MIN_COUNT} times, shorter than {SECOND_MIN_LENGTH} letters, or listed as curated modern spellings are skipped",
                    "weight": SECOND_WEIGHT, "min_count": SECOND_MIN_COUNT, "min_length": SECOND_MIN_LENGTH,
                    "sources": {language: [{**item, "url": SECOND_URL.format(name=item["name"]), "bytes": len(second_raw[item["name"]])}
                                           for item in items] for language, items in SECOND_SOURCES.items()}}})
            refresh_supplemental_counts(manifest, resources, full_stages)
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
            if download:
                (source_dir / "second").mkdir(parents=True, exist_ok=True)
                for name, raw in second_raw.items():
                    (source_dir / "second" / f"{name}.txt").write_bytes(raw)
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
