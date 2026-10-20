#!/usr/bin/env python3
"""Check publishable paths, data hashes and manual-only CI; prints no secrets."""
import hashlib
import json
from pathlib import Path
import re
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
    for language, entry in manifest["languages"].items():
        data = (ROOT / entry["output"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["output_sha256"] or len(data.splitlines()) != entry["entries"]:
            failures.append((entry["output"], f"{language} resource mismatch"))
    for path, reason in failures:
        print(f"FAIL {path}: {reason}", file=sys.stderr)
    if failures:
        return 1
    print(f"Public checks passed: {sum(bool(p) for p in paths)} files; dictionary hashes verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
