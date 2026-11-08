#!/usr/bin/env python3
"""Generates the four launch Lottie files in hush/Launch/Animations/.

Layers mix in. Three waveforms, one per sound layer, arrive one after
another on three lanes, then slide together and merge into one combined wave:
the mix. The resting hairline (frame 0, identical to LaunchScreen.storyboard)
becomes the middle lane.

  0-4     hold      hairline only, matching the static launch screen
  4-28    layer 1   slow sage wave draws on along the top lane
  10-34   layer 2   the hairline itself swells into a cream wave
  16-40   layer 3   quick deep-sage ripple draws on along the bottom lane
  42-70   mix       lanes slide together, crossing through each other, and
                    the three shapes merge into their sum a beat behind
  70-86   hold      the combined wave
  86-104  hush      it flattens back to a line and fades
  104-108 bare      background only, so the overlay cuts away seamlessly

Every move is a two-keyframe morph or trim with an easing curve; nothing is
baked per frame. Reduced motion keeps the same layers and fades but nothing
moves: the combined wave crossfades in over the hairline and fades out.

The contract `hushTests/LaunchTests.swift` checks (top-level layers):
  - 1179x2556 @ 60fps, frames 0...108, no text layers
  - frame 0: only "Background Field" (100) and "Resting Hairline" (>0) visible
  - last frame: only "Background Field" visible
  - reduced motion: same layers and frame-0 fades, no transform animation

Stdlib only:  python3 scripts/make_launch_animation.py
"""
import json
import math
import os

W, H, FPS, OP = 1179, 2556, 60, 108

CX, HORIZON = 589.5, 1140.0
HALF = 280.0                 # the hairline is 560px wide
STROKE = 6.0                 # the hairline's weight
MIX_STROKE = 8.0             # the combined wave reads a touch heavier
LANE_GAP = 112.0
N = 72                       # vertices per path

# name: (amplitude, periods across the line, phase, lane offset). Phases are
# picked so the sum has several even crests rather than one spike.
LAYERS = {
    "Wave Slow": (34.0, 1.0, 1.57, -LANE_GAP),
    "Wave Mid": (26.0, 2.25, 1.18, 0.0),
    "Wave Ripple": (12.0, 5.0, 0.0, LANE_GAP),
}

COLORWAYS = {
    "dark": {
        "bg": (9, 9, 11),
        "hairline": (176, 194, 187),
        "hairline_opacity": 40,
        "Wave Slow": (176, 196, 188),    # accentSoft sage
        "Wave Mid": (239, 231, 212),     # accent cream
        "Wave Ripple": (112, 150, 136),  # deeper sage
    },
    "light": {
        "bg": (250, 249, 246),
        "hairline": (79, 113, 96),
        "hairline_opacity": 35,
        "Wave Slow": (122, 156, 140),
        "Wave Mid": (176, 150, 104),
        "Wave Ripple": (79, 113, 96),
    },
}

# Easing anchors (cubic-bezier x1, y1, x2, y2), picked by behaviour.
ENTRANCE_SHARP = (0.20, 0.75, 0.34, 0.94)   # draw-ons, the swell
SETTLE_SOFT = (0.00, 0.65, 0.51, 0.99)      # the mix landing
EXIT_ACCELERATE = (1.00, 0.02, 0.54, 0.42)  # hush

ARRIVE = {"Wave Slow": (4, 28), "Wave Mid": (10, 34), "Wave Ripple": (16, 40)}
CONVERGE = (42, 62)      # lanes slide together first (lead)...
MIX = (48, 70)           # ...then the shapes merge into their sum (follow)
EXIT = (86, 104)
REDUCED_IN = (4, 30)


def rgba(c):
    return [round(v / 255, 5) for v in c] + [1]


def static(v):
    return {"a": 0, "k": v}


def animated(keys, dims=1):
    """[(t, value, curve-to-next | 'hold')]. Segment easing lives on the
    start keyframe (`o` and `i`), per the Lottie spec."""
    out = []
    for n, (t, v, curve) in enumerate(keys):
        k = {"t": t, "s": v if isinstance(v, list) else [v]}
        if n < len(keys) - 1:
            if curve == "hold":
                k["h"] = 1
            else:
                x1, y1, x2, y2 = curve
                k["o"] = {"x": [x1] * dims, "y": [y1] * dims}
                k["i"] = {"x": [x2] * dims, "y": [y2] * dims}
        out.append(k)
    return {"a": 1, "k": out}


