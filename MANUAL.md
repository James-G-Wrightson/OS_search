# OS_search — Step-by-Step Manual

A practical walk-through for extracting open-science data for a single CIHR Project Grant. Work one grant from top to bottom: pick it, run the registry search, triage the results tabs, download the CSV, scan the papers you care about, then export again.

------------------------------------------------------------------------

## 1. Before you start

### 1.1 One-time setup (Python venv)

The PDF extraction tab shells out to a local Python pipeline. Install the venv once:

``` sh
python3 -m venv .venv
.venv/bin/pip install pymupdf4llm
```

Takes \~30 s. No network calls at scan time, no LLM — the detectors are rule-based.

### 1.2 Launching the app

From the project root:

``` sh
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

Wait for `Listening on http://127.0.0.1:<port>` before opening the browser (the launcher opens it automatically).

### 1.3 First-launch grant cache

The first launch parses the CIHR Project Grant workbooks and caches them to `cache/project_grants.rds`. This takes \~30 s. Subsequent launches load in under a second.

### 1.4 Optional: polite-pool email

Crossref and OpenAlex use their "polite pool" (higher rate limits, better reliability) when a contact email is supplied. To override the default:

``` sh
export OS_SEARCH_MAILTO='you@example.org'
```

Then relaunch the app.

------------------------------------------------------------------------

## 2. Picking a grant

All controls are in the left sidebar.

### 2.1 Choose a Competition fiscal year

The **Competition fiscal year** dropdown defaults to `202122`. Change it to another FY, or to `All` to search across every year loaded from the workbooks.

The grant picker below is filtered by this selection: if FY is `202122` you only see 2021–22 grants; if FY is `All` you see every grant.

### 2.2 Select the Project Grant number

Two ways:

-   **Project Grant number** typeahead — start typing an award ID and pick from the matches scoped to the chosen fiscal year.
-   **Find grant by number (across all FYs)** — if you know the number but don't know the FY, use this field instead; it ignores the FY filter.

### 2.3 Confirm the grant

The read-only info panel (sidebar, below the picker) shows:

-   PI name
-   Fiscal year
-   Institution
-   Funding period
-   Total awarded
-   Grant title
-   Abstract (click to expand)

If any of these look wrong, you've picked the wrong record — re-check the number before searching.

------------------------------------------------------------------------

## 3. Running the registry search

### 3.1 Click **Search linked works**

A status line appears:

> Querying Crossref, OpenAlex (author + ORCID), DataCite (PI + ORCID), ClinicalTrials.gov (keyword + PI), OpenAIRE, Europe PMC (grant + PI)...

The search hits six upstream APIs in parallel and typically takes 10–45 s (longer on cold starts or if an upstream is slow).

### 3.2 Choose whether to collapse duplicate DOIs

The **Collapse duplicate DOIs across sources** checkbox is **off** by default. Turn it on if you want each DOI shown only once, in the row from the highest-priority source. Priority order:

> OpenAlex → Europe PMC → Crossref → DataCite → OpenAIRE

The kept row gains an `also_in` column listing the other sources that saw the same DOI. ClinicalTrials.gov rows have no DOI and are left untouched. The setting applies to both the Strict and Fallback tabs and to the downloadable CSV.

You can toggle this any time after the search completes — no need to re-run.

### 3.3 What's happening behind the scenes

| Source | Strict query | Fallback query |
|------------------------|------------------------|------------------------|
| **Crossref** | `funder=10.13039/501100000024` + `award.number=<id>` | `funder` + `query.author=<PI>` |
| **OpenAlex** | `awards.funder_id=F4320334506` + `awards.funder_award_id=<id>` | `author.id` + `awards.funder_id` |
| **DataCite** | Three-form funder union + `awardNumber:<id>`; plus related-identifier backchain off strict paper DOIs | Three-form funder union + `creators.name`/`contributors.name:<PI>` |
| **ClinicalTrials.gov** | Award number in any field (rarely indexed) | `query.lead=<PI>` ∪ `query.spons=(CIHR, Canadian Institutes of Health Research)` |
| **OpenAIRE** | — | PI + `funder=cihr` (limited CIHR coverage) |
| **Europe PMC** | `GRANT_ID:<id> AND GRANT_AGENCY:("CIHR" OR "Canadian Institutes of Health Research")` | `AUTH:<PI>` + same funder clause |

