from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


FRAME_WIDTH = 192
FRAME_HEIGHT = 208

ANIMATION_STATES = {
    "idle": {"row": 0, "frames": 6, "durations": [280, 110, 110, 140, 140, 320]},
    "running-right": {"row": 1, "frames": 8, "durations": [120, 120, 120, 120, 120, 120, 120, 220]},
    "running-left": {"row": 2, "frames": 8, "durations": [120, 120, 120, 120, 120, 120, 120, 220]},
    "waving": {"row": 3, "frames": 4, "durations": [140, 140, 140, 280]},
    "jumping": {"row": 4, "frames": 5, "durations": [140, 140, 140, 140, 280]},
    "failed": {"row": 5, "frames": 8, "durations": [140, 140, 140, 140, 140, 140, 140, 240]},
    "waiting": {"row": 6, "frames": 6, "durations": [150, 150, 150, 150, 150, 260]},
    "running": {"row": 7, "frames": 6, "durations": [120, 120, 120, 120, 120, 220]},
    "review": {"row": 8, "frames": 6, "durations": [150, 150, 150, 150, 150, 280]},
}


def extract_idle_frames(spritesheet_path: Path, output_dir: Path) -> None:
    extract_state_frames(spritesheet_path, output_dir, "idle")


def extract_state_frames(spritesheet_path: Path, output_dir: Path, state: str) -> None:
    metadata = ANIMATION_STATES[state]
    output_dir.mkdir(parents=True, exist_ok=True)
    image = Image.open(spritesheet_path).convert("RGBA")
    row_top = metadata["row"] * FRAME_HEIGHT

    for column in range(metadata["frames"]):
        box = (
            column * FRAME_WIDTH,
            row_top,
            (column + 1) * FRAME_WIDTH,
            row_top + FRAME_HEIGHT,
        )
        frame = image.crop(box)
        frame.save(output_dir / f"{state}-{column}.png")


def extract_all_frames(spritesheet_path: Path, output_dir: Path) -> None:
    for state in ANIMATION_STATES:
        extract_state_frames(spritesheet_path, output_dir, state)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("spritesheet", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--state", choices=sorted(ANIMATION_STATES), default="all")
    args = parser.parse_args()

    if args.state == "all":
        extract_all_frames(args.spritesheet, args.output_dir)
    else:
        extract_state_frames(args.spritesheet, args.output_dir, args.state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
