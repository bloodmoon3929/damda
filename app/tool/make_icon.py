"""Draws the 나무 app icon: a tree whose crown is a small note graph.

The graph is the one from the old icon (five notes, six links, the orange
one in the middle); the orange note sits where the trunk splits, so the
links read as branches and the notes as leaves.

python tool/make_icon.py  →  assets/icon/icon.png (full icon, 1024px)
                             assets/icon/foreground.png (Android adaptive
                             foreground: the tree alone, inside the safe zone)
                             assets/icon/icon_macos.png (macOS: inset + shadow)
Drawn at 4x and scaled down for smooth edges.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling
N = 1024 * S
BG = (232, 244, 234)  # pale leaf (also adaptive_icon_background in pubspec)
CROWN = (52, 150, 96)  # leaves
TRUNK = (121, 85, 61)  # bark
LINE = (170, 220, 185)  # links between notes
NODE = (255, 255, 255)
NODE_MAIN = (255, 138, 61)  # warm orange: the note everything grows from

out = Path(__file__).resolve().parent.parent / "assets" / "icon"
out.mkdir(parents=True, exist_ok=True)

# The graph, in a unit square: same notes and links as before.
PTS = {
    "a": (0.29, 0.33),
    "b": (0.50, 0.19),
    "c": (0.50, 0.50),  # orange, where the trunk meets the crown
    "d": (0.71, 0.35),
    "e": (0.31, 0.53),
}
LINKS = [("a", "c"), ("b", "c"), ("c", "d"), ("b", "d"), ("c", "e"), ("a", "b")]
# The crown: overlapping circles (x, y, radius) behind the graph.
CROWN_CIRCLES = [
    (0.50, 0.35, 0.25),
    (0.31, 0.42, 0.17),
    (0.69, 0.42, 0.17),
    (0.37, 0.25, 0.16),
    (0.63, 0.25, 0.16),
    (0.50, 0.48, 0.16),
]


def draw_tree(d: ImageDraw.ImageDraw, x0, y0, s):
    """The tree in the square at (x0, y0) with side s."""
    X = lambda u: x0 + s * u  # noqa: E731
    Y = lambda v: y0 + s * v  # noqa: E731
    for u, v, r in CROWN_CIRCLES:
        d.ellipse([X(u - r), Y(v - r), X(u + r), Y(v + r)], fill=CROWN)
    # Trunk: from the orange note down, widening, with a small root flare.
    cx, cy = PTS["c"]
    d.polygon(
        [
            (X(cx - 0.035), Y(cy)),
            (X(cx + 0.035), Y(cy)),
            (X(cx + 0.055), Y(0.82)),
            (X(cx + 0.10), Y(0.90)),
            (X(cx - 0.10), Y(0.90)),
            (X(cx - 0.055), Y(0.82)),
        ],
        fill=TRUNK,
    )
    lw = int(s * 0.026)
    for a, b in LINKS:
        d.line([(X(PTS[a][0]), Y(PTS[a][1])), (X(PTS[b][0]), Y(PTS[b][1]))],
               fill=LINE, width=lw)
    for k, (u, v) in PTS.items():
        r = s * (0.07 if k == "c" else 0.05)
        d.ellipse([X(u) - r, Y(v) - r, X(u) + r, Y(v) + r],
                  fill=NODE_MAIN if k == "c" else NODE)


# Full icon: the tree on the pale rounded square (Windows, legacy Android).
img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, N - 1, N - 1], radius=N * 0.22, fill=BG)
draw_tree(d, N * 0.05, N * 0.04, N * 0.90)
img.resize((1024, 1024), Image.LANCZOS).save(out / "icon.png")

# Adaptive foreground: transparent, tree within the central safe zone
# (Android crops to ~66%); the pale green comes from the background color.
fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(fg)
draw_tree(d, N * 0.20, N * 0.19, N * 0.60)
fg.resize((1024, 1024), Image.LANCZOS).save(out / "foreground.png")

# macOS: the full icon at 824px on a 1024 canvas with a soft shadow, like
# Apple's icon template, so it sits the same size as other Dock icons.
mac_size = int(N * 824 / 1024)
inner = img.resize((mac_size, mac_size), Image.LANCZOS)
off = (N - mac_size) // 2
alpha = Image.new("L", (N, N), 0)
alpha.paste(inner.getchannel("A"), (off, off + int(10 * S)))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(10 * S)).point(lambda a: a * 0.3))
shadow.alpha_composite(inner, (off, off))
shadow.resize((1024, 1024), Image.LANCZOS).save(out / "icon_macos.png")
print("ok", out)