CIHR IDs like `175325_1` are stripped to the bare number (`175325`) before hitting Crossref and OpenAlex.

------------------------------------------------------------------------

## 4. Reviewing the Summary tab

The **Summary** tab lands first after a search.

### 4.1 Three-outcome counts

At the top of the tab you'll see counts for:

-   **Publications** (journal articles, preprints)
-   **Trials** (ClinicalTrials.gov registrations)
-   **Datasets / OSF** (DataCite records, OSF registrations)
-   **OA-only** (open-access publications, separate count)

Treat these as a first-pass sanity check: zero publications on a grant that's been running four years is a red flag; zero trials on a non-clinical trial grant is expected.

### 4.2 Counts by source

A second table breaks the totals down per source. Use this to spot coverage gaps — e.g. if Europe PMC has 12 matches but OpenAlex has 2, you've likely got a grant-ID indexing mismatch worth investigating on the Strict tab.

### 4.3 Downloading the matched-works CSV

The download button writes:

```         
downloads/{grant_id}_{PI_surname}/cihr_{grant_id}_linked_works.csv
```

relative to the app's working directory. The file includes every matched row (strict + fallback, across all sources) with source, match type, DOI/IDs, title, year, and PI linkage columns.

You'll come back to this button in **§7** after adding PDF-derived rows.

------------------------------------------------------------------------

## 5. Working through the Strict match tab

Tab title: **Strict match (grant ID + funder)**.

### 5.1 What "strict" means

The source itself confirmed the funder-plus-award-ID pair. These rows don't require manual review — the grant linkage is asserted by the registry.

### 5.2 Per-source tables

