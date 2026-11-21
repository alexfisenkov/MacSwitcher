#!/usr/bin/env python3
"""Private, bounded MacSwitcher outcome journal. No input payload is accepted."""
import argparse
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import stat
import subprocess
import sys
import tempfile
import time

SUBSYSTEM = "com.alexfisenkov.macswitcher"
CATEGORY = "Diagnostics"
DOMAIN = "com.alexfisenkov.macswitcher"
KEY = "com.macswitcher.metadataDiagnosticsEnabled"
FAMILIES = frozenset(("textEdit", "codex", "browser", "chrome", "safari",
                      "firefox", "edge", "telegram", "vsCode", "claude",
                      "claudeSecondary", "other"))
OPERATIONS = frozenset(("word", "selection", "undo", "recovery"))
RESULTS = frozenset(("confirmed", "refused", "uncertain", "pending", "sourceUnconfirmed"))
DOUBLE_EVENTS = frozenset((
    "doubleRecognized", "doubleFirstSnapshotUnavailable", "doubleReceived",
    "doubleDisabled", "doubleSecureInput", "doubleWrongProcess",
    "doubleRevisionChanged", "doubleRemoteDeferred", "doubleMissingFocus",
    "doubleInvalidExecution", "doubleNoReconversionState", "doubleMissingWordContext",
    "doubleNoBufferOrSelection", "doubleFailed", "doubleSucceeded",
    "soloReceived", "doubleWindowMissed", "doubleArrivalSkewRejected",
    "doubleCaretReanchored", "doubleLayoutUnconfirmed", "secureFlagWithEvents",
))
FAILURES = frozenset((
    "selectionSourceMismatch", "selectionStateBlocked", "selectionTimeout",
    "selectionInvalidExecution", "selectionSnapshotMissing", "selectionFieldUnavailable",
    "selectionCoordinateEvidenceUnavailable", "selectionCoordinateProjectionMismatch",
    "selectionCoordinateEndpointUnproven",
    "selectionFieldMismatch", "selectionTextMismatch", "selectionPolicyNoChange",
    "selectionReplacementRejected", "selectionRevalidationFailed",
    "transactionCandidateUnavailable", "transactionInvalidExecution",
    "transactionRevisionChanged", "transactionWrongProcess", "transactionSecureInput",
    "transactionFieldChanged", "transactionSourceChanged", "wordContextUnavailable",
    "wordInputBarrierUnavailable", "wordBufferUnavailable", "wordMappingUnavailable",
    "wordConversionBusy", "wordMappingNoChange", "wordNativeStateBlocked",
    "wordNativeCaretMismatch", "wordNativeSnapshotInvalid",
    "wordNativeFirstSelectionMissing", "wordNativeFirstSelectionNoncollapsed",
    "wordNativeFirstCaretTooShort", "wordNativeEditRefused",
    "verifiedWordStateBlocked", "verifiedWordCaretUnavailable",
    "verifiedWordFieldUnavailable", "verifiedWordFieldMismatch",
    "verifiedWordTrailingSpaceLimit", "verifiedWordNoFinalLetter",
    "verifiedWordTokenLimit", "verifiedWordBoundaryInvalid",
    "verifiedWordTokenInvalid", "verifiedWordNoConversion",
    "verifiedWordRevalidationFailed", "recoveryNoRAMSnapshot",
    "recoveryInputUnavailable", "recoverySelectionMissing",
    "recoverySelectionMismatch", "recoveryEditRefused", "recoveryEditUnknown",
    "editBudgetExhausted", "editTimeoutUnavailable", "editSelectionDrifted",
    "editSelectionShapeInvalid", "editBarrierInactive", "editEndpointWitnessMissing",
    "editPreservedFieldMismatch", "editSourceUnretained", "staleAutomaticRequest",
    "caretReanchorRefused", "editorClockInvalid", "editorIdentityLost",
    "editorFieldNotEditable", "editorFirstReadInvalid", "editorPlanRefused",
    "editorFieldChanged", "editorPreparationNotQueued", "editorReplacementNotQueued",
    "editorPreparationCancelled",
))
HEALTH_EVENTS = frozenset((
    "tapDisabledTimeout", "tapDisabledUserInput", "fenceTapMissing",
    "fenceTapDisabled", "fenceInterrupted", "fencePendingSource", "fenceBusy",
    "fenceGateNotConfigured", "nativeFenceUnavailable", "nativeFenceInterrupted",
    "recoverySameFieldBlocked", "recoverySlotsFull", "recoveryUnitsFull",
    "recoveryArchiveLimit", "recoveryArchiveFailed", "recoveryArchiveQuota",
    "recoveryArchiveWriteFailed", "recoveryArchiveVerificationFailed",
    "rivalKeyboardTapActive", "autoLoopGuardTripped",
))
EDIT_FAILURE_EVENTS = frozenset((
    "ackDeadline", "ackGateInvalid", "ackObservationLimit", "ackObservationUnavailable",
    "ackTextMismatch", "ackCaretMismatch", "ackSelectionMismatch",
    "ackFocusUnavailable", "ackFocusChanged", "ackRevisionChanged",
    "ackWrongProcess", "ackSecureInput", "autoTextUnconfirmed",
    "autoSourceFailed", "autoSourceUnconfirmed", "autoEditRefused",
    "autoTargetUnavailable", "autoFocusAnchorUnavailable", "autoFocusMismatch",
    "autoCaretUnavailable", "autoCaretMismatch", "autoAXUnsupported",
    "autoAXMutationUnknown", "nativeAutoUncertain", "nativeAutoBlocked",
    "nativeAutoFocusRecheckFailed", "nativeInvalidExecution", "nativeSuffixMismatch",
    "selectionAXMutationUnknown", "selectionAXReadbackMismatch",
    "unconfirmedEditBlocked", "executionFocusUnavailable", "executionFocusChanged",
    "executionWrongProcess", "executionRevisionChanged", "executionSecureInput",
    "ackLateConfirmed", "ackDeadlineSourceVisible", "ackDeadlineCaretOnly", "ackDeadlineOther",
    "autocompleteSuggestionRefused",
))
EXACT_EVENTS = DOUBLE_EVENTS | HEALTH_EVENTS | EDIT_FAILURE_EVENTS | frozenset("failure." + x for x in FAILURES)
MAX_AGE = 14 * 86400
MAX_EVENTS = 6000
MAX_BYTES = 1024 * 1024
MAX_CATCHUP = 24 * 3600
OVERLAP = 5
PAGE_SECONDS = 900
MAX_PAGES = 4
QUERY_SECONDS = 30
RUN_SECONDS = 120
EPISODE_SECONDS = 3
MAX_BUDGET_RETRIES = 3


