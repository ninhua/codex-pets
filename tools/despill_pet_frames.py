#!/usr/bin/env python3
"""Remove green-screen fringe from extracted pet frames."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def has_transparent_neighbor(alpha, x: int, y: int, radius: int = 2) -> bool:
    width, height = alpha.size
    for yy in range(max(0, y - radius), min(height, y + radius + 1)):
        for xx in range(max(0, x - radius), min(width, x + radius + 1)):
            if alpha.getpixel((xx, yy)) <= 8:
                return True
    return False


def clean_image(path: Path) -> int:
    image = Image.open(path).convert("RGBA")
    alpha = image.getchannel("A")
    pixels = image.load()
    changed = 0

    for y in range(image.height):
        for x in range(image.width):
            red, green, blue, a = pixels[x, y]
            if a == 0:
                if (red, green, blue) != (0, 0, 0):
                    pixels[x, y] = (0, 0, 0, 0)
                    changed += 1
                continue

            green_excess = green - max(red, blue)
            near_alpha = has_transparent_neighbor(alpha, x, y, radius=3)
            strong_key = green > 135 and red < 125 and blue < 125 and green_excess > 45
            edge_green = green > 85 and green_excess > 12 and near_alpha

            if strong_key:
                pixels[x, y] = (0, 0, 0, 0)
                changed += 1
            elif edge_green:
                target_green = max(red, blue) + 2
                pixels[x, y] = (red, min(green, target_green), blue, a)
                changed += 1

    if changed:
        image.save(path)
    return changed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("frames_root", type=Path)
    args = parser.parse_args()

    total = 0
    files = sorted(args.frames_root.glob("*/*.png"))
    for path in files:
        total += clean_image(path)
    print({"files": len(files), "changed_pixels": total})


if __name__ == "__main__":
    main()
