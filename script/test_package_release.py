#!/usr/bin/env python3
"""Offline contract tests for the public release packager."""
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_release as release


class PackageReleaseTests(unittest.TestCase):
    SUBMISSION_ID = "12345678-1234-4234-8234-123456789abc"

    def test_output_is_versioned_new_directory_inside_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / ".сборки"
            base.mkdir()
            with patch.object(release, "BUILDS", base):
                valid = base / "release-0.1.0-alpha.15"
                self.assertEqual(release.output_path(valid, "0.1.0-alpha.15"), valid)
                for invalid in (Path(directory) / "release-0.1.0-alpha.15", base / "release-14"):
                    with self.assertRaises(ValueError):
                        release.output_path(invalid, "0.1.0-alpha.15")
                valid.mkdir()
                with self.assertRaisesRegex(ValueError, "already exists"):
                    release.output_path(valid, "0.1.0-alpha.15")
                symlink = base / "symlink"
                symlink.symlink_to(Path(directory), target_is_directory=True)
                with self.assertRaises(ValueError):
                    release.output_path(symlink / "release-0.1.0-alpha.15", "0.1.0-alpha.15")
                with self.assertRaises(ValueError):
                    release.output_path(Path("/Applications/release-0.1.0-alpha.15"), "0.1.0-alpha.15")

    def test_source_must_be_exact_clean_checkout(self):
        with patch.object(release.build_app, "git_state", return_value=("a" * 40, True)):
            with self.assertRaisesRegex(ValueError, "clean Git"):
                release.source_state()

    def test_appcast_adds_item_and_preserves_old_items(self):
        original = release.APPCAST.read_bytes()
        version = {"version": "0.1.0-alpha.15", "build": 15, "channel": "alpha", "notes": "Safe <update> & Undo"}
        result = release.unsigned_feed(original, version, "v0.1.0-alpha.15",
                                       "MacSwitcher-0.1.0-alpha.15-universal.zip", 1234, "QUJD")
        items = release.feed_items(result)
        self.assertEqual(len(items), len(release.feed_items(original)) + 1)
        self.assertEqual(items[0].findtext(f"{{{release.SPARKLE}}}version"), "15")
        self.assertIn(b"Safe &lt;update&gt; &amp; Undo", result)
        self.assertNotIn(b"sparkle-signatures:", result)

    def test_version_must_advance_and_tag_must_be_unused(self):
        feed = release.APPCAST.read_bytes()
        with self.assertRaisesRegex(ValueError, "newer"):
            release.version_preflight({"version": "0.1.0-alpha.15", "build": 14}, feed)
        with patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
            with self.assertRaisesRegex(ValueError, "tag already exists"):
                release.version_preflight({"version": "0.1.0-alpha.15", "build": 15}, feed)

    def test_zip_requires_bundle_and_safe_framework_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("MacSwitcher.app/Contents/Info.plist", b"plist")
                archive.writestr("MacSwitcher.app/Contents/MacOS/RuSwitcher", b"binary")
                entry = zipfile.ZipInfo("MacSwitcher.app/Contents/Frameworks/Sparkle.framework/Versions/Current")
                entry.create_system = 3
                entry.external_attr = 0o120777 << 16
                archive.writestr(entry, "A")
            length, digest = release.verify_zip(path)
            self.assertEqual(length, path.stat().st_size)
            self.assertEqual(len(digest), 64)
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("../escape", b"bad")
            with self.assertRaisesRegex(ValueError, "outside"):
                release.verify_zip(path)

    def test_notary_rejection_is_recorded_and_stops_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "not accepted"):
                release.accepted_submission({"id": self.SUBMISSION_ID, "status": "Invalid"},
                                            destination, {"archive_sha256": "f" * 64})
            recorded = json.loads((destination / "notary-result.json").read_text())
            self.assertEqual(recorded["state"], "REJECTED")
            self.assertEqual(recorded["id"], self.SUBMISSION_ID)

    def test_accepted_without_valid_id_remains_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "not accepted"):
                release.accepted_submission({"id": "private credential value", "status": "Accepted"},
                                            destination, {"archive_sha256": "f" * 64})
            recorded = json.loads((destination / "notary-result.json").read_text())
            self.assertEqual(recorded["state"], "UNKNOWN")
            self.assertIsNone(recorded["id"])
            self.assertEqual(recorded["reason"], "invalid_result")

    def test_notary_unknown_failures_record_receipt_before_submit_and_stop(self):
        cases = {
            "process_exit": subprocess.CalledProcessError(
                74, ["xcrun", "notarytool"],
                output=f'{{"id":"{self.SUBMISSION_ID}","status":"Accepted"}}',
                stderr="private credential value"),
            "timeout": subprocess.TimeoutExpired(
                ["xcrun", "notarytool"], 3900,
                output=f'{{"id":"{self.SUBMISSION_ID}"', stderr="private path"),
            "invalid_json": SimpleNamespace(stdout=f'{{"id":"{self.SUBMISSION_ID}"',
                                                stderr="private config"),
            "output_decode_error": UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid byte"),
        }
        for expected_reason, outcome in cases.items():
            with self.subTest(expected_reason), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory)
                submission = destination / "notary-submission.zip"
                submission.write_bytes(b"archive")
                seen = []

                def fake_run(command, **kwargs):
                    seen.append((command, kwargs))
                    in_progress = json.loads((destination / "notary-result.json").read_text())
                    self.assertEqual(in_progress["state"], "IN_PROGRESS")
                    self.assertEqual(in_progress["archive_sha256"], "f" * 64)
                    self.assertIn("started_utc", in_progress)
                    if isinstance(outcome, Exception):
                        raise outcome
                    return outcome

                with patch.object(release, "run", side_effect=fake_run):
                    with self.assertRaisesRegex(RuntimeError, "outcome unknown"):
                        release.submit_notarization(submission, "selector-only", destination, 7, "f" * 64)
                self.assertEqual(len(seen), 1)
                self.assertEqual(seen[0][1]["timeout"], 3900)
                recorded_text = (destination / "notary-result.json").read_text()
                recorded = json.loads(recorded_text)
                self.assertEqual(recorded["state"], "UNKNOWN")
                self.assertEqual(recorded["reason"], expected_reason)
                self.assertEqual(recorded["id"], None if expected_reason == "output_decode_error"
                                 else self.SUBMISSION_ID)
                if expected_reason == "process_exit":
                    self.assertEqual(recorded["returncode"], 74)
                self.assertNotIn("private", recorded_text)
                self.assertNotIn("selector-only", recorded_text)
                self.assertFalse((destination / "appcast.xml").exists())
                self.assertFalse(any(destination.glob("MacSwitcher-*-universal.zip")))

    def test_full_pipeline_orders_commands_and_retains_existing_feed(self):
        original = release.APPCAST.read_bytes()
        version = {"version": "0.1.0-alpha.15", "short_version": "0.1.0", "build": 15,
                   "channel": "alpha", "notes": "Offline test", "native_backend_accepted": False}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            builds = root / ".сборки"
            builds.mkdir()
            appcast = root / "appcast.xml"
            appcast.write_bytes(original)
            (root / "version.json").write_text(json.dumps(version))
            tool = root / "sign_update"
            tool.touch()
            destination = builds / "release-0.1.0-alpha.15"
            calls = []

            def fake_run(command, **_kwargs):
                calls.append(command)
                if command[0] == sys.executable:
                    (destination / "MacSwitcher.app").mkdir()
                elif command[0] == "/usr/bin/ditto":
                    Path(command[-1]).write_bytes(b"zip")
                if "notarytool" in command:
                    return SimpleNamespace(stdout=json.dumps({"id": self.SUBMISSION_ID, "status": "Accepted"}), stderr="")
                return SimpleNamespace(stdout="", stderr="")

            with patch.multiple(release, ROOT=root, BUILDS=builds, APPCAST=appcast, SIGN_UPDATE=tool), \
                 patch.object(release, "source_state", return_value="a" * 40), \
                 patch.object(release, "version_preflight", return_value="v0.1.0-alpha.15"), \
                 patch.object(release.build_app, "metadata", return_value={}), \
                 patch.object(release.build_app, "validate_updater_metadata"), \
                 patch.object(release, "run", side_effect=fake_run), \
                 patch.object(release, "verify_app", return_value=["arm64", "x86_64"]), \
                 patch.object(release, "verify_zip", return_value=(3, "f" * 64)), \
                 patch.object(release, "signature_for_zip", return_value="QUJD"):
                release.main(["--identity", "Developer ID Application: Example (0123456789)",
                              "--notary-profile", "notary-selector", "--sparkle-account", "sparkle-selector",
                              "--output-dir", str(destination)])
            flattened = [" ".join(call) for call in calls]
            positions = [next(i for i, call in enumerate(flattened) if needle in call)
                         for needle in ("build_app.py", "notarytool submit", "stapler staple", "spctl --assess",
                                        "MacSwitcher-0.1.0-alpha.15-universal.zip", str(destination / "appcast.xml"))]
            self.assertEqual(positions, sorted(positions))
            self.assertEqual(appcast.read_bytes(), original)
            self.assertEqual((destination / "previous-appcast.xml").read_bytes(), original)
            manifest = json.loads((destination / "manifest.json").read_text())
            self.assertFalse(manifest["published"])
            self.assertEqual(manifest["zip_sha256"], "f" * 64)


if __name__ == "__main__":
    unittest.main()
