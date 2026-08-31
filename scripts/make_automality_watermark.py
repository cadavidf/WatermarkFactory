#!/usr/bin/env python3
"""
Generates a transparent-background Automality watermark mark, reproducing
the proportions measured from ~/Dev/animality-kiosk/brand/automality-mark.png
(which has a solid teal-deep background fill, unusable as a watermark as-is).

Geometry measured on the 180x180 source (all values scale proportionally):
  - Two teal vertical bars, each 44px wide, spanning y=[34,146] (112px tall,
    33px margin top/bottom).
  - Bars at x=[34,78] and x=[102,146] (44px gap between their inner edges).
  - Orange square, 44x46px, at x=[68,112] y=[67,113] -- overlaps ~10px into
    each bar's inner edge and sits vertically centered.

Output: transparent PNG at 512x512, same proportions, brand hex colors.
"""
from PIL import Image, ImageDraw

SIZE = 512
SCALE = SIZE / 180.0

TEAL = (0x1A, 0x9A, 0xB2, 255)
ORANGE = (0xF2, 0x64, 0x19, 255)

def s(v):
    return round(v * SCALE)

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Two teal bars
draw.rectangle([s(34), s(34), s(78), s(146)], fill=TEAL)
draw.rectangle([s(102), s(34), s(146), s(146)], fill=TEAL)
# Orange square on top, overlapping both bars' inner edges
draw.rectangle([s(68), s(67), s(112), s(113)], fill=ORANGE)

# Plain bundled resource (not an asset catalog imageset) -- ImageProcessor
# consumes plain file URLs, and Bundle.main.url(forResource:withExtension:)
# gives one directly with no extraction step needed.
out_path = "WatermarkFactory/Resources"
import os
os.makedirs(out_path, exist_ok=True)
img.save(f"{out_path}/automality-watermark.png")

print(f"Wrote {out_path}/automality-watermark.png ({SIZE}x{SIZE}, transparent)")
