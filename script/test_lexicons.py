#!/usr/bin/env python3
"""Deterministic lexicon-import tests; entirely synthetic data in temporary folders."""
from contextlib import closing, redirect_stdout, redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("import_dictionaries", ROOT / "script/import_dictionaries.py")
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


# Public work, business and IT words; film subtitles alone under-represent them.
WORK_VOCABULARY = {
    "ru": ("бюджет дедлайн рентабельность аутентификация "
           "облачные кредитование "
           "аналитика отчётность договор менеджер заказчик исполнитель поставщик логистика регламент согласование "
           "инвестор инвестиции акционер дивиденды выручка налогообложение бухгалтерия аудит спецификация интеграция "
           "алгоритм сервер браузер приложение разработчик программист фреймворк интерфейс платформа шифрование "
           "авторизация конфигурация инфраструктура мониторинг процессор протокол маршрутизатор трафик скрипт "
           "компилятор тестирование релиз резюме собеседование вакансия сотрудник руководитель подразделение стратегия "
           "презентация консалтинг маркетинг стартап").split(),
    "en": ("deadline budget stakeholder roadmap backlog sprint workflow outsourcing invoice quarterly revenue "
           "margin shareholder dividend compliance procurement logistics deliverable milestone repository algorithm "
           "backend database framework compiler debugging refactoring deployment kubernetes fintech saas cryptocurrencies workflows "
           "scalability encryption authentication authorization configuration infrastructure bandwidth "
           "latency throughput firmware cybersecurity blockchain analytics dashboard spreadsheet integration timeline "
           "freelancer entrepreneur startup monetization prototype usability responsive typescript "
           "username password browser server").split(),
}


