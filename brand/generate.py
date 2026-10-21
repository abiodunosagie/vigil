#!/usr/bin/env python3
"""Generates Vigil's brand files from one cup drawing: the mark, the app icon master and the
README banner.

The words are Schibsted Grotesk, outlined so no font is needed (fonts/, SIL Open Font License 1.1).

  python3 brand/generate.py
Needs fontTools (pip install fonttools brotli). Writes vigil-mark.svg, vigil-app-icon.svg, banner.svg and banner-static.svg.
"""
import pathlib

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = pathlib.Path(__file__).resolve().parent
FONT = HERE / "fonts/SchibstedGrotesk-normal-400-800.woff2"

NIGHT = "#15122A"
ORANGE = "#FF9E38"
MOON = "#F3EFE6"
DUSK = "#A79FC0"

CUP = "M58 98 H178 V128 A60 52 0 0 1 58 128 Z"
HANDLE = "M160 128 A30 30 0 1 0 220 128 A30 30 0 1 0 160 128 Z M180 128 A12 12 0 1 0 204 128 A12 12 0 1 0 180 128 Z"
SAUCER = '<rect x="40" y="190" width="176" height="16" rx="8"'
STEAM = ["M96 78 C86 66 106 58 96 44", "M140 78 C130 66 150 58 140 44"]


def cup(fill):
  return (
    f'<path fill="{fill}" d="{CUP}"/><path fill="{fill}" fill-rule="evenodd" d="{HANDLE}"/>{SAUCER} fill="{fill}"/>'
    + "".join(f'<path fill="none" stroke="{fill}" stroke-width="11" stroke-linecap="round" d="{d}"/>' for d in STEAM)
  )


def icon():
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><title>Vigil app icon</title>'
    '<defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#33294D"/>'
    '<stop offset="1" stop-color="#0F0D1F"/></linearGradient></defs>'
    '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>'
    f'<g transform="translate(512 520) scale(2.3) translate(-128 -125)">{cup(ORANGE)}</g></svg>\n'
  )


def outline(text, weight, size):
  font = instancer.instantiateVariableFont(TTFont(FONT), {"wght": weight})
  glyphs, cmap, upm = font.getGlyphSet(), font.getBestCmap(), font["head"].unitsPerEm
  pen, x, scale = SVGPathPen(glyphs), 0.0, size / upm
  for ch in text:
    name = cmap[ord(ch)]
    glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x * scale, 0)))
    x += font["hmtx"][name][0]
  return pen.getCommands()


def banner(animated):
  word = outline("vigil", 700, 190)
  line_1 = outline("Keeps your Mac awake", 500, 42)
  line_2 = outline("while Claude Code works.", 500, 42)
  detail = outline("Tells you when Claude finishes, then lets the Mac sleep.", 400, 26)
  style = ""
  if animated:
    style = """<style>
.cup{animation:fade .6s ease-out .1s both}
.steam{stroke-dasharray:60;stroke-dashoffset:60;animation:draw 1.2s cubic-bezier(.65,0,.35,1) forwards}
.s1{animation-delay:.7s}.s2{animation-delay:.95s}
.word{animation:fade .7s ease-out 1.5s both}.tag{animation:fade .7s ease-out 1.9s both}.detail{animation:fade .7s ease-out 2.2s both}
@keyframes draw{to{stroke-dashoffset:0}}
@keyframes fade{from{opacity:0;transform:translateY(8px)}}
@media (prefers-reduced-motion:reduce){.cup,.word,.tag,.detail{animation:none}.steam{animation:none;stroke-dashoffset:0}}
</style>"""
  steam = "".join(
    f'<path class="steam s{i + 1}" fill="none" stroke="{ORANGE}" stroke-width="11" stroke-linecap="round" d="{d}"/>'
    for i, d in enumerate(STEAM)
  )
  # A few stars: it is night and the Mac is still up.
  stars = "".join(
    f'<circle cx="{x}" cy="{y}" r="{r}" fill="{MOON}" opacity="{o}"/>'
    for x, y, r, o in [(1130, 92, 3, .7), (1210, 160, 2, .5), (1060, 190, 2, .4), (1180, 560, 2.5, .5), (90, 80, 2, .5), (330, 560, 2, .4)]
  )
  body = (
    f'<rect width="1280" height="640" fill="{NIGHT}"/>{stars}'
    f'<g transform="translate(110 150) scale(1.3)">'
    f'<g class="cup"><path fill="{ORANGE}" d="{CUP}"/><path fill="{ORANGE}" fill-rule="evenodd" d="{HANDLE}"/>{SAUCER} fill="{ORANGE}"/></g>'
    f'{steam}</g>'
    f'<g class="word"><path fill="{MOON}" d="{word}" transform="translate(500 290)"/></g>'
    f'<g class="tag"><path fill="{MOON}" d="{line_1}" transform="translate(506 405)"/>'
    f'<path fill="{MOON}" d="{line_2}" transform="translate(506 457)"/></g>'
    f'<g class="detail"><path fill="{DUSK}" d="{detail}" transform="translate(506 517)"/></g>'
  )
  return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640"><title>Vigil</title>{style}{body}</svg>\n'


if __name__ == "__main__":
  (HERE / "vigil-mark.svg").write_text(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><title>Vigil</title>{cup("#000")}</svg>\n'
  )
  (HERE / "vigil-app-icon.svg").write_text(icon())
  (HERE / "banner.svg").write_text(banner(True))
  (HERE / "banner-static.svg").write_text(banner(False))
