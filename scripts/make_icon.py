#!/usr/bin/env python3
"""Generates the WatermarkFactory app icon: a photo stack with a translucent
diagonal watermark stamp across it, on a rounded-square dark gradient."""
import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# --- rounded-square background with a subtle diagonal gradient ---
bg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
grad = Image.new("L", (SIZE, SIZE))
for y in range(SIZE):
    for x in range(0, SIZE, 4):
        t = (x + y) / (2 * SIZE)
        v = int(28 + t * 40)
        for dx in range(4):
            if x + dx < SIZE:
                grad.putpixel((x + dx, y), v)
top = (46, 58, 84, 255)     # slate blue
bottom = (20, 24, 36, 255)  # near-black navy
solid = Image.new("RGBA", (SIZE, SIZE), bottom)
tint = Image.new("RGBA", (SIZE, SIZE), top)
bg = Image.composite(tint, solid, grad)

mask = Image.new("L", (SIZE, SIZE), 0)
d = ImageDraw.Draw(mask)
r = 210
d.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=r, fill=255)
img = Image.composite(bg, img, mask)
draw = ImageDraw.Draw(img)

# --- two stacked photo cards ---
def photo_card(cx, cy, w, h, angle, fill, outline):
    card = Image.new("RGBA", (w + 40, h + 40), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    cd.rounded_rectangle([20, 20, 20 + w, 20 + h], radius=28, fill=fill, outline=outline, width=6)
    card = card.rotate(angle, resample=Image.BICUBIC, expand=True)
    img.alpha_composite(card, (int(cx - card.width / 2), int(cy - card.height / 2)))

shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle([300, 340, 300 + 460, 340 + 360], radius=28, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(shadow, (18, 18))

photo_card(430, 470, 440, 340, -6, (235, 238, 244, 255), (255, 255, 255, 60))
photo_card(480, 520, 440, 340, 4, (250, 251, 253, 255), (255, 255, 255, 80))

# a little mountain/sun glyph inside the top photo to read as "an image"
gd = ImageDraw.Draw(img)
gd.ellipse([620, 400, 690, 470], fill=(247, 197, 106, 255))
gd.polygon([(300, 660), (430, 480), (520, 590), (600, 500), (720, 660)], fill=(120, 150, 130, 255))

# --- diagonal translucent watermark stamp band across the whole icon ---
band = Image.new("RGBA", (SIZE * 2, 260), (0, 0, 0, 0))
bd = ImageDraw.Draw(band)
bd.rectangle([0, 0, band.width, band.height], fill=(255, 255, 255, 46))
bd.rectangle([0, 0, band.width, 8], fill=(255, 255, 255, 90))
bd.rectangle([0, band.height - 8, band.width, band.height], fill=(255, 255, 255, 90))
band = band.rotate(-32, resample=Image.BICUBIC, expand=True)
img.alpha_composite(band, (int(SIZE / 2 - band.width / 2), int(SIZE / 2 - band.height / 2) - 10))

# re-mask to rounded square edges after compositing overlays
img = Image.composite(img, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask)

out_dir = "assets_src"
import os
os.makedirs(out_dir, exist_ok=True)
img.save(f"{out_dir}/icon_1024.png")
print("wrote assets_src/icon_1024.png")
