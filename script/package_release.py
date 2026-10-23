#!/usr/bin/env python3
"""Build a local, notarized MacSwitcher release candidate; never publish it."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import posixpath
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
import zipfile
from xml.sax.saxutils import escape

import build_app

ROOT = Path(__file__).resolve().parents[1]
BUILDS = ROOT / ".сборки"
APPCAST = ROOT / "updates/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIGN_UPDATE = ROOT / "macos/.build/artifacts/sparkle/Sparkle/bin/sign_update"
RELEASES = "https://github.com/alexfisenkov/MacSwitcher/releases"


def run(command, *, cwd=None, timeout=None):
    return subprocess.run(command, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def source_state():
    revision, dirty = build_app.git_state(ROOT)
    if dirty:
        raise ValueError("Release requires an exact clean Git checkout")
    return revision


def output_path(path, version):
    base = BUILDS.absolute()
    if base.is_symlink() or any(parent.is_symlink() for parent in base.parents):
        raise ValueError("Build directory must not contain symlinks")
    path = path.expanduser().absolute()
    if path != path.resolve(strict=False):
        raise ValueError("Release output must not traverse symlinks or parent redirects")
    if path == base or base not in path.parents or version not in path.name:
        raise ValueError("Release output must be a versioned directory inside .сборки")
    if path.exists() or path.is_symlink():
        raise ValueError("Release output already exists")
    if any(parent.is_symlink() for parent in path.parents):
        raise ValueError("Release output must not traverse symlinks")
    if any(parent == Path("/Applications") or parent == Path.home() / "Applications"
           for parent in (path, *path.parents)):
        raise ValueError("Release output cannot be in Applications")
    return path


def feed_items(data):
    root = ET.fromstring(data)
    if root.tag != "rss":
        raise ValueError("Unexpected appcast root")
    items = root.findall("./channel/item")
    if not items:
        raise ValueError("Appcast has no releases")
    return items


def version_preflight(version, data):
    items = feed_items(data)
    builds = []
    for item in items:
        builds.append(int(item.findtext(f"{{{SPARKLE}}}version")))
        if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version["version"]:
            raise ValueError("Release version already appears in appcast")
    if version["build"] <= max(builds):
        raise ValueError("Release build must be newer than every appcast item")
    tag = "v" + version["version"]
    tag_check = subprocess.run(["git", "show-ref", "--verify", "--quiet", "refs/tags/" + tag],
                               cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if tag_check.returncode == 0:
        raise ValueError("Release tag already exists")
    if tag_check.returncode != 1:
        raise RuntimeError("Cannot inspect existing release tags")
    return tag


def verify_app(app, version, revision, team):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier") != build_app.BUNDLE_ID or
            info.get("MacSwitcherReleaseVersion") != version["version"] or
            info.get("CFBundleVersion") != str(version["build"]) or
            info.get("SourceRevision") != revision or info.get("SourceDirty") is not False):
        raise ValueError("Built app metadata does not match clean source")
    build_app.validate_updater_metadata(info)
    executable = app / "Contents/MacOS/RuSwitcher"
    architectures = set(run(["/usr/bin/lipo", "-archs", str(executable)]).stdout.split())
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("Release executable is not universal")
    run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)])
    details = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)]).stderr
    if f"TeamIdentifier={team}" not in details or not re.search(r"flags=0x[0-9a-f]+\(runtime\)", details):
        raise ValueError("Developer ID team or hardened runtime missing")
    run([str(executable), "--self-test-resources"])
    return sorted(architectures)


def verify_zip(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or not names:
            raise ValueError("Invalid or duplicate ZIP entries")
        if any((not name.startswith(("MacSwitcher.app/", "__MACOSX/")) or
                ".." in name.split("/") or name.startswith("/")) for name in names):
            raise ValueError("ZIP contains a path outside MacSwitcher.app")
        required = {"MacSwitcher.app/Contents/Info.plist", "MacSwitcher.app/Contents/MacOS/RuSwitcher"}
        if not required.issubset(names):
            raise ValueError("ZIP omits application metadata or executable")
        symlinks = [entry for entry in archive.infolist()
                    if (entry.external_attr >> 16) & 0o170000 == 0o120000]
        if not any("Sparkle.framework/" in entry.filename for entry in symlinks):
            raise ValueError("ZIP does not preserve Sparkle framework symlinks")
        for entry in symlinks:
            target = archive.read(entry).decode("utf-8")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(entry.filename), target))
            if target.startswith("/") or not resolved.startswith("MacSwitcher.app/"):
                raise ValueError("ZIP contains an escaping symlink")
        if archive.testzip() is not None:
            raise ValueError("ZIP has a damaged entry")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return path.stat().st_size, digest


def signature_for_zip(path, account):
    output = run([str(SIGN_UPDATE), "--account", account, str(path)]).stdout
    signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', output)
    length = re.search(r'length="([0-9]+)"', output)
    if not signature or not length or int(length.group(1)) != path.stat().st_size:
        raise ValueError("Sparkle signature or length disagrees with final ZIP")
    run([str(SIGN_UPDATE), "--account", account, "--verify", str(path), signature.group(1)])
    return signature.group(1)


def unsigned_feed(original, version, tag, asset, length, signature):
    text = original.decode("utf-8")
    old_entries = re.findall(r"<item>.*?</item>", text, re.DOTALL)
    tail = re.search(r"<!-- sparkle-signatures:.*?-->\s*$", text, re.DOTALL)
    if not tail or not old_entries:
        raise ValueError("Expected a signed appcast with existing items")
    body = text[:tail.start()]
    first = body.find("    <item>")
    if first < 0:
        raise ValueError("Cannot locate first appcast item")
    release = escape(version["version"])
    notes = escape(version["notes"])
    date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    item = f'''    <item>
      <title>MacSwitcher {release}</title>
      <link>{RELEASES}/tag/{tag}</link>
      <pubDate>{date}</pubDate>
      <description>{notes}</description>
      <sparkle:version>{version["build"]}</sparkle:version>
      <sparkle:shortVersionString>{release}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:channel>{escape(version["channel"])}</sparkle:channel>
      <enclosure url="{RELEASES}/download/{tag}/{asset}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"></enclosure>
    </item>
'''
    candidate = body[:first] + item + body[first:]
    if re.findall(r"<item>.*?</item>", candidate, re.DOTALL)[1:] != old_entries:
        raise ValueError("Existing feed items changed")
    new_item = feed_items(candidate.encode())[0]
    enclosure = new_item.find("enclosure")
    if (new_item.findtext(f"{{{SPARKLE}}}version") != str(version["build"]) or
            enclosure.get("length") != str(length) or
            enclosure.get(f"{{{SPARKLE}}}edSignature") != signature):
        raise ValueError("Candidate appcast mismatch")
    return candidate.encode("utf-8")


def write_notary_receipt(destination, receipt):
    # No raw tool output, arguments, profile, credential values or local paths.
    with (destination / "notary-result.json").open("w") as handle:
        json.dump(receipt, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def validated_submission_id(value):
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def observed_notary_fields(output, error):
    # Tool text may contain private paths or profile names; extract only allowlisted fields.
    combined = "\n".join(part.decode("utf-8", "replace") if isinstance(part, bytes) else part
                         for part in (output, error) if isinstance(part, (bytes, str)))[:8192]
    try:
        parsed = json.loads(combined)
    except (json.JSONDecodeError, ValueError):
        parsed = None
    if isinstance(parsed, dict):
        identifier = validated_submission_id(parsed.get("id"))
        status = parsed.get("status")
    else:
        pattern = r'(?:submission\s+)?\bid\b["\s]*[:=]["\s]*([0-9a-fA-F-]{36})'
        match = re.search(pattern, combined, re.IGNORECASE)
        identifier = validated_submission_id(match.group(1)) if match else None
        status_match = re.search(r'\bstatus\b["\s]*[:=]["\s]*(Accepted|Invalid|In Progress)\b',
                                 combined, re.IGNORECASE)
        status = status_match.group(1) if status_match else None
    if status not in ("Accepted", "Invalid", "In Progress"):
        status = None
    return identifier, status


def accepted_submission(result, destination, receipt):
    submission_id = validated_submission_id(result.get("id"))
    status = result.get("status") if result.get("status") in ("Accepted", "Invalid", "In Progress") else None
    state = "ACCEPTED" if status == "Accepted" and submission_id else (
        "REJECTED" if status == "Invalid" and submission_id else "UNKNOWN")
    receipt.update(state=state, id=submission_id, status=status)
    if state == "UNKNOWN":
        receipt["reason"] = "invalid_result"
    write_notary_receipt(destination, receipt)
    if receipt["state"] != "ACCEPTED":
        raise RuntimeError("Notarization not accepted; candidate retained for diagnosis")
    return submission_id


def submit_notarization(submission, profile, destination, archive_length, archive_sha256):
    receipt = {"state": "IN_PROGRESS", "archive_length": archive_length,
               "archive_sha256": archive_sha256,
               "started_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
               "id": None, "status": None}
    write_notary_receipt(destination, receipt)
    command = ["xcrun", "notarytool", "submit", str(submission),
               "--keychain-profile", profile, "--wait", "--timeout", "60m",
               "--output-format", "json"]
    try:
        response = run(command, timeout=3900)
        try:
            result = json.loads(response.stdout)
        except (json.JSONDecodeError, ValueError):
            identifier, status = observed_notary_fields(response.stdout, response.stderr)
            receipt.update(state="UNKNOWN", id=identifier, status=status, reason="invalid_json")
            write_notary_receipt(destination, receipt)
            raise RuntimeError("Notarization outcome unknown; inspect submission status before any retry") from None
        if not isinstance(result, dict):
            receipt.update(state="UNKNOWN", reason="invalid_result")
            write_notary_receipt(destination, receipt)
            raise RuntimeError("Notarization outcome unknown; inspect submission status before any retry") from None
    except subprocess.CalledProcessError as failure:
        identifier, status = observed_notary_fields(failure.stdout, failure.stderr)
        receipt.update(state="UNKNOWN", id=identifier, status=status,
                       reason="process_exit", returncode=failure.returncode)
        write_notary_receipt(destination, receipt)
        raise RuntimeError("Notarization outcome unknown; inspect submission status before any retry") from None
    except subprocess.TimeoutExpired as failure:
        identifier, status = observed_notary_fields(failure.stdout, failure.stderr)
        receipt.update(state="UNKNOWN", id=identifier, status=status, reason="timeout")
        write_notary_receipt(destination, receipt)
        raise RuntimeError("Notarization outcome unknown; inspect submission status before any retry") from None
    except UnicodeError:
        receipt.update(state="UNKNOWN", reason="output_decode_error")
        write_notary_receipt(destination, receipt)
        raise RuntimeError("Notarization outcome unknown; inspect submission status before any retry") from None
    return accepted_submission(result, destination, receipt)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Full Developer ID Application identity")
    parser.add_argument("--notary-profile", required=True, help="Existing notarytool Keychain profile name")
    parser.add_argument("--sparkle-account", required=True, help="Existing Sparkle signing account in Keychain")
    parser.add_argument("--output-dir", type=Path, help="New versioned directory inside .сборки")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    build_app.validate_identity(args.identity)
    if not args.notary_profile.strip() or not args.sparkle_account.strip() or args.jobs < 1:
        parser.error("Profile, account, and positive jobs are required")
    team = re.search(r"\(([A-Z0-9]{10})\)$", args.identity).group(1)
    revision = source_state()
    version = json.loads((ROOT / "version.json").read_text())
    build_app.validate_updater_metadata(build_app.metadata(ROOT, revision, False))
    original = APPCAST.read_bytes()
    tag = version_preflight(version, original)
    if not SIGN_UPDATE.is_file():
        raise RuntimeError("Sparkle sign_update is absent; resolve pinned SwiftPM artifacts first")
    run([str(SIGN_UPDATE), "--account", args.sparkle_account, "--verify", str(APPCAST)])
    for executable in ("/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/lipo", "/usr/sbin/spctl"):
        if not Path(executable).is_file():
            raise RuntimeError(f"Missing release tool: {executable}")
    destination = args.output_dir or BUILDS / f"release-{version['version']}-{revision[:8]}-{uuid.uuid4().hex[:8]}"
    destination = output_path(destination, version["version"])
    destination.mkdir(parents=True)
    (destination / "previous-appcast.xml").write_bytes(original)
    app = destination / "MacSwitcher.app"
    run([sys.executable, str(ROOT / "script/build_app.py"), "--identity", args.identity,
         "--arch", "universal", "--jobs", str(args.jobs), "--output", str(app)], cwd=ROOT)
    architectures = verify_app(app, version, revision, team)
    submission = destination / "notary-submission.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(submission)])
    submission_length, submission_sha256 = verify_zip(submission)
    submission_id = submit_notarization(submission, args.notary_profile, destination,
                                        submission_length, submission_sha256)
    run(["xcrun", "stapler", "staple", str(app)])
    run(["xcrun", "stapler", "validate", str(app)])
    verify_app(app, version, revision, team)
    run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)])
    asset = f"MacSwitcher-{version['version']}-universal.zip"
    final_zip = destination / asset
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(final_zip)])
    length, sha256 = verify_zip(final_zip)
    signature = signature_for_zip(final_zip, args.sparkle_account)
    candidate = destination / "appcast.xml"
    candidate.write_bytes(unsigned_feed(original, version, tag, asset, length, signature))
    run([str(SIGN_UPDATE), "--account", args.sparkle_account, str(candidate)])
    run([str(SIGN_UPDATE), "--account", args.sparkle_account, "--verify", str(candidate)])
    signed = candidate.read_bytes()
    if len(feed_items(signed)) != len(feed_items(original)) + 1:
        raise ValueError("Signed candidate appcast changed unexpectedly")
    if re.findall(r"<item>.*?</item>", signed.decode("utf-8"), re.DOTALL)[1:] != re.findall(
            r"<item>.*?</item>", original.decode("utf-8"), re.DOTALL):
        raise ValueError("Existing appcast items changed during signing")
    manifest = {"version": version["version"], "build": version["build"], "channel": version["channel"],
                "tag": tag, "asset": asset, "source_revision": revision, "source_dirty": False,
                "bundle_id": build_app.BUNDLE_ID, "architectures": architectures, "team_id": team,
                "notarization_id": submission_id, "notarization_status": "Accepted",
                "stapled": True, "gatekeeper_assessed": True,
                "zip_length": length, "zip_sha256": sha256, "sparkle_ed_signature": signature,
                "appcast_sha256": hashlib.sha256(signed).hexdigest(),
                "previous_appcast_sha256": hashlib.sha256(original).hexdigest(), "published": False}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"candidate": str(destination), "manifest": str(destination / "manifest.json")}))


if __name__ == "__main__":
    main()