class QueryBudgetError(RuntimeError):
    """One Unified Log page exceeded the bounded query time or volume."""


def allowed_event(value):
    if not isinstance(value, str):
        return False
    if value in EXACT_EVENTS:
        return True
    parts = value.split(".")
    if len(parts) == 3:
        return parts[0] == "automatic" and parts[1] in FAMILIES and parts[2] == "uncertain"
    return (len(parts) == 4 and parts[0] == "combined"
            and parts[1] in FAMILIES and parts[2] in OPERATIONS and parts[3] in RESULTS)


def eligible_record(item):
    """Accept the product producer; older OSLog rows may omit image path."""
    if not isinstance(item, dict) or item.get("subsystem") != SUBSYSTEM or item.get("category") != CATEGORY:
        return False
    image = item.get("processImagePath")
    return image is None or (isinstance(image, str) and image.endswith(
        "/MacSwitcher.app/Contents/MacOS/RuSwitcher"))


def parse_line(raw):
    """Return only closed metadata; the source line and process fields are discarded."""
    try:
        item = json.loads(raw)
        if not eligible_record(item):
            return None
        message = item.get("eventMessage")
        if not allowed_event(message):
            return None
        stamp = item["timestamp"]
        try:
            when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
        except ValueError:
            when = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        # machTimestamp and thread/process metadata disambiguate simultaneous
        # occurrences. Only their irreversible digest reaches the journal.
        tick = item["machTimestamp"]
        if not isinstance(tick, int) or isinstance(tick, bool):
            return None
        identity = [stamp, tick, item.get("processID"), item.get("threadID"),
                    item.get("bootUUID"), item.get("traceID"), message]
        digest = hashlib.sha256(json.dumps(identity, separators=(",", ":")).encode()).hexdigest()
        return {"id": digest, "time": when, "event": message}
    except (ValueError, TypeError, KeyError, AttributeError):
        return None


