#!/usr/bin/env python3
"""Synthetic tests for pinned source gates and deterministic unweighted spelling data."""
from contextlib import closing
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("import_spelling_dictionaries", ROOT / "script/import_spelling_dictionaries.py")
import sys
sys.path.insert(0, str(ROOT / "script"))
import import_spelling_dictionaries as spelling
import import_dictionaries as base


class SpellingTests(unittest.TestCase):
    def make_full(self, path, words):
        with closing(sqlite3.connect(path)) as db:
            db.execute("CREATE TABLE frequencies(word TEXT PRIMARY KEY, frequency INTEGER) WITHOUT ROWID")
            db.executemany("INSERT INTO frequencies VALUES (?,1)", ((word,) for word in words))
            db.commit()

    def test_normalization_filter_and_exact_unweighted_storage(self):
        self.assertEqual(spelling.normal("Е\u0308ЛКА", "ru"), "ёлка")
        self.assertEqual(spelling.normal("HELLO", "en"), "hello")
        for word in ("bad2", "a" * 41, "bad word", ""):
            self.assertIsNone(spelling.normal(word, "en"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_full(root / "full.sqlite", ("hello", "world"))
            output = root / "spellings.sqlite"
            first = spelling.write_spelling_database(output, "en", ["HELLO", "hello", "other", "bad2"],
                                                     ["modern", "other"], root / "full.sqlite")
            data = output.read_bytes()
            output.unlink()
            second = spelling.write_spelling_database(output, "en", ["hello", "other", "HELLO", "bad2"],
                                                      ["other", "modern"], root / "full.sqlite")
            self.assertEqual(output.read_bytes(), data)
            self.assertEqual(first, second)
            self.assertEqual(first["entries"], 3)
            self.assertEqual(first["overlap_with_frequency"], 1)
            self.assertEqual(first["new_unique_against_frequency"], 2)
            self.assertEqual(first["union_with_frequency"], 4)
            with closing(sqlite3.connect(output.as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
                self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)
                self.assertEqual([row[0] for row in db.execute("SELECT word FROM spellings")],
                                 ["hello", "modern", "other"])
                self.assertEqual([row[1] for row in db.execute("PRAGMA table_info(spellings)")], ["word"])
                self.assertIsNone(db.execute("SELECT word FROM spellings WHERE word='hel'").fetchone())

    def test_hash_failure_does_not_replace_existing_cached_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "tiny.txt"
            target.write_bytes(b"old")
            with patch.dict(spelling.SOURCES, {"tiny.txt": ("https://example.invalid/source", "0" * 64, 100)}):
                with self.assertRaisesRegex(ValueError, "SHA-256/size mismatch"):
                    spelling.fetch_pinned("tiny.txt", root)
            self.assertEqual(target.read_bytes(), b"old")
            self.assertEqual(list(root.glob("*.partial")), [])

    def test_pinned_input_failure_keeps_published_resources_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dictionaries").mkdir()
            resources = root / "macos/Sources/RuSwitcher/Resources"
            resources.mkdir(parents=True)
            languages = {}
            for lang in ("ru", "en"):
                trigger = resources / f"{lang}.tsv"
                full = resources / f"{lang}-full.sqlite"
                trigger.write_bytes(b"old trigger")
                full.write_bytes(b"old full")
                languages[lang] = {"output": str(trigger.relative_to(root)),
                                   "output_sha256": spelling.sha256(trigger),
                                   "full": {"output": str(full.relative_to(root)),
                                            "output_sha256": spelling.sha256(full)}}
            source = root / "dictionaries/protected-terms-source.tsv"
            curated = resources / "protected-terms.tsv"
            source.write_bytes(b"old source")
            curated.write_bytes(b"old curated")
            manifest = root / "dictionaries/manifest.json"
            manifest.write_text(json.dumps({"schema": 2, "languages": languages,
                "protected_terms": {"source": str(source.relative_to(root)), "source_sha256": spelling.sha256(source),
                                    "output": str(curated.relative_to(root)), "output_sha256": spelling.sha256(curated)}}))
            old_manifest = manifest.read_bytes()
            source_dir = root / "sources"
            source_dir.mkdir()
            (source_dir / "ru.whl").write_bytes(b"wrong pinned bytes")
            with patch.object(spelling, "ROOT", root), patch.object(base, "ROOT", root):
                with self.assertRaisesRegex(ValueError, "Pinned source SHA-256/size mismatch"):
                    spelling.import_spellings(source_dir)
            self.assertEqual(manifest.read_bytes(), old_manifest)
            self.assertFalse((resources / "ru-spellings.sqlite").exists())
            self.assertEqual(curated.read_bytes(), b"old curated")

    def test_bounded_download_rejects_oversize_and_hash_failure(self):
        class Response(io.BytesIO):
            url = "https://example.invalid/source"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for content, reason in ((b"123456", "Oversized source"), (b"123", "SHA-256 mismatch")):
                with patch.dict(spelling.SOURCES, {"tiny.txt": ("https://example.invalid/source", "0" * 64, 5)}), \
                        patch.object(spelling.urllib.request, "urlopen", return_value=Response(content)):
                    with self.assertRaisesRegex(ValueError, reason):
                        spelling.fetch_pinned("tiny.txt", root)
                self.assertFalse((root / "tiny.txt").exists())
                self.assertEqual(list(root.glob("*.partial")), [])

    def test_missing_and_oversize_wheel_members(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.whl"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("other", "x")
                archive.writestr("huge", "x" * 20)
            with zipfile.ZipFile(path) as archive:
                with self.assertRaisesRegex(ValueError, "member missing"):
                    spelling.validated_member(archive, "missing", 100)
                with self.assertRaisesRegex(ValueError, "member size"):
                    spelling.validated_member(archive, "huge", 10)

    def test_modern_source_strict_format(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "modern.tsv"
            path.write_text("# comment\nen\tOpenAI\nru\tЁЛКА\n")
            with self.assertRaisesRegex(ValueError, "line 2"):
                list(spelling.modern_words(path))
            path.write_text("# comment\nen\topenai\nru\tёлка\n")
            self.assertEqual(list(spelling.modern_words(path)), [("en", "openai"), ("ru", "ёлка")])

    def test_shared_import_lock_rejects_other_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(base, "ROOT", root), base.import_lock():
                with self.assertRaisesRegex(RuntimeError, "Another dictionary import"):
                    with spelling.import_lock():
                        pass

    def test_public_schema3_validator_detects_semantic_corruption(self):
        import check_public
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dictionaries").mkdir()
            (root / "dictionaries/LICENSE-CC-BY-SA-3.0.txt").write_text("fixture")
            (root / "dictionaries/LICENSE-ESDB-Copyright.txt").write_text("fixture")
            (root / "dictionaries/modern-spellings-source.tsv").write_text("en\tmodern\n")
            self.make_full(root / "full.sqlite", ("hello", "world"))
            en = root / "en-spellings.sqlite"
            data = spelling.write_spelling_database(en, "en", ["hello", "other"], ["modern"], root / "full.sqlite")
            # Validator expects both languages. A second tiny RU database uses
            # the same shape and an independent empty frequency table.
            self.make_full(root / "ru-full.sqlite", ("привет",))
            ru = root / "ru-spellings.sqlite"
            ru_data = spelling.write_spelling_database(ru, "ru", ["привет", "ёлка"], [], root / "ru-full.sqlite")
            records = {}
            for lang, path, counts in (("en", en, data), ("ru", ru, ru_data)):
                records[lang] = {"output": path.name, "output_sha256": spelling.sha256(path),
                                 "bytes": path.stat().st_size, **counts}
            notice = root / "dictionaries/LICENSE-ESDB-Copyright.txt"
            modern = root / "dictionaries/modern-spellings-source.tsv"
            manifest = {"languages": {"en": {"full": {"output": "full.sqlite"}},
                                      "ru": {"full": {"output": "ru-full.sqlite"}}},
                        "supplemental_spellings": {"languages": records,
                            "ru_source": {"notice": "dictionaries/LICENSE-CC-BY-SA-3.0.txt",
                                          "notice_sha256": spelling.sha256(root / "dictionaries/LICENSE-CC-BY-SA-3.0.txt")},
                            "en_source": {"notice": "dictionaries/LICENSE-ESDB-Copyright.txt",
                                          "notice_sha256": spelling.sha256(notice)},
                            "sources": {"Copyright": {"sha256": spelling.sha256(notice)}},
                            "modern_source": {"path": "dictionaries/modern-spellings-source.tsv",
                                              "sha256": spelling.sha256(modern), "entries": 1,
                                              "counts": {"en": 1, "ru": 0}}}}
            failures = []
            with patch.object(check_public, "ROOT", root):
                check_public.validate_supplemental(manifest, failures)
            self.assertEqual(failures, [])
            with closing(sqlite3.connect(en)) as db:
                db.execute("INSERT INTO spellings VALUES ('bad2')")
                db.execute("UPDATE metadata SET value='4' WHERE key='entries'")
                db.commit()
            records["en"]["output_sha256"] = spelling.sha256(en)
            records["en"]["bytes"] = en.stat().st_size
            records["en"]["entries"] = 4
            failures = []
            with patch.object(check_public, "ROOT", root):
                check_public.validate_supplemental(manifest, failures)
            self.assertTrue(any("invalid supplemental SQLite" in reason for _, reason in failures))


if __name__ == "__main__":
    unittest.main()