Four separate tables: **OpenAlex**, **Crossref**, **DataCite**, **ClinicalTrials.gov**. Europe PMC strict hits are folded into the publications view; DataCite includes the related-identifier backchain (datasets cited by strict-matched papers, even when the dataset itself doesn't self-report CIHR funding).

### 5.3 When to trust strict rows without review

Almost always. The common exceptions:

-   A paper strictly matched in OpenAlex but missing from Crossref → usually fine, it's a metadata-propagation lag.
-   A DataCite record with no award number but picked up via the backchain → the link is legitimate but indirect; note it in your review.

### 5.4 Caveats

-   **ClinicalTrials.gov** does not index grant numbers as a searchable field. Strict hits here are rare; most trials come in via the Fallback tab.
-   **DataCite** rarely has `awardNumber` populated; most dataset matches are fallback or backchained.

------------------------------------------------------------------------

## 6. Working through the Fallback match tab

Tab title: **Fallback match (PI / ORCID / keywords)**.

### 6.1 When to use it

-   Young grants (funded 2021) where papers haven't been published or indexed yet.
-   Papers that fail to cite the award ID.
-   Datasets and trials (which rarely carry award numbers at the registry level).

Fallback rows are suggestions — treat them as candidates to review, not truth.

### 6.2 Source checkboxes

Filter the single combined table by source: OpenAlex, Crossref, DataCite, ClinicalTrials.gov, OpenAIRE, Europe PMC. All checked by default.

### 6.3 Match-type filters

Two checkboxes, both on by default:

-   **PI + CIHR funder** — the PI is named and the source applied a CIHR funder/sponsor filter. Narrower, cleaner.
-   **PI (any)** — the PI is named with no funder filter. Broadest and noisiest; use when the funder-filtered view returns nothing.

Uncheck **PI (any)** first if the table is overwhelming.

### 6.4 Fiscal-year cutoff

All fallback rows are restricted to the grant's competition fiscal year or later. Papers published before the grant started are excluded automatically.

### 6.5 Human-review checklist

For every fallback row you intend to keep:

-   [ ] Is this really the same PI? (Check homonyms — `J Smith` matches hundreds of people.)
-   [ ] Is the work in the grant's scope / discipline?
-   [ ] Is the publication date consistent with the funding period?
-   [ ] If ORCID is available, does it match?
-   [ ] Could the PI be co-authoring on a different grant?

------------------------------------------------------------------------

## 7. PDF extraction workflow (per paper)

Tab title: **PDF extraction**. This tab is a per-PDF tool — one paper at a time.

### 7.1 Gating: run a search first

If you haven't run a search, the tab shows:

> **Run a grant search first** — Pick a grant in the sidebar and press **Search linked works** before using the PDF registration scanner.

If the Python venv can't be found, you'll instead see **PDF pipeline unavailable** — re-run the setup in §1.1.

### 7.2 Upload the PDF

Use the **PDF file** input to upload a single paper. Then click **Scan paper**.

The status line reads:

> Extracting text and scanning for registrations + data deposits (local, no network)...

Scans take 3–15 s depending on page count. When done:

> Scanned *N* characters of extracted text.

### 7.3 Reading the detector outputs

Three independent detectors run on every scan.

#### 7.3.1 CIHR funding

Answers: *does this paper declare CIHR as a funder of this study?*

-   **Confidence**: `high` / `medium` / `low`
-   **Grant IDs**: any CIHR numbers found near the funding sentence
-   **Sentence**: the surrounding text that triggered the match

Detection is scoped to Funding / Acknowledgments / inline `**Funding:**` blocks. Competing-interest and author-disclosure sentences ("reports receiving grants from CIHR") are explicitly excluded, so a paper that only mentions a past author grant will *not* be flagged.

#### 7.3.2 Registration IDs

Clinical-trial and systematic-review registry identifiers: NCT, ISRCTN, EudraCT, ACTRN, ChiCTR, DRKS, UMIN, jRCT, CTRI, IRCT, PACTR, KCT, ReBec, NTR, WHO UTN, PROSPERO/CRD, INPLASY, OSF, Research Registry.

Each match includes a `study_type_hint`:

-   `trial` — clinical-trial registries
-   `systematic_review` — PROSPERO, INPLASY, etc.
-   `mixed` — registry used for both
-   `unknown` — registry ambiguous on type

#### 7.3.3 Data availability

Repository deposits and data-availability statements. Every paper is classified into one of six outcomes:

-   `deposit_repository` — accession ID in a named repo (GEO `GSE12345`, SRA `SRPnnn`, etc.)
-   `unstructured_repository` — repo named, no accession
-   `on_request` — "available from the authors on reasonable request"
-   `no_new_data` — explicitly declares no new data generated
-   `restricted_access` — deposit exists but is controlled (dbGaP, EGA)
-   `none` — nothing found

Repositories covered include GEO, SRA, BioProject/BioSample, ArrayExpress, BioStudies, PRIDE, MassIVE, MetaboLights, dbGaP, EGA, RefSeq, Assembly, ClinVar, ChEMBL, EMPIAR, EMDB, PDB, UniProt, OpenNeuro, Synapse, GenBank, Zenodo, Figshare, Dryad, Harvard Dataverse, Mendeley Data, Hugging Face datasets, GitHub.

### 7.4 Verify each match

Every detected item shows the surrounding sentence and a **verify link** (opens the registry / repository landing page for that ID). Open the link before trusting the row — regex false positives are rare but happen, especially on short IDs near unrelated numbers.

### 7.5 Append detections to the CSV

Three buttons at the bottom of the PDF tab let you queue detections onto the current grant's CSV download:

-   **Add ticked CIHR-funding rows to matched-works CSV**
-   **Add ticked registration row(s) to matched-works CSV**
-   **Add ticked data-deposit rows to matched-works CSV**

Each button appends only the rows you've ticked in its own table. Confirmation looks like:

> Added *N* registration row(s) to this grant's CSV download.

The CSV buffer persists for the current grant. A running tally is shown:

> *N* PDF-sourced row(s) queued for this grant's CSV.

Re-download the CSV from the **Summary** tab to get the updated file. PDF rows carry distinct `source` values (`pdf_registration`, `pdf_data_deposit`, `pdf_cihr_funding`) alongside section, sentence, anchor phrase, and confidence columns.

------------------------------------------------------------------------

## 8. Putting it together — a per-grant extraction pass

A suggested working order for one grant, start to finish:

1.  **Pick** the grant (§2). Confirm the info panel.
2.  **Search** (§3). Wait for the spinner to finish.
3.  **Summary** (§4). Eyeball the three-outcome counts. If zero, consider whether the grant is too young.
4.  **Strict** (§5). Copy obvious publications/trials/datasets into your review list.
5.  **Fallback** (§6). Tick through the rows; reject homonym matches; promote the rest.
6.  **Download CSV** (§4.3). This is your baseline export.
7.  **PDF scan** (§7) the highest-value papers — anything CIHR-flagged in Strict, anything with likely trial/dataset output.
8.  **Append** detections with the three "Add ticked ... to matched-works CSV" buttons.
9.  **Re-download CSV** — the file now includes the PDF-sourced rows.
10. **Notes** — keep Fallback judgment calls in a review column alongside the CSV; they're not authoritative the way Strict rows are.

### Authority levels at a glance

| Row source | Authority |
|------------------------------------|------------------------------------|
| Strict match (any registry) | Authoritative |
| DataCite related-identifier backchain | Near-authoritative (link is indirect) |
| PDF CIHR-funding detector, `high` confidence | Authoritative |
| PDF CIHR-funding detector, `medium` / `low` | Needs human review |
| PDF registration detector | Authoritative after verify-link check |
| PDF data-availability detector | Authoritative after verify-link check |
| Fallback match | Candidate — requires review |

### Moving on to the next grant

Changing the grant picker resets the CSV buffer, the PDF scan panel, and the results tabs. Make sure you've downloaded the CSV for the current grant before switching.

------------------------------------------------------------------------

## 9. Troubleshooting

### 9.1 Empty results on a young grant

2021-funded grants may have no indexed publications yet. Try:

-   Switch to **Fallback** and uncheck **PI + CIHR funder** — keep only **PI (any)**.
-   Look specifically at Europe PMC (fastest grant-linkage indexing of the six).
-   If still empty, note the grant as "no outputs found yet" and move on.

### 9.2 Transient upstream 502 / timeout

Upstream APIs occasionally 502 or time out. Re-run the search once. If it fails again on the same source, note the source as unavailable and proceed with the rest — don't block the whole grant on one flaky upstream.

### 9.3 PDF scan fails

If you see **PDF pipeline unavailable**:

-   Check `.venv/` exists at the project root.
-   Check `.venv/bin/pip show pymupdf4llm` returns metadata.
-   Re-run the one-off install from §1.1.

If the scan starts but returns no matches on a paper you're certain should match, check the "Scanned *N* characters" count — a very low *N* (say, under 5 000) means the PDF is an image-only scan and needs OCR first.

### 9.4 Where CSVs land and how to clear them

CSVs accumulate under `downloads/{grant_id}_{PI_surname}/`. Each new download for the same grant overwrites the previous file. To clear everything:

``` sh
rm -rf downloads/
```

The folder is recreated on the next download.

------------------------------------------------------------------------

## 10. Appendix

### 10.1 Data-source matching strategies

See the table in §3.3 above, and the **About** tab inside the app for the most up-to-date version (driven from [ABOUT.md](ABOUT.md)).

### 10.2 Grant-ID normalization

CIHR `FundingReferenceNumber` values like `175325_1` are stripped to the bare application number (`175325`) before being used as `award.number` on Crossref and `funder_award_id` on OpenAlex. `PJT-` prefixes are not queried — the APIs don't index them consistently. You can enter either form in the grant picker; normalization happens internally.

### 10.3 Glossary

-   **Strict match** — Registry itself asserts the funder-plus-award-ID pair.
-   **Fallback match** — Author / ORCID / funder heuristic; candidate for review.
-   **OA-only** — Open-access publication count, surfaced separately in Summary.
-   **Deposit repository** — Named repository with an accession ID in the paper.
-   **Unstructured repository** — Named repository, no accession ID given.
-   **Related-identifier backchain** — DataCite query that finds datasets *cited by* strictly matched papers, even when the dataset record doesn't self-report CIHR funding.
-   **Polite pool** — Higher-priority API queue on Crossref / OpenAlex, accessed by supplying a contact email.