class LexiconImportTests(unittest.TestCase):
    def test_filter_is_normalized_bounded_and_retains_full_rare_tail(self):
        raw = "HELLO 50\nhello 40\nrareword 1\ncan't 3\nfoo-bar 2\ninvalid123 900\nbad -1\ninvalid count\n".encode()
        self.assertEqual(importer.filtered_words(raw, "en"), {"hello": 50, "rareword": 1, "can't": 3, "foo-bar": 2})
        self.assertEqual(importer.filtered_words("Е\u0308ЛКА 12\nёлка 4\nчто-то 100\n".encode(), "ru"), {"ёлка": 12, "что-то": 100})

    def test_full_database_is_exact_readonly_and_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "ru-full.sqlite"
            words = {"редкость": 1, "привет": 900_000, "как": 8_000_000}
            with patch.object(importer, "ROOT", root):
                first = importer.write_full_database(output, "ru", words)
                data = output.read_bytes()
                second = importer.write_full_database(output, "ru", dict(reversed(list(words.items()))))
            self.assertEqual(output.read_bytes(), data)
            self.assertEqual(first, second)
            self.assertEqual(first["entries"], 3)
            with closing(sqlite3.connect(output.as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                self.assertEqual(database.execute("SELECT frequency FROM frequencies WHERE word=?", ("редкость",)).fetchone(), (1,))
                self.assertIsNone(database.execute("SELECT frequency FROM frequencies WHERE word=?", ("ред",)).fetchone())
                self.assertEqual(dict(database.execute("SELECT key,value FROM metadata")), {"entries": "3", "language": "ru"})
                with self.assertRaises(sqlite3.OperationalError):
                    database.execute("INSERT INTO frequencies VALUES ('новое', 1)")

    def test_database_writer_never_deletes_another_import_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "en-full.sqlite"
            unrelated = output.with_suffix(".sqlite.partial")
            unrelated.write_bytes(b"another operation owns this")
            with patch.object(importer, "ROOT", root):
                importer.write_full_database(output, "en", {"hello": 20})
            self.assertEqual(unrelated.read_bytes(), b"another operation owns this")

    def test_wrong_pinned_hash_changes_no_published_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "sources"
            sources.mkdir()
            (sources / "ru_full.txt").write_bytes(b"not the pinned public source")
            destination = root / "macos/Sources/RuSwitcher/Resources/ru.tsv"
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"previous verified artifact")
            with patch.object(importer, "ROOT", root), patch.object(sys, "argv", ["import_dictionaries.py", "--source-dir", str(sources)]):
                with self.assertRaisesRegex(ValueError, "Pinned upstream SHA-256 mismatch"):
                    importer.main()
            self.assertEqual(destination.read_bytes(), b"previous verified artifact")
            self.assertFalse((root / "dictionaries/manifest.json").exists())

    def test_second_source_hash_failure_cannot_publish_first_language(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "sources"
            sources.mkdir()
            fixture = "привет 50\n".encode()
            (sources / "ru_full.txt").write_bytes(fixture)
            (sources / "en_full.txt").write_bytes(b"not the pinned English source")
            destination = root / "macos/Sources/RuSwitcher/Resources/ru.tsv"
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"previous verified artifact")
            # One synthetic accepted hash lets the test reach the *second* pinned
            # source gate. Production constants and all publication code are intact.
            with patch.object(importer, "ROOT", root), patch.dict(importer.SOURCE_HASHES, {"ru": importer.digest(fixture)}):
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch for en"):
                    importer.import_project(sources)
            self.assertEqual(destination.read_bytes(), b"previous verified artifact")
            self.assertFalse((root / "dictionaries/manifest.json").exists())
            self.assertEqual(list((root / ".черновики").glob(".dictionary-import-*")), [])

    def test_failed_database_stage_keeps_prior_output_and_cleans_only_owned_temp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "en-full.sqlite"
            output.write_bytes(b"prior artifact")
            with patch.object(importer, "ROOT", root):
                with self.assertRaises(sqlite3.IntegrityError):
                    importer.write_full_database(output, "en", {"hello": 0})
            self.assertEqual(output.read_bytes(), b"prior artifact")
            self.assertEqual(list(root.glob("*.partial")), [])

    def test_parallel_import_is_rejected_before_any_resource_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = """import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location('importer',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.ROOT=pathlib.Path(sys.argv[2]);sys.argv=['import_dictionaries.py']
module.main()
"""
            with patch.object(importer, "ROOT", root), importer.import_lock():
                process = subprocess.run([sys.executable, "-c", code, str(ROOT / "script/import_dictionaries.py"), str(root)],
                                         capture_output=True, text=True, timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("Another dictionary import is in progress", process.stderr)
            self.assertFalse((root / "macos").exists())

    def test_public_validator_checks_sqlite_metadata_beyond_matching_hash(self):
        spec = importlib.util.spec_from_file_location("check_public", ROOT / "script/check_public.py")
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dictionaries").mkdir()
            trigger = root / "en.tsv"
            trigger.write_bytes(b"hello\t50000\n")
            full = root / "en-full.sqlite"
            terms = b"en\tchatgpt\tbrand\n"
            (root / "terms.tsv").write_bytes(terms)
            (root / "source.tsv").write_bytes(terms)
            with patch.object(importer, "ROOT", root):
                full_record = importer.write_full_database(full, "en", {"hello": 50_000})
            manifest = {"schema": 2, "languages": {"en": {
                "output": "en.tsv", "output_sha256": importer.digest(trigger.read_bytes()), "entries": 1, "full": full_record}},
                "protected_terms": {"source": "source.tsv", "source_sha256": importer.digest(terms),
                    "output": "terms.tsv", "output_sha256": importer.digest(terms), "entries": 1,
                    "counts": {"en": 1, "ru": 0}}}
            manifest_path = root / "dictionaries/manifest.json"
            manifest_path.write_text(json.dumps(manifest))
            with patch.object(validator, "ROOT", root), patch.object(validator.subprocess, "check_output", return_value=b""), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(validator.main(), 0)
                with closing(sqlite3.connect(full)) as database:
                    database.execute("UPDATE metadata SET value='2' WHERE key='entries'")
                    database.commit()
                # Hash is deliberately updated: the validator must still reject a
                # semantically inconsistent, otherwise valid database.
                manifest["languages"]["en"]["full"]["output_sha256"] = importer.digest(full.read_bytes())
                manifest_path.write_text(json.dumps(manifest))
                self.assertEqual(validator.main(), 1)
                (root / "terms.tsv").write_bytes(b"invalid\n")
                self.assertEqual(validator.main(), 1)

    def test_second_source_words_merge_case_forms_and_drop_punctuation(self):
        raw = "Hello 10\nhello 5\n! 99\nJSON 7\nbad123 50\nx not-a-number\n".encode()
        self.assertEqual(importer.second_source_words(raw, "en"), {"hello": 15, "json": 7})

    def test_merge_adds_work_words_and_keeps_subtitle_frequencies(self):
        base = {"привет": 1000, "сервер": 2}
        extra = {"сервер": 1000, "дедлайн": 500, "редко": 150}
        # Hand-computed: scale = 0.2 * 1002 / 1650; words below the floor of 200 are not added.
        self.assertEqual(importer.merge_frequencies(base, [extra]), {"привет": 1000, "сервер": 121, "дедлайн": 61})

    def test_merge_never_weights_short_acronyms_or_unweighted_spellings(self):
        base = {"привет": 1000, "ток": 3}
        extra = {"нфр": 400, "ток": 400, "кринж": 300, "дедлайн": 500}
        # Three-letter forms collide with text typed in the wrong layout; curated modern spellings stay unweighted.
        self.assertEqual(importer.merge_frequencies(base, [extra], unweighted={"кринж"}),
                         {"привет": 1000, "ток": 3, "дедлайн": round(0.2 * 1003 / 1600 * 500)})

    def test_trigger_selection_keeps_short_subtitle_forms_inside_the_limit(self):
        base = {"hello": 1000, "world": 900, "abc": 12, "rare1": 13}
        merged = {**base, "newword": 800}
        # "abc" is a short form near the cutoff; wrong-layout detection relies on it staying known.
        self.assertEqual(importer.trigger_selection(base, merged, 4), [("hello", 1000), ("world", 900), ("newword", 800), ("abc", 12)])
        self.assertEqual(importer.trigger_selection(base, merged, 10)[:3], [("hello", 1000), ("world", 900), ("newword", 800)])

    def test_wrong_second_source_hash_changes_no_published_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "sources"
            (sources / "second").mkdir(parents=True)
            fixture = "привет 50\n".encode()
            (sources / "ru_full.txt").write_bytes(fixture)
            (sources / "en_full.txt").write_bytes(fixture)
            (sources / "second" / "ruwiki-2022-08-29.txt").write_bytes(b"not the pinned second source")
            destination = root / "macos/Sources/RuSwitcher/Resources/ru.tsv"
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"previous verified artifact")
            with patch.object(importer, "ROOT", root), patch.dict(importer.SOURCE_HASHES, {"ru": importer.digest(fixture), "en": importer.digest(fixture)}):
                with self.assertRaisesRegex(ValueError, "Second source SHA-256 mismatch"):
                    importer.import_project(sources)
            self.assertEqual(destination.read_bytes(), b"previous verified artifact")
            self.assertFalse((root / "dictionaries/manifest.json").exists())

    def test_public_validator_requires_second_source_license_and_hash_in_notice(self):
        spec = importlib.util.spec_from_file_location("check_public", ROOT / "script/check_public.py")
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        digest = "a" * 64
        record = {"name": "wikipedia-word-frequency", "commit": "c" * 40, "license": "CC-BY-SA-4.0", "sources": {"ru": [{"name": "x", "sha256": digest}], "en": [{"name": "y", "sha256": digest}]}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dictionaries").mkdir()
            notice = root / "dictionaries/NOTICE.md"
            with patch.object(validator, "ROOT", root):
                failures = []
                notice.write_text("no mention of the corpora")
                validator.validate_second_sources({"second_sources": record}, failures)
                self.assertTrue(failures)
                failures = []
                notice.write_text(f"wikipedia-word-frequency {'c' * 40} CC BY-SA 4.0 {digest}")
                validator.validate_second_sources({"second_sources": record}, failures)
                self.assertEqual(failures, [])
                failures = []
                validator.validate_second_sources({}, failures)
                self.assertTrue(failures)

    def test_shipped_trigger_set_is_bounded_and_has_work_vocabulary(self):
        resources = ROOT / "macos/Sources/RuSwitcher/Resources"
        for language, words in WORK_VOCABULARY.items():
            self.assertGreaterEqual(len(words), 50)
            trigger = {line.split("\t")[0] for line in (resources / f"{language}.tsv").read_text(encoding="utf-8").splitlines()}
            self.assertLessEqual(len(trigger), 200_000)
            self.assertEqual([word for word in words if word not in trigger], [])
            with closing(sqlite3.connect((resources / f"{language}-full.sqlite").as_uri() + "?mode=ro&immutable=1", uri=True)) as database:
                known = {row[0] for row in database.execute("SELECT word FROM frequencies WHERE word IN (%s)" % ",".join("?" * len(words)), words)}
            self.assertEqual([word for word in words if word not in known], [])

    def test_curated_terms_are_deduplicated_and_not_case_rewritten_at_runtime(self):
        raw = b"# public examples\nen\tChatGPT\tbrand\nen\tchatgpt\tbrand\nru\t" + "Фёдор".encode() + b"\tname\n"
        self.assertEqual(importer.protected_data(raw).decode(), "en\tchatgpt\tbrand\nru\tфёдор\tname\n")
        for raw in [b"en\tuser@example.org\tname\n", b"xx\tExample\tbrand\n", b"en\tExample\tcontact\n"]:
            with self.assertRaises(ValueError):
                importer.protected_data(raw)


if __name__ == "__main__":
    unittest.main()
