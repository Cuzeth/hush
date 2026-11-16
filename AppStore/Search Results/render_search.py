#!/usr/bin/env python3
"""Render the App Store search results asset (3:2).

The headline, subhead and the iPhone's mix card are composed inside Apple's
Art Safe Area; the iPad and the background are auxiliary art that may be
cropped. Size and safe area come from Apple's creative asset templates:
https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications

Usage: ~/.venvs/tools/bin/python "AppStore/Search Results/render_search.py" [out_dir] [--guides]
  --guides also writes a *-guides.png with the safe area drawn on top (never upload that).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
NAME = "search-3x2-3840x2560"
SIZE = (3840, 2560)
SAFE = (836, 765, 2168, 1030)  # x, y, w, h

HEADLINE = ["Mix your own", "focus sounds"]
HEADLINE_FONT = ("/System/Library/Fonts/NewYork.ttf", [44, 600, 0])  # optical size, weight, grade
HEADLINE_COLOR = (247, 246, 241)
HEADLINE_WIDTH = 1060  # ink width of the widest line
SUBHEAD = "Rain, noise, beats and 87 ambient sounds, layered your way."
SUBHEAD_FONT = ("/System/Library/Fonts/SFNS.ttf", [100, 62, 400, 400])  # width, optical size, grade, weight
SUBHEAD_COLOR = (181, 183, 195)
SUBHEAD_SIZE = 62
TEXT_LEFT = 884
TEXT_CENTER_Y = 1280

# Device mockups cut from the original artwork (source/). The iPad is only its
# left part, so its cut edge has to sit on the canvas edge.
IPHONE_AT = (2156, 600)
IPAD_TOP = 440
IPHONE_KEY_ROWS = (200, 930)  # app title down to the Customize row, in sprite pixels

GRAIN_SIGMA = 2.2
# Background gradient: polynomial in x, y (each -1..1) fitted to the original artwork.
BG_TERMS = [(0, 0), (0, 1), (0, 2), (0, 3), (0, 4), (1, 0), (1, 1), (1, 2), (1, 3), (2, 0), (2, 1), (2, 2), (3, 0), (3, 1), (4, 0)]
BG_COEFS = [
    [30.533, -2.873, -0.639, 0.240, 1.123, 0.038, -0.176, 0.116, 0.175, -0.109, 5.925, -8.964, 0.022, 0.012, -0.628],
    [42.057, -6.102, -1.795, 0.634, 2.544, 0.071, -0.300, 0.195, 0.296, -0.024, 7.625, -12.296, -0.001, 0.079, -0.982],
    [38.694, -4.199, -1.025, 0.494, 1.675, 0.033, -0.254, 0.169, 0.265, 0.041, 7.230, -11.040, 0.046, 0.055, -0.983],
]


def font(spec, size):
    path, axes = spec
    f = ImageFont.truetype(path, size)
    f.set_variation_by_axes(axes)
    return f


def background(width, height):
    w, h = width // 16, height // 16
    yy, xx = np.mgrid[0:h, 0:w]
    x = (xx + 0.5) / w * 2 - 1
    y = (yy + 0.5) / h * 2 - 1
    small = np.stack([sum(c * x ** i * y ** j for c, (i, j) in zip(coef, BG_TERMS)) for coef in BG_COEFS], -1)
    channels = [Image.fromarray(small[..., c].astype(np.float32), "F").resize((width, height), Image.BICUBIC)
                for c in range(3)]
    canvas = np.stack([np.asarray(c) for c in channels], -1)
    coarse = np.random.default_rng(11).normal(0, 1, (height // 2 + 1, width // 2 + 1)).astype(np.float32)
    grain = np.asarray(Image.fromarray(coarse, "F").resize((width, height), Image.BILINEAR))
    canvas = canvas + (grain * (GRAIN_SIGMA / grain.std()))[..., None]
    return Image.fromarray(np.clip(canvas + 0.5, 0, 255).astype(np.uint8), "RGB")


def place(image, sprite, at):
    """Paste a device with a soft shadow underneath it."""
    pad = 160
    shadow = Image.new("L", (sprite.width + 2 * pad, sprite.height + 2 * pad), 0)
    shadow.paste(sprite.getchannel("A"), (pad, pad + 24))
    shadow = shadow.filter(ImageFilter.GaussianBlur(42)).point(lambda v: int(v * 0.5))
    image.paste((0, 0, 0), (at[0] - pad, at[1] - pad), shadow)
    image.paste(sprite, at, sprite)


def wrap(draw, text, f, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if line and draw.textlength(trial, font=f) > width:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


def render(out_dir, guides=False):
    W, H = SIZE
    image = background(W, H)
    iphone = Image.open(HERE / "source" / "iphone.png")
    ipad = Image.open(HERE / "source" / "ipad-left.png")
    place(image, ipad, (W - ipad.width, IPAD_TOP))
    place(image, iphone, IPHONE_AT)

    draw = ImageDraw.Draw(image)
    probe = font(HEADLINE_FONT, 400)
    widest = max(probe.getbbox(line)[2] - probe.getbbox(line)[0] for line in HEADLINE)
    head_size = round(400 * HEADLINE_WIDTH / widest)
    head = font(HEADLINE_FONT, head_size)
    sub = font(SUBHEAD_FONT, SUBHEAD_SIZE)
    sub_lines = wrap(draw, SUBHEAD, sub, HEADLINE_WIDTH)
    head_step, sub_step, gap = round(head_size * 1.1), round(SUBHEAD_SIZE * 1.4), round(head_size * 0.42)
    block = head_step * len(HEADLINE) + gap + sub_step * len(sub_lines)
    y = TEXT_CENTER_Y - block // 2
    boxes = []
    for line in HEADLINE:
        # align the ink, not the side bearing, to the left edge
        draw.text((TEXT_LEFT - head.getbbox(line)[0], y), line, font=head, fill=HEADLINE_COLOR)
        boxes.append(draw.textbbox((TEXT_LEFT - head.getbbox(line)[0], y), line, font=head))
        y += head_step
    y += gap
    for line in sub_lines:
        draw.text((TEXT_LEFT - sub.getbbox(line)[0], y), line, font=sub, fill=SUBHEAD_COLOR)
        boxes.append(draw.textbbox((TEXT_LEFT - sub.getbbox(line)[0], y), line, font=sub))
        y += sub_step

    out = Path(out_dir) / f"{NAME}.png"
    image.save(out, optimize=True)

    sx, sy, sw, sh = SAFE
    text_box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    phone_box = (IPHONE_AT[0], IPHONE_AT[1] + IPHONE_KEY_ROWS[0],
                 IPHONE_AT[0] + iphone.width, IPHONE_AT[1] + IPHONE_KEY_ROWS[1])
    for label, (x0, y0, x1, y1) in (("text", text_box), ("iPhone mix card", phone_box)):
        inside = x0 >= sx and y0 >= sy and x1 <= sx + sw and y1 <= sy + sh
        print(f"{NAME}: {label} {x0},{y0} to {x1},{y1} "
              f"{'inside' if inside else 'OUTSIDE'} safe area {sx},{sy} to {sx + sw},{sy + sh}")
        if not inside:
            raise SystemExit(f"{NAME}: {label} leaves the art safe area")

    if guides:
        overlay = image.convert("RGBA")
        layer = Image.new("RGBA", overlay.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).rectangle([sx, sy, sx + sw, sy + sh], fill=(0, 255, 0, 60), outline=(0, 255, 0, 255), width=6)
        Image.alpha_composite(overlay, layer).convert("RGB").save(Path(out_dir) / f"{NAME}-guides.png")
    return out


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    print("wrote", render(args[0] if args else str(HERE), guides="--guides" in sys.argv))