def empty_state():
    return {"version": 1, "paused": False, "active": False, "enabled_since": None,
            "last_end": None, "events": [], "gaps": [], "failed_runs": 0,
            "last_error": None, "budget_failure": None,
            "events_pruned": 0, "gaps_pruned": 0}


def merge(state, rows, now, max_age=MAX_AGE, max_events=MAX_EVENTS, max_bytes=MAX_BYTES):
    known = {row["id"] for row in state["events"]}
    added = set()
    for row in rows:
        if row["id"] not in known and allowed_event(row["event"]):
            state["events"].append(row)
            known.add(row["id"])
            added.add(row["id"])
    before_events = len(state["events"])
    before_gaps = len(state["gaps"])
    state["events"] = sorted((row for row in state["events"] if row["time"] >= now - max_age),
                             key=lambda row: (row["time"], row["id"]))[-max_events:]
    state["gaps"] = state["gaps"][-32:]
    state["gaps_pruned"] += before_gaps - len(state["gaps"])
    encoded_size = lambda events: len(json.dumps({**state, "events": events}, separators=(",", ":")).encode())
    if encoded_size(state["events"]) > max_bytes:
        low, high = 0, len(state["events"])
        while low < high:
            middle = (low + high) // 2
            if encoded_size(state["events"][middle:]) <= max_bytes:
                high = middle
            else:
                low = middle + 1
        state["events"] = state["events"][low:]
    state["events_pruned"] += before_events - len(state["events"])
    return len(added.intersection(row["id"] for row in state["events"]))


def _ensure_directory(path, create=True):
    path = path.expanduser().absolute()
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError("symlink in diagnostic data path")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    elif not path.exists():
        return path
    if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o777 != 0o700:
        raise ValueError("diagnostic directory must belong to user and be mode 0700")
    return path


def _read_state(path):
    if path.is_symlink():
        raise ValueError("symlinked diagnostic journal")
    if not path.exists():
        return empty_state()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        details = os.fstat(fd)
        if (not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid()
                or details.st_mode & 0o777 != 0o600 or details.st_size > MAX_BYTES):
            raise ValueError("diagnostic file must be regular, owned by user, mode 0600 and bounded")
        chunks = []
        length = 0
        while length <= MAX_BYTES:
            piece = os.read(fd, min(65536, MAX_BYTES + 1 - length))
            if not piece:
                break
            chunks.append(piece)
            length += len(piece)
        if length > MAX_BYTES:
            raise ValueError("diagnostic journal exceeded 1 MiB")
        state = json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        if fd >= 0:
            os.close(fd)
    expected = {"version", "paused", "active", "enabled_since", "last_end", "events",
                "gaps", "failed_runs", "last_error", "budget_failure", "events_pruned", "gaps_pruned"}
    if not isinstance(state, dict) or set(state) != expected or state["version"] != 1:
        raise ValueError("unsupported diagnostic journal")
    if (type(state["paused"]) is not bool or type(state["active"]) is not bool
            or not isinstance(state["events"], list) or len(state["events"]) > MAX_EVENTS
            or not isinstance(state["gaps"], list) or len(state["gaps"]) > 32
            or any(type(state[key]) is not int or state[key] < 0
                   for key in ("failed_runs", "events_pruned", "gaps_pruned"))):
        raise ValueError("invalid diagnostic journal structure")
    if any(value is not None and type(value) is not int for value in
           (state["enabled_since"], state["last_end"])):
        raise ValueError("invalid diagnostic cursor")
    if state["last_error"] is not None and state["last_error"] not in (
            "RuntimeError", "QueryBudgetError", "TimeoutExpired", "OSError", "ValueError"):
        raise ValueError("invalid diagnostic error")
    failure = state["budget_failure"]
    if failure is not None and (not isinstance(failure, dict)
            or set(failure) != {"start", "end", "count"}
            or any(type(failure[key]) is not int for key in failure)
            or not 1 <= failure["count"] < MAX_BUDGET_RETRIES
            or failure["start"] >= failure["end"]):
        raise ValueError("invalid query budget state")
    for row in state["events"]:
        if (not isinstance(row, dict) or set(row) != {"id", "time", "event"}
                or not isinstance(row["id"], str) or len(row["id"]) != 64
                or any(char not in "0123456789abcdef" for char in row["id"])
                or type(row["time"]) not in (int, float) or not allowed_event(row["event"])):
            raise ValueError("invalid closed diagnostic event")
    if any(not isinstance(gap, list) or len(gap) != 3
           or type(gap[0]) is not int or type(gap[1]) is not int
           or gap[2] not in ("catch-up horizon", "query budget") for gap in state["gaps"]):
        raise ValueError("invalid diagnostic gap")
    return state


