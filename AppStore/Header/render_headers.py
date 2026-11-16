#!/usr/bin/env python3
"""Render the App Store product page header (21:9) and universal asset (16:9).

Everything a visitor has to see (the tagline and the moon) is composed inside
Apple's Art Safe Area; the sky and the waves are auxiliary art that may be
cropped. Sizes and safe areas come from Apple's creative asset templates:
https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications

Usage: ~/.venvs/tools/bin/python AppStore/Header/render_headers.py [out_dir] [--guides]
  --guides also writes *-guides.png with the safe area drawn on top (never upload those).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/NewYork.ttf"
FONT_AXES = [44, 600, 0]  # optical size, weight, grade
TAGLINE = "Build your own quiet."

SKY = (16, 26, 22)
GLOW = (50, 54, 49)
MOON = (238, 229, 211)
TEXT = (245, 244, 239)
WAVE_COLORS = [(175, 193, 186), (89, 124, 112), (43, 65, 57), (21, 33, 29)]
GRAIN_SIGMA = 2.2

# Top edge of each wave layer, back to front, sampled left to right.
# Values are fractions of the canvas height in the original 16:9 artwork.
WAVES = [
    [0.6942, 0.6956, 0.6956, 0.6956, 0.6956, 0.6944, 0.6924, 0.6896, 0.6869, 0.6838, 0.6808, 0.6774, 0.6745, 0.6718, 0.6692, 0.6671, 0.6653, 0.6638, 0.6627, 0.6617, 0.6605, 0.6600, 0.6590, 0.6579, 0.6569, 0.6554, 0.6537, 0.6516, 0.6490, 0.6463, 0.6435, 0.6405, 0.6371, 0.6340, 0.6311, 0.6284, 0.6260, 0.6243, 0.6237, 0.6237, 0.6237, 0.6252, 0.6272, 0.6301, 0.6338, 0.6386, 0.6432, 0.6484, 0.6539, 0.6593, 0.6650, 0.6703, 0.6748, 0.6792, 0.6832, 0.6861, 0.6884, 0.6900, 0.6902, 0.6902, 0.6902, 0.6894, 0.6881, 0.6864, 0.6843, 0.6826, 0.6807, 0.6787, 0.6771, 0.6757, 0.6745, 0.6737, 0.6725, 0.6725, 0.6713, 0.6712, 0.6707, 0.6698, 0.6686, 0.6673, 0.6655, 0.6635, 0.6608, 0.6578, 0.6539, 0.6501, 0.6460, 0.6418, 0.6374, 0.6334, 0.6299, 0.6266, 0.6237, 0.6218, 0.6210, 0.6210, 0.6210, 0.6219, 0.6240, 0.6270, 0.6305, 0.6352, 0.6400, 0.6448, 0.6501, 0.6555, 0.6603, 0.6652, 0.6694, 0.6734, 0.6766, 0.6792, 0.6813, 0.6825, 0.6834, 0.6834, 0.6834, 0.6834, 0.6823, 0.6820, 0.6807, 0.6807, 0.6795, 0.6793, 0.6793, 0.6793, 0.6793, 0.6793, 0.6805],
    [0.7441, 0.7409, 0.7372, 0.7342, 0.7318, 0.7301, 0.7287, 0.7280, 0.7268, 0.7263, 0.7254, 0.7245, 0.7233, 0.7218, 0.7197, 0.7174, 0.7152, 0.7126, 0.7102, 0.7084, 0.7070, 0.7064, 0.7064, 0.7079, 0.7099, 0.7131, 0.7177, 0.7224, 0.7287, 0.7337, 0.7397, 0.7461, 0.7516, 0.7562, 0.7599, 0.7628, 0.7646, 0.7647, 0.7647, 0.7637, 0.7614, 0.7587, 0.7559, 0.7528, 0.7498, 0.7470, 0.7444, 0.7423, 0.7405, 0.7391, 0.7381, 0.7375, 0.7363, 0.7354, 0.7340, 0.7324, 0.7302, 0.7277, 0.7245, 0.7212, 0.7174, 0.7141, 0.7101, 0.7072, 0.7046, 0.7028, 0.7024, 0.7024, 0.7040, 0.7066, 0.7102, 0.7150, 0.7203, 0.7260, 0.7316, 0.7382, 0.7437, 0.7485, 0.7524, 0.7560, 0.7583, 0.7593, 0.7593, 0.7593, 0.7590, 0.7575, 0.7559, 0.7539, 0.7518, 0.7503, 0.7492, 0.7485, 0.7474, 0.7471, 0.7471, 0.7461, 0.7458, 0.7447, 0.7435, 0.7415, 0.7390, 0.7354, 0.7316, 0.7274, 0.7227, 0.7177, 0.7132, 0.7090, 0.7054, 0.7025, 0.7010, 0.7010, 0.7010, 0.7019, 0.7049, 0.7089, 0.7132, 0.7182, 0.7235, 0.7290, 0.7345, 0.7390, 0.7441, 0.7476, 0.7501, 0.7518, 0.7531, 0.7539, 0.7539],
    [0.8068, 0.8068, 0.8063, 0.8054, 0.8054, 0.8054, 0.8044, 0.8041, 0.8029, 0.8027, 0.8014, 0.8014, 0.8000, 0.8000, 0.8000, 0.8000, 0.8011, 0.8017, 0.8030, 0.8048, 0.8074, 0.8098, 0.8125, 0.8155, 0.8191, 0.8227, 0.8261, 0.8297, 0.8334, 0.8365, 0.8395, 0.8419, 0.8443, 0.8461, 0.8475, 0.8475, 0.8475, 0.8475, 0.8469, 0.8456, 0.8440, 0.8417, 0.8398, 0.8372, 0.8347, 0.8319, 0.8292, 0.8270, 0.8249, 0.8226, 0.8206, 0.8190, 0.8176, 0.8164, 0.8155, 0.8149, 0.8143, 0.8136, 0.8136, 0.8127, 0.8122, 0.8121, 0.8108, 0.8101, 0.8092, 0.8080, 0.8066, 0.8050, 0.8035, 0.8020, 0.8005, 0.7988, 0.7974, 0.7964, 0.7959, 0.7946, 0.7946, 0.7956, 0.7959, 0.7974, 0.7992, 0.8014, 0.8038, 0.8068, 0.8104, 0.8136, 0.8172, 0.8209, 0.8249, 0.8285, 0.8319, 0.8350, 0.8380, 0.8402, 0.8422, 0.8435, 0.8447, 0.8447, 0.8447, 0.8447, 0.8440, 0.8429, 0.8414, 0.8398, 0.8380, 0.8360, 0.8344, 0.8325, 0.8307, 0.8291, 0.8277, 0.8265, 0.8258, 0.8244, 0.8237, 0.8231, 0.8231, 0.8217, 0.8217, 0.8206, 0.8203, 0.8190, 0.8179, 0.8169, 0.8155, 0.8137, 0.8116, 0.8093, 0.8074],
    [0.8963, 0.8963, 0.8963, 0.8963, 0.8973, 0.8976, 0.8990, 0.9008, 0.9026, 0.9052, 0.9079, 0.9112, 0.9144, 0.9177, 0.9208, 0.9244, 0.9270, 0.9294, 0.9312, 0.9329, 0.9329, 0.9329, 0.9329, 0.9315, 0.9294, 0.9273, 0.9247, 0.9219, 0.9187, 0.9159, 0.9131, 0.9104, 0.9079, 0.9061, 0.9044, 0.9031, 0.9017, 0.9017, 0.9003, 0.9003, 0.9003, 0.9003, 0.9003, 0.8994, 0.8990, 0.8982, 0.8976, 0.8964, 0.8955, 0.8945, 0.8936, 0.8924, 0.8922, 0.8922, 0.8922, 0.8927, 0.8937, 0.8955, 0.8981, 0.9003, 0.9037, 0.9070, 0.9107, 0.9144, 0.9178, 0.9211, 0.9241, 0.9270, 0.9293, 0.9308, 0.9315, 0.9315, 0.9315, 0.9309, 0.9297, 0.9278, 0.9256, 0.9235, 0.9211, 0.9187, 0.9163, 0.9147, 0.9128, 0.9112, 0.9098, 0.9088, 0.9085, 0.9073, 0.9071, 0.9065, 0.9058, 0.9050, 0.9044, 0.9031, 0.9017, 0.9005, 0.8987, 0.8969, 0.8949, 0.8931, 0.8915, 0.8899, 0.8890, 0.8881, 0.8881, 0.8886, 0.8896, 0.8913, 0.8934, 0.8963, 0.8994, 0.9029, 0.9065, 0.9101, 0.9140, 0.9175, 0.9207, 0.9234, 0.9256, 0.9275, 0.9288, 0.9288, 0.9288, 0.9288, 0.9278, 0.9266, 0.9253, 0.9238, 0.9222],
]
WAVE_ANCHOR = 0.6843  # back wave's height at the horizontal centre

# name -> canvas, Apple's art safe area (x, y, w, h), and the composition.
#   text_width / text_top: ink width and top edge of the tagline
#   moon_d / moon_top:     moon diameter and top edge
#   horizon:               y of the back wave at the horizontal centre
#   spacing:               vertical spread of the wave layers (1 = original)
#   glow_r:                radius of the glow behind the moon
LAYOUTS = {
    "header-21x9-3840x1646": dict(
        size=(3840, 1646), safe=(1097, 493, 1646, 661),
        text_width=1380, text_top=528, moon_d=520, moon_top=742,
        horizon=1112, spacing=1.0, glow_r=900,
    ),
    "header-16x9-5244x2950": dict(
        size=(5244, 2950), safe=(1921, 660, 1402, 962),
        text_width=1300, text_top=764, moon_d=660, moon_top=990,
        horizon=1470, spacing=1.7, glow_r=1300,
    ),
}


def tagline_font(target_width):
    """New York sized so the tagline's ink is `target_width` pixels wide."""
    def make(size):
        font = ImageFont.truetype(FONT, size)
        font.set_variation_by_axes(FONT_AXES)
        return font
    probe = make(400)
    box = probe.getbbox(TAGLINE)
    return make(round(400 * target_width / (box[2] - box[0])))


