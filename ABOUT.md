## OS_search prototype

Interactive explorer for open-science outputs of CIHR Project Grants.

The app does two things:

1.  **Search** — query a curated set of registries and aggregators for publications, trials, datasets and other works linked to a chosen Project Grant. Results are split into a strict (grant-ID matched) and a fallback (PI / ORCID / keyword matched) view, plus a downloadable matched-works CSV.
2.  **PDF extraction** (per-PDF tool, gated on a completed grant search). Upload a research paper PDF for the selected grant; the app converts it to markdown locally and runs three rule-based detectors:
    -   **CIHR funding** — does the paper declare CIHR (or the Canadian Institutes of Health Research) as a funder of this study? Detection is scoped to Funding / Acknowledgments / inline `**Funding:**` blocks; Competing-interest and author-disclosure sentences are explicitly excluded so a paper that only mentions past author grants isn't flagged. Each match includes the surrounding sentence, confidence (`high` / `medium` / `low`), and any CIHR grant IDs detected nearby.
    -   Clinical-trial / systematic-review **registration identifiers** — NCT, ISRCTN, EudraCT, ACTRN, ChiCTR, DRKS, UMIN, jRCT, CTRI, IRCT, PACTR, KCT, ReBec, NTR, WHO UTN, PROSPERO/CRD, INPLASY, OSF, Research Registry. Each match carries a `study_type_hint` (`trial`, `systematic_review`, `mixed`, `unknown`).
    -   **Data-availability statements / public repository deposits** — GEO, SRA, BioProject, BioSample, ArrayExpress, BioStudies, PRIDE, MassIVE, MetaboLights, dbGaP, EGA, RefSeq, Assembly, ClinVar, ChEMBL, EMPIAR, EMDB, PDB, UniProt, OpenNeuro, Synapse, GenBank, Zenodo, Figshare, Dryad, Harvard Dataverse, Mendeley Data, Hugging Face datasets, GitHub. The detector classifies each paper into one of six outcomes: `deposit_repository`, `unstructured_repository` (repo named, no accession), `on_request`, `no_new_data`, `restricted_access`, or `none`.

    Each detected item shows the surrounding sentence and a verify link. Two separate **Add to matched-works CSV** buttons append detections to the grant's CSV download — registrations as `pdf_registration` rows and deposits as `pdf_data_deposit` rows, with section, sentence, anchor phrase and confidence columns preserved.

### UI layout

Sidebar:

-   **Competition fiscal year** selector (default `202122`, or `All`) — filters the grant picker.
-   **Project Grant number** typeahead.
-   **Search linked works** action button.
-   **Collapse duplicate DOIs across sources** checkbox — when on, each DOI is shown only once, in the row from the highest-priority source. Priority order: OpenAlex → Europe PMC → Crossref → DataCite → OpenAIRE (ClinicalTrials.gov has no DOIs and is untouched). The kept row gains an `also_in` column listing the other sources that had the same DOI. Applies to both Strict and Fallback tabs and to the downloadable CSV.
-   Read-only **grant info panel**: PI, fiscal year, institution, funding period, total awarded, title, expandable abstract.

Tabs:

-   **Summary** — three-outcome counts (publications, trials, datasets/OSF, OA-only), counts by source, and the matched-works CSV download.
-   **Strict match** — separate tables for OpenAlex, Crossref, DataCite, ClinicalTrials.gov.
-   **Fallback match** — one combined table with source (OpenAlex / Crossref / DataCite / ClinicalTrials.gov / OpenAIRE / Europe PMC) and match-type checkbox filters: `PI + CIHR funder` (author plus a CIHR funder/sponsor filter at the source) and `PI (any)` (author only, no funder filter — the broadest and noisiest view). All rows are filtered to the grant's competition fiscal year or later. Each row carries a **similarity** badge — a per-grant BM25 score (grant keywords vs item title + abstract, normalised to 0–1) banded as `≥0.6` high (green), `0.2–0.6` plausible (amber), `<0.2` off-topic (grey), `—` when the grant has no usable keywords or the BM25 score has no signal. Default sort is by source priority (OpenAlex → Europe PMC → Crossref → DataCite → OpenAIRE → CT.gov), then by similarity descending within each source. Abstracts are pulled only from OpenAlex (`abstract_inverted_index` reconstruction) and Europe PMC (`abstractText`); items from other sources or without an abstract are scored on title alone, which BM25's length normalisation handles gracefully.
-   **PDF extraction** — PDF upload + scan (gated on having run a search).
-   **About** — this file.