def _write_state(path, state):
    fd, temp_name = tempfile.mkstemp(prefix=".journal-", dir=str(path.parent))
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temp.exists():
            temp.unlink()


def _with_store(path, callback):
    directory = _ensure_directory(path)
    lock = directory / "journal.lock"
    if lock.is_symlink():
        raise ValueError("symlinked lock")
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        details = os.fstat(fd)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid() or details.st_mode & 0o777 != 0o600:
            raise ValueError("lock file must be mode 0600")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state_path = directory / "journal.json"
        state = _read_state(state_path)
        result = callback(state)
        _write_state(state_path, state)
        return result
    finally:
        os.close(fd)


def read_store(path):
    directory = _ensure_directory(path, create=False)
    if not directory.exists():
        return empty_state()
    return _read_state(directory / "journal.json")


def diagnostics_enabled():
    result = subprocess.run(["/usr/bin/defaults", "read", DOMAIN, KEY],
                            capture_output=True, text=True, timeout=5, check=False)
    return result.returncode == 0 and result.stdout.strip().lower() in ("1", "true", "yes")


def fetch_logs(start, end):
    if end <= start or end - start > PAGE_SECONDS:
        raise ValueError("expected one bounded log page")
    predicate = 'subsystem == "' + SUBSYSTEM + '" AND category == "' + CATEGORY + '"'
    local = lambda value: datetime.fromtimestamp(value).strftime("%Y-%m-%d %H:%M:%S")
    rows = []
    cursor = start
    while cursor < end:
        window_end = min(cursor + PAGE_SECONDS, end)
        command = ["/usr/bin/log", "show", "--style", "ndjson",
                   "--start", local(cursor), "--end", local(window_end), "--predicate", predicate]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        selector = selectors.DefaultSelector()
        chunks = []
        size = 0
        deadline = time.monotonic() + QUERY_SECONDS
        try:
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise QueryBudgetError("unified log query timed out")
                if not selector.select(remaining):
                    raise QueryBudgetError("unified log query timed out")
                piece = os.read(process.stdout.fileno(), 65536)
                if not piece:
                    break
                size += len(piece)
                if size > 8 * 1024 * 1024:
                    raise QueryBudgetError("unified log query exceeded 8 MiB per page")
                chunks.append(piece)
            try:
                status = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired as error:
                raise QueryBudgetError("unified log query timed out") from error
            if status:
                raise RuntimeError("unified log query failed")
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
        for line in b"".join(chunks).splitlines():
            try:
                item = json.loads(line)
            except ValueError:
                raise RuntimeError("unified log returned malformed JSON")
            event = parse_line(line)
            if eligible_record(item) \
                    and allowed_event(item.get("eventMessage")) and event is None:
                raise RuntimeError("closed diagnostic event lacks stable identity or timestamp")
            if event is not None and start <= event["time"] <= end:
                rows.append(event)
        rows = rows[-MAX_EVENTS:]
        cursor = window_end
    return rows


