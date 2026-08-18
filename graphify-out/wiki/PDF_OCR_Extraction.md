# PDF OCR Extraction

> 8 nodes · cohesion 0.46

## Key Concepts

- **ocr_pdf.py** (5 connections) — `scripts/ocr_pdf.py`
- **main()** (5 connections) — `scripts/ocr_pdf.py`
- **embedded_text()** (4 connections) — `scripts/ocr_pdf.py`
- **fetch()** (4 connections) — `scripts/ocr_pdf.py`
- **ocr()** (4 connections) — `scripts/ocr_pdf.py`
- **Path** (4 connections)
- **What the PDF's own text layer yields. Empty-ish means OCR is needed.** (1 connections) — `scripts/ocr_pdf.py`
- **(text, engine). Renders each page, then reads the pixels.** (1 connections) — `scripts/ocr_pdf.py`

## Relationships

- [Syllabus Snapshot Checks](Syllabus_Snapshot_Checks.md) (2 shared connections)

## Source Files

- `scripts/ocr_pdf.py`

## Audit Trail

- EXTRACTED: 15 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*