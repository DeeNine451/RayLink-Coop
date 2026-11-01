#!/usr/bin/env python3
"""The soft spot of a head torch's glare (scripts/coop_hud_glare.script): gamedata/textures/ui/coop/ui_coop_glare.dds.

128x128, an uncompressed DDS A8R8G8B8 (BGRA bytes) without mips, the layout of ui_coop_hud.dds (tools/make_hud_atlas.py).
One warm white everywhere, under alpha 0 too (a texture filter then has no dark fringe to pull in); the shape is the alpha:
a hot core in a wide halo, 0 on the border so that no square shows. textures_descr/ui_coop_glare.xml is written by hand.
The standard library only.

Usage: python -I tools/make_glare_texture.py [--gamedata DIR]     (default: gamedata of this project)
"""
import argparse
import math
import struct
from pathlib import Path

SIZE = 128
WARM = (255, 244, 224)  # R, G, B


def alpha_at(r):
    """r: distance from the centre, 1 at the edge of the image. 0..1."""
    core = 0.62 * math.exp(-((r / 0.20) ** 2))
    halo = 0.38 * math.exp(-((r / 0.52) ** 2))
    t = min(1.0, max(0.0, (r - 0.72) / 0.26))  # the window closes before the border
    return (core + halo) * (1.0 - t * t * (3.0 - 2.0 * t))


def pixels():
    c = SIZE / 2.0
    out = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            r = math.hypot(x + 0.5 - c, y + 0.5 - c) / c
            a = int(round(255 * alpha_at(r) / alpha_at(0.0)))
            out += bytes((WARM[2], WARM[1], WARM[0], a))
    return bytes(out)


def write_dds(data, path):
    """DDS A8R8G8B8 (masks R 0xFF0000 / G 0xFF00 / B 0xFF / A 0xFF000000), one level: BGRA bytes."""
    hdr = struct.pack("<4s7I", b"DDS ", 124, 0x100F, SIZE, SIZE, SIZE * 4, 0, 1)
    hdr += b"\0" * 44
    hdr += struct.pack("<2I4s5I", 32, 0x41, b"\0\0\0\0", 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000)
    hdr += struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    assert len(hdr) == 128
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(hdr + data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gamedata", type=Path, default=Path(__file__).resolve().parent.parent / "gamedata")
    args = ap.parse_args()
    dds = args.gamedata / "textures" / "ui" / "coop" / "ui_coop_glare.dds"
    write_dds(pixels(), dds)
    print("%s (%d bytes)" % (dds, dds.stat().st_size))


if __name__ == "__main__":
    main()
