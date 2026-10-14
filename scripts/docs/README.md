# Document builders

Scripts that generate the Day 5 documents from facts recorded in the repo. They don't touch the org.

| Script | Output |
| --- | --- |
| `arch_svg.py <out_dir>` | `architecture.svg` and `architecture.png`: the architecture diagram, hand-placed SVG rendered to PNG with headless Microsoft Edge. Copy both to `docs/diagrams/` |
| `docxkit.py` | Shared Word styling: Calibri 11, accent headings, title page, TOC field, header and "Page X of Y" footer, tables with a repeated header row |
| `build_fs.py <out.docx> <architecture.png>` | `docs/Functional_Specification.docx` |
| `build_tp.py <out.docx> <architecture.png> <test_results.csv>` | `docs/Test_Protocol.docx`; results come from the CSV, every TC without a row shows "Pending execution" |
| `build_deck.py <out.pptx> <architecture.png>` | `docs/Panel_Overview.pptx` (16:9, speaker notes, "[after execution]" placeholders) |
| `ppt_render.ps1 -PptPath <pptx> -OutDir <dir>` | Exports every slide to PNG through PowerPoint (COM) |
| `slide_sheets.py <slides_dir> <prefix>` | Contact sheets of the slide PNGs, for the layout check |
| `word_finish.ps1 -DocPath <docx> -PdfPath <pdf>` | Opens the document in Word (COM), updates the TOC and page fields, saves, and exports a PDF |
| `render_pages.py <pdf> <prefix> [per_sheet] [dpi]` | Contact sheets of the PDF pages, for the layout check |

Requirements: Python 3 with `python-docx`, `python-pptx` and `pymupdf`; Microsoft Word and PowerPoint (the TOC and page numbers
are computed by Word); Microsoft Edge for the diagram.

Example:
```
python -X utf8 scripts/docs/arch_svg.py out
python -X utf8 scripts/docs/build_fs.py out/Functional_Specification.docx out/architecture.png
powershell -File scripts/docs/word_finish.ps1 -DocPath <full path>.docx -PdfPath <full path>.pdf
```
