#!/usr/bin/env python3
"""One-shot paper scanner: PDF -> markdown -> registration + data-availability.

Calls pymupdf4llm once and feeds the markdown to both detectors so the R
side only pays the PDF parse cost a single time.

Usage:
    python scan_paper.py <input.pdf>

Outputs JSON to stdout:
    {"markdown_chars": int,
     "registration": <registration extractor JSON>,
     "data_availability": <data-availability extractor JSON>}
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Make sibling modules importable regardless of how the script is invoked.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_registrations as er  # noqa: E402
import extract_data_availability as eda  # noqa: E402
import extract_cihr_funding as ecf  # noqa: E402


def scan(pdf_path: Path) -> dict:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    if pdf_path.suffix.lower() == ".md":
        md = pdf_path.read_text(encoding="utf-8")
    else:
        import pymupdf4llm
        md = pymupdf4llm.to_markdown(str(pdf_path))
    return {
        "markdown_chars": len(md),
        "registration": er.extract_from_markdown(md),
        "data_availability": eda.extract_data_availability(md),
        "cihr_funding": ecf.extract_cihr_funding(md),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path)
    args = ap.parse_args()
    out = scan(args.path)
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
