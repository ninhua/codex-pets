import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image

from desktop_pet.scripts.extract_idle_frames import ANIMATION_STATES, extract_state_frames


class FrameExtractorTests(unittest.TestCase):
    def test_animation_state_metadata_matches_codex_atlas(self):
        self.assertEqual(ANIMATION_STATES["idle"]["row"], 0)
        self.assertEqual(ANIMATION_STATES["idle"]["frames"], 6)
        self.assertEqual(ANIMATION_STATES["running-right"]["row"], 1)
        self.assertEqual(ANIMATION_STATES["running-right"]["frames"], 8)
        self.assertEqual(ANIMATION_STATES["review"]["row"], 8)
        self.assertEqual(ANIMATION_STATES["review"]["durations"], [150, 150, 150, 150, 150, 280])

    def test_extract_state_frames_writes_named_pngs(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            spritesheet = root / "spritesheet.png"
            output_dir = root / "frames"
            Image.new("RGBA", (1536, 1872), (0, 0, 0, 0)).save(spritesheet)

            extract_state_frames(spritesheet, output_dir, "waving")

            self.assertEqual(
                sorted(path.name for path in output_dir.iterdir()),
                ["waving-0.png", "waving-1.png", "waving-2.png", "waving-3.png"],
            )


if __name__ == "__main__":
    unittest.main()
