#!/usr/bin/env python3
# Usage: python3 docs/brand/tools/build-brand.py docs/brand   (needs fonttools; rsvg-convert for PNGs)
"""Builds every Workstation AI-native CRM logo file from one definition of the mark.

The mark is the Workstation icon: a white "W" folded from one ribbon on a #FF004E disc (the
OpsAPI primary). The wordmark is "Workstation AI-native CRM".

Writes the SVGs into the brand folder, PNG renders into png/, the Icon Composer layers into
icon-layers/, and (with --app) the iOS asset catalog images.
"""
import os
import subprocess
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

brand = sys.argv[1]
app_assets = None
if "--app" in sys.argv:
    app_assets = sys.argv[sys.argv.index("--app") + 1]

# MARK: Tokens (BRAND.md § Colour)

INK = "#0F172A"  # OpsAPI secondary-900 (foreground)
NIGHT = "#131A2B"  # OpsAPI dark surface
ROSE = "#FF6088"  # OpsAPI primary-400
PRIMARY = "#FF004E"  # OpsAPI primary-500
DEEP = "#C20035"  # OpsAPI primary-700
WHITE = "#FFFFFF"

# The mark: a white "W" folded from one ribbon, on a #FF004E disc (the Workstation icon).
# Four flat-cut strokes on the 1024 grid; the up-strokes sit behind and are shaded, so the W reads
# as a ribbon folding at each point.
W_TOP, W_BOTTOM = 372, 668
W_THICK, W_RUN = 118, 88
W_LEFT = 512 - (4 * W_RUN + W_THICK) / 2


def stroke_poly(i):
    """Stroke i (0-3): down-right for even i, up-right for odd, as a parallelogram."""
    x0 = W_LEFT + i * W_RUN
    t, b = (W_TOP, W_BOTTOM) if i % 2 == 0 else (W_BOTTOM, W_TOP)
    pts = [(x0, t), (x0 + W_THICK, t), (x0 + W_RUN + W_THICK, b), (x0 + W_RUN, b)]
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def w_mark(front=WHITE, back="url(#fold)", last="url(#fade)"):
    """The W: back strokes (up) first, then the front strokes (down) over them."""
    return (f'<polygon points="{stroke_poly(1)}" fill="{back}"/>'
            f'<polygon points="{stroke_poly(3)}" fill="{last}"/>'
            f'<polygon points="{stroke_poly(0)}" fill="{front}"/>'
            f'<polygon points="{stroke_poly(2)}" fill="{front}"/>')


def w_defs(light="#FFFFFF", fold="#FFE1E9", fade_to="#FFB8CB"):
    return (f'<linearGradient id="fold" x1="0" y1="{W_BOTTOM}" x2="0" y2="{W_TOP}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{fold}"/><stop offset="1" stop-color="{light}"/></linearGradient>'
            f'<linearGradient id="fade" x1="0" y1="{W_BOTTOM}" x2="0" y2="{W_TOP}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{fold}"/><stop offset="1" stop-color="{fade_to}"/></linearGradient>')


DISC_DEFS = (f'<radialGradient id="disc" cx="0.3" cy="0.25" r="0.85">'
             f'<stop offset="0" stop-color="#FF2D6E"/><stop offset="0.6" stop-color="{PRIMARY}"/>'
             f'<stop offset="1" stop-color="#E40046"/></radialGradient>'
             '<filter id="lift" x="-20%" y="-20%" width="140%" height="150%">'
             '<feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#7A0026" flood-opacity="0.35"/></filter>')

FULL_BLEED = '<rect width="1024" height="1024" fill="url(#disc)"/>'
DISC = '<circle cx="512" cy="512" r="480" fill="url(#disc)"/>'
GLYPH_BOX = (24, 24, 976, 976)  # the disc with a hair of air


def svg(title, body, defs="", view="0 0 1024 1024", size=None):
    w, h = size or view.split()[2:]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" width="{w}" height="{h}">\n'
            f'  <title>{title}</title>\n  <defs>{defs}</defs>\n  {body}\n</svg>\n')


