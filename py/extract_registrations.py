#!/usr/bin/env python3
"""Detect trial / systematic-review registration IDs in a research paper.

Fully local rule-based extraction: pymupdf4llm for PDF->markdown, then a
vetted regex corpus adapted from maia-sh/ctregistries and CrossRef's
clinical-trials-importer registry list. No LLM, no network, no model files.

Usage:
    python extract_registrations.py <input.pdf|input.md>

Emits JSON to stdout:
    {"is_registered": bool,
     "study_type_hint": "trial" | "systematic_review" | "mixed" | "unknown",
     "match_count": int,
     "matches": [
        {"registry": str, "id": str, "section": str,
         "sentence": str, "anchor": str|null,
         "confidence": "high"|"medium"}, ...
     ],
     "markdown_chars": int}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Unicode dash characters used interchangeably in PDFs.
DASH_CHARS = r"\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212"
DASH = f"[{DASH_CHARS}]"
# Optional whitespace-or-dash glue inside/around an ID.
SP = f"[\\s{DASH_CHARS}]?"

# Trial-registry patterns (applied with re.IGNORECASE).
# Anchored with \b to avoid substring hits inside longer tokens.
_TRIAL_REGISTRIES: dict[str, list[str]] = {
    "ClinicalTrials.gov": [
        rf"\bNCT{SP}0\d{{7}}\b",
    ],
    "ISRCTN": [
        rf"\bISRCTN[\s{DASH_CHARS}:]?\d{{8}}\b",
    ],
    "EudraCT": [
        # Year 20xx + 6 digits + 2 digits. Year-only lookbehind avoids hits
        # inside longer ACTRN/phone strings.
        r"(?<![A-Za-z0-9])20\d{2}-\d{6}-\d{2}\b",
    ],
    "ANZCTR": [
        rf"\bACTRN{SP}126\d{{11}}\b",
    ],
    "ChiCTR": [
        r"\bChiCTR2\d{9}\b",                 # new-style (2016+)
        r"\bChiCTR-[A-Z]{2,4}-\d{8}\b",      # legacy
    ],
    "DRKS": [
        rf"\bDRKS{SP}000\d{{5}}\b",
    ],
    "UMIN": [
        rf"\bUMIN{SP}0000\d{{5}}\b",
    ],
    "jRCT": [
        rf"\bjRCT{SP}[a-z]\d{{9}}\b",
    ],
    "CTRI": [
        r"\bCTRI/20\d{2}/\d{2,3}/0\d{5}\b",
    ],
    "IRCT": [
        rf"\bIRCT{SP}20\d{{10,12}}N\d{{1,3}}\b",
    ],
    "NTR": [
        rf"\bNTR{SP}\d{{2,4}}\b",
    ],
    "PACTR": [
        rf"\bPACTR{SP}20\d{{13,14}}\b",
    ],
    "ReBec": [
        rf"\bRBR{SP}[0-9a-z]{{6}}\b",
    ],
    "KCT": [
        rf"\bKCT{SP}00\d{{5}}\b",
    ],
    "WHO UTN": [
        rf"\bU1111{DASH}\d{{4}}{DASH}\d{{4}}\b",
    ],
}

_REVIEW_REGISTRIES: dict[str, list[str]] = {
    "PROSPERO": [
        # Canonical form is CRD + 11 digits today (CRD4 + 2-digit year
        # + 8 digits). Allow 10-13 for legacy / forward-compat.
        r"\bCRD\d{10,13}\b",
    ],
    "INPLASY": [
        rf"\bINPLASY{SP}20\d{{7,9}}\b",
    ],
    "OSF": [
        # URL form — lookbehind prevents hits inside a longer path
        # like "10.17605/OSF.IO/AB3CD".
        r"(?<![/A-Za-z0-9])osf\.io/[a-z0-9]{5,8}\b",
        r"\b10\.17605/OSF\.IO/[A-Z0-9]{5,8}\b",
    ],
    "Research Registry": [
        r"\bresearchregistry\d{3,6}\b",
    ],
}

_COMPILED: dict[str, dict[str, list[re.Pattern]]] = {
    "trial":  {name: [re.compile(p, re.IGNORECASE) for p in pats]
               for name, pats in _TRIAL_REGISTRIES.items()},
    "review": {name: [re.compile(p, re.IGNORECASE) for p in pats]
               for name, pats in _REVIEW_REGISTRIES.items()},
}

# High-confidence anchor phrases that typically precede a registration ID.
_ANCHOR_RE = re.compile(
    r"(?i)\b("
    r"trials?\s+registration"
    r"|trial\s+registry"
    r"|registered\s+(?:at|on|in|with|as|prospectively)"
    r"|clinicaltrials\.gov"
    r"|prospero(?:\s+registration)?(?:\s+number)?"
    r"|systematic\s+review\s+registration"
    r"|registration\s+number"
    r")\b"
)

# Markdown section segmentation.
_SECTION_HDR = re.compile(r"^#{1,6}\s*(.+?)\s*$", re.MULTILINE)
_REFS_HDR = re.compile(r"(?i)^(references|bibliography|works\s+cited|literature\s+cited)\b")

# Sentence splitter (unicode-friendly).
_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"'\u201c])")


_REPAIR_PREFIXES = ("NCT", "ISRCTN", "ACTRN", "DRKS", "UMIN", "CRD", "KCT",
                    "INPLASY", "IRCT", "PACTR", "RBR", "ChiCTR")
_REPAIR_PAT = re.compile(
    rf"\b({'|'.join(_REPAIR_PREFIXES)})\s*(\d(?:[\d\s]{{4,22}}\d|\d{{4,20}}))\b",
    re.IGNORECASE,
)


def preprocess(md: str) -> str:
    # Drop soft-hyphen / zero-width.
    md = re.sub(r"[\u00AD\u200B]", "", md)
    # Rejoin ONLY true mid-token line-wraps:
    #   (a) hyphenated word wrap: letter + dash + \n + letter   -> letter+letter
    #   (b) numeric token split:  digit + \n + digit            -> digit+digit
    # Leave plain word-end newlines alone; otherwise we merge
    # paragraph text and destroy section structure.
    md = re.sub(rf"(?<=[A-Za-z]){DASH}\n(?=[A-Za-z])", "", md)
    md = re.sub(r"(?<=\d)\n(?=\d)", "", md)
    # Repair PyMuPDF artifact: "ISRCT N3551 6780" -> "ISRCTN35516780".
    md = re.sub(r"\bISRCT\s+N(?=\d)", "ISRCTN", md, flags=re.IGNORECASE)
    # Collapse whitespace inside digit runs following known registry prefixes.
    md = _REPAIR_PAT.sub(lambda m: m.group(1) + re.sub(r"\s+", "", m.group(2)), md)
    return md


def classify_sections(md: str) -> list[tuple[int, int, str, bool]]:
    """Split markdown into [(start, end, section_name, is_references)]."""
    headers = [(m.start(), m.group(1).strip()) for m in _SECTION_HDR.finditer(md)]
    if not headers:
        return [(0, len(md), "body", False)]
    out = []
    if headers[0][0] > 0:
        out.append((0, headers[0][0], "preamble", False))
    for i, (start, name) in enumerate(headers):
        end = headers[i + 1][0] if i + 1 < len(headers) else len(md)
        out.append((start, end, name, bool(_REFS_HDR.match(name))))
    return out


def section_label(raw_name: str) -> str:
    n = raw_name.lower().strip("# ").strip()
    if n == "preamble":
        return "preamble"
    if re.search(r"\babstract\b", n):     return "abstract"
    if re.search(r"\b(method(?:s|ology)?|materials\s+and\s+methods)\b", n): return "methods"
    if re.search(r"\b(results?|findings)\b", n):           return "results"
    if re.search(r"\b(discussion|conclusions?)\b", n):     return "discussion"
    if re.search(r"\b(declar|disclosure|funding|acknowled|conflict|ethic|trial registration)\b", n):
        return "declarations"
    if re.search(r"\bintroduction\b", n):                  return "introduction"
    return raw_name[:60] or "body"


def surrounding_sentence(text: str, start: int, end: int, window: int = 350) -> str:
    lo = max(0, start - window)
    hi = min(len(text), end + window)
    chunk = text[lo:hi]
    rel = start - lo
    # Walk through split parts to find the one containing the match.
    pieces = _SENT_SPLIT.split(chunk)
    acc = 0
    for p in pieces:
        seg_start = acc
        seg_end = acc + len(p)
        if seg_start <= rel < seg_end + 1:
            return p.strip()
        acc = seg_end + 1  # approx for whitespace
    return chunk.strip()


# Registries whose IDs can have their *prefix*-to-digits separator stripped
# safely to produce a canonical form.  Excludes registries that use internal
# hyphens (WHO UTN = U1111-NNNN-NNNN, ReBec = RBR-xxxxxx).
_UP_PREFIX = {
    "ClinicalTrials.gov": "NCT",
    "ISRCTN": "ISRCTN",
    "ANZCTR": "ACTRN",
    "DRKS": "DRKS",
    "UMIN": "UMIN",
    "IRCT": "IRCT",
    "NTR": "NTR",
    "PACTR": "PACTR",
    "KCT": "KCT",
    "INPLASY": "INPLASY",
    "PROSPERO": "CRD",
}


def normalize_id(registry: str, raw: str) -> str:
    s = raw.strip()
    # Kill intra-dash-class separators between prefix and digits.
    pref = _UP_PREFIX.get(registry)
    if pref is not None:
        s = re.sub(
            rf"^({re.escape(pref)})[\s{DASH_CHARS}:]+",
            pref, s, flags=re.IGNORECASE,
        )
        # force canonical case on the prefix
        s = re.sub(rf"^{re.escape(pref)}", pref, s, flags=re.IGNORECASE)
    if registry == "ChiCTR":
        s = re.sub(r"^chictr", "ChiCTR", s, flags=re.IGNORECASE)
    if registry == "jRCT":
        s = re.sub(r"^jrct", "jRCT", s, flags=re.IGNORECASE)
    if registry == "OSF":
        s = re.sub(r"(?i)^osf\.io", "osf.io", s)
        s = re.sub(r"(?i)^10\.17605/OSF\.IO", "10.17605/OSF.IO", s)
    if registry == "Research Registry":
        s = s.lower()
    if registry == "EudraCT":
        s = re.sub(r"\s+", "", s)
    if registry == "WHO UTN":
        # strip whitespace but preserve the mandatory internal hyphens
        s = re.sub(r"\s", "", s)
        # canonicalise the prefix casing
        s = re.sub(r"(?i)^u1111", "U1111", s)
    if registry == "ReBec":
        # canonical form is RBR-xxxxxx, preserve the dash
        s = re.sub(r"(?i)^rbr", "RBR", s)
    return s


def extract_from_markdown(md: str) -> dict:
    md = preprocess(md)
    sections = classify_sections(md)
    seen: dict[tuple[str, str], dict] = {}

    for start, end, name, is_ref in sections:
        if is_ref:
            continue
        sec_text = md[start:end]
        sec_label = section_label(name)

        for kind, regs in _COMPILED.items():
            for reg_name, patterns in regs.items():
                for pat in patterns:
                    for m in pat.finditer(sec_text):
                        raw = m.group(0)
                        norm = normalize_id(reg_name, raw)

                        # context-scoped whitelists for noise-prone registries
                        ctx = sec_text[max(0, m.start() - 200): m.end() + 200]
                        if reg_name == "NTR" and not re.search(
                            r"(?i)\b(trial|dutch|netherlands|registration|registry)\b", ctx
                        ):
                            continue
                        if reg_name == "EudraCT" and not re.search(
                            rf"(?i)(eudract|eu{DASH}?ct|european\s+clinical|european\s+union)",
                            ctx,
                        ):
                            continue

                        sentence = surrounding_sentence(sec_text, m.start(), m.end())
                        anchor_m = _ANCHOR_RE.search(sentence)
                        anchor = anchor_m.group(0) if anchor_m else None
                        confidence = "high" if anchor else "medium"

                        rec = {
                            "registry": reg_name,
                            "id": norm,
                            "section": sec_label,
                            "sentence": sentence,
                            "anchor": anchor,
                            "confidence": confidence,
                            "kind": kind,
                        }
                        key = (reg_name, norm)
                        if key not in seen:
                            seen[key] = rec
                        elif rec["confidence"] == "high" and seen[key]["confidence"] != "high":
                            seen[key] = rec

    matches = list(seen.values())
    sec_rank = {"abstract": 0, "declarations": 1, "methods": 2,
                "preamble": 3, "results": 4, "discussion": 5, "introduction": 6}
    matches.sort(key=lambda r: (
        0 if r["confidence"] == "high" else 1,
        sec_rank.get(r["section"], 99),
    ))

    has_trial = any(r["kind"] == "trial" for r in matches)
    has_review = any(r["kind"] == "review" for r in matches)
    if has_trial and has_review:
        hint = "mixed"
    elif has_trial:
        hint = "trial"
    elif has_review:
        hint = "systematic_review"
    else:
        hint = "unknown"

    return {
        "is_registered": bool(matches),
        "study_type_hint": hint,
        "match_count": len(matches),
        "matches": [{k: v for k, v in r.items() if k != "kind"} for r in matches],
    }


def extract_from_pdf(pdf_path: Path) -> dict:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    import pymupdf4llm  # delayed so markdown-only runs don't require it
    md = pymupdf4llm.to_markdown(str(pdf_path))
    out = extract_from_markdown(md)
    out["markdown_chars"] = len(md)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path, help="PDF or markdown file")
    args = ap.parse_args()
    if args.path.suffix.lower() == ".md":
        text = args.path.read_text(encoding="utf-8")
        out = extract_from_markdown(text)
        out["markdown_chars"] = len(text)
    else:
        out = extract_from_pdf(args.path)
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
