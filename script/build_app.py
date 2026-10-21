#!/usr/bin/env python3
"""Build an independently identified macOS bundle. Never installs or starts it."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.alexfisenkov.macswitcher"


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, **kwargs)


def metadata(root, revision, dirty):
    version = json.loads((root / "version.json").read_text())
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version["version"]):
        raise ValueError("Invalid release version")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version["short_version"]):
        raise ValueError("Invalid bundle version")
    if type(version["build"]) is not int or version["build"] < 1:
        raise ValueError("Build number must be a positive integer")
    if version["version"].split("-", 1)[0] != version["short_version"]:
        raise ValueError("Release and bundle versions disagree")
    info = plistlib.loads((root / "macos/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != BUNDLE_ID:
        raise ValueError("Unexpected bundle identity")
    info.update(CFBundleShortVersionString=version["short_version"],
                CFBundleVersion=str(version["build"]),
                MacSwitcherReleaseVersion=version["version"],
                MacSwitcherChannel=version["channel"],
                SourceRevision=revision, SourceDirty=dirty)
    accepted = version.get("native_backend_accepted", False)
    if type(accepted) is not bool:
        raise ValueError("Native backend acceptance must be a boolean")
    info["MacSwitcherNativeBackendAccepted"] = accepted
    # Never bake a private source checkout path or the old personal updater into an app.
    for key in list(info):
        if key.startswith("LocalProject") or key.startswith("LocalUpstream"):
            del info[key]
    return info


def git_state(root):
    revision = run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain", "--untracked-files=normal"],
                     cwd=root, capture_output=True).stdout.strip())
    return revision, dirty


def validate_output(output):
    if output.name != "MacSwitcher.app":
        raise ValueError("Build output must be named MacSwitcher.app")
    if output.parent == Path("/Applications") or output.parent == Path.home() / "Applications":
        raise ValueError("Build output cannot be an installed Applications directory")
    if output.is_symlink():
        raise ValueError("Build output must not be a symlink")


def validate_identity(identity):
    if not identity or not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]{10}\)", identity):
        raise ValueError("Use a full Developer ID Application identity, or explicit --ad-hoc for development")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--identity", help="Explicit Developer ID signing identity")
    signing.add_argument("--ad-hoc", action="store_true", help="Development only: explicitly use ad-hoc signing")
    parser.add_argument("--allow-dirty", action="store_true", help="Mark an experimental build as containing uncommitted source")
    parser.add_argument("--output", type=Path, default=ROOT / ".сборки/MacSwitcher.app")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args(argv)
    output = args.output.expanduser().absolute()
    validate_output(output)
    if not args.ad_hoc:
        validate_identity(args.identity)
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    revision, dirty = git_state(ROOT)
    if dirty and not args.allow_dirty:
        parser.error("Source has uncommitted changes; commit first or explicitly use --allow-dirty")
    info = metadata(ROOT, revision, dirty)
    icon = ROOT / "assets/MacSwitcher.icns"
    if not args.ad_hoc and not icon.is_file():
        parser.error("Signed release requires assets/MacSwitcher.icns")
    run(["swift", "build", "--package-path", str(ROOT / "macos"), "-c", "release", "-j", str(args.jobs),
         "-Xswiftc", "-DMACSWITCHER_APP_BUNDLE"])
    binary_dir = Path(run(["swift", "build", "--package-path", str(ROOT / "macos"),
                           "-c", "release", "--show-bin-path"], capture_output=True).stdout.strip())
    executable = binary_dir / "RuSwitcher"
    if not executable.is_file():
        raise RuntimeError("SwiftPM executable was not produced")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Sign in the system temporary directory: synchronized folders can attach
    # Finder metadata between xattr and codesign, making that check racy.
    # The project and final build output stay in their configured locations.
    with tempfile.TemporaryDirectory(prefix="macswitcher-build-") as temporary:
        staged = Path(temporary) / "MacSwitcher.app"
        contents = staged / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        resources = contents / "Resources"
        resources.mkdir()
        shutil.copy2(executable, contents / "MacOS/RuSwitcher")
        if icon.is_file():
            shutil.copy2(icon, resources / "MacSwitcher.icns")
        # Release-only PredictionResources resolves Contents/Resources explicitly;
        # unit tests continue to use SwiftPM's normal Bundle.module accessor.
        for bundle in binary_dir.glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        licenses = resources / "Licenses"
        licenses.mkdir()
        for filename in ("LICENSE", "NOTICE.md"):
            shutil.copy2(ROOT / filename, licenses / filename)
        dictionary_licenses = licenses / "dictionaries"
        dictionary_licenses.mkdir()
        for document in (ROOT / "dictionaries").iterdir():
            if document.is_file() and document.suffix.lower() not in (".tsv", ".txt"):
                shutil.copy2(document, dictionary_licenses / document.name)
            elif document.is_file() and document.name.startswith(("LICENSE", "COPYING")):
                shutil.copy2(document, dictionary_licenses / document.name)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
        # Finder metadata/resource forks are not sealed application resources.
        # copy2 and a synchronized workspace may carry them into the staged app.
        run(["/usr/bin/xattr", "-cr", str(staged)])
        identity = "-" if args.ad_hoc else args.identity
        command = ["/usr/bin/codesign", "--force", "--sign", identity]
        if args.ad_hoc:
            command += ["--timestamp=none"]
        else:
            command += ["--options", "runtime", "--timestamp"]
        command += ["--entitlements", str(ROOT / "macos/RuSwitcher.entitlements"), str(staged)]
        run(command)
        # Finder/File Provider can reattach metadata while codesign runs.
        # Clear it again before verification; this does not alter sealed bytes.
        run(["/usr/bin/xattr", "-cr", str(staged)])
        run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(staged)])
        run([str(contents / "MacOS/RuSwitcher"), "--self-test-resources"])
        if output.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup = output.with_name("MacSwitcher.previous-" + stamp + "-" + uuid.uuid4().hex[:8] + ".app")
            os.rename(output, backup)
            print("Previous build preserved:", backup)
        shutil.move(str(staged), str(output))
        run(["/usr/bin/xattr", "-cr", str(output)])
        run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(output)])
    print(json.dumps({"app": str(output), "bundle_id": BUNDLE_ID,
                      "version": info["MacSwitcherReleaseVersion"], "source_revision": revision,
                      "source_dirty": dirty, "signing": "ad-hoc-development" if args.ad_hoc else "Developer ID"}))


if __name__ == "__main__":
    main()
