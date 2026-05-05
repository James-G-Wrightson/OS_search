## OS_search prototype

Interactive explorer for open-science outputs of CIHR Project Grants.

The app does two things:

1.  **Search** — query a curated set of registries and aggregators for publications, trials, datasets and other works linked to a chosen Project Grant. Results are split into a strict (grant-ID matched) and a fallback (PI / ORCID / keyword matched) view, plus a downloadable matched-works CSV. As part of the search, every accessible OA PDF for strict matches and for fallback matches above the similarity threshold is auto-downloaded into per-grant folders on disk (see **Auto-download** below).
2.  **PDF extraction** (folder-scan, gated on a completed grant search). Two batch-scan tabs (**Strict PDFs**, **Fallback PDFs**) scan every PDF in `strict_papers/` / `fallback_papers/` for the selected grant and run three rule-based detectors:
    -   **CIHR funding** — does the paper declare CIHR (or the Canadian Institutes of Health Research) as a funder of this study? Detection is scoped to Funding / Acknowledgments / inline `**Funding:**` blocks; Competing-interest and author-disclosure sentences are explicitly excluded so a paper that only mentions past author grants isn't flagged. Each match includes the surrounding sentence, confidence (`high` / `medium` / `low`), and any CIHR grant IDs detected nearby. On the Fallback PDFs tab this feeds the per-PDF "Current grant in PDF" table — one row per scanned PDF, flagged true when the current grant's bare CIHR award number appears in the extracted CIHR grant IDs.
    -   Clinical-trial / systematic-review **registration identifiers** — NCT, ISRCTN, EudraCT, ACTRN, ChiCTR, DRKS, UMIN, jRCT, CTRI, IRCT, PACTR, KCT, ReBec, NTR, WHO UTN, PROSPERO/CRD, INPLASY, OSF, Research Registry. Each match carries a `study_type_hint` (`trial`, `systematic_review`, `mixed`, `unknown`).
    -   **Data-availability statements / public repository deposits** — GEO, SRA, BioProject, BioSample, ArrayExpress, BioStudies, PRIDE, MassIVE, MetaboLights, dbGaP, EGA, RefSeq, Assembly, ClinVar, ChEMBL, EMPIAR, EMDB, PDB, UniProt, OpenNeuro, Synapse, GenBank, Zenodo, Figshare, Dryad, Harvard Dataverse, Mendeley Data, Hugging Face datasets, GitHub. The detector classifies each paper into one of six outcomes: `deposit_repository`, `unstructured_repository` (repo named, no accession), `on_request`, `no_new_data`, `restricted_access`, or `none`.

    Each detected item shows the surrounding sentence and a verify link. Per-tab **Add ticked … to CSV** buttons append detections to the grant's CSV download — registrations as `{strict|fallback}_pdf_registration` rows, deposits as `{strict|fallback}_pdf_data_deposit` rows, and per-PDF grant-ID hits (Fallback only) as `fallback_pdf_grant_match` rows. Section, sentence, anchor phrase and confidence columns are preserved. PDF rows with a `linked_doi` are merged onto the source paper's existing CSV row so each paper appears once.

### Auto-download

On every search, the app builds two download sets and fetches both in parallel before the Summary tab opens:

-   **Strict set** — every strict-table row that has an `oa_pdf_url` (from OpenAlex `best_oa_location.pdf_url` or Europe PMC `fullTextUrlList`). Saved to `downloads/{grant_id}_{PI_surname}/strict_papers/<doi>.pdf`.
-   **Fallback set** — fallback rows with an OA URL whose BM25 similarity strictly exceeds `AUTO_DL_FB_THRESHOLD` (0.19), capped at `AUTO_DL_CAP` (50) per grant to bound the worst case for prolific PIs. Saved to `…/fallback_papers/<doi>.pdf`.

Filenames are derived from the row's DOI (path-unsafe characters replaced with `_`); `match_doi_from_filename()` recovers the DOI from any PDF dropped into the folder later. Each fetch validates by HTTP status, response size *and* `%PDF-` magic bytes — publishers commonly serve "you are blocked" HTML with `Content-Type: application/pdf`, so magic-bytes is the load-bearing check. Failed fetches don't crash the search; their rows surface in the per-tab "manual download needed" panel.

### Dedup, manual-download reconciliation, strict→fallback subtraction

The Strict PDFs and Fallback PDFs tabs apply three quiet bits of cleanup so the user only sees actionable rows:

