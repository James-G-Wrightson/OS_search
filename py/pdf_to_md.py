#!/usr/bin/env python3
"""Convert a PDF to Markdown using pymupdf4llm.

Pure local rule-based extraction (PyMuPDF + pymupdf4llm). No network calls,
no LLMs, no model downloads. Data never leaves the machine.

Usage:
    python pdf_to_md.py <input.pdf> [output.md]

If output.md is omitted, markdown is written to stdout.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pymupdf4llm


def convert(pdf_path: Path) -> str:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    return pymupdf4llm.to_markdown(str(pdf_path))


def main() -> int:
    ap = argparse.ArgumentParser(description="PDF -> Markdown (local, no LLM).")
    ap.add_argument("pdf", type=Path, help="Input PDF path")
    ap.add_argument("output", nargs="?", type=Path,
                    help="Output .md path (default: stdout)")
    args = ap.parse_args()

    md = convert(args.pdf)
    if args.output is None:
        sys.stdout.write(md)
    else:
        args.output.write_text(md, encoding="utf-8")
        print(f"wrote {args.output} ({len(md):,} chars)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
