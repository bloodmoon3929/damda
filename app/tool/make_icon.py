"""Draws the 담다 app icon: a note page with a small graph on it.

python tool/make_icon.py  →  assets/icon/icon.png (full icon, 1024px)
                             assets/icon/foreground.png (Android adaptive
                             foreground: the page alone, inside the safe zone)
                             assets/icon/icon_macos.png (macOS: inset + shadow)
Drawn at 4x and scaled down for smooth edges.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling
N = 1024 * S
BG = (49, 87, 214)  # indigo blue
PAGE = (255, 255, 255)
FOLD = (214, 223, 248)
LINE = (163, 178, 222)
NODE_MAIN = (255, 138, 61)  # warm orange (the "담은" note)
NODE = (49, 87, 214)
TEXT = (226, 231, 245)

out = Path(__file__).resolve().parent.parent / "assets" / "icon"
out.mkdir(parents=True, exist_ok=True)


def draw_page(d: ImageDraw.ImageDraw, x0, y0, w, h):
    """A page with a folded top-right corner, two text lines and a graph."""
    fold = w * 0.24
    r = w * 0.07
    # Body (rounded except the folded corner).
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=r, fill=PAGE)
    d.polygon(
        [(x0 + w - fold, y0 - 1), (x0 + w + 1, y0 - 1), (x0 + w + 1, y0 + fold)],
        fill=BG_FOR_PAGE,
    )
    d.polygon(
        [(x0 + w - fold, y0), (x0 + w - fold, y0 + fold), (x0 + w, y0 + fold)],
        fill=FOLD,
    )
    # Two short "text" lines at the top.
    lh = w * 0.055
    for i, frac in enumerate((0.48, 0.32)):
        ly = y0 + h * (0.14 + i * 0.11)
        d.rounded_rectangle(
            [x0 + w * 0.14, ly, x0 + w * (0.14 + frac), ly + lh],
            radius=lh / 2,
            fill=TEXT,
        )
    # Graph: nodes joined by lines in the lower part of the page.
    gx, gy, gw, gh = x0 + w * 0.12, y0 + h * 0.42, w * 0.76, h * 0.48
    pts = {
        "a": (0.18, 0.30),
        "b": (0.62, 0.16),
        "c": (0.42, 0.62),
        "d": (0.86, 0.66),
        "e": (0.14, 0.88),
    }
    xy = {k: (gx + gw * u, gy + gh * v) for k, (u, v) in pts.items()}
    lw = int(w * 0.035)
    for a, b in [("a", "c"), ("b", "c"), ("c", "d"), ("b", "d"), ("c", "e"), ("a", "b")]:
        d.line([xy[a], xy[b]], fill=LINE, width=lw)
    for k, (cx, cy) in xy.items():
        rad = w * (0.085 if k == "c" else 0.058)
        d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                  fill=NODE_MAIN if k == "c" else NODE)


# Full icon: page on the blue rounded square (Windows, legacy Android).
BG_FOR_PAGE = BG
img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, N - 1, N - 1], radius=N * 0.22, fill=BG)
pw, ph = N * 0.56, N * 0.66
draw_page(d, (N - pw) / 2, (N - ph) / 2, pw, ph)
img.resize((1024, 1024), Image.LANCZOS).save(out / "icon.png")

# Adaptive foreground: transparent, page within the central safe zone
# (Android crops to ~66%); the blue comes from the background color.
BG_FOR_PAGE = (0, 0, 0, 0)
fg = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(fg)
pw, ph = N * 0.44, N * 0.52
draw_page(d, (N - pw) / 2, (N - ph) / 2, pw, ph)
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
