# OS_search — Step-by-Step Manual Outline

## 1. Before you start

-   1.1 One-time setup (Python venv, `pymupdf4llm` install)
-   1.2 Launching the app (`Rscript -e 'shiny::runApp("app.R")'`)
-   1.3 First-launch grant-workbook cache (\~30 s)
-   1.4 Optional: set `OS_SEARCH_MAILTO` for the polite pool

## 2. Picking a grant

-   2.1 Choose **Competition fiscal year** (default `202122`, or `All`)
-   2.2 Type/select the **Project Grant number** in the typeahead
-   2.3 Confirm the grant in the **read-only info panel** (PI, institution, funding period, total awarded, title, abstract)

## 3. Running the registry search

-   3.1 Click **Search linked works**
-   3.2 Toggle **Collapse duplicate DOIs across sources** (explain priority order)
-   3.3 What's happening behind the scenes (Crossref, OpenAlex, DataCite, CT.gov, OpenAIRE, Europe PMC)
-   3.4 Expected wait time and how to read the status line

## 4. Reviewing the Summary tab

-   4.1 Three-outcome counts (publications, trials, datasets/OSF, OA-only)
-   4.2 Counts by source — sanity-checking coverage
-   4.3 Downloading the matched-works CSV (file path under `downloads/{grant_id}_{PI_surname}/`)

## 5. Working through the Strict match tab

-   5.1 What "strict" means (award-ID matched at source)
-   5.2 Per-source tables: OpenAlex, Crossref, DataCite, ClinicalTrials.gov
-   5.3 When to trust strict rows without review
-   5.4 Caveats (CT.gov has no grant-ID index; DataCite award numbers are sparse)

## 6. Working through the Fallback match tab

-   6.1 When to use it (young grants, papers that don't cite the award)
-   6.2 Source checkboxes (OpenAlex / Crossref / DataCite / CT.gov / OpenAIRE / Europe PMC)
-   6.3 Match-type filters: `PI + CIHR funder` vs `PI (any)` — noise trade-off
-   6.4 Fiscal-year cutoff rule
-   6.5 Human-review checklist (PI homonyms, co-authorship on other grants)

## 7. PDF extraction workflow (per paper)

-   7.1 Gating rule — must run a search first
-   7.2 Uploading a PDF
-   7.3 Reading the three detector outputs:
    -   7.3.1 **CIHR funding** — `high`/`medium`/`low` confidence, sentence + grant-ID context, why disclosure lines are excluded
    -   7.3.2 **Registration IDs** — registry list, `study_type_hint` meaning
    -   7.3.3 **Data availability** — six outcomes (`deposit_repository` → `none`), repo list
-   7.4 Using the **verify link** for each match
-   7.5 Appending to the CSV: **Add to matched-works CSV** buttons (`pdf_registration` and `pdf_data_deposit` rows)

## 8. Putting it together — a per-grant extraction pass

-   8.1 Suggested order: search → Summary → Strict → Fallback → download CSV → PDF scan top-priority papers → re-download CSV with PDF rows appended
-   8.2 What goes in human-review notes vs. what's authoritative
-   8.3 Moving on to the next grant (state is reset on grant change)

## 9. Troubleshooting

-   9.1 Empty results on a young grant → try Fallback
-   9.2 Transient upstream 502/timeout → retry
-   9.3 PDF scan fails → check `.venv` and `pymupdf4llm`
-   9.4 Where CSVs land and how to clear them

## 10. Appendix

-   10.1 Data-source matching strategies (reference table from ABOUT.md)
-   10.2 Grant-ID normalization rule (`175325_1` → `175325`)
-   10.3 Glossary (strict vs fallback, OA-only, deposit vs unstructured repository)