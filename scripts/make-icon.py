#!/usr/bin/env python3
"""Regenerates the app icon (treble clef on Apple Music red): python3 scripts/make-icon.py
Needs rsvg-convert (brew install librsvg). The clef outline is the Apple Symbols U+1D11E glyph (scripts/clef.path)."""
import subprocess, pathlib, sys
here = pathlib.Path(__file__).parent
out = here.parent / "Sources/Assets.xcassets/AppIcon.appiconset"
clef = (here / "clef.path").read_text()
X0, Y0, X1, Y1 = 58, -157, 627, 1343  # glyph bounds (font units, y up)
H, BOLD = 800, 22                      # clef height in icon px; stroke in font units thickens it
s = H / (Y1 - Y0); w = (X1 - X0) * s
glyph = (f'<g transform="translate({512 - w/2 - X0*s:.1f} {512 + H/2 + Y0*s:.1f}) scale({s:.4f} {-s:.4f})">'
         f'<path d="{clef}" fill="url(#ink)" stroke="url(#ink)" stroke-width="{BOLD}" stroke-linejoin="round"/></g>')
defs = '''<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff5c73"/><stop offset=".5" stop-color="#fa2d48"/><stop offset="1" stop-color="#d61733"/></linearGradient>
<linearGradient id="ink" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbf8f8"/><stop offset="1" stop-color="#e6dfdf"/></linearGradient>
<filter id="sh" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#5a0010" flood-opacity=".38"/></filter>
<filter id="msh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity=".35"/></filter></defs>'''
def svg(mac):
    if mac:  # macOS: rounded body inset in the canvas (824px, r185) with a soft shadow
        body = f'<g filter="url(#msh)"><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/></g><g transform="translate(100 100) scale(.8047)"><g filter="url(#sh)">{glyph}</g></g>'
    else:    # iOS: full-bleed square, the system applies the mask
        body = f'<rect width="1024" height="1024" fill="url(#bg)"/><g filter="url(#sh)">{glyph}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{defs}{body}</svg>'
def render(mac, px, name):
    p = subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px)], input=svg(mac).encode(), capture_output=True)
    if p.returncode: sys.exit(p.stderr.decode())
    (out / name).write_bytes(p.stdout)
render(False, 1024, "ios1024.png")
for n in (16, 32, 128, 256, 512):
    render(True, n, f"mac{n}@1x.png"); render(True, n * 2, f"mac{n}@2x.png")
