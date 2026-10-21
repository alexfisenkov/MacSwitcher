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

ROOT = Path(__file__).resolve().parent.parent


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
    if manifest.get("schema") != 2:
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
    for path, reason in failures:
        print(f"FAIL {path}: {reason}", file=sys.stderr)
    if failures:
        return 1
    print(f"Public checks passed: {sum(bool(p) for p in paths)} files; trigger/full SQLite/curated hashes and counts verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
