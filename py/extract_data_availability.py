#!/usr/bin/env python3
"""Detect data-availability statements and public-repository deposits.

Approach is adapted from ODDPub (Riedel et al., 2020,
https://github.com/quest-bih/oddpub): rule-based, sentence-level
co-occurrence of category buckets (repository names, "available" verbs,
accession-number regexes, "data" nouns, negative-statement phrases).
Reported sens 0.73 / spec 0.97 with no ML.

Fully local. No LLM, no network, no model files. Designed to share the
same preprocess + section split used by extract_registrations.py.

Usage:
    python extract_data_availability.py <input.pdf|input.md>

Outputs JSON to stdout:
    {"outcome": "deposit_repository" | "unstructured_repository"
                | "on_request" | "no_new_data" | "restricted_access" | "none",
     "has_das_section": bool,
     "das_text": str | null,
     "match_count": int,
     "matches": [
        {"repository": str, "accession": str | null,
         "category": "accession" | "doi" | "url" | "repo_name"
                     | "negative_statement",
         "section": str, "sentence": str,
         "evidence": "das" | "methods" | "results" | "discussion"
                     | "acknowledgements" | "abstract" | "body",
         "confidence": "high" | "medium" | "low"}
     ],
     "markdown_chars": int}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Shared text-preprocess utilities.  Duplicated from extract_registrations.py
# on purpose - keeping a single shared module would couple two CLIs that are
# otherwise independent.  When one changes, sanity-check the other.
# ---------------------------------------------------------------------------

DASH_CHARS = r"\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212"
DASH = f"[{DASH_CHARS}]"

# Prefix-spacing repair patterns for accessions split across PDF token boundaries.
_REPAIR_PREFIXES = ("GSE", "GSM", "GDS", "GPL", "SRR", "SRP", "SRX", "SRS",
                    "ERR", "ERP", "ERX", "ERS", "DRR", "DRP", "DRX", "DRS",
                    "PRJNA", "PRJEA", "PRJEB", "PRJDA", "PRJDB", "PRJNB",
                    "SAMN", "SAMEA", "SAMD",
                    "PXD", "MSV", "MTBLS", "PHS", "EGAS", "EGAD",
                    "EMPIAR", "EMD", "GCA", "GCF", "VCV", "CHEMBL", "BIAD")
_REPAIR_PAT = re.compile(
    rf"\b({'|'.join(_REPAIR_PREFIXES)})\s*(\d(?:[\d\s]{{4,22}}\d|\d{{4,20}}))\b",
    re.IGNORECASE,
)


def preprocess(md: str) -> str:
    md = re.sub(r"[\u00AD\u200B]", "", md)
    # Only join hyphenated wraps and digit-digit splits (see registration.py).
    md = re.sub(rf"(?<=[A-Za-z]){DASH}\n(?=[A-Za-z])", "", md)
    md = re.sub(r"(?<=\d)\n(?=\d)", "", md)
    md = _REPAIR_PAT.sub(lambda m: m.group(1) + re.sub(r"\s+", "", m.group(2)), md)
    return md


# Markdown-heading section splitter.  We re-classify each section into a
# canonical bucket so downstream confidence rules are easy to express.
_SECTION_HDR = re.compile(r"^#{1,6}\s*(.+?)\s*$", re.MULTILINE)
_REFS_HDR = re.compile(r"(?i)^(references|bibliography|works\s+cited|literature\s+cited)\b")

# Data-availability section heading variants (see ODDPub + JATS4R).
_DAS_HDR = re.compile(
    r"""(?ix)^
    (?:\d+\.?\s*)?
    (?:
      data\s+availability(?:\s+statement)?
    | availability\s+of\s+data(?:\s+(?:and|&)\s+(?:materials?|code))?
    | data\s+(?:and|&)\s+code\s+availability
    | code\s+(?:and|&)\s+data\s+availability
    | code\s+availability(?:\s+statement)?
    | data\s+sharing(?:\s+statement)?
    | data\s+access(?:ibility)?(?:\s+statement)?
    | materials?\s+(?:and|&)\s+data\s+availability
    | resource\s+availability
    | data,?\s+materials?,?\s+(?:and|&)\s+code\s+availability
    )
    \s*:?\s*$
    """,
)


def _strip_md_emphasis(s: str) -> str:
    """Remove markdown bold/italic wrappers from a heading string."""
    s = re.sub(r"^\*+\s*", "", s)
    s = re.sub(r"\s*\*+$", "", s)
    s = re.sub(r"^_+\s*", "", s)
    s = re.sub(r"\s*_+$", "", s)
    return s.strip()


def _section_label(raw: str) -> str:
    cleaned = _strip_md_emphasis(raw.strip("# ").strip())
    n = cleaned.lower()
    if not n: return "body"
    if _DAS_HDR.match(cleaned): return "das"
    if "abstract" in n: return "abstract"
    if re.search(r"\b(method(?:s|ology)?|materials?\s+and\s+methods)\b", n): return "methods"
    if re.search(r"\b(results?|findings)\b", n): return "results"
    if re.search(r"\b(discussion|conclusions?)\b", n): return "discussion"
    if re.search(r"\b(acknowled|funding|disclos|declar|conflict|ethic)\b", n): return "acknowledgements"
    if re.search(r"\bintroduction\b", n): return "introduction"
    return raw[:60] or "body"


def classify_sections(md: str):
    """Return [(start, end, raw_name, label, is_references)]."""
    headers = [(m.start(), m.group(1).strip()) for m in _SECTION_HDR.finditer(md)]
    if not headers:
        return [(0, len(md), "body", "body", False)]
    out = []
    if headers[0][0] > 0:
        out.append((0, headers[0][0], "preamble", "abstract", False))
    for i, (start, name) in enumerate(headers):
        end = headers[i + 1][0] if i + 1 < len(headers) else len(md)
        is_ref = bool(_REFS_HDR.match(name))
        out.append((start, end, name, _section_label(name), is_ref))
    return out


_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"'\u201c])")


def surrounding_sentence(text: str, start: int, end: int, window: int = 350) -> str:
    lo = max(0, start - window)
    hi = min(len(text), end + window)
    chunk = text[lo:hi]
    rel = start - lo
    pieces = _SENT_SPLIT.split(chunk)
    acc = 0
    for p in pieces:
        seg_start = acc
        seg_end = acc + len(p)
        if seg_start <= rel < seg_end + 1:
            return p.strip()
        acc = seg_end + 1
    return chunk.strip()


# ---------------------------------------------------------------------------
# Repository regex corpus.
# Patterns marked "gated" require an additional repository-context keyword
# in the surrounding sentence to fire (handles e.g. PDB 4-char codes that
# would otherwise collide with figure labels and primer codes).
# ---------------------------------------------------------------------------

# (repository, pattern, gated_context_regex_or_None)
ACCESSION_PATTERNS: list[tuple[str, str, str | None]] = [
    # ---- safe accessions (well-anchored prefixes) ----
    ("GEO",            r"\bG(?:SE|SM|DS|PL)\d{2,}\b",                                None),
    ("SRA",            r"\b[SED]R[PRSX]\d{3,}\b",                                    None),
    ("BioProject",     r"\bPRJ(?:NA|EA|EB|DA|DB|NB)\d+\b",                           None),
    ("BioSample",      r"\bSAM(?:N|EA|D)\d+\b",                                      None),
    ("ArrayExpress",   r"\b[EP]-[A-Z]{4}-\d+\b",                                     None),
    ("BioStudies",     r"\bS-?BIAD\d+\b",                                            None),
    ("PRIDE",          r"\bR?PXD\d{5,7}\b",                                          None),
    ("MassIVE",        r"\bMSV\d{9}\b",                                              None),
    ("MetaboLights",   r"\bMTBLS\d+\b",                                              None),
    ("dbGaP",          r"\bphs\d{6}(?:\.v\d+)?(?:\.p\d+)?\b",                        None),
    ("EGA",            r"\bEGA[SD]\d{11}\b",                                         None),
    ("RefSeq",         r"\b(?:N[CGMTPRWZ]|X[MRP]|YP|AP|WP)_\d+(?:\.\d+)?\b",         None),
    ("Assembly",       r"\bGC[AF]_\d{9}\.\d+\b",                                     None),
    ("ClinVar",        r"\b[VS]CV\d{9}(?:\.\d+)?\b",                                 None),
    ("ChEMBL",         r"\bCHEMBL\d+\b",                                             None),
    ("EMPIAR",         r"\bEMPIAR-\d{4,5}\b",                                        None),
    ("EMDB",           r"\bEMD(?:B)?-\d{4,5}\b",                                     None),

    # ---- gated accessions (high false-positive risk in isolation) ----
    ("PDB",            r"(?<![A-Z0-9])[1-9][A-Z0-9]{3}(?![A-Z0-9])",
                       r"(?i)\b(PDB|RCSB|wwPDB|protein\s+data\s+bank|crystal\s+structure|coordinates?\s+(?:were\s+)?deposited|pdb\.org|rcsb\.org)\b"),
    ("UniProt",        r"\b(?:[OPQ]\d[A-Z0-9]{3}\d|[A-NR-Z]\d[A-Z][A-Z0-9]{2}\d(?:[A-Z][A-Z0-9]{2}\d)?)\b",
                       r"(?i)\b(uniprot|swiss-?prot|trembl)\b"),
    ("OpenNeuro",      r"\bds\d{6}\b",
                       r"(?i)\bopenneuro\b"),
    ("Synapse",        r"\bsyn\d{6,}\b",
                       r"(?i)\bsynapse\b"),
    ("GenBank",        r"\b[A-Z]{1,2}\d{5,8}(?:\.\d+)?\b",
                       r"(?i)\b(genbank|gen\s?bank|ncbi|deposited|accession\s*(?:no\.?|number)?\s*[:#]?)\b"),
]

# DOI prefixes that uniquely identify a public data repository.
DOI_PATTERNS: list[tuple[str, str]] = [
    ("Zenodo",            r"\b10\.5281/zenodo\.\d+\b"),
    ("Figshare",          r"\b10\.6084/m9\.figshare\.\d+(?:\.v\d+)?\b"),
    ("Dryad",             r"\b10\.5061/dryad\.[A-Za-z0-9]+\b"),
    ("Harvard Dataverse", r"\b10\.7910/DVN/[A-Z0-9]+\b"),
    ("Mendeley Data",     r"\b10\.17632/[A-Za-z0-9]+\.\d+\b"),
    ("OpenNeuro",         r"\b10\.18112/openneuro\.ds\d+\.v[\d.]+\b"),
    ("OSF",               r"\b10\.17605/OSF\.IO/[A-Z0-9]{5,8}\b"),
]

# URL forms (case-insensitive).
URL_PATTERNS: list[tuple[str, str]] = [
    ("Zenodo",            r"\bzenodo\.org/(?:record|records|doi)/\d+\b"),
    ("Figshare",          r"\bfigshare\.com/(?:articles|s|collections|projects)/[^\s)\]]+"),
    ("Dryad",             r"\bdatadryad\.org/(?:stash/dataset|resource)/[^\s)\]]+"),
    ("OSF",               r"(?<![/A-Za-z0-9])osf\.io/[a-z0-9]{5,8}\b"),
    ("Harvard Dataverse", r"\bdataverse\.harvard\.edu/dataset\.xhtml\?persistentId=[^\s)\]]+"),
    ("Hugging Face",      r"\bhuggingface\.co/datasets/[A-Za-z0-9_./\-]+"),
    ("GitHub",            r"\b(?:https?://)?(?:www\.)?github\.com/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+\b"),
]

# Repository names mentioned in prose - used to upgrade confidence and to
# emit "unstructured_repository" outcomes when a repo is named without an
# accession.  Drawn from ODDPub field_specific_repo + generalist_repo lists.
REPO_NAMES = [
    "GenBank", "RefSeq", "GEO", "Gene Expression Omnibus",
    "Sequence Read Archive", "SRA", "ArrayExpress", "BioStudies",
    "BioProject", "BioSample", "PRIDE", "ProteomeXchange", "MassIVE",
    "MetaboLights", "dbGaP", "EGA", "European Genome-phenome Archive",
    "ENA", "European Nucleotide Archive", "DDBJ", "PDB", "Protein Data Bank",
    "wwPDB", "RCSB", "EMPIAR", "EMDB", "UniProt", "Swiss-Prot", "TrEMBL",
    "ClinVar", "ChEMBL", "OpenNeuro", "PhysioNet",
    # generalist
    "Zenodo", "Figshare", "Dryad", "Harvard Dataverse", "Dataverse",
    "Mendeley Data", "OSF", "Open Science Framework", "Synapse",
    "Hugging Face", "GitHub",
]
_REPO_NAME_RE = re.compile(
    r"(?i)\b(?:" + "|".join(re.escape(r) for r in REPO_NAMES) + r")\b"
)

# "Data is available" verb cluster (ODDPub `available` bucket, condensed).
_AVAILABLE_VERB = re.compile(
    r"(?i)\b("
    r"(?:are|is|will\s+be|were|was|been|been\s+made)\s+(?:publicly\s+|freely\s+|openly\s+|made\s+)?available"
    r"|deposited|uploaded|hosted|archived|accessible(?:\s+(?:at|via|from|in|on|through))?"
    r"|can\s+be\s+(?:found|accessed|downloaded|obtained)"
    r"|available\s+(?:at|in|on|via|from|under|through)"
    r"|accession\s+(?:no\.?|number|code|id)?"
    r"|under\s+accession"
    r"|(?:freely|publicly|openly)\s+(?:available|accessible)"
    r")\b"
)

# Negative / non-deposit statements (ODDPub buckets).
_NEG_PATTERNS: list[tuple[str, str]] = [
    ("on_request",
     r"(?i)\b(data|datasets?|materials?)[^.\n]{0,80}\b(?:available|provided|shared|obtainable)\b[^.\n]{0,40}\b(?:on|upon)\b[^.\n]{0,15}\b(?:reasonable\s+)?request\b"),
    ("on_request",
     r"(?i)\bavailable\s+(?:on|upon)\s+(?:reasonable\s+)?request\b"),
    ("on_request",
     r"(?i)\b(?:from|on\s+request\s+(?:from|to))\s+the\s+corresponding\s+author\b"),
    ("no_new_data",
     r"(?i)\bno\s+(?:new\s+)?(?:data|datasets?)\s+(?:were|was|have\s+been)\s+(?:generated|created|produced|analy[sz]ed|collected)\b"),
    ("no_new_data",
     r"(?i)\bdata\s+sharing\s+(?:is\s+)?not\s+applicable\b"),
    ("restricted_access",
     r"(?i)\b(?:controlled|restricted)[\s\-]+access\b"),
    ("restricted_access",
     r"(?i)\bsubject\s+to\s+(?:institutional\s+)?(?:approval|review|controlled\s+access)\b"),
]

# Sometimes papers say data are in supplementary material.  Treated as a
# *non-deposit* outcome (ODDPub `supplement` bucket).
_SUPPLEMENT_RE = re.compile(
    r"(?i)\b(?:supplement(?:ary|al)\s+(?:material|information|file|data|tables?)"
    r"|supporting\s+information|SI\s+appendix)\b"
)

# Compile patterns once.
_ACCESSION_COMPILED = [(name, re.compile(p), re.compile(g) if g else None)
                       for (name, p, g) in ACCESSION_PATTERNS]
_DOI_COMPILED = [(name, re.compile(p, re.IGNORECASE)) for (name, p) in DOI_PATTERNS]
_URL_COMPILED = [(name, re.compile(p, re.IGNORECASE)) for (name, p) in URL_PATTERNS]
_NEG_COMPILED = [(label, re.compile(p)) for (label, p) in _NEG_PATTERNS]


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def _normalize_url(url: str) -> str:
    if url.startswith("http"):
        return url
    return "https://" + url


def _confidence_for(evidence: str, repo: str, has_repo_ctx: bool, has_avail_verb: bool) -> str:
    if evidence == "das":
        return "high"
    if has_repo_ctx and has_avail_verb:
        return "high"
    if has_repo_ctx or has_avail_verb:
        return "medium"
    return "low"


def _scan_section(sec_text: str, sec_label: str, results: list,
                  seen: set, base_offset: int) -> None:
    """Sweep a section of text and append matches to `results`."""
    # 1) accession sweeps
    for repo, pat, gate in _ACCESSION_COMPILED:
        for m in pat.finditer(sec_text):
            raw = m.group(0)
            ctx = sec_text[max(0, m.start() - 200): m.end() + 200]
            if gate is not None and not gate.search(ctx):
                continue
            sentence = surrounding_sentence(sec_text, m.start(), m.end())
            has_repo_ctx = bool(_REPO_NAME_RE.search(ctx))
            has_avail_verb = bool(_AVAILABLE_VERB.search(ctx))
            conf = _confidence_for(sec_label, repo, has_repo_ctx, has_avail_verb)
            key = ("acc", repo, raw)
            if key in seen: continue
            seen.add(key)
            results.append({
                "repository": repo, "accession": raw,
                "category": "accession",
                "section": sec_label, "sentence": sentence,
                "evidence": sec_label, "confidence": conf,
            })

    # 2) DOI sweeps (data-repo prefixes)
    for repo, pat in _DOI_COMPILED:
        for m in pat.finditer(sec_text):
            raw = m.group(0)
            sentence = surrounding_sentence(sec_text, m.start(), m.end())
            ctx = sec_text[max(0, m.start() - 200): m.end() + 200]
            has_repo_ctx = True  # DOI prefix already identifies the repo
            has_avail_verb = bool(_AVAILABLE_VERB.search(ctx))
            conf = "high" if (sec_label == "das" or has_avail_verb) else "medium"
            key = ("doi", repo, raw)
            if key in seen: continue
            seen.add(key)
            results.append({
                "repository": repo, "accession": raw,
                "category": "doi",
                "section": sec_label, "sentence": sentence,
                "evidence": sec_label, "confidence": conf,
            })

    # 3) URL sweeps
    for repo, pat in _URL_COMPILED:
        for m in pat.finditer(sec_text):
            raw = m.group(0)
            sentence = surrounding_sentence(sec_text, m.start(), m.end())
            ctx = sec_text[max(0, m.start() - 200): m.end() + 200]
            # GitHub URLs default to code-not-data unless adjacent text
            # mentions "data" or path includes /data
            if repo == "GitHub":
                if not (re.search(r"(?i)/(?:data|datasets?)\b", raw)
                        or re.search(r"(?i)\b(data|dataset|repository)\b", ctx)):
                    # still record but flag as code-only with low confidence
                    rep = "GitHub (code)"
                else:
                    rep = "GitHub"
            else:
                rep = repo
            has_avail_verb = bool(_AVAILABLE_VERB.search(ctx))
            conf = "high" if (sec_label == "das" and has_avail_verb) else \
                   "medium" if has_avail_verb else "low"
            key = ("url", rep, raw.lower())
            if key in seen: continue
            seen.add(key)
            results.append({
                "repository": rep, "accession": _normalize_url(raw),
                "category": "url",
                "section": sec_label, "sentence": sentence,
                "evidence": sec_label, "confidence": conf,
            })


def extract_data_availability(md: str) -> dict:
    md = preprocess(md)
    sections = classify_sections(md)

    # Locate the DAS section (if any)
    das_text = None
    has_das = False
    for start, end, raw, label, is_ref in sections:
        if label == "das":
            das_text = md[start:end].strip()
            has_das = True
            break

    matches: list[dict] = []
    seen: set = set()

    for start, end, raw, label, is_ref in sections:
        if is_ref:
            continue
        sec_text = md[start:end]
        _scan_section(sec_text, label, matches, seen, start)

    # ---- Negative-statement classification ----
    neg_matches: list[dict] = []
    # Run within DAS first (high precision); fall back to whole body if no DAS
    neg_scan_blocks = []
    if das_text:
        neg_scan_blocks.append(("das", das_text))
    else:
        for start, end, raw, label, is_ref in sections:
            if is_ref or label == "das":
                continue
            neg_scan_blocks.append((label, md[start:end]))
    neg_seen: set = set()
    for sec_label, txt in neg_scan_blocks:
        for label, pat in _NEG_COMPILED:
            for m in pat.finditer(txt):
                sentence = surrounding_sentence(txt, m.start(), m.end())
                # Dedupe by (label, sentence-text) so multiple regex variants
                # hitting the same sentence collapse to one match.
                key = (label, sentence[:120])
                if key in neg_seen: continue
                neg_seen.add(key)
                neg_matches.append({
                    "repository": label, "accession": None,
                    "category": "negative_statement",
                    "section": sec_label,
                    "sentence": sentence,
                    "evidence": sec_label, "confidence": "high",
                    "_neg_label": label,
                })

    # ---- Outcome decision ----
    has_deposit = any(m["category"] in ("accession", "doi") for m in matches)
    has_repo_url = any(m["category"] == "url" and not m["repository"].endswith("(code)")
                       for m in matches)

    # repo names mentioned (without accession) only count as
    # "unstructured_repository" if no deposit was found
    repo_name_in_das = bool(das_text and _REPO_NAME_RE.search(das_text))

    on_request = any(m["_neg_label"] == "on_request" for m in neg_matches)
    no_new = any(m["_neg_label"] == "no_new_data" for m in neg_matches)
    restricted = any(m["_neg_label"] == "restricted_access" for m in neg_matches)

    if has_deposit or has_repo_url:
        outcome = "deposit_repository"
    elif restricted:
        outcome = "restricted_access"
    elif no_new:
        outcome = "no_new_data"
    elif on_request:
        outcome = "on_request"
    elif repo_name_in_das:
        outcome = "unstructured_repository"
    else:
        outcome = "none"

    # Include negative-statement matches in output if no deposit was found,
    # so the UI can quote the actual sentence.
    if outcome != "deposit_repository":
        for nm in neg_matches:
            nm.pop("_neg_label", None)
            matches.append(nm)

    # If outcome is unstructured_repository, surface the repo name(s)
    # mentioned in the DAS as match rows.
    if outcome == "unstructured_repository":
        for rm in _REPO_NAME_RE.finditer(das_text or ""):
            matches.append({
                "repository": rm.group(0),
                "accession": None,
                "category": "repo_name",
                "section": "das",
                "sentence": surrounding_sentence(das_text, rm.start(), rm.end()),
                "evidence": "das",
                "confidence": "medium",
            })

    # Sort: high-confidence first, accession > doi > url > repo_name > negative
    cat_rank = {"accession": 0, "doi": 1, "url": 2, "repo_name": 3, "negative_statement": 4}
    conf_rank = {"high": 0, "medium": 1, "low": 2}
    matches.sort(key=lambda r: (conf_rank.get(r["confidence"], 9),
                                cat_rank.get(r["category"], 9)))

    return {
        "outcome": outcome,
        "has_das_section": has_das,
        "das_text": das_text,
        "match_count": len(matches),
        "matches": matches,
    }


def extract_from_pdf(pdf_path: Path) -> dict:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    import pymupdf4llm
    md = pymupdf4llm.to_markdown(str(pdf_path))
    out = extract_data_availability(md)
    out["markdown_chars"] = len(md)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path)
    args = ap.parse_args()
    if args.path.suffix.lower() == ".md":
        text = args.path.read_text(encoding="utf-8")
        out = extract_data_availability(text)
        out["markdown_chars"] = len(text)
    else:
        out = extract_from_pdf(args.path)
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
