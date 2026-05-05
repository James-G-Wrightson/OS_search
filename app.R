suppressPackageStartupMessages({
  library(shiny); library(bslib); library(DT); library(dplyr)
  library(stringr); library(shinybusy); library(purrr)
  library(httr2); library(tibble); library(jsonlite)
  library(markdown)
})

# Shiny's default file-upload cap is 5 MB, which clips many real
# journal-article PDFs (image-heavy preprints, supplements). Raise to
# 100 MB so the PDF-extraction tab works for anything plausibly a paper.
options(shiny.maxRequestSize = 100 * 1024 * 1024)

source("R/data_loader.R")
source("R/api_clients.R")
source("R/pdf_convert.R")
source("R/pdf_download.R")
source("R/similarity.R")

PG <- load_project_grants()
UG <- unique_grants(PG)

# Ensure the local Python venv used by the PDF extraction tab is
# ready. On failure (Python too old, venv create or pip install broken),
# the UI degrades the PDF tab to an explanatory alert instead of crashing.
PDF_VENV_STATUS <- ensure_pdf_venv()

# Auto-PDF-download tunables.  Defined before `ui` so the fallback
# similarity-threshold UI default tracks the same value the auto-download
# hook in result() filters on (rows above 0.19 are pre-ticked AND auto-
# downloaded).  Cap protects the user from a runaway high-volume PI
# whose fallback list is hundreds long.
AUTO_DL_FB_THRESHOLD <- 0.19
AUTO_DL_CAP          <- 50L

ui <- page_sidebar(
  title = "CIHR Project Grant \u2192 Open Outputs Explorer (prototype)",
  theme = bs_theme(bootswatch = "flatly"),
  sidebar = sidebar(
    width = 420,
    selectizeInput(
      "fy", "Competition fiscal year",
      choices = c("All", sort(unique(UG$competition_fy))),
      selected = "All"
    ),
    selectizeInput(
      "grant", "Project Grant number",
      choices = NULL,
      options = list(placeholder = "type a grant number...")
    ),
    selectizeInput(
      "grant_search", "Find grant by number (across all FYs)",
      choices = NULL,
      options = list(placeholder = "type any grant number...")
    ),
    actionButton("go", "Search linked works", class = "btn-primary"),
    checkboxInput("dedup_doi",
                  "Collapse duplicate DOIs across sources",
                  value = TRUE),
    hr(),
    uiOutput("grant_info"),
    hr(),
    actionButton("exit_app", "Exit app",
                 icon = icon("power-off"),
                 class = "btn-outline-danger")
  ),

  # Neutralise DataTables' Select-extension row-highlight tint.  The
  # strict-tab tables are pre-ticked (every row in the CSV by default),
  # so the constant blue selected-row background is visually noisy.
  # Keep the checkbox indicator itself untouched — only the row tint
  # is removed.
  tags$head(tags$style(HTML(
    "table.dataTable tbody tr.selected,
     table.dataTable tbody tr.selected > td,
     table.dataTable tbody tr > .selected {
       background-color: inherit !important;
       color: inherit !important;
       box-shadow: none !important;
     }"
  ))),

  add_busy_spinner(spin = "fading-circle", color = "#0d6efd", position = "top-right"),

  navset_tab(
    id = "tabs",
    nav_panel(
      "Summary",
      h4("Three-outcome summary"),
      p(em("Rows combine strict (grant+funder) and fallback (PI+funder) matches. The strict column is authoritative; fallback suggests likely links when PIs didn't cite the award ID.")),
      tableOutput("summary_tbl"),
      hr(),
      h4("Counts by source"),
      tableOutput("counts_tbl"),
      hr(),
      actionButton("dl_csv", "Download matched works (CSV)",
                   icon = icon("download"), class = "btn-primary"),
      tags$div(style = "margin-top:0.5em;color:#555;font-size:0.9em",
               textOutput("dl_status", inline = TRUE))
    ),
    nav_panel(
      "Strict match (grant ID + funder)",
      uiOutput("strict_grant_banner"),
      p("These works explicitly cite the CIHR grant number in the funding metadata of Crossref/OpenAlex/DataCite, or mention the award number in ClinicalTrials.gov."),
      tags$p(tags$small(style = "color:#666",
        "All strict rows are ", tags$strong("ticked by default"),
        " and will be added to the matched-works CSV. Untick any rows you want to exclude.")),
      h5("OpenAlex works"),     DTOutput("strict_oa"),
      h5("Europe PMC"),         DTOutput("strict_epmc"),
      h5("Crossref works"),     DTOutput("strict_cr"),
      h5("DataCite records"),   DTOutput("strict_dc"),
      h5("ClinicalTrials.gov"), DTOutput("strict_ct")
    ),
    nav_panel(
      "Strict PDFs",
      uiOutput("strict_pdfs_tab_content")
    ),
    nav_panel(
      "Fallback match (PI / ORCID / keywords)",
      uiOutput("fallback_grant_banner"),
      p("Broader search. Useful when the PI didn't acknowledge the award ID, or when the output (e.g. a trial registration, a dataset) doesn't carry grant metadata. Human review required."),
      uiOutput("fallback_header"),
      hr(),
      fluidRow(
        column(6, radioButtons(
          "fb_sources", "Source (one at a time, ordered by dedup priority)",
          choices = c("OpenAlex", "Europe PMC", "Crossref",
                      "DataCite", "OpenAIRE", "ClinicalTrials.gov"),
          selected = "OpenAlex",
          inline = TRUE
        )),
        column(6, checkboxGroupInput(
          "fb_match_types", "Match type",
          choices  = c("PI + CIHR funder" = "PI",
                       "PI (any)"         = "any"),
          selected = c("PI", "any"),
          inline = TRUE
        ))
      ),
      fluidRow(
        column(6, checkboxInput(
          "fb_hide_dissimilar",
          "Hide dissimilar results (similarity at or below threshold)",
          value = TRUE
        )),
        column(6, numericInput(
          "fb_sim_threshold", "Similarity threshold",
          value = AUTO_DL_FB_THRESHOLD, min = 0, max = 1, step = 0.05,
          width = "120px"
        ))
      ),
      tags$p(tags$small(style = "color:#666",
        "Rows above the threshold are ", tags$strong("ticked by default"),
        " and will be added to the matched-works CSV. Untick any rows you want to exclude. Lowering the threshold reveals more rows; new rows stay un-ticked.")),
      DTOutput("fb_table")
    ),
    nav_panel(
      "Fallback PDFs",
      uiOutput("fallback_pdfs_tab_content")
    ),
    nav_panel(
      "About",
      includeMarkdown("ABOUT.md")
    )
  )
)

DOWNLOAD_BASE <- file.path(getwd(), "downloads")

.pi_surname_slug <- function(family_name, pi_full_name = NULL) {
  s <- if (!is.null(family_name) && !is.na(family_name) && nzchar(family_name)) {
    as.character(family_name)
  } else if (!is.null(pi_full_name) && !is.na(pi_full_name) && nzchar(pi_full_name)) {
    parts <- strsplit(trimws(as.character(pi_full_name)), "\\s+")[[1]]
    parts[length(parts)]
  } else {
    "unknown"
  }
  s <- gsub("[^A-Za-z0-9]", "", s)
  if (!nzchar(s)) "unknown" else s
}

.grant_folder <- function(grant_id, family_name, pi_full_name = NULL,
                          base = DOWNLOAD_BASE) {
  file.path(base, sprintf("%s_%s", grant_id, .pi_surname_slug(family_name, pi_full_name)))
}

# Strict download set: union of all five strict buckets, restricted to rows
# where the upstream surfaced an OA PDF URL.  Source-agnostic so future
# clients that learn to expose oa_pdf_url for Crossref/DataCite/CT.gov are
# picked up automatically.  Hard-capped at AUTO_DL_CAP.
.auto_dl_strict_set <- function(r, cap = AUTO_DL_CAP) {
  empty <- tibble::tibble(doi = character(), title = character(),
                          oa_pdf_url = character())
  if (is.null(r$strict)) return(empty)
  rows <- bind_rows(r$strict)
  if (is.null(rows) || nrow(rows) == 0 || !"oa_pdf_url" %in% names(rows)) {
    return(empty)
  }
  rows <- rows[!is.na(rows$oa_pdf_url) & nzchar(rows$oa_pdf_url), , drop = FALSE]
  if (nrow(rows) > cap) {
    showNotification(sprintf(
      "Strict auto-download capped at %d PDFs (%d had OA URLs). Drop the rest in manually.",
      cap, nrow(rows)),
      type = "warning", duration = 8)
    rows <- rows[seq_len(cap), , drop = FALSE]
  }
  rows
}

# Fallback download set: rows whose similarity strictly exceeds `threshold`
# AND who carry an oa_pdf_url AND whose DOI isn't already in the strict
# download set (would download the same paper into both folders, then both
# PDF tabs would surface duplicate findings).  Capped at AUTO_DL_CAP.
# Score recomputed inline rather than reusing fallback_all() because that
# reactive depends on result() — calling it from inside result() would
# loop.  Doesn't honour input$dedup_doi: auto-DL fires on what the
# upstream actually returned, not the dedup view.
.auto_dl_fallback_set <- function(r, strict_dl,
                                   threshold = AUTO_DL_FB_THRESHOLD,
                                   cap = AUTO_DL_CAP) {
  empty <- tibble::tibble(doi = character(), title = character(),
                          oa_pdf_url = character(), similarity = numeric())
  if (is.null(r$fallback)) return(empty)
  rows <- bind_rows(lapply(names(r$fallback), function(nm) {
    t <- r$fallback[[nm]]
    if (is.null(t) || nrow(t) == 0) return(NULL)
    t$source_api <- nm
    t
  }))
  if (is.null(rows) || nrow(rows) == 0 || !"oa_pdf_url" %in% names(rows)) {
    return(empty)
  }
  rows$similarity <- score_fallback(rows, r$grant)
  rows <- rows[!is.na(rows$similarity) & rows$similarity > threshold, , drop = FALSE]
  rows <- rows[!is.na(rows$oa_pdf_url) & nzchar(rows$oa_pdf_url), , drop = FALSE]
  if (nrow(rows) == 0) return(empty)
  strict_dois <- if (!is.null(strict_dl) && nrow(strict_dl) && "doi" %in% names(strict_dl)) {
    d <- strict_dl$doi
    unique(d[!is.na(d) & nzchar(d)])
  } else character()
  if (length(strict_dois) > 0 && "doi" %in% names(rows)) {
    rows <- rows[is.na(rows$doi) | !nzchar(rows$doi) |
                 !rows$doi %in% strict_dois, , drop = FALSE]
  }
  if (nrow(rows) > cap) {
    showNotification(sprintf(
      "Fallback auto-download capped at %d PDFs (%d above threshold %.2f). Lower the cap or raise the threshold.",
      cap, nrow(rows), threshold),
      type = "warning", duration = 8)
    rows <- rows[seq_len(cap), , drop = FALSE]
  }
  rows
}