def wave_edges(width, height, horizon, spacing):
    """Per-pixel top edge of each wave layer for a canvas of this size."""
    src = np.array(WAVES)
    xs = np.linspace(0, src.shape[1] - 1, width)
    step = max(3, int(width / (src.shape[1] - 1)) | 1)
    kernel = np.ones(step) / step
    edges = []
    for layer in src:
        offset = (layer - WAVE_ANCHOR) + (layer.mean() - src[0].mean()) * (spacing - 1)
        y = horizon + np.interp(xs, np.arange(len(layer)), offset) * height
        for _ in range(2):  # round off the straight segments between samples
            y = np.convolve(np.pad(y, step // 2, mode="edge"), kernel, mode="valid")
        edges.append(y)
    return edges


def blend(canvas, mask, color):
    alpha = (np.asarray(mask, dtype=np.float32) / 255.0)[..., None]
    canvas *= 1 - alpha
    canvas += alpha * np.array(color, dtype=np.float32)


def render(name, out_dir, guides=False):
    spec = LAYOUTS[name]
    W, H = spec["size"]
    ss = 2  # supersample the shapes for clean edges
    cx = W / 2
    moon_r = spec["moon_d"] / 2
    moon_cy = spec["moon_top"] + moon_r

    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    glow = np.exp(-(((xx - cx) ** 2 + (yy - moon_cy) ** 2) / spec["glow_r"] ** 2))[..., None]
    canvas = np.array(SKY, np.float32) + glow * (np.array(GLOW, np.float32) - np.array(SKY, np.float32))
    del yy, xx, glow

    mask = Image.new("L", (W * ss, H * ss), 0)
    ImageDraw.Draw(mask).ellipse(
        [(cx - moon_r) * ss, (moon_cy - moon_r) * ss, (cx + moon_r) * ss, (moon_cy + moon_r) * ss], fill=255)
    blend(canvas, mask.reduce(ss), MOON)

    edges = wave_edges(W * ss, H, spec["horizon"], spec["spacing"])
    xs = np.arange(W * ss)
    for edge, color in zip(edges, WAVE_COLORS):
        mask = Image.new("L", (W * ss, H * ss), 0)
        points = [(0, H * ss)] + list(zip(xs.tolist(), (edge * ss).tolist())) + [(W * ss, H * ss)]
        ImageDraw.Draw(mask).polygon(points, fill=255)
        blend(canvas, mask.reduce(ss), color)

    font = tagline_font(spec["text_width"])
    box = font.getbbox(TAGLINE)
    text_x = round(cx - (box[2] - box[0]) / 2)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).text((text_x - box[0], spec["text_top"] - box[1]), TAGLINE, font=font, fill=255)
    blend(canvas, mask, TEXT)
    text_box = (text_x, spec["text_top"], text_x + box[2] - box[0], spec["text_top"] + box[3] - box[1])

    # Soft film grain: half-resolution noise scaled up, like the original artwork.
    coarse = np.random.default_rng(7).normal(0, 1, (H // 2 + 1, W // 2 + 1)).astype(np.float32)
    grain = np.asarray(Image.fromarray(coarse, "F").resize((W, H), Image.BILINEAR))
    grain = (grain * (GRAIN_SIGMA / grain.std()))[..., None]
    image = Image.fromarray(np.clip(canvas + grain + 0.5, 0, 255).astype(np.uint8), "RGB")
    out = Path(out_dir) / f"{name}.png"
    image.save(out, optimize=True)

    # The focal art has to sit inside the safe area: the tagline's ink and the
    # part of the moon that shows above the waves.
    sx, sy, sw, sh = spec["safe"]
    centre_edge = edges[0][int(cx * ss)]
    moon_box = (cx - moon_r, spec["moon_top"], cx + moon_r, min(moon_cy + moon_r, centre_edge))
    for label, (x0, y0, x1, y1) in (("tagline", text_box), ("moon", moon_box)):
        inside = x0 >= sx and y0 >= sy and x1 <= sx + sw and y1 <= sy + sh
        print(f"{name}: {label} {round(x0)},{round(y0)} to {round(x1)},{round(y1)} "
              f"{'inside' if inside else 'OUTSIDE'} safe area {sx},{sy} to {sx + sw},{sy + sh}")
        if not inside:
            raise SystemExit(f"{name}: {label} leaves the art safe area")

    if guides:
        overlay = image.convert("RGBA")
        layer = Image.new("RGBA", overlay.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).rectangle([sx, sy, sx + sw, sy + sh], fill=(0, 255, 0, 60), outline=(0, 255, 0, 255), width=6)
        Image.alpha_composite(overlay, layer).convert("RGB").save(Path(out_dir) / f"{name}-guides.png")
    return out


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_dir = args[0] if args else str(Path(__file__).parent)
    for layout in LAYOUTS:
        print("wrote", render(layout, out_dir, guides="--guides" in sys.argv))
