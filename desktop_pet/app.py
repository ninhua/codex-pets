from __future__ import annotations

import json
import sys
import tkinter as tk
from dataclasses import dataclass
from pathlib import Path
from tkinter import messagebox
from typing import Any

from PIL import Image, ImageTk


APP_DIR = Path(__file__).resolve().parent
CODEX_PETS_DIR = Path.home() / ".codex" / "pets"
LOCAL_PETS_DIR = APP_DIR / "pets"
CONFIG_PATH = APP_DIR / "config.json"

CODEX_SOURCE = "codex"
LOCAL_SOURCE = "local"

SOURCE_LABELS = {
    CODEX_SOURCE: "Codex",
    LOCAL_SOURCE: "Local",
}

FRAME_WIDTH = 192
FRAME_HEIGHT = 208
IDLE_ROW = 0
IDLE_COLUMNS = range(6)
IDLE_DURATIONS_MS = [280, 110, 110, 140, 140, 320]
TRANSPARENT_COLOR = "#00ff01"


@dataclass(frozen=True)
class PetInfo:
    source: str
    pet_id: str
    display_name: str
    description: str
    pet_dir: Path
    spritesheet_path: Path

    @property
    def source_label(self) -> str:
        return SOURCE_LABELS.get(self.source, self.source)

    @property
    def menu_label(self) -> str:
        return f"{self.display_name} [{self.source_label}]"

    @property
    def selection_key(self) -> tuple[str, str]:
        return (self.source, self.pet_id)


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return {}


def load_config(config_path: Path = CONFIG_PATH) -> dict[str, Any]:
    if not config_path.exists():
        return {}
    return read_json(config_path)


def save_config(pet: PetInfo, config_path: Path = CONFIG_PATH) -> None:
    payload = {
        "source": pet.source,
        "id": pet.pet_id,
    }
    config_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def discover_pets(
    codex_root: Path = CODEX_PETS_DIR,
    local_root: Path = LOCAL_PETS_DIR,
) -> list[PetInfo]:
    pets: list[PetInfo] = []
    pets.extend(_discover_from_root(codex_root, CODEX_SOURCE))
    pets.extend(_discover_from_root(local_root, LOCAL_SOURCE))
    return pets


def _discover_from_root(root: Path, source: str) -> list[PetInfo]:
    if not root.exists():
        return []

    pets: list[PetInfo] = []
    for pet_dir in sorted((entry for entry in root.iterdir() if entry.is_dir()), key=lambda p: p.name.lower()):
        manifest_path = pet_dir / "pet.json"
        if not manifest_path.exists():
            continue

        manifest = read_json(manifest_path)
        pet_id = str(manifest.get("id") or pet_dir.name).strip()
        display_name = str(manifest.get("displayName") or pet_id).strip()
        description = str(manifest.get("description") or "").strip()
        spritesheet_name = str(manifest.get("spritesheetPath") or "spritesheet.webp").strip()
        if not pet_id or not spritesheet_name:
            continue

        spritesheet_path = (pet_dir / spritesheet_name).resolve()
        if not spritesheet_path.exists():
            continue

        pets.append(
            PetInfo(
                source=source,
                pet_id=pet_id,
                display_name=display_name,
                description=description,
                pet_dir=pet_dir.resolve(),
                spritesheet_path=spritesheet_path,
            )
        )
    return pets


def choose_initial_pet(pets: list[PetInfo], config: dict[str, Any]) -> PetInfo | None:
    if not pets:
        return None

    saved_source = str(config.get("source") or "")
    saved_id = str(config.get("id") or "")
    if saved_source and saved_id:
        for pet in pets:
            if pet.source == saved_source and pet.pet_id == saved_id:
                return pet

    for pet in pets:
        if pet.source == CODEX_SOURCE and pet.pet_id == "liuying":
            return pet

    return pets[0]


