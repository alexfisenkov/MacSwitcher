import tempfile
import unittest
from pathlib import Path

import build_trigrams


class BuildTrigramsTests(unittest.TestCase):
    def test_counts_padded_trigrams_with_log_weights(self):
        counts = build_trigrams.count_trigrams([("кот", 8), ("кот9", 100), ("Кот", 5)], "ru")
        # Only the lowercase lexical word counts; frequency 8 weighs int(log2 8) + 1 = 4.
        self.assertEqual(counts, {"^^к": 4, "^ко": 4, "кот": 4, "от$": 4})

    def test_rendered_table_is_sorted_and_drops_single_counts(self):
        text = build_trigrams.render({"^^b": 1, "^^a": 3, "ab$": 2})
        self.assertEqual(text, "^^a\t3\nab$\t2\n")

    def test_build_writes_both_languages_under_two_megabytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "ru.tsv").write_text("привет\t1000\nмир\t500\n", encoding="utf-8")
            (root / "en.tsv").write_text("hello\t1000\n", encoding="utf-8")
            sizes = build_trigrams.build(root)
            self.assertTrue((root / "ru-trigrams.tsv").read_text(encoding="utf-8").startswith("^^м\t"))
            self.assertLess(max(sizes.values()), build_trigrams.MAX_BYTES)

    def test_shipped_tables_match_a_rebuild(self):
        resources = build_trigrams.RESOURCES
        with tempfile.TemporaryDirectory() as folder:
            build_trigrams.build(resources, Path(folder))
            for language in ("ru", "en"):
                shipped = (resources / f"{language}-trigrams.tsv").read_bytes()
                self.assertLessEqual(len(shipped), build_trigrams.MAX_BYTES)
                self.assertEqual(shipped, (Path(folder) / f"{language}-trigrams.tsv").read_bytes())


if __name__ == "__main__":
    unittest.main()
