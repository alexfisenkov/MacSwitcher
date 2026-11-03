#!/usr/bin/env python3
"""SHA-256 of a Git commit's file tree, independent of archive compression.

Framing v1: prefix MACSWITCHER-SOURCE-TREE-SHA256-V1 + NUL, then each blob in
raw path-byte order: little-endian u32 path length, path bytes, u8 mode length,
ASCII mode, little-endian u64 blob length, blob bytes. Symlinks are Git blobs
with mode 120000. Gitlinks/submodules are refused.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFIX = b"MACSWITCHER-SOURCE-TREE-SHA256-V1\0"
MODES = {b"100644", b"100755", b"120000"}


def git(*arguments: str) -> bytes:
    try:
        return subprocess.run(["git", "-C", str(ROOT), *arguments],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        raise ValueError("Git source tree is unavailable") from None


def read_entries(revision: str) -> tuple[str, list[tuple[bytes, bytes, bytes]]]:
    if revision != "HEAD" and not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Revision must be HEAD or a 40-character commit ID")
    commit = git("rev-parse", "--verify", revision + "^{commit}").strip().decode("ascii")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid commit ID")
    listing = git("ls-tree", "-r", "-z", "--full-tree", commit)
    if listing and listing[-1:] != b"\0":
        raise ValueError("Invalid Git tree listing")
    entries: list[tuple[bytes, bytes, bytes]] = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        try:
            metadata, path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.split(b" ")
        except ValueError:
            raise ValueError("Invalid Git tree entry") from None
        if mode == b"160000" or kind != b"blob":
            raise ValueError("Submodules or non-blob tree entries are unsupported")
        if mode not in MODES or not path or not re.fullmatch(rb"[0-9a-f]{40}", object_id):
            raise ValueError("Invalid Git tree entry")
        entries.append((path, mode, object_id))
    entries.sort(key=lambda item: item[0])
    if any(entries[index][0] == entries[index - 1][0] for index in range(1, len(entries))):
        raise ValueError("Duplicate Git path")
    return commit, entries


def consume_blob(stream, expected_id: bytes, digest: hashlib._Hash) -> None:
    header = stream.readline(256)
    try:
        object_id, kind, size_text = header.rstrip(b"\n").split(b" ")
        size = int(size_text)
    except (ValueError, OverflowError):
        raise ValueError("Invalid Git blob header") from None
    if object_id != expected_id or kind != b"blob" or size < 0 or size >= 1 << 63:
        raise ValueError("Git blob identity mismatch")
    digest.update(struct.pack("<Q", size))
    remaining = size
    while remaining:
        block = stream.read(min(1024 * 1024, remaining))
        if not block:
            raise ValueError("Truncated Git blob")
        digest.update(block)
        remaining -= len(block)
    if stream.read(1) != b"\n":
        raise ValueError("Invalid Git blob framing")


def source_digest(revision: str) -> str:
    _, entries = read_entries(revision)
    digest = hashlib.sha256(PREFIX)
    with tempfile.TemporaryFile() as requests:
        for _, _, object_id in entries:
            requests.write(object_id + b"\n")
        requests.seek(0)
        process = subprocess.Popen(["git", "-C", str(ROOT), "cat-file", "--batch"],
                                   stdin=requests, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        try:
            if process.stdout is None:
                raise ValueError("Git blob stream unavailable")
            for path, mode, object_id in entries:
                digest.update(struct.pack("<I", len(path)))
                digest.update(path)
                digest.update(struct.pack("<B", len(mode)))
                digest.update(mode)
                consume_blob(process.stdout, object_id, digest)
            if process.stdout.read(1):
                raise ValueError("Unexpected Git blob data")
            if process.wait() != 0:
                raise ValueError("Git blob read failed")
        except Exception:
            process.kill()
            process.wait()
            raise
        finally:
            if process.stdout:
                process.stdout.close()
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default="HEAD")
    arguments = parser.parse_args()
    try:
        print(source_digest(arguments.revision))
    except (OSError, ValueError) as error:
        print("source-digest: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
