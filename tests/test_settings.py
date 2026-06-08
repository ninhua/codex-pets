import unittest

from desktop_pet.settings import DEFAULT_SCALE, normalize_scale


class SettingsTests(unittest.TestCase):
    def test_default_scale_matches_codex_like_size(self):
        self.assertEqual(DEFAULT_SCALE, 0.6)

    def test_normalize_scale_uses_default_for_invalid_values(self):
        self.assertEqual(normalize_scale(None), 0.6)
        self.assertEqual(normalize_scale("nope"), 0.6)
        self.assertEqual(normalize_scale(-1), 0.6)

    def test_normalize_scale_snaps_to_supported_scale(self):
        self.assertEqual(normalize_scale(0.62), 0.6)
        self.assertEqual(normalize_scale("1.2"), 1.25)


if __name__ == "__main__":
    unittest.main()