def run_once(data_dir, now=None, enabled=diagnostics_enabled, fetch=fetch_logs, initial_hours=0):
    now = int(time.time() if now is None else now)
    def action(state):
        def fail(error):
            state["failed_runs"] += 1
            name = type(error).__name__
            state["last_error"] = name if name in (
                "RuntimeError", "QueryBudgetError", "TimeoutExpired", "OSError", "ValueError") else "RuntimeError"
            merge(state, [], now)
        try:
            opt_in = enabled() if not state["paused"] else False
        except Exception as error:
            fail(error)
            return "scan failed; preference check"
        if not opt_in:
            state["active"] = False
            state["last_end"] = now
            state["enabled_since"] = None
            state["last_error"] = None
            state["budget_failure"] = None
            merge(state, [], now)
            return "paused or diagnostics opt-out"
        first_backfill = bool(initial_hours and not state["active"] and state["last_end"] is None)
        if not state["active"]:
            state["active"] = True
            if first_backfill:
                state["enabled_since"] = now - initial_hours * 3600
                state["last_end"] = state["enabled_since"]
            else:
                state["enabled_since"] = now
                state["last_end"] = now
                merge(state, [], now)
                return "armed; collection begins now"
        previous = int(state["last_end"])
        if now <= previous:
            merge(state, [], now)
            return "no new interval"
        start = max(int(state["enabled_since"]), previous - OVERLAP,
                    now - (initial_hours * 3600 if first_backfill else MAX_CATCHUP))
        retry = state["budget_failure"]
        if retry is not None and retry["start"] >= previous - OVERLAP and retry["end"] <= now:
            start = retry["start"]
        elif state["gaps"] and state["gaps"][-1][1] == previous and state["gaps"][-1][2] == "query budget":
            start = previous
        horizon_gap = [previous, start, "catch-up horizon"] if start > previous else None
        cursor = start
        pages = 0
        added_total = 0
        deadline = time.monotonic() + RUN_SECONDS
        while cursor < now and pages < MAX_PAGES and time.monotonic() < deadline:
            page_end = (retry["end"] if retry is not None and retry["start"] == cursor
                        else min(cursor + PAGE_SECONDS, now))
            try:
                rows = fetch(cursor, page_end)
                if not enabled():
                    state["active"] = False
                    state["enabled_since"] = None
                    state["last_end"] = now
                    state["budget_failure"] = None
                    merge(state, [], now)
                    return "opt-out during scan; current page discarded"
            except Exception as error:
                fail(error)
                if isinstance(error, QueryBudgetError):
                    previous_failure = state["budget_failure"]
                    count = (previous_failure["count"] + 1 if previous_failure is not None
                             and previous_failure["start"] == cursor and previous_failure["end"] == page_end else 1)
                    if count >= MAX_BUDGET_RETRIES:
                        if horizon_gap is not None:
                            state["gaps"].append(horizon_gap)
                        state["gaps"].append([cursor, page_end, "query budget"])
                        state["last_end"] = page_end
                        state["budget_failure"] = None
                        merge(state, [], now)
                        return "scan failed; query-budget gap recorded"
                    state["budget_failure"] = {"start": cursor, "end": page_end, "count": count}
                else:
                    state["budget_failure"] = None
                return "scan failed; completed pages retained" if pages else "scan failed; cursor retained"
            if horizon_gap is not None:
                state["gaps"].append(horizon_gap)
                horizon_gap = None
            state["budget_failure"] = None
            added_total += merge(state, rows, now)
            state["last_end"] = page_end
            state["last_error"] = None
            cursor = page_end
            pages += 1
        merge(state, [], now)
        return "stored %d new closed events; scanned through %s%s" % (
            added_total, _time(state["last_end"]), "; backlog remains" if cursor < now else "")
    return _with_store(data_dir, action)


