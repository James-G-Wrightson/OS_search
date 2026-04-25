#!/usr/bin/env python3
"""Detect whether a paper is FUNDED BY CIHR (not merely mentions CIHR).

Fully local rule-based extraction, no LLM, no network. Scoped detection:
only sentences in a funding / acknowledgments context can contribute a
positive match, and sentences in competing-interest / author-disclosure
sections are ignored. This is what stops author COI lines ("Dr X reports
receiving grants from CIHR") from flipping a paper that was funded by a
different agency to a false positive.

Usage:
    python extract_cihr_funding.py <input.pdf|input.md>

Emits JSON:
    {"funded_by_cihr": bool,
     "confidence": "high" | "medium" | "low" | "none",
     "match_count": int,
     "matches": [
        {"section": str, "sentence": str,
         "evidence": str, "grant_ids": [str, ...],
         "category": "explicit_funding" | "grant_id" | "inline_funding",
         "confidence": "high"|"medium"|"low"},
        ...
     ],
     "markdown_chars": int}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# ---- Preprocessing (mirrors extract_registrations.preprocess) -------------

DASH_CHARS = r"\-‐‑‒–—―−"
DASH = f"[{DASH_CHARS}]"


def preprocess(md: str) -> str:
    md = re.sub(r"[­​]", "", md)
    md = re.sub(rf"(?<=[A-Za-z]){DASH}\n(?=[A-Za-z])", "", md)
    md = re.sub(r"(?<=\d)\n(?=\d)", "", md)
    return md


# ---- Section segmentation -------------------------------------------------

_SECTION_HDR = re.compile(r"^#{1,6}\s*(.+?)\s*$", re.MULTILINE)
_REFS_HDR = re.compile(
    r"(?i)^(references|bibliography|works\s+cited|literature\s+cited)\b"
)

# Section names whose bodies COULD carry an authoritative funding statement.
_FUNDING_HDR = re.compile(
    r"(?i)\b("
    r"funding"
    r"|financial\s+support"
    r"|sources?\s+of\s+funding"
    r"|funding\s+(statement|information|sources?|support)"
    r"|grant\s+support"
    r"|role\s+of\s+the\s+funding\s+source"
    r")\b"
)
_ACK_HDR = re.compile(r"(?i)\b(acknowledg)")

# Section names we must EXCLUDE even though they can talk about CIHR
# funding — these describe authors' other funding, not this paper's.
_COI_HDR = re.compile(
    r"(?i)\b("
    r"competing\s+interests?"
    r"|conflicts?\s+of\s+interest"
    r"|disclosures?"
    r"|declarations?"       # often wraps COI + ethics
    r"|financial\s+disclosures?"
    r"|duality\s+of\s+interest"
    r")\b"
)

_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"'“])")


# Some papers (notably PNAS) use an inline boldface "**ACKNOWLEDGMENTS.**"
# marker instead of a proper markdown header.  Treat those as synthetic
# section starts so the funding-verb window covers the grant attribution
# line that follows.
_INLINE_ACK_BOLD = re.compile(
    r"(?im)^\*\*\s*(acknowledg\w*|funding|financial\s+support|"
    r"grant\s+support|sources?\s+of\s+funding)\s*\.?\*\*"
)


def classify_sections(md: str) -> list[tuple[int, int, str, str]]:
    """Return [(start, end, raw_name, kind)] where kind is one of
    'funding' | 'ack' | 'coi' | 'refs' | 'other' | 'preamble'."""
    headers: list[tuple[int, str]] = [
        (m.start(), m.group(1).strip()) for m in _SECTION_HDR.finditer(md)
    ]
    # Treat inline boldface markers as additional section starts.
    for m in _INLINE_ACK_BOLD.finditer(md):
        headers.append((m.start(), m.group(0).strip("* .")))
    headers.sort(key=lambda h: h[0])
    if not headers:
        return [(0, len(md), "body", "other")]
    out = []
    if headers[0][0] > 0:
        out.append((0, headers[0][0], "preamble", "preamble"))
    for i, (start, name) in enumerate(headers):
        end = headers[i + 1][0] if i + 1 < len(headers) else len(md)
        if _REFS_HDR.match(name):
            kind = "refs"
        elif _COI_HDR.search(name):
            kind = "coi"
        elif _FUNDING_HDR.search(name):
            kind = "funding"
        elif _ACK_HDR.search(name):
            kind = "ack"
        else:
            kind = "other"
        out.append((start, end, name, kind))
    return out


# ---- CIHR mention + funding verb patterns --------------------------------

# All recognised spellings of CIHR. The typo "Canadian Institute of
# Health Research" (singular) genuinely appears in several papers.
_CIHR_RE = re.compile(
    r"\b("
    r"CIHR"
    r"|Canadian\s+Institutes?\s+(?:of|for)\s+Health\s+Research"
    r")\b",
    re.IGNORECASE,
)

# Core "funded by" phrase that identifies the study's own funder.
# Deliberately tight: must name the study (this work / this study / ...)
# as the subject, and the funding verb must be passive ("was supported by").
_STUDY_SUBJECT = (
    r"(?:this|the|our|present|current)\s+"
    r"(?:work|works|study|studies|research|project|paper|manuscript|article|"
    r"trial|analysis|report|investigation|initiative)"
)
_FUND_VERB = (
    r"(?:was|were|is|are|has\s+been|have\s+been)\s+"
    r"(?:supported|funded|financed|sponsored|made\s+possible)"
)
_EXPLICIT_FUNDING_RE = re.compile(
    rf"(?i){_STUDY_SUBJECT}\s+{_FUND_VERB}\s+by\b"
)

# Inline "Funding:" / "Funding statement:" label, common when the paper
# doesn't have a top-level ## Funding header.
_INLINE_FUNDING_LABEL = re.compile(
    r"(?i)(?:^|\n|\s)\*{0,2}"
    r"(funding(?:\s+statement|\s+information|\s+source[s]?)?"
    r"|financial\s+support"
    r"|grant\s+support"
    r"|sources?\s+of\s+funding"
    r"|role\s+of\s+the\s+funding\s+source)"
    r"\*{0,2}\s*[:\-–—]"
)

# Author-disclosure patterns to reject. If a sentence matches one of
# these AND names CIHR, the CIHR mention is almost certainly about the
# author's other funding, not this paper's.
_AUTHOR_DISCLOSURE_RE = re.compile(
    r"(?i)\b("
    r"reports?\s+(?:receiving|having\s+received|a\s+grant)"
    r"|has\s+received\s+(?:grants?|funding|support)"
    r"|received\s+(?:grants?|funding|support)\s+from"
    r"|holds?\s+a?\s*(?:grant|award|chair)"
    r"|reports?\s+grants?"
    r"|was\s+(?:previously|formerly)\s+(?:supported|funded)"
    r")\b"
)

# Negation check: "no funding from CIHR", "not funded by CIHR".
_NEGATION_RE = re.compile(
    r"(?i)\b(no|not|never|without|neither)\b[^.]{0,60}\b(funding|funded|support|grant)"
)

# A CIHR token followed by a plausible grant identifier.  Several
# award-id shapes appear in the wild:
#   CIHR (PJT-178123)      CIHR grant (MOP49566)
#   CIHR [179724]          CIHR grant 10013803
#   CIHR, 201903           CIHR grants PJT-148562, PJT-159693
#   CIHR FRN#123456        CIHR #OF7 B1-PCPEGT 410-10-9633
# We look forward from a CIHR mention up to ~80 chars for a plausible ID.
# Grant-ID shapes seen in CIHR funding statements.  Every form is
# anchored to at least one digit run — a grant ID without digits would
# be indistinguishable from ordinary text ("of Health", "CIHR Institute
# of Nutrition") and was a false-positive source earlier.
_GRANT_ID_FORMS = (
    # Named CIHR programme prefixes + digits: PJT-178123, MOP49566,
    # FDN-000123, OOP-110788, etc. Case-sensitive so "OF" doesn't match
    # the English word "of".
    r"(?-i:PJT|MOP|MSH|FRN|HSI|IGH|INMD|IPPH|IHDCYH|IHSPR|OOP|CPP|HOA|FDN|SOP|PJ)"
    r"[\s#\-:_]*\d{3,8}"
    r"|[A-Z]{2,5}[\-\s]?\d{4,8}"
    r"|\b\d{5,10}\b"
    r"|\[\d{4,10}\]"
)
# Allow up to ~80 non-newline chars between the CIHR mention and the
# grant ID. Papers commonly inject a connecting word or two ("CIHR grant
# (#MOP49566)", "CIHR project grant (PJT-148562)") so a character-only
# separator is too strict.
_CIHR_GRANT_ID_RE = re.compile(
    rf"(?i)(?:CIHR|Canadian\s+Institutes?\s+(?:of|for)\s+Health\s+Research)"
    rf"[^\n]{{0,80}}?(?P<id>{_GRANT_ID_FORMS})"
)


def _sentences(text: str) -> list[tuple[int, int, str]]:
    """Return list of (start, end, sentence)."""
    out = []
    pos = 0
    for p in _SENT_SPLIT.split(text):
        start = text.find(p, pos)
        if start < 0:
            start = pos
        end = start + len(p)
        out.append((start, end, p.strip()))
        pos = end
    return out


def _closest_cihr(sentence: str, anchor_pos: int) -> tuple[int, int] | None:
    """Return (start, end) of the closest CIHR match in `sentence`, or None."""
    best = None
    best_dist = None
    for m in _CIHR_RE.finditer(sentence):
        d = min(abs(m.start() - anchor_pos), abs(m.end() - anchor_pos))
        if best_dist is None or d < best_dist:
            best = (m.start(), m.end())
            best_dist = d
    return best


def _extract_grant_ids(context: str) -> list[str]:
    """Pull plausible grant identifiers from `context` near a CIHR mention."""
    ids = []
    for m in _CIHR_GRANT_ID_RE.finditer(context):
        gid = m.group("id").strip(" ,;[]()")
        # Filter out obvious junk (years, ISBN-like, plain small numbers)
        if re.fullmatch(r"19\d{2}|20[0-3]\d", gid):
            continue
        if gid.lower() in {"cihr", "canadian"}:
            continue
        if gid not in ids:
            ids.append(gid)
    return ids


def _is_in_funding_context(sec_kind: str) -> bool:
    return sec_kind in ("funding", "ack")


def _scan_sentence(sent: str, sec_kind: str) -> dict | None:
    """Return a match dict if this sentence evidences CIHR funding, else None."""
    if not _CIHR_RE.search(sent):
        return None

    # Hard reject in negation contexts.
    if _NEGATION_RE.search(sent):
        return None

    # Hard reject if this looks like an author's personal disclosure — these
    # sentences legitimately name CIHR but not as the study's funder.  We
    # apply this check in *every* section, because declarations-style COI
    # blocks sometimes appear without their own header.
    if _AUTHOR_DISCLOSURE_RE.search(sent):
        return None

    # Pattern 1: explicit "this work was funded by ... CIHR".  Only fires
    # in funding/ack/preamble/other contexts (not COI).  We used to
    # reject subordinate-clause interpretations ("This work was a sub-
    # study of X, which was funded by CIHR") but those are legitimately
    # ambiguous — the parent trial's funding often pays for the sub-
    # study — so we now surface them and let the user decide via the
    # per-row tick boxes whether to include them in the CSV.
    m = _EXPLICIT_FUNDING_RE.search(sent)
    if m and sec_kind not in ("coi", "refs"):
        cihr = _closest_cihr(sent, m.end())
        if cihr is not None and cihr[0] >= m.end() - 5:
            # Flag subordinate-clause matches as medium rather than high
            # confidence, so the confidence badge signals the ambiguity.
            between = sent[m.end():cihr[0]]
            subordinate = bool(
                re.search(r"(?i)\bwhich\s+(?:was|were|is|are)\b", between)
                or re.search(r"(?i)\bsub\s*[\-–]?\s*study\s+of\b", between)
            )
            ids = _extract_grant_ids(sent)
            return {
                "category": "explicit_funding",
                "evidence": sent[m.start(): cihr[1]].strip(),
                "sentence": sent,
                "grant_ids": ids,
                "confidence": "medium" if subordinate else "high",
            }

    # Pattern 2: CIHR adjacent to a grant identifier, inside a funding-ish
    # section.  Good secondary signal when the paper lists funders without
    # writing a full "this work was supported by" sentence.
    if sec_kind in ("funding", "ack"):
        ids = _extract_grant_ids(sent)
        if ids:
            # Additional guard: the sentence must also carry a funding
            # verb (supported / funded / awarded / grant), otherwise we
            # might hit an unrelated parenthetical.
            if re.search(
                r"(?i)\b(support|fund|award|grant|sponsor|financ)",
                sent,
            ):
                return {
                    "category": "grant_id",
                    "evidence": f"CIHR + grant id(s): {', '.join(ids)}",
                    "sentence": sent,
                    "grant_ids": ids,
                    "confidence": "medium",
                }

    # Pattern 3: generic "supported/funded by CIHR" inside a funding
    # context even when the subject isn't explicitly "this work".  Common
    # short-form funding statements look like:
    #   "This work was supported by Canadian Institutes of Health Research, 201903."
    # which Pattern 1 already catches, but also:
    #   "Supported by the Canadian Institutes of Health Research."
    # which doesn't have an explicit subject.
    if sec_kind in ("funding", "ack"):
        if re.search(
            r"(?i)\b(supported|funded|financed|sponsored|made\s+possible)\s+by\b",
            sent,
        ) and _CIHR_RE.search(sent):
            ids = _extract_grant_ids(sent)
            # Subordinate clauses are surfaced but demoted to low confidence
            # (weaker than the medium-bar explicit subject patterns).
            subordinate = bool(
                re.search(r"(?i)\bwhich\s+(?:was|were|is|are)\s+(?:funded|supported)\s+by\b", sent)
            )
            if subordinate:
                conf = "low"
            elif ids:
                conf = "high"
            else:
                conf = "medium"
            return {
                "category": "inline_funding",
                "evidence": "Funding-context sentence names CIHR",
                "sentence": sent,
                "grant_ids": ids,
                "confidence": conf,
            }

    # Pattern 4: funder-list style. Some papers list all funders without
    # a "was supported by" verb — e.g. "Additional funding was received
    # from [list], the Canadian Institutes of Health Research (CIHR)."
    # Only fires in a Funding section, and only when the sentence
    # contains the word "funding" (so we don't accidentally match a
    # discussion of CIHR as a concept).
    if sec_kind == "funding" and re.search(r"(?i)\bfunding\b", sent):
        if re.search(
            r"(?i)\b(received|provided|obtained|came)\b.{0,40}\b(from|by)\b",
            sent,
        ) or re.search(r"(?i)\bfunding\s+(from|by)\b", sent):
            ids = _extract_grant_ids(sent)
            return {
                "category": "inline_funding",
                "evidence": "Funding-section funder list names CIHR",
                "sentence": sent,
                "grant_ids": ids,
                "confidence": "medium",
            }

    return None


def _scan_inline_funding_blocks(md: str, sections: list[tuple[int, int, str, str]]
                                ) -> list[dict]:
    """Scan for '**Funding:**'-style inline labels anywhere in the document
    and treat a short window after the label as a funding context."""
    out = []
    for m in _INLINE_FUNDING_LABEL.finditer(md):
        sec_kind = "other"
        for s, e, _name, kind in sections:
            if s <= m.start() < e:
                sec_kind = kind
                break
        if sec_kind == "coi":
            continue
        block = md[m.start(): min(len(md), m.end() + 1500)]
        for _s, _e, sent in _sentences(block):
            hit = _scan_sentence(sent, "funding")
            if hit is not None:
                hit["section"] = "funding (inline)"
                out.append(hit)
    return out


def extract_cihr_funding(md: str) -> dict:
    md = preprocess(md)
    sections = classify_sections(md)

    found: list[dict] = []
    seen_sentences: set[str] = set()

    for start, end, name, kind in sections:
        if kind in ("refs",):
            continue
        text = md[start:end]
        for _s, _e, sent in _sentences(text):
            hit = _scan_sentence(sent, kind)
            if hit is None:
                continue
            key = hit["sentence"].strip()
            if key in seen_sentences:
                continue
            seen_sentences.add(key)
            hit["section"] = name if kind != "preamble" else "preamble"
            found.append(hit)

    # Pick up short-form funding statements labeled inline (**Funding:**).
    for hit in _scan_inline_funding_blocks(md, sections):
        key = hit["sentence"].strip()
        if key in seen_sentences:
            continue
        seen_sentences.add(key)
        found.append(hit)

    # Overall paper-level confidence: highest match confidence wins.
    rank = {"high": 3, "medium": 2, "low": 1}
    best = max((rank.get(h["confidence"], 0) for h in found), default=0)
    paper_conf = {3: "high", 2: "medium", 1: "low", 0: "none"}[best]

    # Order matches: high > medium > low, then by appearance order.
    found.sort(key=lambda h: -rank.get(h["confidence"], 0))

    return {
        "funded_by_cihr": bool(found),
        "confidence": paper_conf,
        "match_count": len(found),
        "matches": found,
    }


def extract_from_pdf(pdf_path: Path) -> dict:
    if not pdf_path.exists():
        raise FileNotFoundError(pdf_path)
    import pymupdf4llm
    md = pymupdf4llm.to_markdown(str(pdf_path))
    out = extract_cihr_funding(md)
    out["markdown_chars"] = len(md)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path, help="PDF or markdown file")
    args = ap.parse_args()
    if args.path.suffix.lower() == ".md":
        text = args.path.read_text(encoding="utf-8")
        out = extract_cihr_funding(text)
        out["markdown_chars"] = len(text)
    else:
        out = extract_from_pdf(args.path)
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
