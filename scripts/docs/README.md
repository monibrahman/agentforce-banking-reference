# Document builders

Scripts that generate the Day 5 documents from facts recorded in the repo. They don't touch the org.

| Script | Output |
| --- | --- |
| `arch_svg.py <out_dir>` | `architecture.svg` and `architecture.png`: the architecture diagram, hand-placed SVG rendered to PNG with headless Microsoft Edge. Copy both to `docs/diagrams/` |
| `docxkit.py` | Shared Word styling: Calibri 11, accent headings, title page, TOC field, header and "Page X of Y" footer, tables with a repeated header row |
| `build_fs.py <out.docx> <architecture.png>` | `docs/Functional_Specification.docx` |
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
