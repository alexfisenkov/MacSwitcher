#!/usr/bin/env python3
"""Selectively migrate local preferences. Default is a read-only dry run."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "com.alexfisenkov.ruswitcher.local"
TARGET = "com.alexfisenkov.macswitcher"
PREFIX = "com.ruswitcher."
BOOLS = {
    "autoSwitch", "perAppLayout", "triggerRightOnly", "triggerDoubleTap",
    "combinedShiftEnabled", "switchDoubleTap", "switchRightOnly", "caseDoubleTap",
    "caseRightOnly", "autoConvert", "smartConversion", "convertByText", "convertWholeLine",
    "remoteDesktopMode", "showRemoteDesktopBeta", "keySound", "caretFlag", "secureInputNotice",
    "hideMenuBarIcon", "monochromeIcon",
}
STRINGS = {"layout1ID", "layout2ID", "interfaceLanguage", "triggerKey", "switchHotkey", "caseHotkey"}
LISTS = {"deniedAppsAdded", "deniedAppsRemoved", "deniedWords", "alwaysConvertWords"}


def select_preferences(source):
    result = {}
    for key, value in source.items():
        if not key.startswith(PREFIX):
            continue
        name = key[len(PREFIX):]
        valid = ((name in BOOLS and type(value) is bool)
                 or (name in STRINGS and isinstance(value, str))
                 or (name in LISTS and isinstance(value, list)
                     and all(isinstance(item, str) for item in value)))
        if valid:
            result[key] = value
    return result


def read_domain(domain):
    result = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True)
    if result.returncode != 0:
        # defaults does not distinguish a missing domain with a dedicated code.
        # Only an actual absent plist may become an empty destination/source.
        path = Path.home() / "Library/Preferences" / (domain + ".plist")
        if not path.exists():
            return {}
        raise RuntimeError("Could not read preference domain " + domain)
    value = plistlib.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("Preference domain is not a dictionary")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Back up destination, then import selected settings")
    parser.add_argument("--backup-dir", type=Path, default=ROOT / ".журналы/settings-migration")
    args = parser.parse_args(argv)
    source = read_domain(SOURCE)
    selected = select_preferences(source)
    target = read_domain(TARGET)
    # New app has its own identity: do not carry permission, update, debug, or
    # launch-at-login flags across. Existing destination values survive by default.
    additions = {key: value for key, value in selected.items() if key not in target}
    if not args.apply:
        print(json.dumps({"status": "dry-run", "source": SOURCE, "target": TARGET,
                          "selected_keys": sorted(additions), "preserved_target_keys": len(target)}))
        return
    if not additions:
        print(json.dumps({"status": "unchanged", "reason": "No new allowlisted settings"}))
        return
    directory = args.backup_dir.expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    backup = directory / (stamp + "-before.plist")
    merged_file = directory / (stamp + "-merged.plist")
    for path, value in ((backup, target), (merged_file, {**target, **additions})):
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            plistlib.dump(value, stream)
    if read_domain(TARGET) != target:
        raise RuntimeError("Destination preferences changed during migration; nothing imported")
    subprocess.run(["/usr/bin/defaults", "import", TARGET, str(merged_file)], check=True, capture_output=True)
    actual = read_domain(TARGET)
    if any(actual.get(key) != value for key, value in additions.items()):
        raise RuntimeError("Preference import read-back failed; destination backup preserved")
    print(json.dumps({"status": "migrated", "count": len(additions), "backup": str(backup),
                      "source_unchanged": True}))


if __name__ == "__main__":
    main()
