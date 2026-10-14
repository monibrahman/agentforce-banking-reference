"""Contact sheets of exported slide PNGs (4 per sheet, half size) for the visual check.

usage: python -X utf8 slide_sheets.py <slides_dir> <out_prefix>
"""
import glob
import os
import sys
import fitz

src, prefix = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(src, 'slide_*.png')))
pms = []
for f in files:
    p = fitz.Pixmap(f)
    p.shrink(1)                       # halve: 1600x900 -> 800x450
    if p.alpha:
        p = fitz.Pixmap(p, 0)
    pms.append(p)
w, h = pms[0].width, pms[0].height
for n, start in enumerate(range(0, len(pms), 4), 1):
    sheet = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 2 * w + 30, 2 * h + 30), False)
    sheet.set_rect(sheet.irect, (120, 120, 120))
    for i, p in enumerate(pms[start:start + 4]):
        p.set_origin(10 + (i % 2) * (w + 10), 10 + (i // 2) * (h + 10))
        sheet.copy(p, p.irect)
    sheet.save(f'{prefix}_{n:02d}.png')
print(len(pms), 'slides')
