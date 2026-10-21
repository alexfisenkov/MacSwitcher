#!/usr/bin/env python3
"""Build/sign the synthetic input fixture. Never installs or launches the app."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.alexfisenkov.macswitcher.inputfixture"
APP_NAME = "MacSwitcherInputFixture.app"


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, **kwargs)


def validate_output(output):
    if output.name != APP_NAME or output.is_symlink():
        raise ValueError("Output must be a non-symlink MacSwitcherInputFixture.app")
    output = output.resolve()
    for installed in (Path("/Applications"), Path.home() / "Applications"):
        if installed == output or installed in output.parents:
            raise ValueError("Fixture output cannot be inside an Applications directory")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--identity", help="Full Developer ID Application signing identity")
    signing.add_argument("--ad-hoc", action="store_true", help="Explicit local test signing")
    parser.add_argument("--output", type=Path, default=ROOT / ".сборки" / APP_NAME)
    args = parser.parse_args(argv)
    try:
        output = validate_output(args.output.expanduser().absolute())
    except ValueError as error:
        parser.error(str(error))
    if not args.ad_hoc and not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]{10}\)", args.identity or ""):
        parser.error("Use a full Developer ID Application identity or --ad-hoc")
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        parser.error("Fixture build requires an arm64 or x86_64 Mac")
    source = ROOT / "script/fixtures/InputFixture.swift"
    driver = ROOT / "macos/Sources/RuSwitcher/DiagnosticFixtureInputDriver.swift"
    output.parent.mkdir(parents=True, exist_ok=True)
    copied = output.with_name(".MacSwitcherInputFixture.staging-" + uuid.uuid4().hex + ".app")
    try:
        with tempfile.TemporaryDirectory(prefix="macswitcher-input-fixture-") as temporary:
            staged = Path(temporary) / APP_NAME
            contents = staged / "Contents"
            binary = contents / "MacOS/InputFixture"
            binary.parent.mkdir(parents=True)
            # Multiple Swift files require the GUI top-level entry in main.swift.
            fixture_main = Path(temporary) / "main.swift"
            fixture_main.write_bytes(source.read_bytes())
            run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "6", "-O",
                 "-target", arch + "-apple-macos13.0", str(fixture_main), str(driver),
                 "-framework", "AppKit", "-framework", "Carbon", "-o", str(binary)])
            info = {
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleExecutable": "InputFixture",
                "CFBundleName": "MacSwitcher Input Fixture",
                "CFBundleDisplayName": "MacSwitcher Input Fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "0.1",
                "LSMinimumSystemVersion": "13.0",
                "NSPrincipalClass": "MacSwitcherInputFixtureApplication",
                "NSHighResolutionCapable": True,
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
            run(["/usr/bin/xattr", "-cr", str(staged)])
            identity = "-" if args.ad_hoc else args.identity
            command = ["/usr/bin/codesign", "--force", "--sign", identity]
            command += ["--timestamp=none"] if args.ad_hoc else ["--options", "runtime", "--timestamp"]
            run(command + [str(staged)])
            run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(staged)])
            run(["/usr/bin/ditto", "--noextattr", "--norsrc", str(staged), str(copied)])
            run(["/usr/bin/xattr", "-cr", str(copied)])
            run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(copied)])
        if output.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup = output.with_name("MacSwitcherInputFixture.previous-" + stamp + "-" + uuid.uuid4().hex[:8] + ".app")
            os.rename(output, backup)
            print("Previous fixture preserved:", backup)
        os.rename(copied, output)
        run(["/usr/bin/xattr", "-cr", str(output)])
        run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(output)])
    finally:
        if copied.exists():
            shutil.rmtree(copied)
    print(json.dumps({"app": str(output), "binary": str(output / "Contents/MacOS/InputFixture"),
                      "bundle_id": BUNDLE_ID, "architecture": arch,
                      "signing": "ad-hoc-development" if args.ad_hoc else "Developer ID",
                      "launched": False}))


if __name__ == "__main__":
    main()
