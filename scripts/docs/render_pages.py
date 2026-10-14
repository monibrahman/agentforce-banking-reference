"""Render a PDF to contact sheets (N pages per image) for the visual layout check.

usage: python -I -X utf8 render_pages.py <pdf> <out_prefix> [per_sheet=4] [dpi=70]
"""
import sys
import fitz

pdf, prefix = sys.argv[1], sys.argv[2]
per = int(sys.argv[3]) if len(sys.argv) > 3 else 4
dpi = int(sys.argv[4]) if len(sys.argv) > 4 else 70
doc = fitz.open(pdf)
pages = [p.get_pixmap(dpi=dpi) for p in doc]
w, h = max(p.width for p in pages), max(p.height for p in pages)
cols = 2 if per >= 2 else 1
rows = (per + cols - 1) // cols
sheets = 0
for start in range(0, len(pages), per):
    sheet = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, cols * w + (cols + 1) * 10, rows * h + (rows + 1) * 10), False)
    sheet.set_rect(sheet.irect, (150, 150, 150))
    for i, pm in enumerate(pages[start:start + per]):
        x = 10 + (i % cols) * (w + 10)
        y = 10 + (i // cols) * (h + 10)
        pm.set_origin(x, y)
        sheet.copy(pm, pm.irect)
    sheets += 1
    sheet.save(f'{prefix}_{sheets:02d}.png')
print(len(pages), 'pages ->', sheets, 'sheets')
