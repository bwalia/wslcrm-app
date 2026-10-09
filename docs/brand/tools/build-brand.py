#!/usr/bin/env python3
# Usage: python3 docs/brand/tools/build-brand.py docs/brand   (needs fonttools; rsvg-convert for PNGs)
"""Builds every Workstation CRM logo file from one definition of the mark.

The mark is a "W" drawn as one continuous route: it starts at a white dot (the job, where
someone is going) and its last stroke climbs past the first, so the W ends as a tick. Its
colour is the OpsAPI primary, #FF004E, running light to deep along the route.

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

# The route, on the 1024 icon grid. Round caps and joins at this width keep it friendly.
ROUTE = "M236 330 L374 704 L512 446 L650 704 L828 262"
START = (236, 330)
STROKE = 108
# Bounds of the route including the stroke: x 182–882, y 208–758.
GLYPH_BOX = (172, 198, 720, 570)  # x, y, w, h with a little air


def momentum(gid="momentum"):
    return (f'<linearGradient id="{gid}" x1="190" y1="0" x2="860" y2="0" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{ROSE}"/><stop offset="0.5" stop-color="{PRIMARY}"/>'
            f'<stop offset="1" stop-color="{DEEP}"/></linearGradient>')


def route(stroke, extra=""):
    return (f'<path d="{ROUTE}" fill="none" stroke="{stroke}" stroke-width="{STROKE}" '
            f'stroke-linecap="round" stroke-linejoin="round"{extra}/>')


def start_dot(fill=WHITE, glow=True):
    x, y = START
    halo = (f'<circle cx="{x}" cy="{y}" r="40" fill="{fill}" opacity="0.6" filter="url(#soft)"/>' if glow else "")
    return f'{halo}<circle cx="{x}" cy="{y}" r="30" fill="{fill}"/>'


DEPTH_DEFS = (
    '<linearGradient id="sheen" x1="0" y1="250" x2="0" y2="760" gradientUnits="userSpaceOnUse">'
    '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.35"/><stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/>'
    '</linearGradient>'
    '<filter id="lift" x="-20%" y="-20%" width="140%" height="150%">'
    '<feDropShadow dx="0" dy="24" stdDeviation="26" flood-color="#020611" flood-opacity="0.65"/></filter>'
    '<filter id="soft" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="18"/></filter>')

BACKGROUND_DEFS = (
    '<linearGradient id="bg" x1="0.1" y1="0" x2="0.9" y2="1">'
    '<stop offset="0" stop-color="#1B2439"/><stop offset="0.55" stop-color="#0B1120"/><stop offset="1" stop-color="#060A14"/>'
    '</linearGradient>'
    '<radialGradient id="glow" cx="0.22" cy="0.16" r="0.75">'
    '<stop offset="0" stop-color="#FF004E" stop-opacity="0.32"/><stop offset="0.6" stop-color="#FF004E" stop-opacity="0"/>'
    '</radialGradient>'
    '<radialGradient id="glow2" cx="0.9" cy="0.92" r="0.6">'
    '<stop offset="0" stop-color="#FF6088" stop-opacity="0.22"/><stop offset="1" stop-color="#FF6088" stop-opacity="0"/>'
    '</radialGradient>')

BACKGROUND = ('<rect width="1024" height="1024" fill="url(#bg)"/>'
              '<rect width="1024" height="1024" fill="url(#glow)"/>'
              '<rect width="1024" height="1024" fill="url(#glow2)"/>')


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

LIFTED_MARK = (f'<g filter="url(#lift)">{route("url(#momentum)")}</g>'
               f'{route("url(#sheen)")}{start_dot()}')

# iOS masks the corners itself, so the icon is full bleed.
write("logo-icon.svg", svg("Workstation CRM app icon", BACKGROUND + LIFTED_MARK, BACKGROUND_DEFS + momentum() + DEPTH_DEFS))
# Dark appearance: the system draws its own dark backdrop behind a transparent icon.
write("logo-icon-dark.svg", svg("Workstation CRM app icon, dark", LIFTED_MARK, momentum() + DEPTH_DEFS))
# Tinted appearance: greyscale on transparent; the system tints it.
write("logo-icon-tinted.svg", svg("Workstation CRM app icon, tinted",
                                  route("url(#grey)") + start_dot(WHITE, glow=False),
                                  '<linearGradient id="grey" x1="190" y1="0" x2="860" y2="0" gradientUnits="userSpaceOnUse">'
                                  '<stop offset="0" stop-color="#9A9A9A"/><stop offset="1" stop-color="#FFFFFF"/></linearGradient>'))

gx, gy, gw, gh = GLYPH_BOX
glyph_view = f"{gx} {gy} {gw} {gh}"
# On light surfaces the white start dot needs an ink centre to stay visible.
write("logo-glyph.svg", svg("Workstation CRM mark", route("url(#momentum)") + start_dot(INK, glow=False),
                            momentum(), view=glyph_view))
write("logo-glyph-on-dark.svg", svg("Workstation CRM mark, on dark", route("url(#momentum)") + start_dot(WHITE, glow=False),
                                    momentum(), view=glyph_view))
x, y = START
write("logo-mono.svg", svg("Workstation CRM mark, one colour",
                           f'<mask id="m"><rect x="{gx}" y="{gy}" width="{gw}" height="{gh}" fill="#fff"/>'
                           f'<circle cx="{x}" cy="{y}" r="30" fill="#000"/></mask>'
                           f'<g mask="url(#m)">{route("currentColor")}</g>', view=glyph_view))

# Icon Composer layers (iOS 26 Liquid Glass), back to front.
write("icon-layers/1-background.svg", svg("Background", BACKGROUND, BACKGROUND_DEFS))
write("icon-layers/2-route.svg", svg("Route", route("url(#momentum)"), momentum()))
write("icon-layers/3-start.svg", svg("Start dot", start_dot(WHITE, glow=False)))

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


NAME, PRODUCT = "Workstation", "CRM"


def name_paths(size, x, baseline, color):
    """"Workstation" in the text colour, "CRM" in the primary, one word-space apart."""
    d1, w1 = text_path(NAME, size, x, baseline)
    gap = size * 0.26
    d2, w2 = text_path(PRODUCT, size, x + w1 + gap, baseline)
    return f'<path fill="{color}" d="{d1}"/><path fill="{PRIMARY}" d="{d2}"/>', w1 + gap + w2


def wordmark(color, name, title):
    size = 160
    paths, width = name_paths(size, 24, 24 + CAP * size, color)
    w, h = int(width + 48), int(CAP * size * 1.3 + 48)
    write(name, svg(title, paths, size=(w, h), view=f"0 0 {w} {h}"))


def lockup(color, dot, name, title):
    height = 190
    scale = height / gh
    size = 140
    cap = CAP * size
    tx = 24 + gw * scale + 48
    baseline = 24 + height / 2 + cap / 2
    paths, width = name_paths(size, tx, baseline, color)
    w, h = int(tx + width + 28), int(height + 48)
    body = (f'<g transform="translate(24 24) scale({scale:.5f}) translate({-gx} {-gy})">'
            f'{route("url(#momentum)")}{start_dot(dot, glow=False)}</g>{paths}')
    write(name, svg(title, body, momentum(), size=(w, h), view=f"0 0 {w} {h}"))


wordmark(INK, "wordmark.svg", "Workstation CRM")
wordmark(WHITE, "wordmark-on-dark.svg", "Workstation CRM")
lockup(INK, INK, "lockup.svg", "Workstation CRM")
lockup(WHITE, WHITE, "lockup-on-dark.svg", "Workstation CRM")


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

print("Built the Workstation CRM brand files in", brand)
