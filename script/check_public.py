#!/usr/bin/env python3
"""Check publishable paths, data hashes and manual-only CI; prints no secrets."""
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parent.parent


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_supplemental(manifest, failures):
    supplemental = manifest.get("supplemental_spellings")
    if not isinstance(supplemental, dict) or set(supplemental.get("languages", {})) != {"ru", "en"}:
        failures.append(("dictionaries/manifest.json", "missing supplemental spelling records"))
        return
    modern = supplemental.get("modern_source", {})
    try:
        modern_path = ROOT / modern["path"]
        if file_sha256(modern_path) != modern["sha256"]:
            raise ValueError("modern source hash mismatch")
        rows = [line.split("\t") for line in modern_path.read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")]
        counts = {lang: sum(row[0] == lang for row in rows if len(row) == 2) for lang in ("ru", "en")}
        if (len(rows) != modern["entries"] or counts != modern["counts"] or
                any(len(row) != 2 or row[0] not in counts or len(row[1]) < 2 for row in rows)):
            raise ValueError("modern source count/schema mismatch")
    except (OSError, KeyError, ValueError, UnicodeError) as error:
        failures.append(("dictionaries/manifest.json", f"modern source invalid: {error}"))
    for key in ("ru_source", "en_source"):
        try:
            item = supplemental[key]
            notice = ROOT / item["notice"]
            if file_sha256(notice) != item["notice_sha256"]:
                failures.append((item["notice"], "bundled license hash mismatch"))
        except (OSError, KeyError):
            failures.append(("dictionaries/manifest.json", f"missing {key} bundled license"))
    try:
        if file_sha256(ROOT / "dictionaries/LICENSE-ESDB-Copyright.txt") != supplemental["sources"]["Copyright"]["sha256"]:
            failures.append(("dictionaries/LICENSE-ESDB-Copyright.txt", "ESDB notice hash mismatch"))
    except (OSError, KeyError):
        failures.append(("dictionaries/manifest.json", "missing ESDB notice record"))
    patterns = {"ru": re.compile(r"[а-яё]+(?:-[а-яё]+)*\Z"),
                "en": re.compile(r"[a-z]+(?:['-][a-z]+)*\Z")}
    for language, entry in supplemental["languages"].items():
        try:
            path = ROOT / entry["output"]
            if file_sha256(path) != entry["output_sha256"] or path.stat().st_size != entry["bytes"] or entry["bytes"] >= 100_000_000:
                failures.append((entry["output"], "supplemental hash/size mismatch"))
                continue
            with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                table = database.execute("SELECT sql FROM sqlite_master WHERE name='spellings' AND type='table'").fetchone()
                if not table or "WITHOUT ROWID" not in table[0].upper():
                    raise ValueError("spellings table schema mismatch")
                columns = database.execute("PRAGMA table_info(spellings)").fetchall()
                if [(row[1], row[2], row[3], row[5]) for row in columns] != [("word", "TEXT", 1, 1)]:
                    raise ValueError("spellings columns mismatch")
                metadata = dict(database.execute("SELECT key,value FROM metadata"))
                count = database.execute("SELECT COUNT(*) FROM spellings").fetchone()[0]
                if (database.execute("PRAGMA user_version").fetchone()[0] != 1 or
                        metadata != {"entries": str(count), "language": language} or
                        count != entry["entries"] or database.execute("PRAGMA quick_check").fetchone()[0] != "ok"):
                    raise ValueError("metadata/count/integrity mismatch")
                for (word,) in database.execute("SELECT word FROM spellings"):
                    if not (1 <= len(word) <= 40 and unicodedata.normalize("NFC", word.lower()) == word and patterns[language].fullmatch(word)):
                        raise ValueError("invalid normalized spelling")
                frequency = ROOT / manifest["languages"][language]["full"]["output"]
                database.execute("ATTACH DATABASE ? AS frequency", (frequency.resolve().as_uri() + "?mode=ro&immutable=1",))
                overlap = database.execute("SELECT COUNT(*) FROM spellings s JOIN frequency.frequencies f ON s.word=f.word").fetchone()[0]
                full_count = database.execute("SELECT COUNT(*) FROM frequency.frequencies").fetchone()[0]
                if (overlap != entry["overlap_with_frequency"] or
                        count - overlap != entry["new_unique_against_frequency"] or
                        full_count + count - overlap != entry["union_with_frequency"]):
                    raise ValueError("union/overlap mismatch")
        except (OSError, KeyError, TypeError, ValueError, sqlite3.Error) as error:
            failures.append((entry.get("output", "dictionaries/manifest.json"), f"invalid supplemental SQLite: {error}"))


def main():
    paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    failures = []
    secret_patterns = [
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        r"\bgh[pousr]_[A-Za-z0-9]{30,}\b",
        r"\bgithub_pat_[A-Za-z0-9_]{40,}\b",
        r"\bsk-(?:proj-)?[A-Za-z0-9_-]{35,}\b",
        r"/Users/[A-Za-z][A-Za-z0-9_]+/",
    ]
    for relative in paths:
        if not relative:
            continue
        path = ROOT / relative
        if not path.is_file():
            continue
        parts = Path(relative).parts
        if any(p in {".реестры", ".журналы", ".черновики", ".критики", ".env", "user-dictionary"} for p in parts) or path.suffix in {".p12", ".pem", ".key", ".app", ".zip", ".dmg"}:
            failures.append((relative, "private path/artifact"))
        if path.suffix in {".swift", ".py", ".sh", ".md", ".json", ".plist", ".yml", ".yaml", ".toml"}:
            content = path.read_text(encoding="utf-8")
            if any(re.search(pattern, content) for pattern in secret_patterns):
                failures.append((relative, "credential or private absolute path pattern"))
        if relative.startswith(".github/workflows/"):
            content = path.read_text()
            if re.search(r"^\s*(?:push|pull_request|schedule|release)\s*:", content, re.MULTILINE) or "workflow_dispatch" not in content:
                failures.append((relative, "workflow must be manual-only"))
    manifest = json.loads((ROOT / "dictionaries/manifest.json").read_text())
    if manifest.get("schema") not in (2, 3):
        failures.append(("dictionaries/manifest.json", "unsupported dictionary manifest schema"))
    for language, entry in manifest["languages"].items():
        data = (ROOT / entry["output"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["output_sha256"] or len(data.splitlines()) != entry["entries"]:
            failures.append((entry["output"], f"{language} trigger resource mismatch"))
        full = entry.get("full", {})
        full_path = ROOT / full.get("output", "missing-full-resource")
        if not full_path.is_file():
            failures.append((str(full_path.relative_to(ROOT)), f"{language} full resource missing"))
            continue
        full_data = full_path.read_bytes()
        if hashlib.sha256(full_data).hexdigest() != full.get("output_sha256") or len(full_data) != full.get("bytes"):
            failures.append((full["output"], f"{language} full resource hash/size mismatch"))
        if len(full_data) >= 100_000_000:
            failures.append((full["output"], "database exceeds public per-file size budget"))
        try:
            with closing(sqlite3.connect(full_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                version = database.execute("PRAGMA user_version").fetchone()[0]
                metadata = dict(database.execute("SELECT key, value FROM metadata"))
                schema = database.execute("SELECT sql FROM sqlite_master WHERE name='frequencies'").fetchone()[0]
                count = database.execute("SELECT COUNT(*) FROM frequencies").fetchone()[0]
                invalid = database.execute("SELECT 1 FROM frequencies WHERE frequency<=0 OR word='' LIMIT 1").fetchone()
                healthy = database.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                if (version != 1 or "WITHOUT ROWID" not in schema.upper() or not healthy or invalid
                        or metadata.get("language") != language or metadata.get("entries") != str(count)
                        or count != full.get("entries") or count < entry["entries"]):
                    failures.append((full["output"], f"{language} full SQLite schema/count/integrity mismatch"))
        except (sqlite3.Error, TypeError, IndexError):
            failures.append((full["output"], f"{language} invalid SQLite database"))
    protected = manifest.get("protected_terms", {})
    try:
        source = (ROOT / protected["source"]).read_bytes()
        data = (ROOT / protected["output"]).read_bytes()
        rows = [row.split("\t") for row in data.decode("utf-8").splitlines()]
        counts = {language: sum(row[0] == language for row in rows) for language in ("ru", "en")}
        valid_rows = all(len(row) == 3 and row[0] in counts and row[1]
                         and row[2] in {"brand", "name", "abbreviation", "word", "place"} for row in rows)
        if (hashlib.sha256(source).hexdigest() != protected["source_sha256"]
                or hashlib.sha256(data).hexdigest() != protected["output_sha256"]
                or len(rows) != protected["entries"] or counts != protected["counts"]
                or not valid_rows or len({(row[0], row[1]) for row in rows if len(row) == 3}) != len(rows)):
            failures.append((protected["output"], "curated resource hash/schema/count mismatch"))
    except (KeyError, OSError, UnicodeError):
        failures.append(("dictionaries/manifest.json", "missing/invalid curated resource record"))
    if manifest.get("schema") == 3:
        validate_supplemental(manifest, failures)
    for path, reason in failures:
        print(f"FAIL {path}: {reason}", file=sys.stderr)
    if failures:
        return 1
    print(f"Public checks passed: {sum(bool(p) for p in paths)} files; trigger/full/curated"
          + ("/supplemental" if manifest.get("schema") == 3 else "") + " hashes and counts verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