def _time(value):
    return datetime.fromtimestamp(value).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def report(state, now, hours):
    rows = [row for row in state["events"] if row["time"] >= now - hours * 3600]
    lines = ["MacSwitcher local diagnostics", "Stored events: %d; shown for %d h: %d" % (
        len(state["events"]), hours, len(rows))]
    lines.append("Stored span: %s — %s" % (_time(state["events"][0]["time"]),
                                            _time(state["events"][-1]["time"])) if state["events"] else "Stored span: none")
    lines.append("Pruned by retention: %d events, %d old gap records" % (
        state["events_pruned"], state["gaps_pruned"]))
    lines.append("Collection: %s; last scan end: %s; failed runs: %d" % (
        "paused" if state["paused"] else "active" if state["active"] else "opted out / not armed",
        _time(state["last_end"]) if state["last_end"] else "none", state["failed_runs"]))
    for begin, end, reason in state["gaps"]:
        lines.append("Gap: %s — %s (%s)" % (_time(begin), _time(end), reason))
    if state["last_error"]:
        lines.append("Last scan error: " + state["last_error"])
    if state["budget_failure"] is not None:
        lines.append("Pending query-budget retry: %d/%d" % (
            state["budget_failure"]["count"], MAX_BUDGET_RETRIES))
    outcome = lambda row: row["event"].startswith(("combined.", "automatic."))
    outcomes = [row for row in rows if outcome(row)]
    episodes = []
    for row in outcomes:
        if episodes and row["time"] - episodes[-1][-1]["time"] <= EPISODE_SECONDS:
            episodes[-1].append(row)
        else:
            episodes.append([row])
    lines.append("Episodes: %d; outcomes: %d" % (len(episodes), len(outcomes)))
    codes = [row for row in rows if not outcome(row)]
    for number, episode in enumerate(episodes, 1):
        begin, end = episode[0]["time"], episode[-1]["time"]
        lines.append("Episode %d: %s — %s, outcomes %d" % (number, _time(begin), _time(end), len(episode)))
        owned = {id(row): [] for row in episode}
        for code in codes:
            if not begin - EPISODE_SECONDS <= code["time"] <= end + EPISODE_SECONDS:
                continue
            # A stage precedes the outcome it explains: attach it to the first
            # outcome at or after it, otherwise to the episode's last outcome.
            owner = next((row for row in episode if row["time"] >= code["time"]), episode[-1])
            owned[id(owner)].append(code["event"])
        for row in episode:
            tally = {}
            for event in owned[id(row)]:
                tally[event] = tally.get(event, 0) + 1
            stages = ", ".join(event if count == 1 else "%s x%d" % (event, count)
                               for event, count in sorted(tally.items()))
            lines.append("  %s  %s%s" % (_time(row["time"]), row["event"],
                                         "; codes " + stages if stages else ""))
    counts = {}
    for row in codes:
        counts[row["event"]] = counts.get(row["event"], 0) + 1
    if counts.get("doubleRecognized"):
        # Counts presses, not checks: each recognized double ends in one of these.
        ended = sum(counts.get(name, 0) for name in
                    ("doubleSucceeded", "doubleFailed", "doubleLayoutUnconfirmed"))
        lines.append("Double Shift: recognized %d; succeeded %d; failed %d; layout unconfirmed %d; "
                     "ended earlier %d" % (counts["doubleRecognized"], counts.get("doubleSucceeded", 0),
                                           counts.get("doubleFailed", 0),
                                           counts.get("doubleLayoutUnconfirmed", 0),
                                           max(0, counts["doubleRecognized"] - ended)))
    for event, count in sorted(counts.items()):
        lines.append("%s: %d" % (event, count))
    lines.append("Episode codes are timing neighbours within %d s, not proven causes; "
                 "browser is legacy Chrome/Safari aggregate." % EPISODE_SECONDS)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("once", "status", "report", "stop", "start", "plist"))
    parser.add_argument("--data-dir", type=Path,
                        default=Path.home() / "Library/Application Support/MacSwitcher/Diagnostics")
    parser.add_argument("--hours", type=int, default=24)
    parser.add_argument("--backfill-hours", type=int, default=0,
                        help="explicit first-run import only, maximum 24 hours")
    args = parser.parse_args(argv)
    if args.hours < 1 or args.hours > 14 * 24:
        parser.error("--hours must be 1..336")
    if args.backfill_hours < 0 or args.backfill_hours > 24:
        parser.error("--backfill-hours must be 0..24")
    if args.command == "plist":
        print(plistlib.dumps({"Label": "com.alexfisenkov.macswitcher.local-diagnostics",
                             "ProgramArguments": ["/usr/bin/python3", str(Path(__file__).resolve()), "once"],
                             "RunAtLoad": True, "StartInterval": 60,
                             "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"}).decode(), end="")
    elif args.command == "once":
        outcome = run_once(args.data_dir, initial_hours=args.backfill_hours)
        print(outcome)
        if outcome.startswith("scan failed"):
            return 1
    elif args.command in ("start", "stop"):
        def toggle(state):
            state["paused"] = args.command == "stop"
            state["active"] = False
            state["enabled_since"] = None
            state["last_end"] = int(time.time())
            state["budget_failure"] = None
            merge(state, [], state["last_end"])
            return "collection " + ("stopped" if state["paused"] else "armed from now")
        print(_with_store(args.data_dir, toggle))
    else:
        def inspect(state):
            return report(state, int(time.time()), args.hours) if args.command == "report" else (
                "paused=%s active=%s last_end=%s events=%d gaps=%d failed_runs=%d "
                "pruned_events=%d pruned_gaps=%d budget_retry=%d" % (
                    state["paused"], state["active"], _time(state["last_end"]) if state["last_end"] else "none",
                    len(state["events"]), len(state["gaps"]), state["failed_runs"],
                    state["events_pruned"], state["gaps_pruned"],
                    state["budget_failure"]["count"] if state["budget_failure"] else 0))
        print(inspect(read_store(args.data_dir)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print("diagnostic collector: " + str(error), file=sys.stderr)
        sys.exit(1)
