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

> **Are you a research assistant or undergrad working through a list of grants?** Skip ahead to the [User Guide](USER_GUIDE.md) — it's a step-by-step walkthrough of one grant from search to CSV export, written for people who weren't involved in building the tool.

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

### [USER_GUIDE.md](USER_GUIDE.md) — for the people doing the data extraction

A practical, no-jargon walkthrough aimed at research assistants and undergrads working through a list of grant numbers. Plan around 20–40 minutes per grant. Covers, in order:

1. Launching the app.
2. Finding the grant by number and confirming the PI / institution / abstract match.
3. Running the registry search and reading the **Summary** counts.
4. Reviewing the **Strict match** tab — rows are pre-ticked by default; untick anything that doesn't belong.
5. Downloading each paper's PDF (open-access link if available; otherwise UBC Library credentials or Google Scholar) and uploading them one by one to the **PDF extraction** tab to capture CIHR funding evidence, registration IDs, and data deposits.
6. Reviewing the **Fallback match** tab — rows are *not* pre-ticked here (opposite default to Strict); tick to include after verifying the work belongs to this grant.
7. Downloading the matched-works CSV and moving to the next grant.

Includes a quick rejection checklist for fallback rows (PI homonyms, pre-grant publications, etc.), a tips-and-traps section (one PDF at a time; new uploads clear previous scans), and a glossary.

### [ABOUT.md](ABOUT.md) — for developers and reviewers

UI layout, the exact strict / fallback queries used at each registry, how CIHR grant IDs are normalised across deposit conventions (`175325_1` → `175325`; with / without `PJT-` prefix), and the parent-versus-thematic-institute funder identity issue that makes the CIHR-family OR clauses necessary. Rendered inside the app under the **About** tab.

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

Copyright © 2026 James Wrightson.

OS_search is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. The full license text is in [LICENSE](LICENSE) at the repository root.

This program is distributed in the hope that it will be useful, but **without any warranty**; without even the implied warranty of merchantability or fitness for a particular purpose. See the GPL for details.

In short:

- You can use, modify, and redistribute the code freely.
- If you distribute a modified version, it must also be GPL-3.0 and ship its source.
- The GPL choice is partly forced by upstream: the data-availability detector is adapted from [ODDPub](https://github.com/quest-bih/oddpub), which is GPL-3.0.
