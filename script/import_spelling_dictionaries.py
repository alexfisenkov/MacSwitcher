#!/usr/bin/env python3
"""Build pinned, unweighted RU/EN exact spelling databases independently of frequencies."""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import unicodedata
import urllib.request
import zipfile

from import_dictionaries import ROOT, PATTERNS, import_lock

REV_RU = "2.4.417150.4580142"
REV_EN = "7f2f4078354752045ee16a041605686561122185"
RU_URL = "https://files.pythonhosted.org/packages/b0/67/469e9e52d046863f5959928794d3067d455a77f580bf4a662630a43eb426/pymorphy3_dicts_ru-2.4.417150.4580142-py2.py3-none-any.whl"
DAWG_URL = "https://files.pythonhosted.org/packages/6a/84/ff1ce2071d4c650ec85745766c0047ccc3b5036f1d03559fd46bb38b5eeb/DAWG_Python-0.7.2-py2.py3-none-any.whl"
EN_URL = "https://raw.githubusercontent.com/en-wl/wordlist-diff/" + REV_EN + "/{}-large.txt"
COPYRIGHT_URL = "https://raw.githubusercontent.com/en-wl/wordlist-diff/" + REV_EN + "/Copyright"
SOURCES = {
    "ru.whl": (RU_URL, "718bac64c73c10c16073a199402657283d9b64c04188b694f6d3e9b0d85440f4", 12_000_000),
    "dawg.whl": (DAWG_URL, "4941d5df081b8d6fcb4597e073a9f60d5c1ccc9d17cd733e8744d7ecfec94ef3", 100_000),
    "Copyright": (COPYRIGHT_URL, "71bffd4b74ad47fff01c8b3c666e77da92737854e568850d8728024e0a53f304", 100_000),
    "en_US.txt": (EN_URL.format("en_US"), "815abb6f1855304a6c3f358aa1e5ce85823140a547226ce4114386f9b796c30f", 5_000_000),
    "en_GB.txt": (EN_URL.format("en_GB"), "e89e38c3685ba5830f76d804cd6998ba7048d734bd92a97f24855d96b6d26d20", 5_000_000),
    "en_CA.txt": (EN_URL.format("en_CA"), "ca1258552a81db34951374deafaa67bd676a02f0e1a026b14855f6042e46d47d", 5_000_000),
    "en_AU.txt": (EN_URL.format("en_AU"), "16a868afb85faa109be217cae3cf506d7d4eafe128a3a5fbf335ef5ee6d6c73e", 5_000_000),
}
RU_MEMBER = "pymorphy3_dicts_ru/data/words.dawg"
RU_META = "pymorphy3_dicts_ru/data/meta.json"
MODERN = "dictionaries/modern-spellings-source.tsv"
MODERN_SHA256 = "435eb0875367d56bf94e1e8b4b8ffa5f99ea2f0ac81d447565be72b29683ab0a"
STORAGE = "SQLite spellings(word TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID; metadata; user_version=1"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_pinned(name, directory):
    url, expected, limit = SOURCES[name]
    target = directory / name
    if target.is_file():
        if target.stat().st_size > limit or sha256(target) != expected:
            raise ValueError(f"Pinned source SHA-256/size mismatch: {name}")
        return target
    descriptor, filename = tempfile.mkstemp(prefix=name + ".", suffix=".partial", dir=directory)
    candidate = Path(filename)
    try:
        with os.fdopen(descriptor, "wb") as output, urllib.request.urlopen(url, timeout=60) as response:
            if response.url.split(":", 1)[0] != "https":
                raise ValueError("Source redirected away from TLS")
            size = 0
            while block := response.read(1024 * 1024):
                size += len(block)
                if size > limit:
                    raise ValueError(f"Oversized source: {name}")
                output.write(block)
        if sha256(candidate) != expected:
            raise ValueError(f"Pinned source SHA-256 mismatch: {name}")
        candidate.replace(target)
        return target
    finally:
        candidate.unlink(missing_ok=True)


def validated_member(archive, member, limit):
    try:
        info = archive.getinfo(member)
    except KeyError as error:
        raise ValueError(f"Required wheel member missing: {member}") from error
    if info.file_size <= 0 or info.file_size > limit or info.compress_size > limit:
        raise ValueError(f"Invalid wheel member size: {member}")
    return archive.read(info)


def normal(word, language):
    word = unicodedata.normalize("NFC", word.lower())
    if 1 <= len(word) <= 40 and re.fullmatch(PATTERNS[language], word):
        return word
    return None


