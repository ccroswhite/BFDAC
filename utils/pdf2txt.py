"""Dump the text of datasheet PDFs to sidecar .txt files for grepping.

usage: python utils/pdf2txt.py datasheets/foo.pdf [more.pdf ...]
Writes datasheets/_foo.txt with '=== page N ===' separators.
"""
import sys
from pathlib import Path

import pymupdf

for arg in sys.argv[1:]:
    src = Path(arg)
    dst = src.with_name("_" + src.stem + ".txt")
    doc = pymupdf.open(str(src))
    with dst.open("w", encoding="utf-8") as f:
        for i, pg in enumerate(doc, 1):
            f.write(f"\n=== page {i} ===\n")
            f.write(pg.get_text())
    print(f"{src.name}: {len(doc)} pages -> {dst.name}")