def transform(p=None, o=None, a=None):
    return {"o": o or static(100), "r": static(0), "p": p or static([0, 0, 0]),
            "a": a or static([0, 0, 0]), "s": static([100, 100, 100])}


# --- waveforms (layer space: x across the line, y = 0 on the line) ----------

U = [i / (N - 1) for i in range(N)]


def envelope(u):
    """Every wave is pinned to the hairline's ends, like a clip in a track."""
    return math.sin(math.pi * u) ** 0.6


def layer_wave(name, u):
    amp, periods, phase, _ = LAYERS[name]
    return amp * math.sin(2 * math.pi * periods * u + phase)


def own(name):
    return lambda u: envelope(u) * layer_wave(name, u)


def combined(u):
    return envelope(u) * sum(layer_wave(n, u) for n in LAYERS)


def flat(u):
    return 0.0


def path(fy):
    # Inset by the round cap so the stroke spans exactly the hairline's 560px.
    x0, span = CX - HALF + STROKE / 2, 2 * HALF - STROKE
    pts = [(x0 + span * u, fy(u)) for u in U]
    v, i, o = [], [], []
    for j, (x, y) in enumerate(pts):
        a, b = pts[max(j - 1, 0)], pts[min(j + 1, N - 1)]
        tx, ty = (b[0] - a[0]) / 6, (b[1] - a[1]) / 6   # Catmull-Rom tangents
        if j in (0, N - 1):
            tx, ty = tx / 2, ty / 2
        v.append([round(x, 2), round(y, 2)])
        i.append([round(-tx, 2), round(-ty, 2)])
        o.append([round(tx, 2), round(ty, 2)])
    return {"c": False, "v": v, "i": i, "o": o}


# --- layers -----------------------------------------------------------------

def shape_layer(ind, nm, ks, shapes):
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": nm, "sr": 1, "ks": ks, "ao": 0,
            "shapes": shapes, "ip": 0, "op": OP, "st": 0, "bm": 0}


def stroke_group(nm, shape, color, opacity, width, trim=None):
    items = [{"ty": "sh", "nm": nm + " Path", "ks": shape}]
    if trim:
        items.append({"ty": "tm", "nm": nm + " Draw On", "s": static(0), "e": trim,
                      "o": static(0), "m": 1})
    items += [
        {"ty": "st", "nm": nm + " Stroke", "c": color, "o": opacity, "w": width,
         "lc": 2, "lj": 2, "ml": 4},
        {"ty": "tr", "p": static([0, 0]), "a": static([0, 0]), "s": static([100, 100]),
         "r": static(0), "o": static(100), "sk": static(0), "sa": static(0)},
    ]
    return {"ty": "gr", "nm": nm + " Group", "it": items}


def fill_group(nm, size, color, sid, radius):
    return {"ty": "gr", "nm": nm + " Group", "it": [
        {"ty": "rc", "d": 1, "nm": nm + " Rect", "p": static([0, 0]), "s": static(size), "r": static(radius)},
        {"ty": "fl", "nm": nm + " Fill", "c": dict(static(color), sid=sid), "o": static(100), "r": 1},
        {"ty": "tr", "p": static([0, 0]), "a": static([0, 0]), "s": static([100, 100]),
         "r": static(0), "o": static(100), "sk": static(0), "sa": static(0)},
    ]}


