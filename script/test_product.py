#!/usr/bin/env python3
"""Small product-contract tests; never reads or writes real user preferences."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "script" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProductTests(unittest.TestCase):
    def test_migration_refuses_renamed_running_bundle_by_identity(self):
        migration = load("migrate_settings")
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "MacSwitcher Alpha.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": migration.TARGET}))
            commands = SimpleNamespace(stdout=str(app / "Contents/MacOS/RuSwitcher") + "\n")
            with patch.object(migration.subprocess, "run", return_value=commands):
                with self.assertRaisesRegex(RuntimeError, "Quit MacSwitcher"):
                    migration.require_target_stopped()
    def test_metadata_has_own_identity_and_no_source_path(self):
        build = load("build_app")
        info = build.metadata(ROOT, "a" * 40, False)
        self.assertEqual(info["CFBundleIdentifier"], "com.alexfisenkov.macswitcher")
        self.assertEqual(info["CFBundleDisplayName"], "MacSwitcher")
        self.assertEqual(info["SourceRevision"], "a" * 40)
        self.assertTrue(info["LocalCombinedShiftDefault"])
        self.assertNotIn("LocalProjectRoot", info)
        self.assertNotIn(b"/Users/", plistlib.dumps(info))

    def test_native_rollout_metadata_requires_explicit_boolean_acceptance(self):
        build = load("build_app")
        version = build.json.loads((ROOT / "version.json").read_text())
        for accepted in (False, True):
            with patch.object(build.json, "loads", return_value={**version, "native_backend_accepted": accepted}):
                info = build.metadata(ROOT, "a" * 40, False)
                self.assertIs(info["MacSwitcherNativeBackendAccepted"], accepted)
        for malformed in ("false", 0, 1, None):
            with patch.object(build.json, "loads", return_value={**version, "native_backend_accepted": malformed}):
                with self.assertRaisesRegex(ValueError, "acceptance must be a boolean"):
                    build.metadata(ROOT, "a" * 40, False)

    def test_builder_refuses_installed_or_symlink_target(self):
        build = load("build_app")
        with self.assertRaises(ValueError):
            build.validate_output(Path("/Applications/MacSwitcher.app"))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "MacSwitcher.app"
            output.symlink_to(Path(directory) / "other")
            with self.assertRaises(ValueError):
                build.validate_output(output)

    def test_release_identity_cannot_silently_be_ad_hoc(self):
        build = load("build_app")
        for identity in ("-", "", "Apple Development: Example (0123456789)"):
            with self.assertRaises(ValueError):
                build.validate_identity(identity)
        build.validate_identity("Developer ID Application: Example Developer (0123456789)")

    def test_migration_excludes_privileged_private_and_malformed_keys(self):
        migration = load("migrate_settings")
        source = {
            "com.ruswitcher.combinedShiftEnabled": True,
            "com.ruswitcher.autoConvert": False,
            "com.ruswitcher.layout1ID": "com.apple.keylayout.US",
            "com.ruswitcher.debugLog": True,
            "com.ruswitcher.permissionsWereGranted": True,
            "com.ruswitcher.launchAtLogin": True,
            "LocalProjectRoot": "/private/source",
            "com.ruswitcher.deniedWords": ["synthetic-example"],
            "com.ruswitcher.deniedAppsAdded": [42],
            "com.ruswitcher.triggerDoubleTap": "YES",
        }
        result = migration.select_preferences(source)
        self.assertEqual(set(result), {
            "com.ruswitcher.combinedShiftEnabled", "com.ruswitcher.autoConvert",
            "com.ruswitcher.layout1ID", "com.ruswitcher.deniedWords",
        })
        self.assertIs(result["com.ruswitcher.autoConvert"], False)

    def test_updater_cannot_launch_old_installer_or_vendor_feed(self):
        paths = [ROOT / "macos/Sources/RuSwitcher" / name
                 for name in ("UpdateChecker.swift", "LocalUpdateBridge.swift")]
        source = "\n".join(path.read_text() for path in paths)
        for forbidden in ("Process()", "update_local.py", "hdiutil", "rashn/RuSwitcher", "raw.githubusercontent.com"):
            self.assertNotIn(forbidden, source)
        self.assertIn("api.github.com/repos/", source)
        self.assertIn("/releases/tag/", source)


if __name__ == "__main__":
    unittest.main()