def write(name, text):
    path = os.path.join(brand, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


# MARK: Icon and mark

# iOS masks the corners itself, so the app icon is full bleed: the W on brand red, a little larger.
ICON_W = f'<g transform="translate(512 520) scale(1.12) translate(-512 -520)" filter="url(#lift)">{w_mark()}</g>'
write("logo-icon.svg", svg("Workstation CRM app icon", FULL_BLEED + ICON_W, DISC_DEFS + w_defs()))
# Dark appearance: the system draws its own dark backdrop behind a transparent icon; the W turns pink.
write("logo-icon-dark.svg", svg("Workstation CRM app icon, dark",
                                f'<g transform="translate(512 520) scale(1.12) translate(-512 -520)">'
                                f'{w_mark(PRIMARY, "url(#fold)", "url(#fade)")}</g>',
                                w_defs(light=PRIMARY, fold=DEEP, fade_to=ROSE)))
# Tinted appearance: greyscale on transparent; the system tints it.
write("logo-icon-tinted.svg", svg("Workstation CRM app icon, tinted",
                                  f'<g transform="translate(512 520) scale(1.12) translate(-512 -520)">'
                                  f'{w_mark("#FFFFFF", "url(#fold)", "url(#fade)")}</g>',
                                  w_defs(light="#FFFFFF", fold="#BDBDBD", fade_to="#8C8C8C")))

gx, gy, gw, gh = GLYPH_BOX
glyph_view = f"{gx} {gy} {gw} {gh}"
# The round mark: exactly the Workstation icon. Works on light and dark.
GLYPH = DISC + w_mark()
write("logo-glyph.svg", svg("Workstation CRM mark", GLYPH, DISC_DEFS + w_defs(), view=glyph_view))
write("logo-glyph-on-dark.svg", svg("Workstation CRM mark, on dark", GLYPH, DISC_DEFS + w_defs(), view=glyph_view))
write("logo-mono.svg", svg("Workstation CRM mark, one colour",
                           f'<mask id="m"><rect x="{gx}" y="{gy}" width="{gw}" height="{gh}" fill="#fff"/>'
                           f'{w_mark("#000", "#000", "#000")}</mask>'
                           f'<circle cx="512" cy="512" r="480" fill="currentColor" mask="url(#m)"/>', view=glyph_view))

# Icon Composer layers (iOS 26 Liquid Glass), back to front.
for old in ("icon-layers/2-route.svg", "icon-layers/3-start.svg"):
    if os.path.exists(os.path.join(brand, old)):
        os.remove(os.path.join(brand, old))
write("icon-layers/1-background.svg", svg("Background", FULL_BLEED, DISC_DEFS))
write("icon-layers/2-ribbon-back.svg", svg("Ribbon, back strokes",
                                           f'<polygon points="{stroke_poly(1)}" fill="url(#fold)"/>'
                                           f'<polygon points="{stroke_poly(3)}" fill="url(#fade)"/>', w_defs()))
write("icon-layers/3-ribbon-front.svg", svg("Ribbon, front strokes",
                                            f'<polygon points="{stroke_poly(0)}" fill="#FFFFFF"/>'
                                            f'<polygon points="{stroke_poly(2)}" fill="#FFFFFF"/>'))

# MARK: Wordmark and lockups (Plus Jakarta Sans ExtraBold, outlined)

font = instantiateVariableFont(TTFont(os.path.join(brand, "fonts/PlusJakartaSans.ttf")), {"wght": 800})
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()
upm = font["head"].unitsPerEm


def text_path(text, size, x, baseline, tracking=-0.02):
    scale = size / upm
    pen = SVGPathPen(glyphs)
    cursor = 0.0
    for ch in text:
        g = cmap[ord(ch)]
        glyphs[g].draw(TransformPen(pen, (scale, 0, 0, -scale, x + cursor, baseline)))
        cursor += glyphs[g].width * scale + tracking * size
    return pen.getCommands(), cursor - tracking * size


CAP = font["OS/2"].sCapHeight / upm


NAME, PRODUCT = "Workstation", "AI-native CRM"


def name_paths(size, x, baseline, color):
    """"Workstation" in the text colour, "AI-native CRM" in the primary, one word-space apart."""
    d1, w1 = text_path(NAME, size, x, baseline)
    gap = size * 0.26
    d2, w2 = text_path(PRODUCT, size, x + w1 + gap, baseline)
    return f'<path fill="{color}" d="{d1}"/><path fill="{PRIMARY}" d="{d2}"/>', w1 + gap + w2


def wordmark(color, name, title):
    size = 160
    paths, width = name_paths(size, 24, 24 + CAP * size, color)
    w, h = int(width + 48), int(CAP * size * 1.3 + 48)
    write(name, svg(title, paths, size=(w, h), view=f"0 0 {w} {h}"))


def lockup(color, name, title):
    height = 190
    scale = height / gh
    size = 132
    cap = CAP * size
    tx = 24 + gw * scale + 44
    baseline = 24 + height / 2 + cap / 2
    paths, width = name_paths(size, tx, baseline, color)
    w, h = int(tx + width + 28), int(height + 48)
    body = f'<g transform="translate(24 24) scale({scale:.5f}) translate({-gx} {-gy})">{GLYPH}</g>{paths}'
    write(name, svg(title, body, DISC_DEFS + w_defs(), size=(w, h), view=f"0 0 {w} {h}"))


wordmark(INK, "wordmark.svg", "Workstation AI-native CRM")
wordmark(WHITE, "wordmark-on-dark.svg", "Workstation AI-native CRM")
lockup(INK, "lockup.svg", "Workstation AI-native CRM")
lockup(WHITE, "lockup-on-dark.svg", "Workstation AI-native CRM")


# MARK: Renders


def render(src, dst, width):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(["rsvg-convert", "-w", str(width), src, "-o", dst], check=True)


def flatten(png):
    """App Store icons must be opaque: drop the alpha channel."""
    subprocess.run(["sips", "-s", "format", "jpeg", png, "--out", png + ".jpg"], check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "png", png + ".jpg", "--out", png], check=True, capture_output=True)
    os.remove(png + ".jpg")