# Map a DOI prefix to its preprint server name when the DOI belongs to
# a known self-archive registry.  Used to fill venue / is_oa / oa_status
# for preprints whose upstream metadata records the work but leaves
# `journalTitle` empty (Europe PMC, Crossref) or `host_venue` mis-typed
# as not-OA.  Returns NA_character_ for unknown prefixes.
#
# 10.1101 covers both bioRxiv and medRxiv; default to "bioRxiv" since
# bio outweighs med ~10:1 by volume — disambiguation would require
# fetching the URL, which we explicitly avoid here.
.PREPRINT_VENUES <- c(
  "10.1101"   = "bioRxiv",
  "10.21203"  = "Research Square",
  "10.31219"  = "OSF Preprints",
  "10.31234"  = "PsyArXiv",
  "10.20944"  = "Preprints.org",
  "10.31222"  = "EarthArXiv",
  "10.55458"  = "ChemRxiv",
  "10.48550"  = "arXiv",
  "10.36227"  = "TechRxiv",
  "10.32942"  = "EarthArXiv"
)

.preprint_venue_from_doi <- function(doi) {
  if (!length(doi)) return(character(0))
  out <- rep(NA_character_, length(doi))
  hit <- !is.na(doi) & nzchar(doi)
  if (!any(hit)) return(out)
  prefix <- sub("/.*$", "", doi[hit])
  out[hit] <- unname(.PREPRINT_VENUES[prefix])
  out
}