def ru_words(wheel, reader, stage):
    # The pinned pymorphy3 data format is RecordDAWG >HH; keys may repeat for
    # several morphology records, so SQLite supplies bounded deduplication.
    if sha256(reader) != SOURCES["dawg.whl"][1]:
        raise ValueError("Pinned DAWG reader SHA-256 mismatch")
    sys.path.insert(0, str(reader))
    try:
        import dawg_python
        from dawg_python import RecordDAWG
        if not str(Path(dawg_python.__file__)).startswith(str(reader)):
            raise ValueError("DAWG reader did not load from pinned wheel")
        with zipfile.ZipFile(wheel) as archive:
            meta = dict(json.loads(validated_member(archive, RU_META, 10_000)))
            if (meta.get("source") != "opencorpora.org" or meta.get("source_revision") != "417150"
                    or meta.get("corpus_revision") != "4580142" or meta.get("words_dawg_length") != 5_140_211):
                raise ValueError("Unexpected Russian dictionary metadata")
            data = validated_member(archive, RU_MEMBER, 12_000_000)
        dawg_file = stage / "words.dawg"
        dawg_file.write_bytes(data)
        dictionary = RecordDAWG(">HH").load(str(dawg_file))
        if not dictionary.get("привет"):
            raise ValueError("Russian DAWG format did not decode known word")
        yield from dictionary.iterkeys()
    finally:
        sys.path.remove(str(reader))


def en_words(sources):
    for name in ("en_US.txt", "en_GB.txt", "en_CA.txt", "en_AU.txt"):
        with sources[name].open("r", encoding="utf-8") as stream:
            for line in stream:
                yield line.rstrip("\r\n")