def wave_layer(ind, name, c, reduced):
    lane = LAYERS[name][3]
    color = rgba(c[name])
    anchor = static([CX, 0, 0])
    if reduced:
        fade = animated([(0, 0, "hold"), (REDUCED_IN[0], 0, SETTLE_SOFT), (REDUCED_IN[1], 100, "hold"),
                         (EXIT[0], 100, EXIT_ACCELERATE), (EXIT[1], 0, "hold")])
        group = stroke_group(name, static(path(combined)), static(color), static(100), static(MIX_STROKE))
        return shape_layer(ind, name, transform(p=static([CX, HORIZON, 0]), a=anchor, o=fade), [group])

    t0, t1 = ARRIVE[name]
    shape_keys = []
    if name == "Wave Mid":
        # The hairline becomes this wave: it starts flat and swells.
        shape_keys += [(0, [path(flat)], "hold"), (t0, [path(flat)], ENTRANCE_SHARP)]
    shape_keys += [
        (t1 if name == "Wave Mid" else 0, [path(own(name))], "hold"),
        (MIX[0], [path(own(name))], SETTLE_SOFT),
        (MIX[1], [path(combined)], "hold"),
        (EXIT[0], [path(combined)], EXIT_ACCELERATE),
        (EXIT[1], [path(flat)], "hold"),
        (OP, [path(flat)], "hold"),
    ]
    width = animated([(0, STROKE, "hold"), (MIX[0], STROKE, SETTLE_SOFT), (MIX[1], MIX_STROKE, "hold"),
                      (EXIT[0], MIX_STROKE, EXIT_ACCELERATE), (EXIT[1], STROKE, "hold")])
    stroke_o = animated([(0, 100, "hold"), (EXIT[0], 100, EXIT_ACCELERATE), (EXIT[1], 0, "hold")])

    if name == "Wave Mid":
        # Takes over from the hairline on frame 1 with the same width, weight,
        # colour and opacity, so the swap is invisible; then warms to cream.
        hair_o = c["hairline_opacity"]
        layer_o = animated([(0, 0, "hold"), (1, 100, "hold"), (EXIT[1], 0, "hold")])
        stroke_o = animated([(0, hair_o, "hold"), (t0, hair_o, ENTRANCE_SHARP), (t1, 100, "hold"),
                             (EXIT[0], 100, EXIT_ACCELERATE), (EXIT[1], 0, "hold")])
        color_p = animated([(0, rgba(c["hairline"]), "hold"), (t0, rgba(c["hairline"]), ENTRANCE_SHARP),
                            (t1, color, "hold")], 4)
        trim = None
    else:
        layer_o = animated([(0, 0, "hold"), (t0, 100, "hold"), (EXIT[1], 0, "hold")])
        color_p = static(color)
        trim = animated([(0, 0, "hold"), (t0, 0, ENTRANCE_SHARP), (t1, 100, "hold")])

    position = animated([(0, [CX, HORIZON + lane, 0], "hold"),
                         (CONVERGE[0], [CX, HORIZON + lane, 0], SETTLE_SOFT),
                         (CONVERGE[1], [CX, HORIZON, 0], "hold")], 3)
    group = stroke_group(name, animated(shape_keys), color_p, stroke_o, width, trim)
    return shape_layer(ind, name, transform(p=position, a=anchor, o=layer_o), [group])


def build(appearance, reduced):
    c = COLORWAYS[appearance]
    hair_o = c["hairline_opacity"]
    if reduced:
        hair = animated([(0, hair_o, "hold"), (REDUCED_IN[0], hair_o, SETTLE_SOFT),
                         (REDUCED_IN[1] - 8, 0, "hold")])
    else:
        hair = animated([(0, hair_o, "hold"), (1, 0, "hold")])

    # Cream mid wave on top: once merged, it is the one stroke you see.
    layers = [wave_layer(1, "Wave Mid", c, reduced),
              wave_layer(2, "Wave Slow", c, reduced),
              wave_layer(3, "Wave Ripple", c, reduced)]
    layers.append(shape_layer(4, "Resting Hairline", transform(p=static([CX, HORIZON, 0]), o=hair),
                              [fill_group("Resting Hairline", [2 * HALF, STROKE],
                                          rgba(c["hairline"]), "hairlineColor", 3)]))
    layers.append(shape_layer(5, "Background Field", transform(p=static([W / 2, H / 2, 0])),
                              [fill_group("Background", [W, H], rgba(c["bg"]), "bgColor", 0)]))

    slots = {"bgColor": {"p": static(rgba(c["bg"]))}, "hairlineColor": {"p": static(rgba(c["hairline"]))}}
    name = ("launch-reduced-motion-" if reduced else "launch-") + appearance
    return name, {"v": "5.7.0", "fr": FPS, "ip": 0, "op": OP, "w": W, "h": H, "nm": name, "ddd": 0,
                  "assets": [], "slots": slots, "layers": layers}


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hush", "Launch", "Animations")
    for appearance in COLORWAYS:
        for reduced in (False, True):
            name, doc = build(appearance, reduced)
            dest = os.path.join(out, name + ".json")
            with open(dest, "w") as f:
                json.dump(doc, f, separators=(",", ":"))
            print("wrote", name, os.path.getsize(dest) // 1024, "KB")
