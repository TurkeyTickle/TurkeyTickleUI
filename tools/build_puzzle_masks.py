"""Writes the puzzle's knob and hole mask textures: an antialiased circle, and its inverse.

    python3 tools/build_puzzle_masks.py

The circle's diameter is CIRCLE / SIZE of the texture; Board.lua sizes the masks to match.
"""

import os
import struct

SIZE = 64
CIRCLE = 60
SAMPLES = 8
OUT = os.path.join(os.path.dirname(__file__), "..", "TurkeyTickleUI_Puzzle", "Media")


def coverage(px, py):
    center, radius = SIZE / 2, CIRCLE / 2
    inside = 0
    for sy in range(SAMPLES):
        for sx in range(SAMPLES):
            dx = px + (sx + 0.5) / SAMPLES - center
            dy = py + (sy + 0.5) / SAMPLES - center
            inside += dx * dx + dy * dy <= radius * radius
    return inside / (SAMPLES * SAMPLES)


def write_tga(path, alpha):
    # Uncompressed 32-bit BGRA, top-left origin.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    body = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            body += bytes((255, 255, 255, round(alpha(x, y) * 255)))
    with open(path, "wb") as f:
        f.write(header + body)


def main():
    os.makedirs(OUT, exist_ok=True)
    write_tga(os.path.join(OUT, "Knob.tga"), coverage)
    write_tga(os.path.join(OUT, "Hole.tga"), lambda x, y: 1 - coverage(x, y))


if __name__ == "__main__":
    main()
