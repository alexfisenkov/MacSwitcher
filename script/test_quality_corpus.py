#!/usr/bin/env python3
"""Tests for the quality-corpus generator; synthetic sentences, no network."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_quality_corpus", ROOT / "script/build_quality_corpus.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

CORPUS = ROOT / "macos/Tests/RuSwitcherTests/Resources/quality-corpus.json"
NAMES_RU = ["Анна", "Мила", "Лиза", "Олег", "Павел", "Игорь", "Роман", "Ольга", "Вера", "Тимур",
            "Нина", "Марина", "Артем", "Елена", "Мария", "Антон", "Никита", "Алина"]
NAMES_EN = ["Anna", "Mila", "Lisa", "Oleg", "Paul", "Igor", "Roman", "Olga", "Vera", "Timur",
            "Nina", "Marina", "Artem", "Elena", "Maria", "Anton", "Nikita", "Alina"]
RU = [f"{n} читает интересный роман по вечерам" for n in NAMES_RU]
EN = [f"{n} likes to read books in the evening" for n in NAMES_EN]


def sample_corpus(per_category=2):
    counts = {name: per_category for name in gen.CATEGORIES}
    return gen.build_corpus(RU, EN, seed=7, counts=counts)


class LayoutTableTests(unittest.TestCase):
    def test_known_physical_key_pairs(self):
        self.assertEqual(gen.to_other_layout("привет", "ru"), "ghbdtn")
        self.assertEqual(gen.to_other_layout("hello", "en"), "руддщ")
        self.assertEqual(gen.to_other_layout("ёж", "ru"), "`;")
        self.assertEqual(gen.to_other_layout("Привет", "ru"), "Ghbdtn")
        self.assertEqual(gen.to_other_layout("ХЪ", "ru"), "{}")

    def test_hyphen_and_apostrophe_follow_their_keys(self):
        self.assertEqual(gen.to_other_layout("что-то", "ru"), "xnj-nj")
        self.assertEqual(gen.to_other_layout("don't", "en"), "вщтэе")


class SentenceFilterTests(unittest.TestCase):
    def test_keeps_plain_sentences_and_strips_punctuation(self):
        self.assertEqual(gen.clean_sentence("Я люблю книги, а ты?", "ru"), "Я люблю книги а ты")

    def test_rejects_digits_foreign_script_and_length(self):
        self.assertIsNone(gen.clean_sentence("В 2020 году было тепло и ясно", "ru"))
        self.assertIsNone(gen.clean_sentence("Я люблю Paris очень сильно", "ru"))
        self.assertIsNone(gen.clean_sentence("Привет мир", "ru"))
        self.assertIsNone(gen.clean_sentence("Я люблю кофе", "en"))
        self.assertIsNone(gen.clean_sentence("café au lait is very good here", "en"))


class CorpusShapeTests(unittest.TestCase):
    def test_every_category_and_language_present_and_deterministic(self):
        first, second = sample_corpus(), sample_corpus()
        self.assertEqual(first, second)
        seen = {(c["category"], c["language"]) for c in first["cases"]}
        self.assertEqual(seen, {(name, lang) for name in gen.CATEGORIES for lang in ("ru", "en")})

    def test_ids_are_unique_and_safe(self):
        ids = [c["id"] for c in sample_corpus()["cases"]]
        self.assertEqual(len(ids), len(set(ids)))
        for case_id in ids:
            self.assertRegex(case_id, r"^[A-Za-z0-9_-]{1,80}$")

    def test_wrong_layout_tokens_round_trip_to_expected(self):
        for case in sample_corpus()["cases"]:
            for typed, expected, layout, *_ in case["tokens"]:
                if typed == expected or case["category"] == "typo":
                    continue
                self.assertEqual(gen.to_other_layout(typed, layout), expected)

    def test_correct_and_caps_correct_expect_no_change(self):
        for case in sample_corpus()["cases"]:
            if case["category"] in ("correct", "caps-correct"):
                self.assertTrue(all(t[0] == t[1] for t in case["tokens"]))

    def test_caps_cases_are_uppercase_and_need_conversion(self):
        for case in sample_corpus()["cases"]:
            if case["category"] == "caps":
                for typed, expected, *_ in case["tokens"]:
                    self.assertEqual(expected, expected.upper())
                    self.assertNotEqual(typed, expected)

    def test_mixed_has_both_kept_and_converted_tokens(self):
        for case in sample_corpus()["cases"]:
            if case["category"] == "mixed":
                changed = [t[0] != t[1] for t in case["tokens"]]
                self.assertTrue(any(changed) and not all(changed))

    def test_typo_differs_from_clean_by_one_adjacent_swap(self):
        for case in sample_corpus()["cases"]:
            if case["category"] != "typo":
                continue
            marked = [i for i, token in enumerate(case["tokens"]) if len(token) == 4]
            self.assertEqual(len(marked), 1)
            self.assertEqual(case["tokens"][marked[0]][3], "typo")
            wrong = [tuple(token[:3]) for token in case["tokens"]]
            fixed = [gen.to_other_layout(t, lay) for t, _, lay in wrong]
            diffs = [(a, b) for a, (_, b, _) in zip(fixed, wrong) if a != b]
            self.assertEqual(len(diffs), 1)
            a, b = diffs[0]
            self.assertEqual(sorted(a), sorted(b))
            self.assertEqual(sum(x != y for x, y in zip(a, b)), 2)


class SourceReadingTests(unittest.TestCase):
    def test_reads_bz2_tsv_for_language(self):
        import bz2
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.tsv.bz2"
            path.write_bytes(bz2.compress("1\trus\tЯ люблю читать книги по вечерам.\n2\trus\tКороткая фраза\n".encode()))
            self.assertEqual(gen.read_sentences(path, "ru"), ["Я люблю читать книги по вечерам"])


class ShippedCorpusTests(unittest.TestCase):
    @unittest.skipUnless(CORPUS.exists(), "corpus not generated")
    def test_size_and_categories(self):
        data = json.loads(CORPUS.read_text(encoding="utf-8"))
        cases = data["cases"]
        self.assertTrue(5000 <= len(cases) <= 10000, len(cases))
        self.assertEqual({c["category"] for c in cases}, set(gen.CATEGORIES))
        self.assertEqual({c["language"] for c in cases}, {"ru", "en"})
        self.assertIn("CC BY 2.0 FR", data["source"]["license"])

    def test_notice_records_source_and_license(self):
        notice = (ROOT / "dictionaries/NOTICE.md").read_text(encoding="utf-8")
        self.assertIn("Tatoeba", notice)
        self.assertIn("CC BY 2.0 FR", notice)


if __name__ == "__main__":
    unittest.main()
