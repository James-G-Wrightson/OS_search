# OS_search

Interactive Shiny app that surfaces open-science outputs of CIHR Project Grants. Pick a grant, query six registries (Crossref, OpenAlex, DataCite, ClinicalTrials.gov, OpenAIRE, Europe PMC) for linked publications, trials, datasets and preprints, and run a fully-local PDF scanner that extracts CIHR funding declarations, trial / systematic-review registration IDs, and data-availability statements.

```
┌────────────────┐   ┌──────────────────┐   ┌────────────────┐
│  Grant picker  │──▶│  6 registries    │──▶│  Matched-works │
│  (CIHR xlsx)   │   │  strict +        │   │  CSV export    │
│                │   │  fallback search │   │                │
└────────────────┘   └──────────────────┘   └────────────────┘
                              │                       ▲
                              ▼                       │
                     ┌──────────────────┐             │
                     │  PDF scanner     │─────────────┘
                     │  (3 detectors,   │
                     │   fully local)   │
                     └──────────────────┘
```

## Features

- **Strict + fallback search.** Strict matches use the registry's own `funder + award` linkage (authoritative). Fallback uses PI / ORCID / keyword heuristics for grants where authors didn't cite the award ID.
- **Six upstream sources.** Crossref, OpenAlex, DataCite, ClinicalTrials.gov, OpenAIRE, Europe PMC — queried in parallel, deduplicated by DOI across sources.
- **BM25 similarity score** on every fallback row, banded `high / plausible / off-topic`, so reviewers can prioritise.
- **Local PDF pipeline** (no LLM, no network at scan time) with three rule-based detectors:
  - **CIHR funding** — section-aware, ignores author-disclosure mentions.
  - **Trial / systematic-review registrations** — NCT, ISRCTN, EudraCT, PROSPERO, OSF, …
  - **Data availability** — GEO, SRA, Zenodo, Dryad, GitHub, OSF, and ~25 more repositories.
- **CSV export** that combines registry rows with PDF-extracted signals, linked back to the source paper's DOI.

## Quick start

You need **R 4.2+** and **Python 3.10+** on your `PATH`. Everything else is handled on first launch — R packages load via `pacman`, and the app creates `.venv/` and installs `pymupdf4llm` from [python/requirements.lock.txt](python/requirements.lock.txt) the first time it starts.

The app reads `app.R`, `R/`, `python/`, and the grant workbook relative to the current working directory, so launch from the project root.

From a macOS / Linux terminal:

```sh
cd /path/to/OS_search
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

From the Windows Command Prompt or PowerShell:

```bat
cd C:\path\to\OS_search
Rscript -e "shiny::runApp('app.R', launch.browser = TRUE)"
```

Watch the console for `Listening on http://127.0.0.1:<port>` — the browser opens there automatically. The very first launch builds the venv, downloads `pymupdf4llm` (and PyMuPDF), and parses the grant workbook into `cache/project_grants.rds` (~30 s total). Subsequent launches are instant.

If Python is missing or too old, the **PDF extraction** tab degrades to an explanatory alert; the rest of the app keeps working.

### Conda alternative

For a fully reproducible environment (pinned R + Python + system deps):

```sh
conda env create -f environment.yml
conda activate os_search
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

## Documentation

- [ABOUT.md](ABOUT.md) — UI layout, data-source matching strategies, and notes on how grant IDs are normalised across registries. Rendered inside the app under the **About** tab.
- [USER_GUIDE.md](USER_GUIDE.md) — step-by-step walkthrough aimed at research assistants extracting outputs for a list of grants.

## Project layout

```
app.R                Shiny UI + server (single file)
R/data_loader.R      Parses CIHR Project Grant workbooks, caches to RDS
R/api_clients.R      Crossref / OpenAlex / DataCite / CT.gov / OpenAIRE /
                     Europe PMC clients + outcome summariser
R/pdf_convert.R      Wraps the py/ helpers via system2(); JSON → tibble
R/similarity.R       BM25 similarity score for fallback rows
py/                  Local PDF pipeline (PyMuPDF + rule-based detectors)
python/              Pinned Python requirements
environment.yml      Conda environment for reproducible installs
cache/               project_grants.rds (parsed workbooks; gitignored)
downloads/           Per-grant CSV exports (gitignored)
```

## Acknowledgments

Two of the PDF detectors are direct adaptations of published rule sets:

- **Trial / systematic-review registration patterns** are adapted from [maia-sh/ctregistries](https://github.com/maia-sh/ctregistries) and Crossref's clinical-trials importer.
- **Data-availability detection** follows the design of [ODDPub](https://github.com/quest-bih/oddpub) (Riedel et al., 2020).

Both upstream projects are independent open-source efforts — credit for the underlying corpora belongs to their authors.

This app uses public APIs from Crossref, OpenAlex, DataCite, ClinicalTrials.gov, OpenAIRE, and Europe PMC. Set `OS_SEARCH_MAILTO=you@example.org` to use the Crossref / OpenAlex polite pool.

## License

No license has been specified yet. Until one is added, default copyright applies — code is visible but not licensed for reuse. If you'd like to use, modify, or distribute this work, please open an issue.
