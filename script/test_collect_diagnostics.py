"""Synthetic contract checks; never read the owner's unified log or preferences."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("collect_diagnostics", Path(__file__).with_name("collect_diagnostics.py"))
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
TEMP_ROOT = str(Path(tempfile.gettempdir()).resolve())


def line(message, tick, seconds=1000, **extra):
    return json.dumps({"timestamp": "2026-11-16 10:00:00.000000+0800",
                       "machTimestamp": tick, "processID": 765,
                       "threadID": 42, "subsystem": collector.SUBSYSTEM,
                       "category": collector.CATEGORY, "eventMessage": message,
                       **extra})


class CollectorTests(unittest.TestCase):
    def test_exact_closed_vocabulary_and_no_sensitive_payload(self):
        for message in ("combined.codex.word.refused", "failure.wordNativeEditRefused",
                        "doubleRecognized", "tapDisabledTimeout", "recoveryArchiveFailed"):
            event = collector.parse_line(line(message, 1))
            self.assertEqual(event["event"], message)
            self.assertEqual(set(event), {"id", "time", "event"})
        for message in ("soloReceived", "autoUnicodePresent", "combined.browser.word.confirmed URL secret",
                        "combined.com.secret.word.refused", "failure.wordNativeEditRefused password",
                        "keyDown.42", "selectionAXWritePosted"):
            self.assertIsNone(collector.parse_line(line(message, 2)))
        self.assertIsNone(collector.parse_line(line("combined.codex.word.refused", 2,
                                            subsystem="other")))
        private = collector.parse_line(line("combined.chrome.word.refused", 9,
                                            windowTitle="Secret draft", url="https://secret.invalid",
                                            keyCode=42, clipboard="Private text"))
        self.assertEqual(set(private), {"id", "time", "event"})
        self.assertNotIn("Secret", json.dumps(private))
        self.assertNotIn("765", json.dumps(private))
        self.assertIsNone(collector.parse_line(line("doubleRecognized", 10,
                                            processImagePath="fixture/Test.app/Contents/MacOS/Test")))

    def test_new_combined_matrix_is_closed(self):
        for family in collector.FAMILIES:
            for operation in collector.OPERATIONS:
                for outcome in collector.RESULTS:
                    self.assertTrue(collector.allowed_event("combined.%s.%s.%s" %
                                                            (family, operation, outcome)))
        self.assertFalse(collector.allowed_event("combined.chrome.word.confirmed.extra"))
        self.assertFalse(collector.allowed_event("combined.chrome.typing.confirmed"))
        self.assertTrue(collector.allowed_event("automatic.chrome.uncertain"))
        self.assertFalse(collector.allowed_event("automatic.chrome.confirmed"))

    def test_streaming_log_reader_uses_only_exact_fixture_rows(self):
        fixture = "\n".join((line("combined.chrome.word.refused", 11,
                                  processImagePath="fixture/MacSwitcher.app/Contents/MacOS/RuSwitcher"),
                             line("combined.chrome.word.refused", 12,
                                  processImagePath="fixture/xctest", timestamp="invalid"),
                             line("autoUnicodePresent", 12),
                             line("automatic.chrome.uncertain", 13))) + "\n"
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "log.ndjson"
            path.write_text(fixture)
            original_popen = subprocess.Popen
            def fake_popen(_command, **kwargs):
                return original_popen(["/bin/cat", str(path)], **kwargs)
            moment = collector.parse_line(line("doubleRecognized", 1))["time"]
            with patch.object(collector.subprocess, "Popen", side_effect=fake_popen):
                found = collector.fetch_logs(moment - 1, moment + 1)
            self.assertEqual([row["event"] for row in found],
                             ["combined.chrome.word.refused", "automatic.chrome.uncertain"])

    def test_allowlist_matches_swift_closed_outcome_cases(self):
        source = (Path(__file__).resolve().parents[1] /
                  "macos/Sources/RuSwitcher/Editing/CombinedShiftEditing.swift").read_text()
        family = re.search(r"enum CombinedShiftApplicationFamily[^{}]*\{\s*[^\n]*\n\s*case ([^\n]+)", source)
        operation = re.search(r"enum Operation: String[^{}]*\{ case ([^}]+) \}", source)
        result = re.search(r"enum Result: String[^{}]*\{ case ([^}]+) \}", source)
        self.assertIsNotNone(family)
        self.assertIsNotNone(operation)
        self.assertIsNotNone(result)
        cases = lambda match: frozenset(word.strip() for word in match.group(1).split(","))
        self.assertEqual(collector.FAMILIES, cases(family))
        self.assertEqual(collector.OPERATIONS, cases(operation))
        self.assertEqual(collector.RESULTS, cases(result))
        diagnostics = (Path(__file__).resolve().parents[1] /
                       "macos/Sources/RuSwitcher/RuntimeDiagnostics.swift").read_text()
        event_body = diagnostics.split("enum RuntimeDiagnosticEvent:", 1)[1].split("var logOnce:", 1)[0]
        failure_body = diagnostics.split("enum RuntimeDiagnosticFailureReason:", 1)[1].split("enum RuntimeDiagnostics", 1)[0]
        def enum_cases(body):
            return frozenset(name.strip() for line in body.splitlines()
                             if line.strip().startswith("case ")
                             for name in line.strip()[5:].split(","))
        self.assertTrue((collector.DOUBLE_EVENTS | collector.HEALTH_EVENTS |
                         collector.EDIT_FAILURE_EVENTS) <= enum_cases(event_body))
        self.assertEqual(collector.FAILURES, enum_cases(failure_body))

    def test_distinct_events_survive_overlap_and_repeat_is_idempotent(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            rows = [collector.parse_line(line("combined.codex.word.refused", tick)) for tick in (1, 2)]
            state = collector.empty_state()
            collector.merge(state, rows, 1000)
            collector.merge(state, rows, 1001)
            self.assertEqual(len(state["events"]), 2)

    def test_age_count_and_size_bounds(self):
        state = collector.empty_state()
        rows = [{"id": str(i), "time": i, "event": "doubleFailed"} for i in range(50)]
        collector.merge(state, rows, 50, max_age=20, max_events=5, max_bytes=800)
        self.assertEqual(len(state["events"]), 5)
        self.assertTrue(all(row["time"] >= 30 for row in state["events"]))
        self.assertLessEqual(len(json.dumps(state).encode()), 800)

    def test_disabled_never_fetches_and_reenable_starts_now(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            calls = []
            def fetch(start, end):
                calls.append((start, end))
                return []
            collector.run_once(Path(directory), now=1000, enabled=lambda: False, fetch=fetch)
            collector.run_once(Path(directory), now=1100, enabled=lambda: True, fetch=fetch)
            self.assertEqual(calls, [])
            collector.run_once(Path(directory), now=1160, enabled=lambda: True, fetch=fetch)
            self.assertEqual(calls, [(1100, 1160)])

    def test_long_backfill_advances_only_completed_pages(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            calls = []
            def fetch(start, end):
                calls.append((start, end))
                return []
            collector.run_once(path, now=100000, enabled=lambda: True, fetch=fetch, initial_hours=2)
            state = collector.read_store(path)
            self.assertEqual(len(calls), collector.MAX_PAGES)
            self.assertEqual(state["last_end"], 100000 - 2 * 3600 + collector.MAX_PAGES * collector.PAGE_SECONDS)
            self.assertEqual(state["gaps"], [])
            collector.run_once(path, now=100060, enabled=lambda: True, fetch=fetch)
            collector.run_once(path, now=100060, enabled=lambda: True, fetch=fetch)
            self.assertEqual(collector.read_store(path)["last_end"], 100060)

    def test_repeated_failure_does_not_commit_horizon_gap_until_success(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            collector.run_once(path, now=1000, enabled=lambda: True, fetch=lambda *_: [])
            future = 1000 + collector.MAX_CATCHUP + 3600
            def fail(_start, _end):
                raise RuntimeError("synthetic failure")
            collector.run_once(path, now=future, enabled=lambda: True, fetch=fail)
            collector.run_once(path, now=future, enabled=lambda: True, fetch=fail)
            self.assertEqual(collector.read_store(path)["gaps"], [])
            collector.run_once(path, now=future, enabled=lambda: True, fetch=lambda *_: [])
            state = collector.read_store(path)
            self.assertEqual(len(state["gaps"]), 1)
            collector.run_once(path, now=future, enabled=lambda: True, fetch=lambda *_: [])
            self.assertEqual(len(collector.read_store(path)["gaps"]), 1)

    def test_dense_page_eventually_records_gap_and_advances(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            start = 100000 - 3600
            def dense(_start, _end):
                raise collector.QueryBudgetError("synthetic cap")
            for _ in range(2):
                collector.run_once(path, now=100000, enabled=lambda: True,
                                   fetch=dense, initial_hours=1)
            self.assertEqual(collector.read_store(path)["last_end"], start)
            self.assertEqual(collector.read_store(path)["gaps"], [])
            collector.run_once(path, now=100000, enabled=lambda: True, fetch=dense)
            state = collector.read_store(path)
            self.assertEqual(state["last_end"], start + collector.PAGE_SECONDS)
            self.assertEqual(state["gaps"], [[start, start + collector.PAGE_SECONDS, "query budget"]])

    def test_tail_budget_retry_pins_end_across_timer_ticks(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            collector.run_once(path, now=1000, enabled=lambda: True, fetch=lambda *_: [])
            calls = []
            def dense(start, end):
                calls.append((start, end))
                raise collector.QueryBudgetError("synthetic cap")
            for now in (1060, 1120, 1180):
                collector.run_once(path, now=now, enabled=lambda: True, fetch=dense)
            self.assertEqual(calls, [(1000, 1060)] * 3)
            state = collector.read_store(path)
            self.assertEqual(state["last_end"], 1060)
            self.assertEqual(state["gaps"], [[1000, 1060, "query budget"]])
            collector.run_once(path, now=1240, enabled=lambda: True, fetch=lambda *_: [])
            self.assertEqual(collector.read_store(path)["last_end"], 1240)
            self.assertEqual(len(collector.read_store(path)["gaps"]), 1)

    def test_horizon_budget_retry_pins_start_across_timer_ticks(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            collector.run_once(path, now=1000, enabled=lambda: True, fetch=lambda *_: [])
            calls = []
            def dense(start, end):
                calls.append((start, end))
                raise collector.QueryBudgetError("synthetic cap")
            later = 1000 + collector.MAX_CATCHUP + 3600
            for now in (later, later + 60, later + 120):
                collector.run_once(path, now=now, enabled=lambda: True, fetch=dense)
            expected_start = later - collector.MAX_CATCHUP
            self.assertEqual(calls, [(expected_start, expected_start + collector.PAGE_SECONDS)] * 3)
            state = collector.read_store(path)
            self.assertEqual(state["gaps"], [[1000, expected_start, "catch-up horizon"],
                                               [expected_start, expected_start + collector.PAGE_SECONDS,
                                                "query budget"]])

    def test_read_rejects_fifo_and_oversized_file_without_blocking(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            os.chmod(path, 0o700)
            journal = path / "journal.json"
            os.mkfifo(journal, 0o600)
            with self.assertRaises(ValueError):
                collector.read_store(path)
            journal.unlink()
            journal.write_bytes(b"x" * (collector.MAX_BYTES + 1))
            os.chmod(journal, 0o600)
            with self.assertRaises(ValueError):
                collector.read_store(path)

    def test_explicit_first_backfill_and_failed_scan_keep_cursor(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            calls = []
            def failing(start, end):
                calls.append((start, end))
                raise RuntimeError("synthetic")
            self.assertEqual(collector.run_once(path, now=100000, enabled=lambda: True,
                                                fetch=failing, initial_hours=8),
                             "scan failed; cursor retained")
            self.assertEqual(calls, [(100000 - 8 * 3600, 100000 - 8 * 3600 + collector.PAGE_SECONDS)])
            state = collector.read_store(path)
            self.assertEqual(state["last_end"], 100000 - 8 * 3600)
            self.assertEqual(state["failed_runs"], 1)
            collector.run_once(path, now=100060, enabled=lambda: True, fetch=lambda *_: [])
            self.assertGreater(collector.read_store(path)["last_end"], state["last_end"])

    def test_success_then_failure_keeps_partial_page_without_gap(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            calls = []
            def partial(start, end):
                calls.append((start, end))
                if len(calls) == 2:
                    raise RuntimeError("synthetic")
                return []
            outcome = collector.run_once(path, now=100000, enabled=lambda: True,
                                         fetch=partial, initial_hours=1)
            state = collector.read_store(path)
            self.assertEqual(outcome, "scan failed; completed pages retained")
            self.assertEqual(state["last_end"], 100000 - 3600 + collector.PAGE_SECONDS)
            self.assertEqual(state["gaps"], [])
            collector.run_once(path, now=100000, enabled=lambda: True, fetch=lambda *_: [])
            self.assertGreater(collector.read_store(path)["last_end"], state["last_end"])

    def test_budget_retry_after_partial_success_uses_same_page_identity(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory)
            start = 100000 - 3600
            def first(start_page, _end):
                if start_page == start:
                    return []
                raise collector.QueryBudgetError("synthetic cap")
            collector.run_once(path, now=100000, enabled=lambda: True,
                               fetch=first, initial_hours=1)
            for _ in range(2):
                collector.run_once(path, now=100000, enabled=lambda: True,
                                   fetch=lambda *_: (_ for _ in ()).throw(collector.QueryBudgetError("synthetic cap")))
            state = collector.read_store(path)
            self.assertEqual(state["last_end"], start + 2 * collector.PAGE_SECONDS)
            self.assertEqual(state["gaps"], [[start + collector.PAGE_SECONDS,
                                               start + 2 * collector.PAGE_SECONDS, "query budget"]])

    def test_read_only_inspection_does_not_create_store(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            path = Path(directory) / "missing"
            self.assertEqual(collector.read_store(path), collector.empty_state())
            self.assertFalse(path.exists())

    def test_symlinked_store_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as directory:
            root = Path(directory)
            (root / "actual").mkdir()
            (root / "link").symlink_to(root / "actual")
            with self.assertRaises(ValueError):
                collector.run_once(root / "link", now=1000, enabled=lambda: False, fetch=lambda *_: [])


if __name__ == "__main__":
    unittest.main()
