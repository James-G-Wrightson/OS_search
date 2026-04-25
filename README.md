# OS_Search

Interactive explorer for open-science outputs of CIHR Project Grants. Pick a grant, pull publications / trials / datasets / preprints from Crossref, OpenAlex, DataCite, ClinicalTrials.gov, and OpenAIRE, and run a fully-local PDF scanner that flags trial registrations and data-availability statements.

```         
┌─────────────────┐   ┌───────────────┐   ┌──────────────┐
│  Grant picker   │──▶│  5 registries │──▶│  CSV export  │
│  (CIHR xlsx)    │   │  (strict +    │   │  + PDF scan  │
│                 │   │   fallback)   │   │  (local)     │
└─────────────────┘   └───────────────┘   └──────────────┘
```


## Quick start

You need **R 4.2+** and **Python 3.10+** on your PATH. Everything else is handled on first launch: R packages load via `pacman`, and the app creates `.venv/` and installs `pymupdf4llm` from [python/requirements.lock.txt](python/requirements.lock.txt) the first time it starts. Subsequent launches are instant. If Python is missing or too old, the Paper → Registration tab degrades to an explanatory alert instead of crashing — the rest of the app still works.

Both launch commands below read `app.R` relative to the current working directory, so `cd` into wherever you cloned the repo first. The app also reads `R/`, `python/`, and the grant workbook relative to cwd, so launching from the project root is required — not optional.

From a macOS / Linux terminal:

``` sh
cd /path/to/OS_search
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

From the Windows Command Prompt (or PowerShell):

``` bat
cd C:\path\to\OS_search
Rscript -e "shiny::runApp('app.R', launch.browser = TRUE)"
```

Watch the console for `Listening on http://127.0.0.1:<port>` — the browser opens there automatically. On the very first run, expect a one-off pause while the venv is built and `pymupdf4llm` (and its PyMuPDF dependency) is downloaded.