def modern_words(path):
    if not path.is_file():
        raise FileNotFoundError(f"Missing project-curated source: {path}")
    with path.open("r", encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2 or fields[0] not in PATTERNS or normal(fields[1], fields[0]) != fields[1] or len(fields[1]) < 2:
                raise ValueError(f"Invalid modern spelling at line {number}")
            yield fields[0], fields[1]


def write_spelling_database(output, language, source_words, modern, full_path):
    """Write to a private stage; no published resource is touched here."""
    with closing(sqlite3.connect(output, uri=True)) as database:
        database.executescript("""
            PRAGMA page_size=4096;
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            PRAGMA user_version=1;
            CREATE TABLE spellings (word TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
        """)
        batch = []
        source_accepted = 0
        for raw in source_words:
            word = normal(raw, language)
            if word is None:
                continue
            source_accepted += 1
            batch.append((word,))
            if len(batch) == 10_000:
                database.executemany("INSERT OR IGNORE INTO spellings VALUES (?)", batch)
                batch.clear()
        if batch:
            database.executemany("INSERT OR IGNORE INTO spellings VALUES (?)", batch)
        base_entries = database.execute("SELECT COUNT(*) FROM spellings").fetchone()[0]
        database.executemany("INSERT OR IGNORE INTO spellings VALUES (?)", ((word,) for word in modern))
        count = database.execute("SELECT COUNT(*) FROM spellings").fetchone()[0]
        database.execute("ATTACH DATABASE ? AS frequency", (full_path.resolve().as_uri() + "?mode=ro&immutable=1",))
        overlap = database.execute("SELECT COUNT(*) FROM spellings s JOIN frequency.frequencies f ON s.word=f.word").fetchone()[0]
        full_count = database.execute("SELECT COUNT(*) FROM frequency.frequencies").fetchone()[0]
        database.commit()
        database.execute("DETACH DATABASE frequency")
        database.executemany("INSERT INTO metadata VALUES (?, ?)", [("entries", str(count)), ("language", language)])
        database.commit()
        database.execute("VACUUM")
    return {"entries": count, "source_accepted_rows": source_accepted, "source_unique_entries": base_entries,
            "modern_new_entries": count - base_entries, "overlap_with_frequency": overlap,
            "new_unique_against_frequency": count - overlap, "union_with_frequency": full_count + count - overlap}


def import_spellings(source_dir, download=False):
    with import_lock():
        manifest_path = ROOT / "dictionaries/manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("schema") not in (2, 3):
            raise ValueError("Expected existing frequency manifest schema 2 or 3")
        if not manifest.get("languages") or set(manifest["languages"]) != {"ru", "en"}:
            raise ValueError("Missing base frequency records")
        # Check every existing public data product before any new publication.
        for language, record in manifest["languages"].items():
            for item in (record, record["full"]):
                path = ROOT / item["output"]
                if sha256(path) != item["output_sha256"]:
                    raise ValueError(f"Base frequency SHA-256 mismatch: {path.name}")
        protected = manifest["protected_terms"]
        for key, hashkey in (("source", "source_sha256"), ("output", "output_sha256")):
            if sha256(ROOT / protected[key]) != protected[hashkey]:
                raise ValueError("Protected terms SHA-256 mismatch")
        source_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".spelling-import-", dir=ROOT / ".черновики") as directory:
            stage = Path(directory)
            sources = {}
            for name in SOURCES:
                if not download and not (source_dir / name).is_file():
                    raise FileNotFoundError(f"Missing pinned source: {name}; use --download")
                sources[name] = fetch_pinned(name, source_dir)
            modern_path = ROOT / MODERN
            if sha256(modern_path) != MODERN_SHA256:
                raise ValueError("Frozen modern source SHA-256 mismatch")
            modern = list(modern_words(modern_path))
            resource_dir = ROOT / "macos/Sources/RuSwitcher/Resources"
            records = {}
            for language in ("ru", "en"):
                output = resource_dir / f"{language}-spellings.sqlite"
                staged = stage / output.name
                words = ru_words(sources["ru.whl"], sources["dawg.whl"], stage) if language == "ru" else en_words(sources)
                counts = write_spelling_database(staged, language, words, (word for lang, word in modern if lang == language),
                                                  ROOT / manifest["languages"][language]["full"]["output"])
                records[language] = {"output": str(output.relative_to(ROOT)), "output_sha256": sha256(staged),
                    "bytes": staged.stat().st_size, "schema": 1, "storage": STORAGE, **counts}
                if staged.stat().st_size >= 100_000_000:
                    raise ValueError(f"Supplemental database exceeds public file budget: {language}")
            notice_files = ("LICENSE-CC-BY-SA-3.0.txt", "LICENSE-ESDB-Copyright.txt")
            for name in notice_files:
                if not (ROOT / "dictionaries" / name).is_file():
                    raise FileNotFoundError(f"Required bundled license missing: {name}")
            if sha256(ROOT / "dictionaries/LICENSE-ESDB-Copyright.txt") != SOURCES["Copyright"][1]:
                raise ValueError("Bundled ESDB notice SHA-256 mismatch")
            source_records = {name: {"url": url, "sha256": expected, "bytes": sources[name].stat().st_size}
                              for name, (url, expected, _) in SOURCES.items()}
            manifest["schema"] = 3
            manifest["supplemental_spellings"] = {
                "transformation": "NFC/lowercase/alphabet and length 1...40; distinct exact spellings only, no frequency or runtime writes",
                "sqlite_builder_version": sqlite3.sqlite_version,
                "sources": source_records,
                "ru_source": {"name": "pymorphy3-dicts-ru", "version": REV_RU,
                              "underlying_data": "OpenCorpora", "license": "CC-BY-SA-3.0",
                              "license_url": "https://creativecommons.org/licenses/by-sa/3.0/",
                              "notice": "dictionaries/LICENSE-CC-BY-SA-3.0.txt",
                              "notice_sha256": sha256(ROOT / "dictionaries/LICENSE-CC-BY-SA-3.0.txt")},
                "en_source": {"name": "English Speller Database", "revision": REV_EN,
                              "license": "ESDB attribution notice", "notice": "dictionaries/LICENSE-ESDB-Copyright.txt",
                              "notice_sha256": sha256(ROOT / "dictionaries/LICENSE-ESDB-Copyright.txt")},
                "modern_source": {"path": MODERN, "sha256": sha256(modern_path), "entries": len(modern),
                                  "counts": {lang: sum(x[0] == lang for x in modern) for lang in ("ru", "en")},
                                  "license": "CC0-1.0", "license_url": "https://creativecommons.org/publicdomain/zero/1.0/"},
                "languages": records,
            }
            staged_manifest = stage / "manifest.json"
            staged_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            if sha256(modern_path) != MODERN_SHA256:
                raise ValueError("Modern source changed during staging")
            # Same lock covers all resources. Manifest is the final publication marker.
            for language in ("ru", "en"):
                (stage / f"{language}-spellings.sqlite").replace(resource_dir / f"{language}-spellings.sqlite")
            staged_manifest.replace(manifest_path)
            for language, entry in records.items():
                print(f"{language}: {entry['entries']:,} spellings; {entry['new_unique_against_frequency']:,} new unique vs frequency; {entry['bytes']:,} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=ROOT / ".черновики/dictionary-expansion-alpha21/sources-canonical")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    import_spellings(args.source_dir, args.download)


if __name__ == "__main__":
    main()