server <- function(input, output, session) {

  # First-load default — a grant with both a strict-matched OpenAlex
  # paper hit and a strict-matched DataCite Dataset (resourceTypeGeneral
  # == "Dataset") so the app's full output mix renders on landing.
  # Selected by /tmp/find_default_grant.py over 1,080 sampled grants
  # across FY 2017-18 to 2022-23 (Peyrache, Neuronal basis of spatial
  # cognition: 25 OpenAlex strict, 1 DataCite Dataset).
  DEFAULT_GRANT_ID <- "155957_1"

  # Update grant picker when FY changes.  Labels = grant_id only (what the
  # user picks); full metadata appears in the read-only info panel below.
  # Wait for fy to acquire a value: selectize delivers its initial value
  # via WebSocket after the page renders, so on the very first reactive
  # flush input$fy is NULL — `req()` defers until then and avoids a
  # bogus warning in the shiny log.
  #
  # input$grant is read inside isolate() so this observer only re-fires
  # on input$fy changes, never on input$grant.  Without isolate, the
  # `updateSelectizeInput` below echoes a value change back from the
  # client, which re-fires the observer with sel != grant, which
  # re-issues the update — selectize.js briefly clears, the empty value
  # round-trips back, the first branch fires again, and the picker
  # oscillates 155957_1 → "" → 148482_1 → 155957_1 forever.  `seeded`
  # gates the default-grant seed so it runs exactly once on first
  # render.
  seeded <- reactiveVal(FALSE)
  observe({
    req(input$fy)
    dat <- if (input$fy == "All") UG else filter(UG, competition_fy == input$fy)
    sel <- isolate({
      if (!seeded() && input$fy == "All" &&
          (is.null(input$grant) || !nzchar(input$grant)) &&
          DEFAULT_GRANT_ID %in% dat$grant_id) {
        seeded(TRUE)
        DEFAULT_GRANT_ID
      } else if (!is.null(input$grant) && nzchar(input$grant) &&
                 input$grant %in% dat$grant_id) {
        input$grant
      } else {
        NULL
      }
    })
    updateSelectizeInput(session, "grant",
                        choices = sort(dat$grant_id),
                        selected = sel,
                        server = TRUE)
  })

  # Cross-FY grant-number search. Populated once from all unique grants;
  # picking one here snaps the FY filter and main grant picker to match,
  # so a user who knows a grant number but not its FY can still find it.
  updateSelectizeInput(session, "grant_search",
                      choices = sort(UG$grant_id),
                      server = TRUE)

  # When `updateSelectizeInput(grant_search, server = TRUE)` runs above,
  # selectize.js on the client auto-selects the first loaded option and
  # round-trips it back as input$grant_search ~100 ms after the first
  # server flush.  That used to stomp fy from "All" to the alphabetically
  # first grant's FY (201516) and grant from the seeded default to
  # 148482_1.  A previous attempt used `session$onFlushed(once=TRUE)` to
  # gate the observer, but that flag flips before the auto-populated
  # value comes back, so it didn't work.  Skip the very first non-empty
  # arrival explicitly — the selectize auto-populate fires exactly once
  # per session, every later change is a real user pick.
  gs_user_acted <- reactiveVal(FALSE)

  observeEvent(input$grant_search, {
    req(input$grant_search)
    if (!gs_user_acted()) { gs_user_acted(TRUE); return() }
    match_row <- UG |> filter(grant_id == input$grant_search) |> slice(1)
    if (!nrow(match_row)) return()
    if (!identical(input$fy, match_row$competition_fy)) {
      updateSelectizeInput(session, "fy", selected = match_row$competition_fy)
    }
    updateSelectizeInput(session, "grant", selected = match_row$grant_id)
  }, ignoreInit = TRUE)

  current_row <- reactive({
    req(input$grant)
    UG |> filter(grant_id == input$grant) |> slice(1)
  })

  # Read-only info fields.  Using disabled <input>s so they render as
  # greyed-out form fields rather than free-form text.
  .info_field <- function(label, value, area = FALSE) {
    val <- if (is.null(value) || is.na(value) || value == "") "\u2014" else as.character(value)
    input_tag <- if (area) {
      tags$textarea(val, readonly = NA, disabled = NA, rows = 4,
                    class = "form-control form-control-sm",
                    style = "resize:vertical;background:#f6f6f6;color:#333")
    } else {
      tags$input(type = "text", value = val, readonly = NA, disabled = NA,
                 class = "form-control form-control-sm",
                 style = "background:#f6f6f6;color:#333")
    }
    tags$div(class = "mb-2",
             tags$label(label, class = "form-label small text-muted mb-0"),
             input_tag)
  }

  output$grant_info <- renderUI({
    req(input$grant)
    r <- current_row()
    total <- if (is.na(r$total_awarded)) "\u2014"
             else format(r$total_awarded, big.mark = ",")
    tagList(
      .info_field("PI",               r$pi_full_name),
      .info_field("Competition FY",   r$competition_fy),
      .info_field("Institution",      r$institution),
      .info_field("Funding period",
                  paste(format(r$funding_start), "\u2013", format(r$funding_end))),
      .info_field("Total awarded (CAD)", total),
      .info_field("Title",            r$title, area = TRUE),
      tags$details(style = "margin-top:0.5em",
        tags$summary("Abstract"),
        tags$div(style = "max-height:220px;overflow-y:auto;font-size:0.85em;padding:0.4em;background:#f6f6f6;border-radius:4px",
                 r$abstract %||% "\u2014")
      )
    )
  })

  # When the user clicks "Search linked works", check if a folder for this
  # grant already exists. If it does, prompt before firing the search; if
  # not, fire immediately. The actual search reacts to `search_trigger`,
  # which increments only after confirmation (or when no folder exists).
  search_trigger <- reactiveVal(0)

  observeEvent(input$go, {
    req(input$grant)
    folder <- .grant_folder(input$grant,
                            current_row()$family_name,
                            current_row()$pi_full_name)
    if (dir.exists(folder)) {
      showModal(modalDialog(
        title = "Folder already exists",
        tags$p(sprintf("A download folder already exists for grant %s:",
                       input$grant)),
        tags$pre(folder),
        tags$p("Do you want to run the search anyway? Any CSV saved next will overwrite the existing one (with a confirmation prompt)."),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("confirm_search", "Continue", class = "btn-primary")
        ),
        easyClose = FALSE
      ))
    } else {
      search_trigger(search_trigger() + 1)
    }
  })

  observeEvent(input$confirm_search, {
    removeModal()
    search_trigger(search_trigger() + 1)
  })

  result <- eventReactive(search_trigger(), {
    req(search_trigger() > 0, input$grant)
    folder <- .grant_folder(input$grant,
                            current_row()$family_name,
                            current_row()$pi_full_name)
    if (!dir.exists(folder)) {
      dir.create(folder, recursive = TRUE, showWarnings = FALSE)
    }
    show_modal_spinner(spin = "atom", text = "Querying Crossref, OpenAlex (author + ORCID), DataCite (PI + ORCID), ClinicalTrials.gov (keyword + PI), OpenAIRE, Europe PMC (grant + PI)...")
    r <- tryCatch(search_grant_all_sources(current_row()),
                  error = function(e) { remove_modal_spinner(); stop(e) })

    # Auto-download accessible PDFs into per-grant subfolders for the two
    # PDF-scan tabs to pick up.  Folded into result() so the user sees one
    # spinner for "search + download" rather than two.  Idempotent: rows
    # whose dest filename already exists are skipped, so manual drops
    # survive a re-run.  download_pdf() short-circuits to ok=FALSE when
    # OS_SEARCH_DISABLE_PDF_DOWNLOAD is set (smoke tests, dev iteration);
    # the outcome tibbles are still populated, so the manual-DL panel
    # renders correctly in tests.
    strict_dir <- file.path(folder, "strict_papers")
    fb_dir     <- file.path(folder, "fallback_papers")
    strict_dl  <- .auto_dl_strict_set(r)
    fb_dl      <- .auto_dl_fallback_set(r, strict_dl,
                                        threshold = AUTO_DL_FB_THRESHOLD,
                                        cap = AUTO_DL_CAP)
    if (nrow(strict_dl) + nrow(fb_dl) > 0) {
      update_modal_spinner(text = sprintf(
        "Downloading %d strict + %d fallback PDFs (skipping any already on disk)...",
        nrow(strict_dl), nrow(fb_dl)))
    }
    r$strict_dl_outcome   <- download_pdfs_for_rows(strict_dl, strict_dir)
    r$fallback_dl_outcome <- download_pdfs_for_rows(fb_dl,     fb_dir)

    remove_modal_spinner()
    r
  })

  # When the dedup-by-DOI toggle is on, collapse the strict buckets so
  # each DOI appears only under its highest-priority source (OpenAlex
  # first, then Europe PMC, Crossref, DataCite, OpenAIRE — see
  # .SOURCE_PRIORITY in R/api_clients.R).  ClinicalTrials.gov is
  # untouched because its rows carry NCT IDs, not DOIs.
  strict_for_display <- reactive({
    req(result())
    s <- result()$strict
    if (!isTRUE(input$dedup_doi)) return(s)
    doi_buckets <- c("openalex", "crossref", "datacite", "europepmc")
    combined <- bind_rows(lapply(doi_buckets, function(nm) {
      t <- s[[nm]]
      if (is.null(t) || nrow(t) == 0) return(NULL)
      t$.bucket <- nm
      t
    }))
    if (is.null(combined) || nrow(combined) == 0) return(s)
    combined <- dedup_rows_by_doi(combined)
    out <- s
    for (nm in doi_buckets) {
      rows <- combined[combined$.bucket == nm, , drop = FALSE]
      rows$.bucket <- NULL
      out[[nm]] <- rows
    }
    out
  })

  # ---- Summary ----
  output$summary_tbl <- renderTable({
    req(result()); summarise_outcomes(result())
  }, striped = TRUE)

  output$counts_tbl <- renderTable({
    req(result())
    r <- result()
    make <- function(lst, kind) {
      tibble::tibble(
        Match = kind,
        Source = names(lst),
        Hits = vapply(lst, nrow, integer(1))
      )
    }
    bind_rows(make(r$strict, "Strict"), make(r$fallback, "Fallback"))
  }, striped = TRUE)

  # ---- helpers ----
  # Build a URL that opens the source aggregator's web page for each row,
  # so the user can eyeball the original record (funder metadata, etc.).
  .verify_url <- function(row) {
    src <- row$source %||% ""
    doi <- row$doi   %||% NA
    if (src == "OpenAlex") {
      oid <- sub("^https?://openalex\\.org/", "", row$openalex_id %||% "")
      if (nzchar(oid)) return(sprintf("https://openalex.org/works/%s", oid))
    }
    if (src == "Crossref" && !is.na(doi) && nzchar(doi)) {
      return(sprintf("https://search.crossref.org/search/works?q=%s&from_ui=yes",
                     utils::URLencode(doi, reserved = TRUE)))
    }
    if (src == "DataCite" && !is.na(doi) && nzchar(doi)) {
      return(sprintf("https://commons.datacite.org/doi.org/%s", doi))
    }
    if (src == "ClinicalTrials.gov" && !is.null(row$nct_id) && nzchar(row$nct_id)) {
      return(sprintf("https://clinicaltrials.gov/study/%s", row$nct_id))
    }
    if (src == "OpenAIRE" && !is.na(doi) && nzchar(doi)) {
      return(sprintf("https://explore.openaire.eu/search/find?fv0=%s", doi))
    }
    if (src == "Europe PMC") {
      pmid <- row$pmid %||% NA
      esrc <- row$epmc_source %||% "MED"
      if (!is.na(pmid) && nzchar(pmid)) {
        return(sprintf("https://europepmc.org/article/%s/%s", esrc, pmid))
      }
      if (!is.na(doi) && nzchar(doi)) {
        return(sprintf("https://europepmc.org/search?query=DOI:%s",
                       utils::URLencode(doi, reserved = TRUE)))
      }
    }
    ""
  }

  # Format a numeric similarity vector as colour-banded HTML pills.
  # Bands chosen from the BM25 bake-off (build/sim_eval.R):
  #   >=0.60  high       — top of the per-grant distribution, on-topic
  #   0.20-0.60 plausible — partial keyword overlap, worth a glance
  #   <0.20   off-topic   — likely a same-PI-different-topic hit
  # NA renders as an em-dash (sparse-grant guard fired, or no keywords).
  .fmt_sim_badge <- function(x) {
    out <- character(length(x))
    na <- is.na(x)
    out[na] <- '<span style="color:#999">—</span>'
    if (any(!na)) {
      xv <- x[!na]
      bg <- ifelse(xv >= 0.6, "#0a7d2f",
            ifelse(xv >= 0.2, "#c98321", "#888"))
      lab <- ifelse(xv >= 0.6, "high",
             ifelse(xv >= 0.2, "plausible", "off-topic"))
      out[!na] <- sprintf(
        '<span title="%s" style="display:inline-block; min-width:2.6em; padding:1px 6px; border-radius:9px; background:%s; color:#fff; font-weight:600; text-align:center; font-size:0.85em">%.2f</span>',
        lab, bg, xv)
    }
    out
  }

  # Truncate an abstract to its first sentence for display. Similarity
  # scoring runs upstream on the full text (see fallback_all), so this
  # only affects what's shown in the table.
  .first_sentence <- function(x) {
    if (is.null(x) || !length(x)) return(x)
    out <- as.character(x)
    keep <- !is.na(out) & nzchar(out)
    for (i in which(keep)) {
      m <- regexpr("^.*?[.!?](?=\\s|$)", out[i], perl = TRUE)
      if (m != -1L) out[i] <- substr(out[i], 1L, attr(m, "match.length"))
    }
    out
  }

  .render_dt <- function(tbl, linkcol = "url", selection = "none",
                         checkbox = FALSE, checkbox_input = NULL,
                         select_all = FALSE) {
    if (is.null(tbl) || nrow(tbl) == 0) return(datatable(data.frame(info = "(no hits)"),
                                                         rownames = FALSE,
                                                         selection = "none",
                                                         options = list(dom = "t")))
    # Show only the first sentence of the abstract — the full text is
    # used upstream for similarity scoring but clutters the table.
    if ("abstract" %in% names(tbl)) {
      tbl$abstract <- .first_sentence(tbl$abstract)
    }
    # Add a "verify" column pointing to the source aggregator's page for the
    # row.  Uses Shiny's icon helpers via raw HTML for compactness.
    verify_urls <- vapply(seq_len(nrow(tbl)), function(i) .verify_url(tbl[i, ]),
                          character(1))
    src_labels  <- tbl$source %||% rep("source", nrow(tbl))
    tbl$verify <- ifelse(
      nzchar(verify_urls),
      sprintf('<a href="%s" target="_blank" rel="noopener" title="Open on %s">verify \u2197</a>',
              verify_urls, src_labels),
      '<span style="color:#999">\u2014</span>'
    )
    # The OpenAlex work ID is only used upstream to build the verify URL;
    # now that verify has been computed, hide it from the rendered table.
    tbl$openalex_id <- NULL

    if (linkcol %in% names(tbl)) {
      tbl[[linkcol]] <- ifelse(is.na(tbl[[linkcol]]) | tbl[[linkcol]] == "",
                               "", sprintf('<a href="%s" target="_blank">open</a>', tbl[[linkcol]]))
    }
    # Direct-to-PDF link for OA papers (OpenAlex best_oa_location.pdf_url
    # or Europe PMC fullTextUrlList). Lets the user grab a copy to scan
    # before deciding whether to tick the row for the CSV.
    if ("oa_pdf_url" %in% names(tbl)) {
      # Open the PDF in a named popup window rather than a tab so the
      # main app stays visible alongside it (lets the user keep the
      # grant banner in view while saving the PDF to disk).  The
      # `popup,width,height` features are what coax modern browsers
      # (Chrome, Edge, Firefox, Safari) into a window vs. a tab; the
      # named target `pdfviewer` reuses one window across clicks rather
      # than spawning a fresh one each time.  Browser-level prefs (e.g.
      # Firefox's "open new windows in tabs") can still override this —
      # nothing JS-side can bypass that.
      tbl$oa_pdf_url <- ifelse(
        is.na(tbl$oa_pdf_url) | tbl$oa_pdf_url == "",
        '<span style="color:#999">—</span>',
        sprintf(
          '<a href="%s" onclick="window.open(this.href,\'pdfviewer\',\'popup=yes,width=1100,height=850,resizable=yes,scrollbars=yes\'); return false;" rel="noopener" title="Open PDF in popup window (one window, reused)">PDF ⬇</a>',
          tbl$oa_pdf_url)
      )
    }
    # Highlight the award column: when the current grant's award number
    # appears in `matched_award`, bold it green; otherwise grey.
    if ("matched_award" %in% names(tbl) && !is.null(result())) {
      want <- result()$award
      tbl$matched_award <- ifelse(
        is.na(tbl$matched_award) | tbl$matched_award == "",
        '<span style="color:#999">\u2014</span>',
        ifelse(grepl(sprintf("(^|[^0-9])%s([^0-9]|$)", want), tbl$matched_award),
               sprintf('<span style="color:#0a7d2f;font-weight:600">%s</span>', tbl$matched_award),
               sprintf('<span style="color:#555">%s</span>', tbl$matched_award))
      )
    }
    # Pin the most-useful columns to the front in this order:
    # matched_award, verify, url (primary link), oa_pdf_url, then everything else.
    priority_cols <- intersect(c("matched_award", "verify", linkcol, "oa_pdf_url"),
                               names(tbl))
    other_cols    <- setdiff(names(tbl), priority_cols)
    tbl <- tbl[, c(priority_cols, other_cols), drop = FALSE]

    dt_opts <- list(pageLength = 10, scrollX = TRUE)
    dt_ext  <- character(0)
    dt_cb   <- NULL
    dt_sel  <- selection

    if (checkbox) {
      # Explicit checkbox in the first column via DataTables' 'Select'
      # extension. Disable DT's native row-click selection and drive the
      # Shiny input via a callback so only the checkbox toggles selection.
      tbl <- cbind(" " = rep("", nrow(tbl)), tbl)
      dt_sel <- "none"
      dt_ext <- "Select"
      dt_opts$select <- list(style = "multi", selector = "td:first-child")
      dt_opts$columnDefs <- list(list(
        orderable = FALSE, className = "select-checkbox",
        targets = 0, width = "30px"
      ))
      input_name <- checkbox_input %||% "dt_rows_selected"
      # `select_all` controls which rows are programmatically ticked once
      # the listener is wired.  Three forms:
      #   TRUE  -> tick every row (table.rows().select()).
      #   FALSE -> tick nothing (default; opt-in).
      #   numeric vector -> tick those 1-based row indices only (used by
      #     the fallback PDF grant-match table to pre-tick just the rows
      #     where the current grant ID was found in the PDF text).
      # The select() call fires the listener, which pushes the resulting
      # index set up to Shiny via setInputValue — so the CSV builder sees
      # the right "ticked" set without the user having to click anything.
      js_select_all <- if (isTRUE(select_all)) {
        "\ntable.rows().select();"
      } else if (is.numeric(select_all) && length(select_all) > 0) {
        sprintf("\ntable.rows([%s]).select();",
                paste(as.integer(select_all) - 1L, collapse = ","))
      } else {
        ""
      }
      dt_cb <- DT::JS(sprintf(
        "table.on('select deselect', function() {\n  var ids = table.rows({selected:true}).indexes().toArray().map(function(i){ return i + 1; });\n  Shiny.setInputValue('%s', ids, {priority:'event'});\n});%s",
        input_name, js_select_all
      ))
    }

    dt_args <- list(data = tbl, escape = FALSE, rownames = FALSE,
                    selection = dt_sel, extensions = dt_ext,
                    options = dt_opts)
    # Friendlier header for the OA PDF link column without renaming the
    # underlying data column (which other code reads by exact name).
    if ("oa_pdf_url" %in% names(tbl)) {
      dt_args$colnames <- c("OA PDF" = "oa_pdf_url")
    }
    # DT rejects callback = NULL; only include the arg when we actually
    # have a JS callback to attach (checkbox case).
    if (!is.null(dt_cb)) dt_args$callback <- dt_cb
    do.call(datatable, dt_args)
  }

  # ---- Strict tables ----
  # Each strict DT gets a checkbox column; only ticked rows enter the CSV.
  # `server = FALSE` is required for DT's 'Select' extension (client-side).
  output$strict_oa <- renderDT({ req(result()); .render_dt(strict_for_display()$openalex,
    checkbox = TRUE, checkbox_input = "strict_oa_rows_selected", select_all = TRUE) }, server = FALSE)
  output$strict_cr <- renderDT({ req(result()); .render_dt(strict_for_display()$crossref,
    checkbox = TRUE, checkbox_input = "strict_cr_rows_selected", select_all = TRUE) }, server = FALSE)
  output$strict_dc <- renderDT({ req(result()); .render_dt(strict_for_display()$datacite,
    checkbox = TRUE, checkbox_input = "strict_dc_rows_selected", select_all = TRUE) }, server = FALSE)
  output$strict_ct <- renderDT({ req(result()); .render_dt(strict_for_display()$ctgov,
    checkbox = TRUE, checkbox_input = "strict_ct_rows_selected", select_all = TRUE) }, server = FALSE)
  output$strict_epmc <- renderDT({ req(result()); .render_dt(strict_for_display()$europepmc,
    checkbox = TRUE, checkbox_input = "strict_epmc_rows_selected", select_all = TRUE) }, server = FALSE)

  # Map from strict-source key to its checkbox input name, used by the CSV
  # builder to filter each API's tibble to the ticked rows only.
  .strict_selection_map <- c(
    openalex  = "strict_oa_rows_selected",
    crossref  = "strict_cr_rows_selected",
    datacite  = "strict_dc_rows_selected",
    ctgov     = "strict_ct_rows_selected",
    europepmc = "strict_epmc_rows_selected"
  )

  # Columns produced by PDF extraction handlers that should be merged
  # onto the source paper's row in the CSV when a linked_doi is set.
  # When a target row already has a value in one of these cols, values
  # are concatenated with "; " (deduped).  Note `doi` is NOT in this
  # list — the source row's DOI is authoritative; data-deposit rows
  # carry a separate `data_accession`.
  PDF_SIGNAL_COLS <- c(
    "registration_id", "registry",
    "data_repository", "data_accession",
    "cihr_grant_ids", "grant_id_in_pdf",
    "section", "sentence", "anchor", "confidence",
    "pdf_file"
  )

  # ---- Grant banner shown at the top of the strict + fallback tabs.
  # Surfaces the grant ID and the matching download-folder name so the
  # user can pick the right folder when saving a PDF without flipping
  # back to the sidebar.  Rendered into two outputs (one per tab); the
  # ID can't appear twice in the DOM.
  .grant_banner_ui <- function() {
    r <- result()
    if (is.null(r) || is.null(r$grant)) return(NULL)
    folder <- sprintf("%s_%s",
                      r$grant$grant_id,
                      .pi_surname_slug(r$grant$family_name,
                                       r$grant$pi_full_name))
    tags$div(
      style = "padding:0.55em 0.85em; margin-bottom:0.6em; background:#e7f1ff; border-left:4px solid #0d6efd; border-radius:3px; font-size:1.0em",
      tags$strong("Grant: "),
      tags$span(style = "font-family:monospace; font-size:1.1em",
                r$grant$grant_id %||% "—"),
      tags$span(style = "color:#555; margin-left:1.5em", "Download folder: "),
      tags$span(style = "font-family:monospace", folder)
    )
  }
  output$strict_grant_banner   <- renderUI({ req(result()); .grant_banner_ui() })
  output$fallback_grant_banner <- renderUI({ req(result()); .grant_banner_ui() })

  # ---- Fallback header: ORCID + keywords used ----
  output$fallback_header <- renderUI({
    req(result())
    r <- result()
    tagList(
      strong("ORCID used: "),
      if (!is.na(r$orcid %||% NA))
        tags$a(href = paste0("https://orcid.org/", r$orcid),
               target = "_blank", r$orcid)
      else tags$span(style = "color:#888", "not resolved from OpenAlex"),
      br(),
      strong("Keywords used for CT.gov: "),
      if (length(r$keywords)) paste(r$keywords, collapse = ", ")
      else tags$span(style = "color:#888", "none extracted")
    )
  })

  # ---- Fallback: combined + filtered single table ----
  # Classify each row's matched_by into one of the two UI buckets: "PI"
  # (PI + CIHR funder/sponsor) or "any" (PI without any funder filter).
  .classify_match <- function(mb) {
    ifelse(grepl("any sponsor", mb), "any", "PI")
  }

  fallback_all <- reactive({
    req(result())
    f <- result()$fallback
    rows <- bind_rows(lapply(names(f), function(nm) {
      t <- f[[nm]]
      if (nrow(t) == 0) return(NULL)
      t$source_api <- nm
      t
    }))
    if (is.null(rows) || nrow(rows) == 0) return(tibble::tibble())
    rows$match_type <- .classify_match(rows$matched_by)
    if (isTRUE(input$dedup_doi)) {
      # Strict is authoritative — drop fallback rows whose DOI already
      # appears in any strict bucket so the same work doesn't show up
      # under both tabs.
      strict_dois <- unique(unlist(lapply(result()$strict, function(t) {
        if (is.null(t) || nrow(t) == 0 || !"doi" %in% names(t)) return(character())
        d <- t$doi
        d[!is.na(d) & nzchar(d)]
      }), use.names = FALSE))
      if (length(strict_dois) > 0 && "doi" %in% names(rows)) {
        keep <- is.na(rows$doi) | !nzchar(rows$doi) | !rows$doi %in% strict_dois
        rows <- rows[keep, , drop = FALSE]
      }
      if (nrow(rows) == 0) return(tibble::tibble())
      rows <- dedup_rows_by_doi(rows)
    }
    # Per-grant BM25 similarity (grant.keywords vs item.title+abstract).
    # Computed after dedup so each surviving row scores in isolation.
    rows$similarity <- score_fallback(rows, result()$grant)
    rows
  })

  fallback_filtered <- reactive({
    tbl <- fallback_all()
    if (is.null(tbl) || nrow(tbl) == 0) return(tbl)
    src_sel <- input$fb_sources %||% character()
    mt_sel  <- input$fb_match_types %||% character()
    tbl <- tbl[tbl$source %in% src_sel & tbl$match_type %in% mt_sel, , drop = FALSE]
    # Drop rows whose similarity is at or below the user-set threshold.
    # NA similarities (sparse-grant guard fired, or no grant keywords)
    # are kept — that signals "no signal", not "off-topic".
    if (isTRUE(input$fb_hide_dissimilar) &&
        "similarity" %in% names(tbl) && nrow(tbl) > 0) {
      thr <- suppressWarnings(as.numeric(input$fb_sim_threshold))
      if (length(thr) != 1 || is.na(thr)) thr <- 0
      keep <- is.na(tbl$similarity) | tbl$similarity > thr
      tbl <- tbl[keep, , drop = FALSE]
    }
    # Default order: source priority asc (OpenAlex first), then
    # similarity desc within each source (NAs at the bottom).  Done
    # here, not in the renderer, so selection indices stay aligned.
    if ("similarity" %in% names(tbl) && "source" %in% names(tbl) && nrow(tbl) > 0) {
      pri <- .source_priority_rank(tbl$source)
      sim <- tbl$similarity
      sim[is.na(sim)] <- -Inf
      tbl <- tbl[order(pri, -sim), , drop = FALSE]
    }
    tbl
  })

  output$fb_table <- renderDT({
    req(result())
    tbl <- fallback_filtered()
    if (is.null(tbl) || nrow(tbl) == 0) {
      return(datatable(data.frame(info = "(no rows match current filters)"),
                       rownames = FALSE, selection = "none",
                       options = list(dom = "t")))
    }
    # Row order (source priority then similarity desc) is set in
    # fallback_filtered() so checkbox indices align with the visible
    # rows.  Render the similarity score as a coloured badge.  Three bands:
    # >=0.6 green ("high"), 0.2-0.6 amber ("plausible"), <0.2 grey
    # ("off-topic"); NA renders as an em-dash.  Lex-sortable since all
    # numeric labels are 0.NN, and the em-dash sorts to the end.
    if ("similarity" %in% names(tbl)) {
      tbl$similarity <- .fmt_sim_badge(tbl$similarity)
    }
    # Drop api-internal bookkeeping; matched_award is not useful here
    # (matches are by PI/ORCID/keywords, not award number).  Keep
    # `abstract` so .render_dt can show its first sentence — the full
    # text was already consumed upstream by score_fallback().  Keep
    # openalex_id because .render_dt needs it to build the OpenAlex
    # verify URL.
    tbl <- tbl[, setdiff(names(tbl),
                         c("source_api", "matched_award")),
               drop = FALSE]
    # Pin similarity to the front of the non-priority columns so the
    # triage signal is visible without horizontal scroll.  Move `doi`
    # next to `venue` for easy row-by-row scanning.
    if ("similarity" %in% names(tbl)) {
      remaining <- setdiff(names(tbl), "similarity")
      tbl <- tbl[, c("similarity", remaining), drop = FALSE]
    }
    if (all(c("venue", "doi") %in% names(tbl))) {
      remaining <- setdiff(names(tbl), "doi")
      tbl <- tbl[, append(remaining, "doi",
                          after = which(remaining == "venue")),
                 drop = FALSE]
    }
    # Pre-tick all displayed rows.  Because the threshold filter above
    # already drops anything at-or-below the threshold, "all displayed"
    # equals "above threshold" — those are the rows that auto-download
    # also fired on.  Opt-out: the user unticks rows they don't want in
    # the CSV, matching the strict tab's UX.  Lowering the threshold
    # post-render reveals new rows that stay un-ticked (correct: those
    # weren't auto-downloaded either).
    .render_dt(tbl, checkbox = TRUE,
               checkbox_input = "fb_table_rows_selected",
               select_all = TRUE)
  }, server = FALSE)

  # Rows the user has ticked in the fallback table. Selection indexes
  # into the currently-displayed `fallback_filtered()`.
  fallback_selected <- reactive({
    tbl <- fallback_filtered()
    sel <- input$fb_table_rows_selected
    if (is.null(tbl) || nrow(tbl) == 0 || is.null(sel) || length(sel) == 0) {
      return(tibble::tibble())
    }
    # Drop stale indices (from a previous render where the filter set was
    # different) so we never index past the end of the current table.
    sel <- sel[sel >= 1 & sel <= nrow(tbl)]
    if (length(sel) == 0) return(tibble::tibble())
    tbl[sel, , drop = FALSE]
  })

  # ---- PDF -> source-paper linking ----
  # Combined list of strict + fallback rows with non-NA DOI, used to
  # auto-link an uploaded PDF to the paper it came from.  Strict-first
  # binding so dedup keeps the strict row when both surface the same DOI.
  # Carries every column the source rows had so a fabricated `pdf_only`
  # row inherits abstract/type/venue/pmid/epmc_source/etc., not just a
  # whitelisted subset.  UI-only artifacts (similarity, match_type) are
  # dropped so they don't end up in the CSV.
  pdf_link_candidates <- reactive({
    r <- result()
    empty <- tibble::tibble(doi = character(), bucket = character())
    if (is.null(r)) return(empty)
    drop_ui <- c("similarity", "match_type")
    strict_view <- tryCatch(strict_for_display(),
                            error = function(e) r$strict)
    strict_rows <- bind_rows(lapply(strict_view, function(t) {
      if (is.null(t) || nrow(t) == 0) return(NULL)
      out <- t[, setdiff(names(t), drop_ui), drop = FALSE]
      out$bucket <- "strict"
      out
    }))
    fb_df <- tryCatch(fallback_all(), error = function(e) tibble::tibble())
    fb_rows <- if (!is.null(fb_df) && nrow(fb_df)) {
      out <- fb_df[, setdiff(names(fb_df), drop_ui), drop = FALSE]
      out$bucket <- "fallback"
      out
    } else NULL
    out <- bind_rows(strict_rows, fb_rows)
    if (is.null(out) || nrow(out) == 0 || !"doi" %in% names(out)) return(empty)
    out <- out[!is.na(out$doi) & nzchar(out$doi), , drop = FALSE]
    if (nrow(out) == 0) return(empty)
    out$doi <- tolower(out$doi)
    out[!duplicated(out$doi), , drop = FALSE]   # strict-first wins
  })

  # Extra rows harvested from PDF scans (registrations / data deposits /
  # grant-id matches), appended to the CSV download when the user clicks
  # one of the "Add to CSV" buttons in the Strict PDFs / Fallback PDFs
  # tabs.  Keyed on grant_id implicitly: cleared whenever a new search
  # fires.
  extra_rows <- reactiveVal(tibble::tibble())

  # Clear the extra-rows buffer (and the last-saved-path indicator)
  # whenever a new grant search is kicked off, so the PDF-merge state is
  # always scoped to the currently-loaded grant result.
  observeEvent(search_trigger(), {
    extra_rows(tibble::tibble())
    last_saved_path(NULL)
  }, ignoreInit = TRUE)

  # ---- Strict PDFs / Fallback PDFs tabs ----
  # Each tab batch-scans the per-grant subfolder of strict_papers/ or
  # fallback_papers/ for registrations, data-availability statements, and
  # (fallback only) whether the current grant's CIHR number appears in the
  # PDF text.  The two tabs share UI shape via .pdf_tab_ui(); the per-kind
  # observers and reactive scan tibbles are added in the next commit.
  .pdf_tab_ui <- function(kind) {
    if (!isTRUE(PDF_VENV_STATUS$ok)) {
      return(tagList(
        tags$div(
          class = "alert alert-danger",
          tags$h4(style = "margin-top:0", "PDF pipeline unavailable"),
          tags$p(PDF_VENV_STATUS$message),
          tags$p(tags$small(style = "color:#666",
            "The rest of the app (grant search, matched-works CSV) still works normally."))
        )
      ))
    }
    if (search_trigger() < 1) {
      return(tagList(
        tags$div(
          class = "alert alert-info",
          tags$h4(style = "margin-top:0", "Run a grant search first"),
          tags$p("Pick a grant in the sidebar and press ",
                 tags$b("Search linked works"),
                 ". The app will auto-download every accessible OA PDF for ",
                 tags$strong(if (kind == "strict") "strict matches"
                             else "fallback matches above the similarity threshold"),
                 " into ",
                 tags$code(if (kind == "strict") "strict_papers/" else "fallback_papers/"),
                 ", and this tab will scan them.")
        )
      ))
    }
    # Post-search content: manual-download panel + per-section tables.
    folder <- file.path(.grant_folder(input$grant,
                                      current_row()$family_name,
                                      current_row()$pi_full_name),
                        if (kind == "strict") "strict_papers" else "fallback_papers")
    label <- if (kind == "strict") "Strict PDF scan" else "Fallback PDF scan"

    common_controls <- tagList(
      tags$p(tags$small(style = "color:#666",
        "Folder: ", tags$code(folder))),
      uiOutput(sprintf("%s_pdfs_manual_dl_panel", kind)),
      hr(),
      fluidRow(
        column(4, actionButton(
          sprintf("%s_pdfs_rescan", kind),
          "Re-scan folder",
          icon = icon("rotate"),
          class = "btn-outline-primary")),
        column(4, actionButton(
          sprintf("%s_pdfs_open_folder", kind),
          "Open folder",
          icon = icon("folder-open"),
          class = "btn-outline-secondary")),
        column(4, tags$div(style = "padding-top:0.4em;color:#555",
                           textOutput(sprintf("%s_pdfs_scan_status", kind),
                                      inline = TRUE)))
      ),
      uiOutput(sprintf("%s_pdfs_scan_errors", kind))
    )

    if (kind == "fallback") {
      # New flow: pick PDFs first (Current grant in PDF), then the
      # registrations + data-availability tables only show findings from
      # the ticked PDFs.
      tagList(
        tags$h4(label),
        common_controls,
        hr(),
        tags$h5("Current grant in PDF"),
        tags$p(tags$small(style = "color:#666",
          "Per PDF: does the current grant's CIHR ID appear in the text? Rows where it does are pre-ticked. ",
          "The registrations and data-availability tables below are filtered to the PDFs ticked here. ",
          "Adding ticks also merges ",
          tags$code("grant_id_in_pdf=TRUE"),
          " into the source paper's row in the matched-works CSV via the linked DOI.")),
        DTOutput("fallback_pdfs_grant_match_table"),
        uiOutput("fallback_pdfs_grant_match_add_ui"),
        hr(),
        tags$h5("Registrations (clinical-trial / systematic-review IDs) — ticked PDFs only"),
        DTOutput("fallback_pdfs_reg_table"),
        uiOutput("fallback_pdfs_reg_add_ui"),
        hr(),
        tags$h5("Data availability (deposits, accessions, repositories) — ticked PDFs only"),
        DTOutput("fallback_pdfs_da_table"),
        uiOutput("fallback_pdfs_da_add_ui")
      )
    } else {
      tagList(
        tags$h4(label),
        common_controls,
        hr(),
        tags$h5("Registrations (clinical-trial / systematic-review IDs)"),
        DTOutput(sprintf("%s_pdfs_reg_table", kind)),
        uiOutput(sprintf("%s_pdfs_reg_add_ui", kind)),
        hr(),
        tags$h5("Data availability (deposits, accessions, repositories)"),
        DTOutput(sprintf("%s_pdfs_da_table", kind)),
        uiOutput(sprintf("%s_pdfs_da_add_ui", kind))
      )
    }
  }
  output$strict_pdfs_tab_content   <- renderUI({ .pdf_tab_ui("strict")   })
  output$fallback_pdfs_tab_content <- renderUI({ .pdf_tab_ui("fallback") })

  # ---- Helpers shared by both new PDF tabs ----

  # Cross-platform "open this folder in the OS file manager" — Finder on
  # macOS, Explorer on Windows, xdg-open on Linux.  Errors are silent
  # (showNotification on failure rather than crashing the reactive).
  .open_folder_in_os <- function(folder) {
    dir.create(folder, recursive = TRUE, showWarnings = FALSE)
    sysname <- Sys.info()[["sysname"]]
    cmd_ok <- tryCatch({
      if (sysname == "Darwin") {
        system2("open", shQuote(folder))
      } else if (.Platform$OS.type == "windows") {
        system2("explorer", shQuote(folder))
      } else {
        system2("xdg-open", shQuote(folder))
      }
      TRUE
    }, error = function(e) FALSE)
    if (!cmd_ok) {
      showNotification(sprintf("Couldn't open folder: %s", folder),
                       type = "warning", duration = 6)
    }
  }

  # Normalise CIHR grant IDs for comparison: strip a leading "PJT-"/"MOP-"
  # /etc. prefix (OpenAlex stores both forms; the PDF detector returns the
  # bare digits) and trim whitespace, lower-cased.  Used to check whether
  # a CIHR grant ID extracted from a fallback PDF matches the current
  # grant's award number.
  .normalize_cihr_id <- function(x) {
    x <- as.character(x)
    x <- toupper(trimws(x))
    x <- sub("^(PJT|MOP|MSH|FRN|HSI|IGH|INMD|IPPH|OOP|CPP|HOA|FDN|SOP|PJ)[\\-\\s]?",
            "", x, perl = TRUE)
    x <- gsub("[^0-9A-Z]", "", x)
    x
  }

  # Render the "manual download needed" panel: rows where auto-download
  # didn't succeed.  Used in both PDF tabs.  `outcome` is the
  # strict_dl_outcome / fallback_dl_outcome tibble stashed on result().
  .manual_dl_panel <- function(outcome, folder) {
    if (is.null(outcome) || nrow(outcome) == 0) {
      return(tags$div(
        class = "alert alert-success",
        tags$strong("No manual downloads needed."),
        " Either everything was downloaded or no rows had OA links."))
    }
    failed <- outcome[!isTRUE(outcome$ok) & !outcome$ok, , drop = FALSE]
    succeeded <- outcome[isTRUE(outcome$ok) | outcome$ok, , drop = FALSE]
    if (nrow(failed) == 0) {
      return(tags$div(
        class = "alert alert-success",
        sprintf("All %d PDFs downloaded automatically.", nrow(succeeded))))
    }
    items <- lapply(seq_len(nrow(failed)), function(i) {
      row <- failed[i, , drop = FALSE]
      title <- if (!is.na(row$title) && nzchar(row$title)) row$title else "(untitled)"
      url   <- row$url %||% NA_character_
      tags$li(
        tags$strong(title),
        if (!is.na(row$doi) && nzchar(row$doi))
          tags$span(style = "margin-left:0.4em;color:#888;font-size:0.85em",
                    tags$code(row$doi)) else NULL,
        if (!is.na(url) && nzchar(url))
          tags$span(style = "margin-left:0.4em",
                    tags$a(href = url, target = "_blank", rel = "noopener",
                           "open PDF link")) else NULL,
        tags$span(class = "badge bg-warning text-dark",
                  style = "margin-left:0.5em",
                  row$reason %||% "fetch failed")
      )
    })
    tags$div(
      class = "alert alert-warning",
      tags$h5(style = "margin-top:0",
              sprintf("%d PDF%s need manual download",
                      nrow(failed), if (nrow(failed) == 1) "" else "s")),
      tags$p(sprintf("%d already downloaded automatically.", nrow(succeeded))),
      tags$ul(items),
      tags$p(tags$small(style = "color:#555",
        "Open each link, save the PDF into the folder shown above (filename can be anything — the matcher uses the DOI in the filename if present), then press ",
        tags$strong("Re-scan folder"), "."))
    )
  }

  # ---- Per-tab scan reactive: enumerates *.pdf in the kind's folder,
  # invokes scan_paper() per file with per-file tryCatch.  Re-fires on
  # `result()` (i.e. after a fresh search auto-download) and on the
  # "Re-scan folder" button.  Returns a list with `scans` (one entry per
  # OK file: list(file, scan)) and `errors` (one entry per failed file:
  # list(file, message)).  An empty folder returns empty lists, never
  # NULL — downstream renderers branch on length(), not is.null().
  .scan_pdfs_in_folder <- function(folder) {
    files <- list.files(folder, pattern = "\\.pdf$",
                        full.names = TRUE, ignore.case = TRUE)
    if (!length(files)) return(list(scans = list(), errors = list(),
                                    total = 0L))
    show_modal_spinner(spin = "atom",
      text = sprintf("Scanning %d PDF%s for registrations + data deposits + funding...",
                     length(files), if (length(files) == 1) "" else "s"))
    on.exit(try(remove_modal_spinner(), silent = TRUE), add = TRUE)
    scans <- list(); errors <- list()
    for (p in files) {
      r <- tryCatch(scan_paper(p), error = function(e) e)
      if (inherits(r, "error")) {
        errors[[length(errors) + 1L]] <- list(file = basename(p),
                                              message = conditionMessage(r))
      } else {
        scans[[length(scans) + 1L]] <- list(file = p, scan = r)
      }
    }
    list(scans = scans, errors = errors, total = length(files))
  }

  strict_pdfs_scan <- eventReactive(
    list(input$strict_pdfs_rescan, result()),
    {
      req(result())
      folder <- file.path(.grant_folder(input$grant,
                                        current_row()$family_name,
                                        current_row()$pi_full_name),
                          "strict_papers")
      .scan_pdfs_in_folder(folder)
    },
    ignoreNULL = FALSE
  )

  fallback_pdfs_scan <- eventReactive(
    list(input$fallback_pdfs_rescan, result()),
    {
      req(result())
      folder <- file.path(.grant_folder(input$grant,
                                        current_row()$family_name,
                                        current_row()$pi_full_name),
                          "fallback_papers")
      .scan_pdfs_in_folder(folder)
    },
    ignoreNULL = FALSE
  )

  # Flatten one tab's scan list into the per-section tibbles consumed by
  # the DT renderers and the add-to-CSV observers.  `linked_doi` is
  # resolved from the filename via match_doi_from_filename() against the
  # combined strict+fallback candidate set.
  .flatten_registrations <- function(scan_list, candidate_dois) {
    out <- lapply(scan_list, function(item) {
      m <- item$scan$registration$matches
      if (is.null(m) || nrow(m) == 0) return(NULL)
      tibble::tibble(
        pdf_file   = basename(item$file),
        linked_doi = match_doi_from_filename(basename(item$file), candidate_dois),
        registry   = m$registry,
        id         = m$id,
        section    = m$section %||% NA_character_,
        sentence   = m$sentence %||% NA_character_,
        anchor     = m$anchor %||% NA_character_,
        confidence = m$confidence %||% NA_character_
      )
    })
    bind_rows(out)
  }

  .flatten_data_availability <- function(scan_list, candidate_dois) {
    out <- lapply(scan_list, function(item) {
      m <- item$scan$data_availability$matches
      if (is.null(m) || nrow(m) == 0) return(NULL)
      tibble::tibble(
        pdf_file   = basename(item$file),
        linked_doi = match_doi_from_filename(basename(item$file), candidate_dois),
        repository = m$repository,
        accession  = m$accession,
        category   = m$category %||% NA_character_,
        section    = m$section %||% NA_character_,
        sentence   = m$sentence %||% NA_character_,
        confidence = m$confidence %||% NA_character_
      )
    })
    bind_rows(out)
  }

  # Per-PDF grant-match summary (fallback tab only).  One row per scanned
  # PDF, regardless of how many CIHR funding statements it contains.
  .summarise_grant_match <- function(scan_list, candidate_dois, current_award) {
    target <- .normalize_cihr_id(current_award)
    out <- lapply(scan_list, function(item) {
      cf <- item$scan$cihr_funding
      gids <- character()
      if (!is.null(cf$matches) && nrow(cf$matches)) {
        gids_col <- cf$matches$grant_ids
        if (is.list(gids_col)) {
          gids <- unique(unlist(gids_col, use.names = FALSE))
        } else if (is.character(gids_col)) {
          gids <- unique(gids_col)
        }
      }
      gids <- gids[!is.na(gids) & nzchar(gids)]
      norm <- .normalize_cihr_id(gids)
      hit  <- length(target) == 1L && nzchar(target) && target %in% norm
      tibble::tibble(
        pdf_file                 = basename(item$file),
        linked_doi               = match_doi_from_filename(basename(item$file),
                                                           candidate_dois),
        grant_id_in_pdf          = isTRUE(hit),
        extracted_cihr_grant_ids = paste(gids, collapse = "; "),
        funded_by_cihr           = isTRUE(cf$funded_by_cihr),
        funding_confidence       = cf$confidence %||% NA_character_
      )
    })
    bind_rows(out)
  }

  # Reactive flatteners (one per (kind, section)).  Compute against the
  # candidate-DOI set so linked_doi resolves correctly.
  strict_pdfs_reg <- reactive({
    s <- strict_pdfs_scan()
    if (length(s$scans) == 0) return(tibble::tibble())
    .flatten_registrations(s$scans, pdf_link_candidates()$doi)
  })
  strict_pdfs_da <- reactive({
    s <- strict_pdfs_scan()
    if (length(s$scans) == 0) return(tibble::tibble())
    .flatten_data_availability(s$scans, pdf_link_candidates()$doi)
  })
  fallback_pdfs_grant_match <- reactive({
    s <- fallback_pdfs_scan()
    if (length(s$scans) == 0) return(tibble::tibble())
    .summarise_grant_match(s$scans, pdf_link_candidates()$doi,
                           result()$award)
  })
  # The set of PDF filenames the user has ticked in the "Current grant
  # in PDF" table.  Drives which PDFs the registrations + data-
  # availability tables on the fallback tab show — empty selection
  # means empty tables.
  fallback_pdfs_selected_files <- reactive({
    tbl <- fallback_pdfs_grant_match()
    if (is.null(tbl) || nrow(tbl) == 0) return(character(0))
    sel <- input$fallback_pdfs_grant_match_rows_selected
    if (is.null(sel) || length(sel) == 0) return(character(0))
    sel <- sel[sel >= 1 & sel <= nrow(tbl)]
    if (length(sel) == 0) return(character(0))
    unique(tbl$pdf_file[sel])
  })
  fallback_pdfs_reg <- reactive({
    s <- fallback_pdfs_scan()
    if (length(s$scans) == 0) return(tibble::tibble())
    keep <- fallback_pdfs_selected_files()
    if (length(keep) == 0) return(tibble::tibble())
    scans <- Filter(function(it) basename(it$file) %in% keep, s$scans)
    if (length(scans) == 0) return(tibble::tibble())
    .flatten_registrations(scans, pdf_link_candidates()$doi)
  })
  fallback_pdfs_da <- reactive({
    s <- fallback_pdfs_scan()
    if (length(s$scans) == 0) return(tibble::tibble())
    keep <- fallback_pdfs_selected_files()
    if (length(keep) == 0) return(tibble::tibble())
    scans <- Filter(function(it) basename(it$file) %in% keep, s$scans)
    if (length(scans) == 0) return(tibble::tibble())
    .flatten_data_availability(scans, pdf_link_candidates()$doi)
  })

  # ---- Per-tab UI outputs (status, manual-DL panel, errors) ------------

  output$strict_pdfs_scan_status <- renderText({
    s <- strict_pdfs_scan()
    if (s$total == 0L) return("No PDFs in folder yet.")
    sprintf("Scanned %d PDF%s (%d errored).",
            s$total, if (s$total == 1) "" else "s", length(s$errors))
  })
  output$fallback_pdfs_scan_status <- renderText({
    s <- fallback_pdfs_scan()
    if (s$total == 0L) return("No PDFs in folder yet.")
    sprintf("Scanned %d PDF%s (%d errored).",
            s$total, if (s$total == 1) "" else "s", length(s$errors))
  })

  output$strict_pdfs_manual_dl_panel <- renderUI({
    req(result())
    folder <- file.path(.grant_folder(input$grant,
                                      current_row()$family_name,
                                      current_row()$pi_full_name),
                        "strict_papers")
    .manual_dl_panel(result()$strict_dl_outcome, folder)
  })
  output$fallback_pdfs_manual_dl_panel <- renderUI({
    req(result())
    folder <- file.path(.grant_folder(input$grant,
                                      current_row()$family_name,
                                      current_row()$pi_full_name),
                        "fallback_papers")
    .manual_dl_panel(result()$fallback_dl_outcome, folder)
  })

  .render_scan_errors <- function(errs) {
    if (length(errs) == 0) return(NULL)
    items <- lapply(errs, function(e) tags$li(tags$code(e$file), ": ", e$message))
    tags$div(class = "alert alert-warning",
             tags$strong(sprintf("%d PDF%s failed to scan",
                                 length(errs),
                                 if (length(errs) == 1) "" else "s")),
             tags$ul(items))
  }
  output$strict_pdfs_scan_errors <- renderUI({
    .render_scan_errors(strict_pdfs_scan()$errors)
  })
  output$fallback_pdfs_scan_errors <- renderUI({
    .render_scan_errors(fallback_pdfs_scan()$errors)
  })

  # ---- DT renderers for the four similar tables (reg + DA, x2 tabs) ----

  .render_pdf_findings_dt <- function(tbl, checkbox_input) {
    if (is.null(tbl) || nrow(tbl) == 0) {
      return(datatable(data.frame(info = "(no findings)"),
                       rownames = FALSE, selection = "none",
                       options = list(dom = "t")))
    }
    # Truncate sentence to a manageable length for the table view
    if ("sentence" %in% names(tbl)) {
      tbl$sentence <- ifelse(
        is.na(tbl$sentence) | !nzchar(tbl$sentence), "",
        ifelse(nchar(tbl$sentence) > 200,
               paste0(substr(tbl$sentence, 1, 200), "…"),
               tbl$sentence))
    }
    # Reuse the strict-tab pattern: pre-tick all rows, opt-out via untick.
    tbl <- cbind(" " = rep("", nrow(tbl)), tbl)
    dt_opts <- list(
      pageLength = 10, scrollX = TRUE,
      select = list(style = "multi", selector = "td:first-child"),
      columnDefs = list(list(orderable = FALSE,
                             className = "select-checkbox",
                             targets = 0, width = "30px"))
    )
    cb <- DT::JS(sprintf(
      "table.on('select deselect', function() {\n  var ids = table.rows({selected:true}).indexes().toArray().map(function(i){ return i + 1; });\n  Shiny.setInputValue('%s', ids, {priority:'event'});\n});\ntable.rows().select();",
      checkbox_input
    ))
    datatable(tbl, escape = FALSE, rownames = FALSE,
              selection = "none", extensions = "Select",
              options = dt_opts, callback = cb)
  }

  output$strict_pdfs_reg_table <- renderDT({
    .render_pdf_findings_dt(strict_pdfs_reg(),
                            "strict_pdfs_reg_rows_selected")
  }, server = FALSE)
  output$strict_pdfs_da_table <- renderDT({
    .render_pdf_findings_dt(strict_pdfs_da(),
                            "strict_pdfs_da_rows_selected")
  }, server = FALSE)
  output$fallback_pdfs_reg_table <- renderDT({
    .render_pdf_findings_dt(fallback_pdfs_reg(),
                            "fallback_pdfs_reg_rows_selected")
  }, server = FALSE)
  output$fallback_pdfs_da_table <- renderDT({
    .render_pdf_findings_dt(fallback_pdfs_da(),
                            "fallback_pdfs_da_rows_selected")
  }, server = FALSE)

  # Grant-match table: pre-tick only rows where grant_id_in_pdf == TRUE.
  output$fallback_pdfs_grant_match_table <- renderDT({
    tbl <- fallback_pdfs_grant_match()
    if (is.null(tbl) || nrow(tbl) == 0) {
      return(datatable(data.frame(info = "(no PDFs scanned yet)"),
                       rownames = FALSE, selection = "none",
                       options = list(dom = "t")))
    }
    pre <- which(isTRUE(tbl$grant_id_in_pdf) | tbl$grant_id_in_pdf == TRUE)
    select_arg <- if (length(pre) > 0) pre else FALSE
    .render_dt(tbl, checkbox = TRUE,
               checkbox_input = "fallback_pdfs_grant_match_rows_selected",
               select_all = select_arg,
               linkcol = "linked_doi")
  }, server = FALSE)

  # ---- "Add ticked rows to CSV" buttons + observers --------------------

  .pdf_findings_add_btn <- function(tbl, btn_id, label) {
    if (is.null(tbl) || nrow(tbl) == 0) return(NULL)
    actionButton(btn_id, label, icon = icon("plus"),
                 class = "btn-outline-primary")
  }
  output$strict_pdfs_reg_add_ui <- renderUI({
    .pdf_findings_add_btn(strict_pdfs_reg(),
                          "strict_pdfs_add_reg",
                          "Add ticked registrations to CSV")
  })
  output$strict_pdfs_da_add_ui <- renderUI({
    .pdf_findings_add_btn(strict_pdfs_da(),
                          "strict_pdfs_add_da",
                          "Add ticked data-availability rows to CSV")
  })
  output$fallback_pdfs_reg_add_ui <- renderUI({
    .pdf_findings_add_btn(fallback_pdfs_reg(),
                          "fallback_pdfs_add_reg",
                          "Add ticked registrations to CSV")
  })
  output$fallback_pdfs_da_add_ui <- renderUI({
    .pdf_findings_add_btn(fallback_pdfs_da(),
                          "fallback_pdfs_add_da",
                          "Add ticked data-availability rows to CSV")
  })
  output$fallback_pdfs_grant_match_add_ui <- renderUI({
    .pdf_findings_add_btn(fallback_pdfs_grant_match(),
                          "fallback_pdfs_add_grant_match",
                          "Add ticked grant-match rows to CSV")
  })

  # Folder-open observers (one per kind).
  observeEvent(input$strict_pdfs_open_folder, {
    req(result())
    folder <- file.path(.grant_folder(input$grant,
                                      current_row()$family_name,
                                      current_row()$pi_full_name),
                        "strict_papers")
    .open_folder_in_os(folder)
  })
  observeEvent(input$fallback_pdfs_open_folder, {
    req(result())
    folder <- file.path(.grant_folder(input$grant,
                                      current_row()$family_name,
                                      current_row()$pi_full_name),
                        "fallback_papers")
    .open_folder_in_os(folder)
  })

  # Build the per-section "ticked rows -> extra_rows() append" handlers.
  # Registrations: linked_doi from filename match; merges via .build_csv_out.
  .pdf_add_registrations <- function(tbl, sel_input, match_class, button_id) {
    sel <- input[[sel_input]]
    if (is.null(sel) || length(sel) == 0) {
      showNotification("No registration rows ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- sel[sel >= 1 & sel <= nrow(tbl)]
    if (length(sel) == 0) return()
    rows <- tbl[sel, , drop = FALSE]
    new_rows <- tibble::tibble(
      source          = rows$registry,
      source_api      = rows$registry,
      match_class     = match_class,
      doi             = NA_character_,
      title           = rows$pdf_file,
      url             = vapply(seq_len(nrow(rows)),
                               function(i) .reg_verify_url(rows$registry[i],
                                                           rows$id[i]) %||% "",
                               character(1)),
      matched_award   = input$grant,
      matched_by      = ifelse(!is.na(rows$anchor) & nzchar(rows$anchor),
                               sprintf("PDF extraction (anchor: %s)", rows$anchor),
                               "PDF extraction (regex)"),
      registration_id = rows$id,
      registry        = rows$registry,
      section         = rows$section,
      sentence        = rows$sentence,
      anchor          = rows$anchor,
      confidence      = rows$confidence,
      pdf_file        = rows$pdf_file,
      linked_doi      = rows$linked_doi
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(sprintf("Added %d registration row%s to CSV.",
                             nrow(new_rows),
                             if (nrow(new_rows) == 1) "" else "s"),
                     type = "message", duration = 4)
  }

  # Data availability: only category in {accession, doi, url} is addable;
  # negative-statement rows are scan signals, not exportable as outputs.
  # Each ticked deposit becomes its own CSV row with linked_doi="" so
  # .build_csv_out's merge logic routes through the unlinked-append branch.
  .pdf_add_data_availability <- function(tbl, sel_input, match_class) {
    sel <- input[[sel_input]]
    if (is.null(sel) || length(sel) == 0) {
      showNotification("No data-availability rows ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- sel[sel >= 1 & sel <= nrow(tbl)]
    if (length(sel) == 0) return()
    rows <- tbl[sel, , drop = FALSE]
    addable <- rows$category %in% c("accession", "doi", "url")
    rows <- rows[addable, , drop = FALSE]
    if (nrow(rows) == 0) {
      showNotification("Ticked rows are negative statements (e.g. \"on request\") — not exportable.",
                       type = "warning", duration = 6)
      return()
    }
    new_rows <- tibble::tibble(
      source          = rows$repository,
      source_api      = rows$repository,
      match_class     = match_class,
      doi             = ifelse(grepl("^10\\.", rows$accession),
                               rows$accession, NA_character_),
      title           = NA_character_,
      url             = vapply(seq_len(nrow(rows)),
                               function(i) .da_verify_url(rows$repository[i],
                                                          rows$accession[i]),
                               character(1)),
      matched_award   = input$grant,
      matched_by      = "PDF extraction (data-availability scan)",
      data_repository = rows$repository,
      data_accession  = rows$accession,
      section         = rows$section,
      sentence        = rows$sentence,
      confidence      = rows$confidence,
      pdf_file        = rows$pdf_file,
      cited_in_doi    = rows$linked_doi,
      linked_doi      = ""
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(sprintf("Added %d data-availability row%s to CSV.",
                             nrow(new_rows),
                             if (nrow(new_rows) == 1) "" else "s"),
                     type = "message", duration = 4)
  }

  # Fallback grant-match: per-PDF flag, merges into the source paper row
  # via linked_doi.  Each ticked row carries grant_id_in_pdf=TRUE plus the
  # extracted CIHR grant IDs string; .build_csv_out picks these up via the
  # PDF_SIGNAL_COLS merge path.
  .pdf_add_grant_match <- function(tbl, sel_input, match_class) {
    sel <- input[[sel_input]]
    if (is.null(sel) || length(sel) == 0) {
      showNotification("No grant-match rows ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- sel[sel >= 1 & sel <= nrow(tbl)]
    if (length(sel) == 0) return()
    rows <- tbl[sel, , drop = FALSE]
    new_rows <- tibble::tibble(
      source           = "PDF text scan",
      source_api       = "pdf_grant_match",
      match_class      = match_class,
      doi              = NA_character_,
      title            = rows$pdf_file,
      url              = NA_character_,
      matched_award    = input$grant,
      matched_by       = "PDF extraction (CIHR grant ID match)",
      pdf_file         = rows$pdf_file,
      linked_doi       = rows$linked_doi,
      grant_id_in_pdf  = rows$grant_id_in_pdf,
      cihr_grant_ids   = rows$extracted_cihr_grant_ids,
      confidence       = rows$funding_confidence
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(sprintf("Added %d grant-match row%s to CSV.",
                             nrow(new_rows),
                             if (nrow(new_rows) == 1) "" else "s"),
                     type = "message", duration = 4)
  }

  observeEvent(input$strict_pdfs_add_reg, {
    .pdf_add_registrations(strict_pdfs_reg(),
                           "strict_pdfs_reg_rows_selected",
                           "strict_pdf_registration",
                           "strict_pdfs_add_reg")
  })
  observeEvent(input$strict_pdfs_add_da, {
    .pdf_add_data_availability(strict_pdfs_da(),
                               "strict_pdfs_da_rows_selected",
                               "strict_pdf_data_deposit")
  })
  observeEvent(input$fallback_pdfs_add_reg, {
    .pdf_add_registrations(fallback_pdfs_reg(),
                           "fallback_pdfs_reg_rows_selected",
                           "fallback_pdf_registration",
                           "fallback_pdfs_add_reg")
  })
  observeEvent(input$fallback_pdfs_add_da, {
    .pdf_add_data_availability(fallback_pdfs_da(),
                               "fallback_pdfs_da_rows_selected",
                               "fallback_pdf_data_deposit")
  })
  observeEvent(input$fallback_pdfs_add_grant_match, {
    .pdf_add_grant_match(fallback_pdfs_grant_match(),
                         "fallback_pdfs_grant_match_rows_selected",
                         "fallback_pdf_grant_match")
  })

  # ---- CSV export ----
  # Location of the last CSV saved for this grant (used for status display).
  last_saved_path <- reactiveVal(NULL)

  # Build the CSV output data frame from the strict and fallback rows the
  # user has ticked, plus any PDF-extracted extras queued for this grant.
  #
  # PDF rows carry a `linked_doi` set by the user in the PDF tab.  When
  # that DOI matches a row already in `out` (a ticked strict/fallback
  # paper), the PDF's signal columns are merged into that row so each
  # paper appears once.  When the linked DOI is in the candidate set
  # but the source row wasn't ticked, a new row is fabricated from the
  # candidate's metadata so the PDF still has full bibliographic
  # context.  Truly unlinked PDFs (or PDFs whose linked DOI is no
  # longer in either set) keep the historical filename-as-title
  # behaviour, appended at the bottom.
  .build_csv_out <- function() {
    r <- result()
    # Use the deduped view when the toggle is on so the CSV mirrors what
    # the user sees and ticks in the Strict tab.
    strict_view <- strict_for_display()
    strict_rows <- bind_rows(lapply(names(.strict_selection_map), function(api) {
      tbl <- strict_view[[api]]
      if (is.null(tbl) || nrow(tbl) == 0) return(NULL)
      sel <- input[[.strict_selection_map[[api]]]]
      # Strict is opt-out: rows are pre-ticked.  Distinguish:
      #   is.null(sel)      -> JS select-all hasn't reached us yet
      #                        (hidden tab, DT init timing, etc.).
      #                        Fall back to "all rows" so the user
      #                        gets the default-ticked behaviour even
      #                        if they download before the input has
      #                        round-tripped.
      #   length(sel) == 0  -> user explicitly unticked every row in
      #                        this bucket.  Honour that, contribute
      #                        nothing.
      #   otherwise         -> respect the user's selection.
      sel <- if (is.null(sel)) {
        seq_len(nrow(tbl))
      } else if (length(sel) == 0) {
        return(NULL)
      } else {
        sel[sel >= 1 & sel <= nrow(tbl)]
      }
      if (length(sel) == 0) return(NULL)
      out <- tbl[sel, , drop = FALSE]
      out$source_api  <- api
      out$match_class <- "strict"
      out
    }))
    fb_sel <- fallback_selected()
    if (!is.null(fb_sel) && nrow(fb_sel)) {
      fb_sel$match_class <- "fallback"
      # `match_type` is a UI-only classifier; drop for CSV parity.
      fb_sel <- fb_sel[, setdiff(names(fb_sel), "match_type"), drop = FALSE]
    }
    out <- bind_rows(strict_rows, fb_sel)
    out$grant_id <- input$grant
    out$pi       <- current_row()$pi_full_name

    er <- extra_rows()
    if (is.null(er) || !nrow(er)) return(out)

    er$grant_id <- input$grant
    er$pi       <- current_row()$pi_full_name
    if (!"linked_doi" %in% names(er)) er$linked_doi <- ""

    # Pre-create signal columns + pdf_match_class on `out` so per-row
    # writes during the merge loop don't trip over missing columns.
    for (col in c(PDF_SIGNAL_COLS, "pdf_match_class")) {
      if (!col %in% names(out)) out[[col]] <- NA_character_
    }

    # Concat helper: drops NA/empty, dedupes, joins with "; ".
    .concat_uniq <- function(vals) {
      vals <- as.character(vals)
      vals <- vals[!is.na(vals) & nzchar(vals)]
      if (!length(vals)) return(NA_character_)
      paste(unique(vals), collapse = "; ")
    }

    has_link <- !is.na(er$linked_doi) & nzchar(er$linked_doi)
    er_linked   <- er[ has_link, , drop = FALSE]
    er_unlinked <- er[!has_link, , drop = FALSE]

    out_doi_lc <- if ("doi" %in% names(out) && nrow(out)) tolower(out$doi)
                  else character(nrow(out))

    if (nrow(er_linked)) {
      cands <- tryCatch(pdf_link_candidates(),
                        error = function(e) tibble::tibble())
      cand_doi_lc <- if ("doi" %in% names(cands) && nrow(cands)) tolower(cands$doi)
                     else character()

      stale <- list()
      keys <- tolower(er_linked$linked_doi)
      for (k in unique(keys)) {
        grp <- er_linked[keys == k, , drop = FALSE]
        idx <- which(!is.na(out_doi_lc) & nzchar(out_doi_lc) & out_doi_lc == k)
        if (length(idx)) {
          ti <- idx[1]
          for (col in PDF_SIGNAL_COLS) {
            existing <- out[[col]][ti]
            incoming <- if (col %in% names(grp)) grp[[col]] else character()
            out[[col]][ti] <- .concat_uniq(c(existing, incoming))
          }
          mc_in <- if ("match_class" %in% names(grp)) grp$match_class else character()
          out[["pdf_match_class"]][ti] <- .concat_uniq(
            c(out[["pdf_match_class"]][ti], mc_in))
        } else {
          ci <- which(!is.na(cand_doi_lc) & cand_doi_lc == k)
          if (length(ci)) {
            cand_row <- cands[ci[1], , drop = FALSE]
            new_row <- cand_row
            new_row$bucket <- NULL
            new_row$match_class   <- "pdf_only"
            new_row$matched_by    <- sprintf("PDF extraction (linked to %s)",
                                              cands$bucket[ci[1]] %||% "row")
            new_row$matched_award <- input$grant
            new_row$grant_id      <- input$grant
            new_row$pi            <- current_row()$pi_full_name
            for (col in PDF_SIGNAL_COLS) {
              incoming <- if (col %in% names(grp)) grp[[col]] else character()
              new_row[[col]] <- .concat_uniq(incoming)
            }
            mc_in <- if ("match_class" %in% names(grp)) grp$match_class else character()
            new_row[["pdf_match_class"]] <- .concat_uniq(mc_in)
            out <- bind_rows(out, new_row)
            out_doi_lc <- c(out_doi_lc, k)
          } else {
            # Stale link (candidate set changed since user added row,
            # or DOI never existed).  Fall through to unlinked branch.
            stale[[length(stale) + 1L]] <- grp
          }
        }
      }

      if (length(stale)) {
        er_unlinked <- bind_rows(er_unlinked, bind_rows(stale))
      }
    }

    if (nrow(er_unlinked)) out <- bind_rows(out, er_unlinked)

    # Preprint enrichment: fill venue / is_oa / oa_status for any row
    # whose DOI prefix is a known preprint server but whose upstream
    # metadata left these fields empty (Europe PMC frequently does
    # this for bioRxiv/medRxiv records).  Preprints are author-self-
    # archived, so green OA by definition.
    if ("doi" %in% names(out) && nrow(out)) {
      pp <- .preprint_venue_from_doi(out$doi)
      pp_hit <- !is.na(pp)
      if (any(pp_hit)) {
        if (!"venue" %in% names(out)) out$venue <- NA_character_
        if (!"is_oa" %in% names(out)) out$is_oa <- NA
        if (!"oa_status" %in% names(out)) out$oa_status <- NA_character_
        v_missing <- is.na(out$venue) | !nzchar(as.character(out$venue))
        out$venue[pp_hit & v_missing] <- pp[pp_hit & v_missing]
        # Vectorised "not already TRUE": NA or FALSE both qualify.
        is_oa_lgl <- suppressWarnings(as.logical(out$is_oa))
        oa_missing <- is.na(is_oa_lgl) | !is_oa_lgl
        out$is_oa[pp_hit & oa_missing] <- TRUE
        st_missing <- is.na(out$oa_status) |
                      !nzchar(as.character(out$oa_status))
        out$oa_status[pp_hit & st_missing] <- "green"
      }
    }

    # Internal handoff column — not informative in the CSV.
    out$linked_doi <- NULL
    out
  }

  .perform_csv_write <- function() {
    req(result(), input$grant)
    folder <- .grant_folder(input$grant,
                            current_row()$family_name,
                            current_row()$pi_full_name)
    file_path <- file.path(folder, sprintf("cihr_%s_linked_works.csv", input$grant))
    out <- .build_csv_out()
    write.csv(out, file_path, row.names = FALSE)
    last_saved_path(file_path)
    showNotification(
      sprintf("Saved %d row%s to %s",
              nrow(out), if (nrow(out) == 1) "" else "s", file_path),
      type = "message", duration = 8
    )
  }

  observeEvent(input$dl_csv, {
    req(result(), input$grant)
    folder <- .grant_folder(input$grant,
                            current_row()$family_name,
                            current_row()$pi_full_name)
    file_path <- file.path(folder, sprintf("cihr_%s_linked_works.csv", input$grant))
    if (file.exists(file_path)) {
      showModal(modalDialog(
        title = "CSV already exists",
        tags$p("A CSV already exists at:"),
        tags$pre(file_path),
        tags$p("Overwrite with the current results?"),
        footer = tagList(
          modalButton("No"),
          actionButton("confirm_overwrite", "Yes, overwrite",
                       class = "btn-primary")
        ),
        easyClose = FALSE
      ))
    } else {
      .perform_csv_write()
    }
  })

  observeEvent(input$confirm_overwrite, {
    removeModal()
    .perform_csv_write()
  })

  output$dl_status <- renderText({
    p <- last_saved_path()
    if (is.null(p)) "" else sprintf("Last saved: %s", p)
  })

  # ---- Exit app ----
  # If a search has run and the CSV hasn't been saved yet, prompt
  # before exiting.  `last_saved_path()` is reset to NULL whenever a
  # new search starts, so it correctly tracks "since the most recent
  # search".  If no search has run, just exit — there's nothing to
  # save.
  observeEvent(input$exit_app, {
    if (!is.null(result()) && is.null(last_saved_path())) {
      showModal(modalDialog(
        title = "Save CSV before exiting?",
        tags$p("You haven't saved the matched-works CSV for this grant yet."),
        tags$p(tags$small(style = "color:#666",
                          "If you exit now, your row selections will be lost.")),
        footer = tagList(
          modalButton("Cancel"),
          actionButton("exit_quit_no_save", "Exit without saving",
                       class = "btn-outline-danger"),
          actionButton("exit_save_then_quit", "Save CSV and exit",
                       class = "btn-primary")
        ),
        easyClose = FALSE
      ))
    } else {
      stopApp()
    }
  })

  observeEvent(input$exit_save_then_quit, {
    removeModal()
    # Skip the overwrite-confirmation modal flow: the user has just
    # explicitly chosen "save and exit", so silently overwrite.
    .perform_csv_write()
    stopApp()
  })

  observeEvent(input$exit_quit_no_save, {
    removeModal()
    stopApp()
  })
}

shinyApp(ui, server)
