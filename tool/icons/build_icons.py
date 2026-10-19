#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds every kickFile icon (Android, macOS, Windows, Linux, tray, site, store) from the "Beam" mark.

    python3 tool/icons/build_icons.py

Needs Google Chrome (headless, for SVG -> PNG) and macOS `sips` (resizing). Writes into app/, site/ and fastlane/.
"""
import os
import struct
import subprocess
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
APP = os.path.join(ROOT, 'app')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

PURPLE_TOP, PURPLE_BOTTOM, CORAL, WHITE = '#7C5CF2', '#5130C2', '#FF7A59', '#FFFFFF'

# The mark on a 1024 grid: a file sending a local signal from its corner.
DOC = 'M248 440H432L512 520V800Q512 840 472 840H248Q208 840 208 800V480Q208 440 248 440Z'
ARCS = ['M540 320A140 140 0 0 1 680 460', 'M540 190A270 270 0 0 1 810 460']
ARC_WIDTH = 60


def glyph(doc=WHITE, arc=CORAL, scale=1.0):
    arcs = ''.join(f'<path d="{d}" fill="none" stroke="{arc}" stroke-width="{ARC_WIDTH}" stroke-linecap="round"/>' for d in ARCS)
    return (f'<g transform="translate(512 512) scale({scale}) translate(-512 -512)">'
            f'<path d="{DOC}" fill="{doc}"/>{arcs}</g>')


GRADIENT = (f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="{PURPLE_TOP}"/>'
            f'<stop offset="1" stop-color="{PURPLE_BOTTOM}"/></linearGradient>'
            '<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="14" stdDeviation="16" '
            'flood-color="#1b1036" flood-opacity=".35"/></filter></defs>')


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{GRADIENT}{body}</svg>'


MASTERS = {
    # Rounded tile: Windows, Linux, legacy Android, site, store.
    'full': svg('<rect width="1024" height="1024" rx="230" fill="url(#bg)"/>' + glyph()),
    # macOS: the 824 px rounded square of Apple's icon grid, with its shadow.
    'mac': svg('<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#sh)"/>' + glyph(scale=0.8)),
    # Android adaptive layers (108 dp canvas; the mark stays inside the 66 dp safe circle).
    'fg': svg(glyph(scale=0.62)),
    'bg': svg('<rect width="1024" height="1024" fill="url(#bg)"/>'),
    'mono': svg(glyph(WHITE, WHITE, scale=0.62)),
    # Store icon (Play / F-Droid want a full square; the stores round it themselves).
    'store': svg('<rect width="1024" height="1024" fill="url(#bg)"/>' + glyph(scale=0.86)),
    # Menu-bar template (macOS tints it): black mark, no tile, filling the canvas.
    'template': svg(glyph('#000', '#000', scale=1.42)),
}


def render(name, workdir):
    page = os.path.join(workdir, f'{name}.html')
    with open(page, 'w') as f:
        f.write('<!doctype html><html><body style="margin:0;background:transparent">'
                + MASTERS[name].replace('<svg ', '<svg width="1024" height="1024" ', 1) + '</body></html>')
    out = os.path.join(workdir, f'{name}.png')
    subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--default-background-color=00000000',
                    '--force-device-scale-factor=1', '--window-size=1024,1024', f'--screenshot={out}', f'file://{page}'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out


def resize(src, size, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run(['sips', '-z', str(size), str(size), src, '--out', dest], check=True, stdout=subprocess.DEVNULL)


def ico(pngs, dest):
    """A Windows .ico holding PNG images (Vista and later)."""
    datas = [open(p, 'rb').read() for p in pngs]
    sizes = [struct.unpack('>II', d[16:24])[0] for d in datas]
    out = struct.pack('<HHH', 0, 1, len(datas))
    offset = 6 + 16 * len(datas)
    for size, d in zip(sizes, datas):
        out += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(d), offset)
        offset += len(d)
    with open(dest, 'wb') as f:
        f.write(out + b''.join(datas))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        m = {name: render(name, tmp) for name in MASTERS}
        res = os.path.join(APP, 'android/app/src/main/res')
        for density, legacy, layer in [('mdpi', 48, 108), ('hdpi', 72, 162), ('xhdpi', 96, 216), ('xxhdpi', 144, 324), ('xxxhdpi', 192, 432)]:
            resize(m['full'], legacy, f'{res}/mipmap-{density}/ic_launcher.png')
            for layer_name in ('fg', 'bg', 'mono'):
                suffix = {'fg': 'foreground', 'bg': 'background', 'mono': 'monochrome'}[layer_name]
                resize(m[layer_name], layer, f'{res}/mipmap-{density}/ic_launcher_{suffix}.png')
        icon_set = os.path.join(APP, 'macos/Runner/Assets.xcassets/AppIcon.appiconset')
        for s in (16, 32, 64, 128, 256, 512, 1024):
            resize(m['mac'], s, f'{icon_set}/app_icon_{s}.png')
        win = []
        for s in (16, 24, 32, 48, 64, 128, 256):
            win.append(os.path.join(tmp, f'win_{s}.png'))
            resize(m['full'], s, win[-1])
        ico(win, os.path.join(APP, 'windows/runner/resources/app_icon.ico'))
        ico(win[:4], os.path.join(APP, 'assets/tray/tray.ico'))
        resize(m['full'], 256, os.path.join(APP, 'assets/icon/kickfile_256.png'))
        resize(m['full'], 64, os.path.join(APP, 'assets/tray/tray.png'))
        resize(m['template'], 18, os.path.join(APP, 'assets/tray/tray_template.png'))
        resize(m['template'], 36, os.path.join(APP, 'assets/tray/tray_template@2x.png'))
        resize(m['store'], 512, os.path.join(ROOT, 'fastlane/metadata/android/en-US/images/icon.png'))
    for path in (os.path.join(APP, 'assets/icon/kickfile.svg'), os.path.join(ROOT, 'site/icon.svg')):
        with open(path, 'w') as f:
            f.write(MASTERS['full'] + '\n')
    print('icons written')


if __name__ == '__main__':
    main()