### Data sources queried

| Source | What it gives you | Matching strategy |
|------------------------|------------------------|------------------------|
| **Crossref** | Publications (DOI, metadata) | `funder=<CIHR-family DOI>` (OR of parent `10.13039/501100000024` + 20 institute/programme Funder DOIs — see `CIHR_CROSSREF_FUNDER_DOIS`) + `award.number=<id>` (strict); same funder clause + `query.author=<PI>` (fallback) |
| **OpenAlex** | Publications with OA status | `awards.funder_id=F1\|F2\|...` (parent `F4320334506` + 19 institute/programme funder IDs — see `CIHR_OPENALEX_FUNDER_IDS`) + `awards.funder_award_id=<id>` (strict); `author.id` + same funder union (fallback) |
| **DataCite** | Datasets, preprints, OSF registrations | Three-form funder union (strict + fallback): `fundingReferences.funderIdentifier` across all CIHR-family Funder DOIs, the CIHR ROR (`https://ror.org/01gavpb45`), or `fundingReferences.funderName` across all CIHR / institute names — deposited populations differ (ROR ~293 records, Funder DOI ~98, name-only catches the rest). Strict adds `awardNumber:<id>`; fallback adds `creators.name`/`contributors.name:<PI>`. **Plus a related-identifier backchain**: for each paper DOI already strictly matched in OpenAlex/Crossref/Europe PMC, query `relatedIdentifiers.relatedIdentifier:"<paper_doi>"` to surface datasets/supplements that don't self-report CIHR funding but are cited by a CIHR-funded paper. |
| **ClinicalTrials.gov** | Trial registrations | award number in any field (strict); `query.lead=<PI>` unioned across both `query.spons="Canadian Institutes of Health Research"` and `query.spons="CIHR"` (fallback; acronym picks up ~2.7% more records the full name misses) |
| **OpenAIRE** | European aggregator | PI + `funder=cihr` (OpenAIRE does not index CIHR projects well; coverage is limited) |
| **Europe PMC** | PubMed/PMC publications with grant-linkage metadata | `GRANT_ID:<id> AND GRANT_AGENCY:(<CIHR-family names>)` (strict, 23-name OR clause including the 13 thematic institutes); `AUTH:<PI>` + same funder clause (fallback). Replicates what the [Grant Finder](https://europepmc.org/grantfinder) web UI shows on a grant's detail page. |

### How grant IDs are matched

A CIHR `FundingReferenceNumber` like `175325_1` is stripped to the bare app number (`175325`). Depositors send this to the APIs in two forms — bare (`175325`) or prefixed (`PJT-175325`) — and usage varies by era: pre-2020 Project Grant papers are mostly prefixed, 2021+ records are mixed. Each strict query is therefore issued twice, once per form, and the results are unioned; a post-filter keeps only records whose CIHR-tagged award, stripped of prefix/surrounding non-digits, equals the bare number.

**Funder identity — parent vs institutes.** CIHR is structured as a parent organisation with 13 thematic institutes (`Institute of Circulatory and Respiratory Health`, `Institute of Cancer Research`, etc.) and several programmatic initiatives (Clinical Trials Fund, SPOR, HIV/AIDS, AMR, Healthy Cities). Each has its own Crossref Funder DOI and OpenAlex funder ID. Publishers forward Crossref one or the other (or neither) with no consistency — e.g. the ARTESiA trial in NEJM is tagged only to `Institute of Circulatory and Respiratory Health` with no parent-CIHR entry. Filtering on just the parent DOI therefore misses a slice of CIHR-funded output. Every CIHR-funder filter in `R/api_clients.R` ORs the full set (parent + 20 descendants) — see `CIHR_CROSSREF_FUNDER_DOIS`, `CIHR_OPENALEX_FUNDER_IDS`, `CIHR_FUNDER_NAMES`.

### Notes / caveats

-   **Young grants** (funded 2021) may not yet have publications, or papers may not cite the award ID. The fallback tab is designed for this case.
-   **ClinicalTrials.gov** does not index grant numbers as searchable fields, so trials are found mainly via the PI + sponsor filter.
-   **DataCite** rarely has award numbers populated; most datasets are found via PI name + funder, or via the related-identifier backchain off strict paper matches.
-   The strict column is authoritative; the fallback column is a suggestion that requires human review (PI homonyms, co-authorship on other grants, etc).

### API keys

-   **Crossref / OpenAlex**: no key required. Both use the "polite pool" when a `mailto` is supplied. Set `OS_SEARCH_MAILTO` env var to override the default.
-   **DataCite, ClinicalTrials.gov**: no key required.
-   **OpenAIRE**: the free public tier is used. For higher rate limits, register at <https://aai.openaire.eu/registry/> and export `OPENAIRE_TOKEN=...` (not yet wired into this prototype).

### Local PDF pipeline

The PDF extraction tab calls Python helpers in [`py/`](py/) via `system2()`. Extraction is fully local (no LLM, no network):

-   [`py/pdf_to_md.py`](py/pdf_to_md.py) — converts PDF to markdown using `pymupdf4llm` (rule-based PyMuPDF wrapper).
-   [`py/extract_cihr_funding.py`](py/extract_cihr_funding.py) — section-scoped CIHR funder detector. Parses the markdown into sections (Funding / Acknowledgments / Competing-interests / References / other), runs funded-by patterns only in funding-context sections, and rejects sentences that look like author disclosures ("reports receiving grants from CIHR") or subordinate-clause references ("sub-study of X, which was funded by CIHR"). Also handles papers that use inline `**Funding:**` or `**ACKNOWLEDGMENTS.**` boldface markers instead of proper headings. Validated on a 16-paper test set (10 CIHR-funded, 6 not) under [`test_pdfs/`](test_pdfs/) with 0 false positives and 0 false negatives.
-   [`py/extract_registrations.py`](py/extract_registrations.py) — vetted regex corpus for trial / review registry IDs, adapted from [maia-sh/ctregistries](https://github.com/maia-sh/ctregistries) and CrossRef's clinical-trials importer. Section-aware (skips References), with PDF-spacing repair and high-confidence anchor-phrase boost.
-   [`py/extract_data_availability.py`](py/extract_data_availability.py) — repository-deposit detector adapted from [ODDPub](https://github.com/quest-bih/oddpub) (Riedel 2020). Two-pass design: locate the data-availability section via heading regex, then sweep the whole body for accessions / data DOIs / repo URLs. High-FP patterns (PDB, UniProt, GenBank, GitHub) are gated on context keywords.
-   [`py/scan_paper.py`](py/scan_paper.py) — combined entry point: one PDF→markdown call, all three detectors run, single JSON returned to R.

### Project layout

```
app.R                 Shiny UI + server (single file)
R/data_loader.R       Parses CIHR Project Grant workbooks, caches to RDS
R/api_clients.R       Crossref / OpenAlex / DataCite / CT.gov / OpenAIRE clients
                      + summarise_outcomes() for the three-outcome summary
R/pdf_convert.R       Wraps the py/ helpers via system2(); JSON → tibble
R/similarity.R        BM25 similarity score for fallback-tab rows
                      (grant.keywords vs item.title+abstract)
py/                   Local PDF pipeline (see above)
cache/                project_grants.rds (parsed workbooks)
```

### Running

First-time setup of the local Python venv (one-off, \~30 s):

``` sh
python3 -m venv .venv
.venv/bin/pip install pymupdf4llm
```

Then launch the app:

``` sh
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

On first launch, the Excel files are parsed and cached to `cache/project_grants.rds` (takes \~30 s). Subsequent launches load in under a second.