-   **Within-table dedup.** Registration tables are deduped by `(registry, id)`; data-availability tables by `(repository, accession)`. First occurrence wins (case-insensitive, whitespace-trimmed). One PDF citing the same NCT or GEO accession ten times shows up once.
-   **Manual-download reconciliation.** The "XX PDFs need manual download" panel re-renders whenever the folder is re-scanned, and reconciles each failed-download row against PDFs actually on disk: a row is treated as resolved when its expected destination path exists, *or* when any PDF in the folder has the row's DOI as a substring of its filename (so a manually-saved file named anything containing the DOI clears the row). Drives the failed-vs-succeeded counter shown in the panel.
-   **Strict→Fallback subtraction.** After dedup, the Fallback PDFs tab drops any registration `id` already shown on the Strict PDFs tab and any data-availability `accession` already shown there. The fallback tab only surfaces *new* findings, so the same NCT or GEO accession can't enter the CSV from both directions.

### Fallback PDFs gating

Unlike Strict PDFs (which shows every finding from every scanned PDF), the Fallback PDFs tab is gated on an explicit per-PDF selection. The first table — **Current grant in PDF** — has one row per scanned fallback PDF, pre-ticked when the current grant's CIHR ID was found in the PDF text. The Registrations and Data-availability tables below it are filtered to *only* the PDFs ticked in that first table. With nothing ticked, both downstream tables are empty; this stops random PDFs from a homonymous PI's other grants from polluting the fallback-derived CSV rows.

### UI layout

Sidebar:

-   **Competition fiscal year** selector (default `202122`, or `All`) — filters the grant picker.
-   **Project Grant number** typeahead.
-   **Search linked works** action button.
-   **Collapse duplicate DOIs across sources** checkbox — when on, each DOI is shown only once, in the row from the highest-priority source. Priority order: OpenAlex → Europe PMC → Crossref → DataCite → OpenAIRE (ClinicalTrials.gov has no DOIs and is untouched). The kept row gains an `also_in` column listing the other sources that had the same DOI. Applies to both Strict and Fallback tabs and to the downloadable CSV.
-   Read-only **grant info panel**: PI, fiscal year, institution, funding period, total awarded, title, expandable abstract.

Tabs:

-   **Summary** — three-outcome counts (publications, trials, datasets/OSF, OA-only), counts by source, and the matched-works CSV download.
-   **Strict match** — separate tables for OpenAlex, Europe PMC, Crossref, DataCite, ClinicalTrials.gov. Every row pre-ticked; ticking only filters the CSV.
-   **Fallback match** — one combined table with source (OpenAlex / Crossref / DataCite / ClinicalTrials.gov / OpenAIRE / Europe PMC) and match-type checkbox filters: `PI + CIHR funder` (author plus a CIHR funder/sponsor filter at the source) and `PI (any)` (author only, no funder filter — the broadest and noisiest view). All rows are filtered to the grant's competition fiscal year or later. Each row carries a **similarity** badge — a per-grant BM25 score (grant keywords vs item title + abstract, normalised to 0–1) banded as `≥0.6` high (green), `0.2–0.6` plausible (amber), `<0.2` off-topic (grey), `—` when the grant has no usable keywords or the BM25 score has no signal. Default sort is by source priority (OpenAlex → Europe PMC → Crossref → DataCite → OpenAIRE → CT.gov), then by similarity descending within each source. Rows above the auto-download threshold (`AUTO_DL_FB_THRESHOLD`, 0.19) are pre-ticked; lower-similarity rows are unticked. Abstracts are pulled only from OpenAlex (`abstract_inverted_index` reconstruction) and Europe PMC (`abstractText`); items from other sources or without an abstract are scored on title alone, which BM25's length normalisation handles gracefully.
-   **Strict PDFs** — batch-scans `strict_papers/` for the selected grant. Manual-download panel at the top (rows whose auto-download failed); deduped Registrations and Data-availability tables below. Add-to-CSV buttons append ticked rows to the grant's CSV.
-   **Fallback PDFs** — batch-scans `fallback_papers/`. Top table: **Current grant in PDF** (one row per scanned PDF; pre-ticked when the grant's CIHR ID is in the text). Registrations and Data-availability tables below are filtered to the PDFs ticked there, deduped, and have any IDs / accessions already shown on the Strict PDFs tab subtracted.
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
R/api_clients.R       Crossref / OpenAlex / DataCite / CT.gov / OpenAIRE /
                      Europe PMC clients + summarise_outcomes()
R/pdf_convert.R       Wraps the py/ helpers via system2(); JSON → tibble.
                      Includes match_doi_from_filename() for linking
                      saved PDFs back to source paper rows.
R/pdf_download.R      Auto-download client: validates by HTTP status +
                      magic bytes (%PDF-); idempotent re-runs.
R/similarity.R        BM25 similarity score for fallback-tab rows
                      (grant.keywords vs item.title+abstract)
py/                   Local PDF pipeline (see above)
cache/                project_grants.rds (parsed workbooks)
downloads/            Per-grant folders: {grant_id}_{PI_surname}/
                        ├── strict_papers/        auto-downloaded strict PDFs
                        ├── fallback_papers/      auto-downloaded fallback PDFs
                        └── cihr_{grant_id}_linked_works.csv
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
