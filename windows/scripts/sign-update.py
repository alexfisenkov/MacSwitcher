#!/usr/bin/env python3
"""Initialize the local Windows update trust anchor and sign a release candidate.

Private material stays outside the repository at ~/.local/share/macswitcher/windows-update-signing.
This tool never publishes or launches an installer.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = ROOT / "windows/src/MacSwitcher.Core/Resources/windows-update-public-key.json"
PRIVATE_DIR = Path.home() / ".local/share/macswitcher/windows-update-signing"
PRIVATE = PRIVATE_DIR / "private.pem"
REPO_URL = "https://github.com/alexfisenkov/MacSwitcher/releases/download/"
VERSION_PATTERN = re.compile(r"0\.[0-9]+\.[0-9]+(?:-alpha\.[1-9][0-9]*)?\Z")
MAX_ASSET = 512 * 1024 * 1024
PLACEHOLDER = '{"keyId":"UNINITIALIZED","modulus":"","exponent":""}\n'


def run_openssl(*args: str, data: bytes | None = None) -> bytes:
    try:
        result = subprocess.run(["openssl", *args], input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        raise RuntimeError("OpenSSL operation failed; private key was not printed") from None
    return result.stdout


def der_item(blob: bytes, offset: int) -> tuple[int, bytes, int]:
    if offset >= len(blob):
        raise ValueError("Invalid public key DER")
    tag = blob[offset]
    offset += 1
    if offset >= len(blob):
        raise ValueError("Invalid public key DER")
    length = blob[offset]
    offset += 1
    if length & 0x80:
        width = length & 0x7f
        if width == 0 or width > 4 or offset + width > len(blob):
            raise ValueError("Invalid public key DER")
        length = int.from_bytes(blob[offset:offset + width], "big")
        offset += width
    if offset + length > len(blob):
        raise ValueError("Invalid public key DER")
    return tag, blob[offset:offset + length], offset + length


def parse_spki(blob: bytes) -> tuple[bytes, bytes]:
    tag, sequence, end = der_item(blob, 0)
    if tag != 0x30 or end != len(blob):
        raise ValueError("Invalid public key SPKI")
    algorithm_tag, _, offset = der_item(sequence, 0)
    bit_tag, bits, offset = der_item(sequence, offset)
    if algorithm_tag != 0x30 or bit_tag != 0x03 or offset != len(sequence) or not bits or bits[0] != 0:
        raise ValueError("Invalid public key SPKI")
    rsa_tag, rsa, end = der_item(bits, 1)
    if rsa_tag != 0x30 or end != len(bits):
        raise ValueError("Invalid RSA public key")
    mod_tag, modulus, offset = der_item(rsa, 0)
    exp_tag, exponent, offset = der_item(rsa, offset)
    if mod_tag != 0x02 or exp_tag != 0x02 or offset != len(rsa):
        raise ValueError("Invalid RSA public key")
    if modulus[:1] == b"\0":
        modulus = modulus[1:]
    if len(modulus) != 384 or exponent != b"\x01\x00\x01":
        raise ValueError("Expected RSA-3072 with exponent 65537")
    return modulus, exponent


def private_ready() -> None:
    if not PRIVATE.exists() or PRIVATE.is_symlink() or not PRIVATE.is_file():
        raise ValueError("Private signing key is absent")
    if PRIVATE_DIR.stat().st_mode & 0o077 or PRIVATE.stat().st_mode & 0o077:
        raise ValueError("Signing key permissions are too broad")


def public_document() -> dict[str, str]:
    private_ready()
    spki = run_openssl("pkey", "-in", str(PRIVATE), "-pubout", "-outform", "DER")
    modulus, exponent = parse_spki(spki)
    return {
        "keyId": hashlib.sha256(spki).hexdigest()[:32],
        "modulus": base64.b64encode(modulus).decode("ascii"),
        "exponent": base64.b64encode(exponent).decode("ascii"),
    }


def init_key(public_output: Path) -> None:
    if public_output.resolve() != PUBLIC.resolve():
        raise ValueError("Public trust anchor must be the Core embedded resource")
    PRIVATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    if PRIVATE_DIR.is_symlink() or PRIVATE_DIR.stat().st_mode & 0o077:
        raise ValueError("Signing directory permissions are too broad")
    if not PRIVATE.exists():
        fd, temp_name = tempfile.mkstemp(prefix=".key-", suffix=".pem", dir=PRIVATE_DIR)
        os.close(fd)
        try:
            run_openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", temp_name)
            os.chmod(temp_name, 0o600)
            os.link(temp_name, PRIVATE)  # fails closed if another key was created meanwhile
        finally:
            Path(temp_name).unlink(missing_ok=True)
    document = public_document()
    rendered = json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
    if PUBLIC.exists():
        existing = PUBLIC.read_text(encoding="utf-8")
        if existing != PLACEHOLDER and existing != rendered:
            raise ValueError("Embedded public key differs from private signer; refusing rotation")
        if existing == rendered:
            print(json.dumps({"keyId": document["keyId"], "publicOutput": str(PUBLIC), "unchanged": True}))
            return
    PUBLIC.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".public-", dir=PUBLIC.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(rendered)
        os.replace(temp_name, PUBLIC)
    finally:
        Path(temp_name).unlink(missing_ok=True)
    print(json.dumps({"keyId": document["keyId"], "publicOutput": str(PUBLIC)}))


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_info(path: Path, name: str, tag: str) -> dict[str, object]:
    if not path.is_file() or path.is_symlink() or path.name != name:
        raise ValueError("Artifact filename does not match the release contract")
    size = path.stat().st_size
    if size <= 0 or size > MAX_ASSET:
        raise ValueError("Artifact size exceeds release contract")
    return {"name": name, "sha256": digest_file(path), "size": size,
            "url": REPO_URL + tag + "/" + name}


def sign(setup: Path, portable: Path, package_manifest: Path, output: Path) -> None:
    private_ready()
    expected_public = json.dumps(public_document(), sort_keys=True, separators=(",", ":")) + "\n"
    if not PUBLIC.exists() or PUBLIC.read_text(encoding="utf-8") != expected_public:
        raise ValueError("Embedded public key does not match signer")
    version_data = json.loads((ROOT / "windows/version.json").read_text(encoding="utf-8"))
    version = version_data.get("version")
    build = version_data.get("build")
    tag = version_data.get("tag")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version) or not isinstance(build, int) or build <= 0 or tag != "windows-v" + version:
        raise ValueError("Invalid Windows version metadata")
    package_data = json.loads(package_manifest.read_text(encoding="utf-8-sig"))
    source_revision = package_data.get("sourceRevision")
    source_sha256 = package_data.get("sourceSha256")
    if not (
        isinstance(source_revision, str) and re.fullmatch(r"[0-9a-f]{40}", source_revision)
        and isinstance(source_sha256, str) and re.fullmatch(r"[0-9a-f]{64}", source_sha256)
        and package_data.get("schema") == 1 and package_data.get("version") == version
        and package_data.get("build") == build and package_data.get("tag") == tag
        and package_data.get("platform") == "windows" and package_data.get("signed") is False
        and package_data.get("sourceDirty") is False
    ):
        raise ValueError("Package manifest identity does not match the Windows version")
    try:
        source_result = subprocess.run(
            [sys.executable, str(ROOT / "windows/scripts/source-digest.py"), "--revision", source_revision],
            cwd=ROOT, check=True, capture_output=True, text=True,
        )
    except subprocess.CalledProcessError:
        raise ValueError("Unable to reproduce package source digest") from None
    if source_result.stdout.strip() != source_sha256:
        raise ValueError("Package source tree digest mismatch")
    setup_name = f"MacSwitcher-Windows-{version}-Setup.exe"
    portable_name = f"MacSwitcher-Windows-{version}-portable.zip"
    setup_info = file_info(setup, setup_name, tag)
    portable_info = file_info(portable, portable_name, tag)
    packages = package_data.get("packages")
    if not isinstance(packages, dict) or set(packages) != {setup_name, portable_name}:
        raise ValueError("Package manifest asset list does not match")
    for item in (setup_info, portable_info):
        expected = packages[item["name"]]
        if not isinstance(expected, dict) or expected.get("sha256") != item["sha256"] or expected.get("size") != item["size"]:
            raise ValueError("Package artifact differs from package manifest")
    payload = {
        "schema": 1, "version": version, "build": build, "tag": tag,
        "sourceRevision": source_revision,
        "assets": [setup_info, portable_info],
    }
    data = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    signature = run_openssl("dgst", "-sha256", "-sign", str(PRIVATE), data=data)
    envelope = {"algorithm": "RSA-SHA256", "payload": base64.b64encode(data).decode("ascii"),
                "signature": base64.b64encode(signature).decode("ascii")}
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".windows-update-", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            target.write(json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n")
        os.replace(temp_name, output)
    finally:
        Path(temp_name).unlink(missing_ok=True)
    print(json.dumps({"output": str(output), "version": version, "build": build,
                      "tag": tag, "sourceRevision": source_revision,
                      "assets": [{"name": item["name"], "size": item["size"], "sha256": item["sha256"]}
                                 for item in payload["assets"]]}))


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    initialize = sub.add_parser("init-key")
    initialize.add_argument("--public-output", type=Path, default=PUBLIC)
    signing = sub.add_parser("sign")
    signing.add_argument("--setup", type=Path, required=True)
    signing.add_argument("--portable", type=Path, required=True)
    signing.add_argument("--package-manifest", type=Path, required=True)
    signing.add_argument("--output", type=Path, default=ROOT / "windows/updates/windows.json")
    arguments = parser.parse_args()
    try:
        if arguments.command == "init-key":
            init_key(arguments.public_output)
        else:
            sign(arguments.setup, arguments.portable, arguments.package_manifest, arguments.output)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("sign-update: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
