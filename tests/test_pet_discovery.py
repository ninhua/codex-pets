import json
import unittest
from pathlib import Path

from desktop_pet.app import (
    CODEX_SOURCE,
    LOCAL_SOURCE,
    choose_initial_pet,
    discover_pets,
)


def write_pet(root: Path, pet_id: str, name: str) -> Path:
    pet_dir = root / pet_id
    pet_dir.mkdir(parents=True)
    (pet_dir / "spritesheet.webp").write_bytes(b"fake image")
    (pet_dir / "pet.json").write_text(
        json.dumps(
            {
                "id": pet_id,
                "displayName": name,
                "description": f"{name} test pet",
                "spritesheetPath": "spritesheet.webp",
            }
        ),
        encoding="utf-8",
    )
    return pet_dir


class PetDiscoveryTests(unittest.TestCase):
    def test_discovers_codex_and_local_pets_with_source_labels(self):
        with self.subTest():
            from tempfile import TemporaryDirectory

            with TemporaryDirectory() as temp:
                root = Path(temp)
                codex_root = root / "codex"
                local_root = root / "local"
                write_pet(codex_root, "liuying", "Liuying")
                write_pet(local_root, "liuying", "Liuying Local")

                pets = discover_pets(codex_root, local_root)

                self.assertEqual([pet.source for pet in pets], [CODEX_SOURCE, LOCAL_SOURCE])
                self.assertEqual(
                    [pet.menu_label for pet in pets],
                    ["Liuying [Codex]", "Liuying Local [Local]"],
                )
                self.assertTrue(all(pet.spritesheet_path.exists() for pet in pets))

    def test_ignores_pets_with_missing_spritesheet(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as temp:
            root = Path(temp)
            codex_root = root / "codex"
            pet_dir = codex_root / "broken"
            pet_dir.mkdir(parents=True)
            (pet_dir / "pet.json").write_text(
                json.dumps(
                    {"id": "broken", "displayName": "Broken", "spritesheetPath": "missing.webp"}
                ),
                encoding="utf-8",
            )

            self.assertEqual(discover_pets(codex_root, root / "local"), [])

    def test_choose_initial_pet_prefers_saved_selection(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as temp:
            root = Path(temp)
            codex_root = root / "codex"
            local_root = root / "local"
            write_pet(codex_root, "liuying", "Liuying")
            write_pet(local_root, "test-pet", "Test Pet")
            pets = discover_pets(codex_root, local_root)

            selected = choose_initial_pet(pets, {"source": LOCAL_SOURCE, "id": "test-pet"})

            self.assertIsNotNone(selected)
            self.assertEqual(selected.source, LOCAL_SOURCE)
            self.assertEqual(selected.pet_id, "test-pet")

    def test_choose_initial_pet_falls_back_to_codex_liuying_then_first(self):
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as temp:
            root = Path(temp)
            codex_root = root / "codex"
            local_root = root / "local"
            write_pet(codex_root, "liuying", "Liuying")
            write_pet(local_root, "alpha", "Alpha")
            pets = discover_pets(codex_root, local_root)

            selected = choose_initial_pet(pets, {"source": LOCAL_SOURCE, "id": "missing"})
            self.assertEqual(selected.pet_id, "liuying")

            only_local = discover_pets(root / "empty", local_root)
            self.assertEqual(choose_initial_pet(only_local, {}).pet_id, "alpha")


if __name__ == "__main__":
    unittest.main()