class DesktopPetApp:
    def __init__(self, root: tk.Tk, pets: list[PetInfo], selected_pet: PetInfo) -> None:
        self.root = root
        self.pets = pets
        self.current_pet = selected_pet
        self.frames: list[ImageTk.PhotoImage] = []
        self.frame_index = 0
        self.drag_offset_x = 0
        self.drag_offset_y = 0
        self.animation_job: str | None = None

        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=TRANSPARENT_COLOR)
        self.root.wm_attributes("-transparentcolor", TRANSPARENT_COLOR)

        self.label = tk.Label(self.root, bd=0, bg=TRANSPARENT_COLOR)
        self.label.pack()

        self.menu = tk.Menu(self.root, tearoff=0)

        self.label.bind("<ButtonPress-1>", self.start_drag)
        self.label.bind("<B1-Motion>", self.drag)
        self.label.bind("<Button-3>", self.show_menu)
        self.root.bind("<Button-3>", self.show_menu)

        self.load_pet(selected_pet)
        self.place_default()

    def build_menu(self) -> None:
        self.menu.delete(0, tk.END)
        for pet in self.pets:
            prefix = "[current] " if pet.selection_key == self.current_pet.selection_key else ""
            self.menu.add_command(
                label=f"{prefix}{pet.menu_label}",
                command=lambda selected=pet: self.switch_pet(selected),
            )
        self.menu.add_separator()
        self.menu.add_command(label="Exit", command=self.root.destroy)

    def load_pet(self, pet: PetInfo) -> None:
        if self.animation_job is not None:
            self.root.after_cancel(self.animation_job)
            self.animation_job = None

        image = Image.open(pet.spritesheet_path).convert("RGBA")
        self.frames = []
        row_top = IDLE_ROW * FRAME_HEIGHT
        for column in IDLE_COLUMNS:
            box = (
                column * FRAME_WIDTH,
                row_top,
                (column + 1) * FRAME_WIDTH,
                row_top + FRAME_HEIGHT,
            )
            frame = image.crop(box)
            self.frames.append(ImageTk.PhotoImage(frame))

        self.current_pet = pet
        self.root.title(f"{pet.display_name} Desktop Pet")
        self.frame_index = 0
        self.build_menu()
        save_config(pet)
        self.animate()

    def switch_pet(self, pet: PetInfo) -> None:
        if pet.selection_key == self.current_pet.selection_key:
            return
        self.load_pet(pet)

    def animate(self) -> None:
        if not self.frames:
            return
        frame = self.frames[self.frame_index]
        self.label.configure(image=frame)
        delay = IDLE_DURATIONS_MS[self.frame_index % len(IDLE_DURATIONS_MS)]
        self.frame_index = (self.frame_index + 1) % len(self.frames)
        self.animation_job = self.root.after(delay, self.animate)

    def place_default(self) -> None:
        self.root.update_idletasks()
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        x = max(0, screen_width - FRAME_WIDTH - 80)
        y = max(0, screen_height - FRAME_HEIGHT - 120)
        self.root.geometry(f"{FRAME_WIDTH}x{FRAME_HEIGHT}+{x}+{y}")

    def start_drag(self, event: tk.Event) -> None:
        self.drag_offset_x = event.x
        self.drag_offset_y = event.y

    def drag(self, event: tk.Event) -> None:
        x = event.x_root - self.drag_offset_x
        y = event.y_root - self.drag_offset_y
        self.root.geometry(f"+{x}+{y}")

    def show_menu(self, event: tk.Event) -> None:
        self.build_menu()
        self.menu.tk_popup(event.x_root, event.y_root)


def main() -> int:
    pets = discover_pets()
    selected_pet = choose_initial_pet(pets, load_config())
    if selected_pet is None:
        root = tk.Tk()
        root.withdraw()
        messagebox.showinfo(
            "Desktop Pet",
            "No valid pets found in ~/.codex/pets or the local pets directory.",
        )
        root.destroy()
        return 1

    root = tk.Tk()
    DesktopPetApp(root, pets, selected_pet)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
