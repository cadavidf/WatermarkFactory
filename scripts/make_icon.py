#!/usr/bin/env python3
"""Generates the WatermarkFactory app icon on-brand for Automality: a house
built entirely from square blocks (no diagonal/rounded roof shapes), with
exactly one orange square as the house's window — the brand's single-accent
rule applied literally. Flat colors, hard ink borders, no gradients/blur
(gradients and soft shadows disappear at 16x16; this icon must read at
every size Finder/Dock actually render it)."""
from PIL import Image, ImageDraw

SIZE = 1024

# Real Automality design tokens (AutomalityColor.swift) — not invented.
INK = (28, 48, 64, 255)         # 0x1C3040
TEAL_DEEP = (8, 62, 72, 255)    # 0x083E48
TEAL = (26, 154, 178, 255)      # 0x1A9AB2
OFF_WHITE = (245, 250, 251, 255)  # 0xF5FAFB
ORANGE = (242, 100, 25, 255)    # 0xF26419

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# --- rounded-square canvas mask (macOS icon convention) ---
mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=210, fill=255)

bg = Image.new("RGBA", (SIZE, SIZE), TEAL_DEEP)
img = Image.composite(bg, img, mask)
draw = ImageDraw.Draw(img)

# --- house grid: 9 columns wide.
# Rows 0-3: stepped roof (a pyramid built from square blocks, not a triangle).
# Rows 4-8: body, 9x5 block grid.
# Exactly one cell (the window) is orange; every other house cell is offWhite.
COLS = 9
ROWS = 9
roof = {
    0: range(4, 5),
    1: range(3, 6),
    2: range(2, 7),
    3: range(1, 8),
}
body_rows = range(4, 9)
window_cell = (5, 1)  # (row, col) within the body — one square, one accent.
# door: a rectangular opening with an arched top, cut into the base of the
# house (background shows through) — distinct from the window, so it must
# not overlap it.
door_cols = range(3, 6)  # 3 cells wide, centered on the 9-wide body
door_rows = range(6, 9)  # bottom 3 rows, flush with the house's base

margin = 140
grid_w = SIZE - margin * 2
cell = grid_w // COLS
grid_h = cell * ROWS
origin_x = margin
origin_y = (SIZE - grid_h) // 2 + 40

# hard offset shadow behind the whole house silhouette — the same signature
# 4px-scaled offset-shadow language as AutomalityButtonStyle, applied once
# to the shape as a whole rather than per-tiny-square (stays legible small).
shadow_offset = cell // 3
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)


def cell_rect(row, col, dx=0, dy=0):
    x0 = origin_x + col * cell + dx
    y0 = origin_y + row * cell + dy
    return [x0, y0, x0 + cell, y0 + cell]


for row, cols in roof.items():
    for col in cols:
        sd.rectangle(cell_rect(row, col, shadow_offset, shadow_offset), fill=(0, 0, 0, 140))
for row in body_rows:
    for col in range(COLS):
        sd.rectangle(cell_rect(row, col, shadow_offset, shadow_offset), fill=(0, 0, 0, 140))
img.alpha_composite(shadow)

border = max(6, cell // 14)


def draw_cell(row, col, fill):
    rect = cell_rect(row, col)
    draw.rectangle(rect, fill=fill, outline=INK, width=border)


for row, cols in roof.items():
    for col in cols:
        draw_cell(row, col, OFF_WHITE)
for row in body_rows:
    for col in range(COLS):
        is_window = (row, col) == window_cell
        draw_cell(row, col, ORANGE if is_window else OFF_WHITE)

# --- carve the door: a rectangular opening with an arched top, cut through
# the house blocks so the dark background shows through, like a real
# doorway. This is the one deliberate curve in an otherwise all-square icon.
door_x0 = origin_x + door_cols.start * cell
door_x1 = origin_x + door_cols.stop * cell
door_y0 = origin_y + door_rows.start * cell
door_y1 = origin_y + door_rows.stop * cell
door_width = door_x1 - door_x0
door_radius = door_width // 2
door_straight_y0 = door_y0 + door_radius  # where the arch meets the jambs

# jambs: a plain rectangle for the straight-sided lower portion
draw.rectangle([door_x0, door_straight_y0, door_x1, door_y1], fill=TEAL_DEEP)
draw.line([door_x0, door_straight_y0, door_x0, door_y1], fill=INK, width=border)
draw.line([door_x1, door_straight_y0, door_x1, door_y1], fill=INK, width=border)

# arch: a half-circle capping the top of the doorway
draw.pieslice(
    [door_x0, door_y0, door_x1, door_y0 + door_radius * 2],
    180, 360,
    fill=TEAL_DEEP, outline=INK, width=border,
)

# re-apply the rounded-square canvas mask on top of everything
img = Image.composite(img, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask)

import os
out_dir = "assets_src"
os.makedirs(out_dir, exist_ok=True)
img.save(f"{out_dir}/icon_1024.png")
print("wrote assets_src/icon_1024.png")
