#!/usr/bin/env python3
"""Read a PDF whose text cannot be extracted, by rendering it and running OCR.

Some official curricula are published as PDFs whose text is present but
unreadable: the fonts are embedded with a custom encoding and no ToUnicode CMap,
so every extractor returns the same handful of characters. CAPA is one — pypdf,
poppler's pdftotext and pdfminer.six independently produce 44 characters from a
three-page curriculum, which is not a bug in any of them. `pdffonts` shows it:

    name                              type      encoding  emb sub uni
    SZZMHS+HelveticaNeueLTStd-Roman   Type 1C   Custom    yes yes no
                                                               ^^^ no Unicode map

This exists so that a syllabus frozen from such a document is derived and
re-runnable like every other one, rather than typed in by hand once and
unverifiable afterwards.

    scripts/ocr_pdf.py <url-or-path>            # text to stdout
    scripts/ocr_pdf.py <url-or-path> --check    # is OCR even needed here?

Deliberately NOT wired into `tracker.fetch_text`: OCR output has errors, and a
syllabus is the list of everything that will be written, so it is worth a human
looking at the result before it is frozen. Free of API quota, but it needs
`pdftoppm` (poppler) and an OCR engine — tesseract, or rapidocr as a pure-pip
fallback. It says which one it used, because they do not make the same mistakes.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

# Below this, a PDF's own text layer is not a text layer. CAPA yields 44
# characters over three pages; a real curriculum page runs to thousands.
MIN_REAL_TEXT = 200


def fetch(source: str, into: Path) -> Path:
    if not source.startswith(("http://", "https://")):
        return Path(source)
    from teach.core import tracker
    body, _ = tracker._get_bytes(source)
    target = into / "source.pdf"
    target.write_bytes(body)
    return target


def embedded_text(pdf: Path) -> str:
    """What the PDF's own text layer yields. Empty-ish means OCR is needed."""
    try:
        from pypdf import PdfReader
        reader = PdfReader(str(pdf))
        return "\n".join(page.extract_text() or "" for page in reader.pages).strip()
    except Exception:
        return ""


def ocr(pdf: Path, dpi: int = 200) -> tuple[str, str]:
    """(text, engine). Renders each page, then reads the pixels."""
    if not shutil.which("pdftoppm"):
        raise SystemExit("pdftoppm not found (install poppler-utils)")

    with tempfile.TemporaryDirectory() as tmp:
        prefix = Path(tmp) / "page"
        subprocess.run(["pdftoppm", "-r", str(dpi), "-png", str(pdf), str(prefix)],
                       check=True, capture_output=True, timeout=300)
        pages = sorted(Path(tmp).glob("page*.png"))
        if not pages:
            raise SystemExit(f"{pdf} rendered no pages")

        if shutil.which("tesseract"):
            out = []
            for page in pages:
                result = subprocess.run(["tesseract", str(page), "-", "--psm", "6"],
                                        capture_output=True, text=True, timeout=300)
                out.append(result.stdout)
            return "\n".join(out), "tesseract"

        try:
            from rapidocr_onnxruntime import RapidOCR
        except ImportError:
            raise SystemExit(
                "No OCR engine. Install one:\n"
                "  sudo dnf install -y tesseract          (better, needs root)\n"
                "  .venv/bin/pip install rapidocr-onnxruntime   (no root)")
        engine = RapidOCR()
        out = []
        for page in pages:
            result, _ = engine(str(page))
            out.append("\n".join(line[1] for line in (result or [])))
        return "\n".join(out), "rapidocr"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="URL or path of the PDF")
    parser.add_argument("--check", action="store_true",
                        help="report whether the PDF needs OCR, and read nothing")
    parser.add_argument("--dpi", type=int, default=200)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        pdf = fetch(args.source, Path(tmp))
        native = embedded_text(pdf)

        if args.check:
            if len(native) >= MIN_REAL_TEXT:
                print(f"No OCR needed: the text layer yields {len(native)} characters.")
                return 0
            print(f"OCR needed: the text layer yields only {len(native)} characters. "
                  f"The text is there but has no Unicode mapping — check with "
                  f"`pdffonts`, the 'uni' column will say no.")
            return 1

        if len(native) >= MIN_REAL_TEXT:
            # Prefer the real text layer: it is exact, and OCR is not.
            print(native)
            return 0

        text, engine = ocr(pdf, args.dpi)
        print(f"# OCR via {engine}; read it before freezing a syllabus from it.",
              file=sys.stderr)
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