B = lambda n: os.path.join(brand, n)  # noqa: E731
render(B("logo-icon.svg"), B("png/icon-1024.png"), 1024)
flatten(B("png/icon-1024.png"))
render(B("logo-icon-dark.svg"), B("png/icon-dark-1024.png"), 1024)
render(B("logo-icon-tinted.svg"), B("png/icon-tinted-1024.png"), 1024)
render(B("logo-glyph.svg"), B("png/glyph@2x.png"), gw)
render(B("logo-glyph-on-dark.svg"), B("png/glyph-on-dark@2x.png"), gw)
for n in ("wordmark", "wordmark-on-dark", "lockup", "lockup-on-dark"):
    render(B(f"{n}.svg"), B(f"png/{n}@2x.png"), 1400)

if app_assets:
    icon = os.path.join(app_assets, "AppIcon.appiconset")
    for src, dst in (("png/icon-1024.png", "AppIcon-1024.png"),
                     ("png/icon-dark-1024.png", "AppIcon-Dark-1024.png"),
                     ("png/icon-tinted-1024.png", "AppIcon-Tinted-1024.png")):
        subprocess.run(["cp", B(src), os.path.join(icon, dst)], check=True)
    mark = os.path.join(app_assets, "BrandMark-WSLCRM.imageset")
    # The sign-in screen shows the mark at 88 pt; render for @2x and @3x of a 96 pt box.
    for scale in (2, 3):
        render(B("logo-glyph.svg"), os.path.join(mark, f"BrandMark-WSLCRM@{scale}x.png"), int(96 * gw / gh) * scale)
        render(B("logo-glyph-on-dark.svg"), os.path.join(mark, f"BrandMark-WSLCRM-Dark@{scale}x.png"),
               int(96 * gw / gh) * scale)

print("Built the Workstation AI-native CRM brand files in", brand)
