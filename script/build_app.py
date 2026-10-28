#!/usr/bin/env python3
"""Build an independently identified macOS bundle. Never installs or starts it."""
import argparse
import base64
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
UPDATE_FEED = "https://raw.githubusercontent.com/alexfisenkov/MacSwitcher/main/updates/appcast.xml"


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
    output = Path(os.path.abspath(os.path.expanduser(output)))
    if output.name != "MacSwitcher.app":
        raise ValueError("Build output must be named MacSwitcher.app")
    installed_roots = (Path("/Applications"), Path.home() / "Applications",
                       Path("/System/Volumes/Data/Applications"))
    if any(root == output or root in output.parents for root in installed_roots):
        raise ValueError("Build output cannot be inside an installed Applications directory")
    if any(part.is_symlink() for part in (output, *output.parents)):
        raise ValueError("Build output must not use a symlinked path")
    resolved = output.resolve(strict=False)
    if any(root == resolved or root in resolved.parents for root in installed_roots):
        raise ValueError("Build output cannot resolve inside an installed Applications directory")


def validate_identity(identity):
    if not identity or not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]{10}\)", identity):
        raise ValueError("Use a full Developer ID Application identity, or explicit --ad-hoc for development")


def validate_updater_metadata(info):
    if info.get("SUFeedURL") != UPDATE_FEED:
        raise ValueError("Signed release requires the fixed MacSwitcher HTTPS appcast URL")
    try:
        public_key = base64.b64decode(info["SUPublicEDKey"], validate=True)
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Signed release requires a valid Sparkle public EdDSA key") from error
    if len(public_key) != 32:
        raise ValueError("Sparkle public EdDSA key must decode to 32 bytes")
    required = {
        "SUEnableAutomaticChecks": True,
        "SUAllowsAutomaticUpdates": False,
        "SUAutomaticallyUpdate": False,
        "SUEnableSystemProfiling": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
    }
    for key, value in required.items():
        if type(info.get(key)) is not type(value) or info[key] != value:
            raise ValueError(f"Signed release requires {key}={value}")


def sparkle_framework(root):
    # SwiftPM expands Sparkle's signed binary target below .build/artifacts.
    artifact_root = root / "macos/.build/artifacts"
    candidates = sorted(artifact_root.rglob("Sparkle.framework"))
    universal = [path for path in candidates if "macos-arm64_x86_64" in path.parts]
    if len(universal) != 1:
        raise RuntimeError("Expected one universal Sparkle 2.10 framework in SwiftPM artifacts")
    return universal[0]


def require_architectures(path, architectures):
    actual = set(run(["/usr/bin/lipo", "-archs", str(path)], capture_output=True).stdout.split())
    if not set(architectures).issubset(actual):
        raise RuntimeError(f"Missing {', '.join(sorted(set(architectures) - actual))} slice in {path}")


def sign_nested_sparkle(framework, identity, ad_hoc, architectures):
    version = framework / "Versions/Current"
    nested = [
        version / "Autoupdate",
        version / "XPCServices/Downloader.xpc",
        version / "XPCServices/Installer.xpc",
        version / "Updater.app",
    ]
    executables = [
        version / "Sparkle",
        version / "Autoupdate",
        version / "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        version / "XPCServices/Installer.xpc/Contents/MacOS/Installer",
        version / "Updater.app/Contents/MacOS/Updater",
    ]
    for executable in executables:
        if not executable.is_file():
            raise RuntimeError(f"Sparkle executable is missing: {executable}")
        require_architectures(executable, architectures)
    options = ["--timestamp=none"] if ad_hoc else ["--options", "runtime", "--timestamp"]
    for path in nested:
        run(["/usr/bin/codesign", "--force", "--sign", identity, *options,
             "--preserve-metadata=entitlements", str(path)])
    run(["/usr/bin/codesign", "--force", "--sign", identity, *options,
         "--preserve-metadata=entitlements", str(framework)])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--identity", help="Explicit Developer ID signing identity")
    signing.add_argument("--ad-hoc", action="store_true", help="Development only: explicitly use ad-hoc signing")
    parser.add_argument("--allow-dirty", action="store_true", help="Mark an experimental build as containing uncommitted source")
    parser.add_argument("--output", type=Path, default=ROOT / ".сборки/MacSwitcher.app")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--arch", choices=("universal", "arm64", "x86_64"), default="universal",
                        help="Executable architecture; public releases default to both Mac architectures")
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
    if not args.ad_hoc:
        validate_updater_metadata(info)
    icon = ROOT / "assets/MacSwitcher.icns"
    if not args.ad_hoc and not icon.is_file():
        parser.error("Signed release requires assets/MacSwitcher.icns")
    architectures = ("arm64", "x86_64") if args.arch == "universal" else (args.arch,)
    binary_dirs = []
    executables = []
    for arch in architectures:
        arch_flags = ["--build-system", "native", "--arch", arch]
        run(["swift", "build", "--package-path", str(ROOT / "macos"), "-c", "release", "-j", str(args.jobs),
             *arch_flags, "-Xswiftc", "-DMACSWITCHER_APP_BUNDLE",
             "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        binary_dir = Path(run(["swift", "build", "--package-path", str(ROOT / "macos"),
                               "-c", "release", *arch_flags, "--show-bin-path"],
                              capture_output=True).stdout.strip())
        executable = binary_dir / "RuSwitcher"
        if not executable.is_file():
            raise RuntimeError(f"SwiftPM {arch} executable was not produced")
        require_architectures(executable, (arch,))
        linked = run(["/usr/bin/otool", "-L", str(executable)], capture_output=True).stdout
        runpaths = run(["/usr/bin/otool", "-l", str(executable)], capture_output=True).stdout
        if "@rpath/Sparkle.framework/" not in linked or "@executable_path/../Frameworks" not in runpaths:
            raise RuntimeError(f"SwiftPM {arch} executable does not link bundled Sparkle via @rpath")
        binary_dirs.append(binary_dir)
        executables.append(executable)
    framework_source = sparkle_framework(ROOT)
    sparkle_license = framework_source.parents[2] / "LICENSE"
    if not sparkle_license.is_file():
        raise RuntimeError("Sparkle artifact LICENSE is missing")
    validate_output(output)
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
        staged_executable = contents / "MacOS/RuSwitcher"
        if len(executables) == 1:
            shutil.copy2(executables[0], staged_executable)
        else:
            run(["/usr/bin/lipo", "-create", *(str(path) for path in executables),
                 "-output", str(staged_executable)])
            os.chmod(staged_executable, executables[0].stat().st_mode)
        require_architectures(staged_executable, architectures)
        frameworks = contents / "Frameworks"
        frameworks.mkdir()
        framework = frameworks / "Sparkle.framework"
        shutil.copytree(framework_source, framework, symlinks=True)
        if icon.is_file():
            shutil.copy2(icon, resources / "MacSwitcher.icns")
        # Release-only PredictionResources resolves Contents/Resources explicitly;
        # unit tests continue to use SwiftPM's normal Bundle.module accessor.
        for bundle in binary_dirs[0].glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        licenses = resources / "Licenses"
        licenses.mkdir()
        shutil.copy2(sparkle_license, licenses / "Sparkle-LICENSE")
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
        sign_nested_sparkle(framework, identity, args.ad_hoc, architectures)
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
        validate_output(output)
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
