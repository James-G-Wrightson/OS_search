if (!requireNamespace("pacman", quietly = TRUE)) {
  install.packages("pacman", repos = "https://cloud.r-project.org")
}
suppressPackageStartupMessages({
  pacman::p_load(shiny, bslib, DT, dplyr, stringr, shinybusy,
                 purrr, httr2, tibble, jsonlite)
})

source("R/data_loader.R")
source("R/api_clients.R")
source("R/pdf_convert.R")
source("R/similarity.R")

PG <- load_project_grants()
UG <- unique_grants(PG)

# Ensure the local Python venv used by the PDF extraction tab is
# ready. On failure (Python too old, venv create or pip install broken),
# the UI degrades the PDF tab to an explanatory alert instead of crashing.
PDF_VENV_STATUS <- ensure_pdf_venv()

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
    uiOutput("grant_info")
  ),

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
      p("These works explicitly cite the CIHR grant number in the funding metadata of Crossref/OpenAlex/DataCite, or mention the award number in ClinicalTrials.gov."),
      tags$p(tags$small(style = "color:#666",
        tags$strong("Tick rows"), " to include them in the matched-works CSV download. Unticked strict rows are ignored by the exporter.")),
      h5("OpenAlex works"),   DTOutput("strict_oa"),
      h5("Crossref works"),   DTOutput("strict_cr"),
      h5("DataCite records"), DTOutput("strict_dc"),
      h5("ClinicalTrials.gov"), DTOutput("strict_ct"),
      h5("Europe PMC"),       DTOutput("strict_epmc")
    ),
    nav_panel(
      "Fallback match (PI / ORCID / keywords)",
      p("Broader search. Useful when the PI didn't acknowledge the award ID, or when the output (e.g. a trial registration, a dataset) doesn't carry grant metadata. Human review required."),
      uiOutput("fallback_header"),
      hr(),
      fluidRow(
        column(6, radioButtons(
          "fb_sources", "Source (one at a time)",
          choices = c("OpenAlex", "Crossref", "DataCite",
                      "ClinicalTrials.gov", "OpenAIRE", "Europe PMC"),
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
          value = 0.00, min = 0, max = 1, step = 0.05, width = "120px"
        ))
      ),
      tags$p(tags$small(style = "color:#666",
        tags$strong("Tick rows"), " to include them in the matched-works CSV download. Unticked fallback rows are ignored by the exporter.")),
      DTOutput("fb_table")
    ),
    nav_panel(
      "PDF extraction",
      uiOutput("pdf_tab_content")
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
                         checkbox = FALSE, checkbox_input = NULL) {
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
      tbl$oa_pdf_url <- ifelse(
        is.na(tbl$oa_pdf_url) | tbl$oa_pdf_url == "",
        '<span style="color:#999">—</span>',
        sprintf('<a href="%s" target="_blank" rel="noopener" title="Direct OA PDF">PDF ⬇</a>',
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
      dt_cb <- DT::JS(sprintf(
        "table.on('select deselect', function() {\n  var ids = table.rows({selected:true}).indexes().toArray().map(function(i){ return i + 1; });\n  Shiny.setInputValue('%s', ids, {priority:'event'});\n});",
        input_name
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
    checkbox = TRUE, checkbox_input = "strict_oa_rows_selected") }, server = FALSE)
  output$strict_cr <- renderDT({ req(result()); .render_dt(strict_for_display()$crossref,
    checkbox = TRUE, checkbox_input = "strict_cr_rows_selected") }, server = FALSE)
  output$strict_dc <- renderDT({ req(result()); .render_dt(strict_for_display()$datacite,
    checkbox = TRUE, checkbox_input = "strict_dc_rows_selected") }, server = FALSE)
  output$strict_ct <- renderDT({ req(result()); .render_dt(strict_for_display()$ctgov,
    checkbox = TRUE, checkbox_input = "strict_ct_rows_selected") }, server = FALSE)
  output$strict_epmc <- renderDT({ req(result()); .render_dt(strict_for_display()$europepmc,
    checkbox = TRUE, checkbox_input = "strict_epmc_rows_selected") }, server = FALSE)

  # Map from strict-source key to its checkbox input name, used by the CSV
  # builder to filter each API's tibble to the ticked rows only.
  .strict_selection_map <- c(
    openalex  = "strict_oa_rows_selected",
    crossref  = "strict_cr_rows_selected",
    datacite  = "strict_dc_rows_selected",
    ctgov     = "strict_ct_rows_selected",
    europepmc = "strict_epmc_rows_selected"
  )

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
    .render_dt(tbl, checkbox = TRUE,
               checkbox_input = "fb_table_rows_selected")
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

  # ---- PDF -> Registration + Data-availability detection ----
  reg_result <- reactiveVal(NULL)   # registration extractor JSON
  da_result  <- reactiveVal(NULL)   # data-availability extractor JSON
  cf_result  <- reactiveVal(NULL)   # CIHR-funding extractor JSON
  reg_name   <- reactiveVal(NULL)   # uploaded PDF basename
  scan_chars <- reactiveVal(NULL)   # markdown char count for status line

  # Wrap a card's inner content with a left-aligned tick box so the user
  # can pick which matches get appended to the matched-works CSV.
  # Default is ticked, matching the previous "add all" behaviour, so the
  # existing flow works unchanged if the user doesn't touch the boxes.
  .card_with_tick <- function(cb_id, card_body,
                              stripe_color = "#0a7d2f",
                              bg_color = "#f4f8f4") {
    tags$div(
      style = sprintf(
        "display:flex; align-items:flex-start; gap:0.25em; margin-bottom:1em; padding:0.85em 1em; border-left:4px solid %s; background:%s; border-radius:3px",
        stripe_color, bg_color
      ),
      tags$div(
        style = "flex:0 0 auto; margin-top:-0.25em;",
        tags$div(
          class = "form-check",
          style = "min-height:1em; padding-left:1.25em",
          tags$input(
            type = "checkbox", id = cb_id, class = "form-check-input",
            checked = NA,
            # Drive the Shiny input; ensures the value is available
            # before the first tick event.
            onchange = sprintf(
              "Shiny.setInputValue('%s', this.checked, {priority:'event'});",
              cb_id
            )
          )
        )
      ),
      tags$div(style = "flex:1; min-width:0", card_body)
    )
  }

  # Read current tick state for rows of a given prefix.
  # `default_selected` is the value returned when a tick box hasn't been
  # touched yet — since checkboxes render checked, we treat untouched as
  # selected, matching the visual state.
  .ticked_rows <- function(prefix, n, default_selected = TRUE) {
    if (!is.numeric(n) || n <= 0) return(integer())
    keep <- vapply(seq_len(n), function(i) {
      v <- input[[sprintf("%s_%d", prefix, i)]]
      if (is.null(v)) default_selected else isTRUE(v)
    }, logical(1))
    which(keep)
  }
  # Extra rows harvested from PDF scans, appended to the CSV download
  # when the user clicks one of the "Add to matched works" buttons.
  # Keyed on grant_id so switching grants clears the buffer.
  extra_rows <- reactiveVal(tibble::tibble())

  # Clear previous result when a new file is picked
  observeEvent(input$pdf_file, {
    reg_result(NULL)
    da_result(NULL)
    cf_result(NULL)
    reg_name(NULL)
    scan_chars(NULL)
  })

  # Clear all PDF state (and the extra-rows buffer) whenever a new grant
  # search is kicked off, so the PDF tab is always scoped to the
  # currently-loaded grant result.
  observeEvent(search_trigger(), {
    reg_result(NULL)
    da_result(NULL)
    cf_result(NULL)
    reg_name(NULL)
    scan_chars(NULL)
    extra_rows(tibble::tibble())
    last_saved_path(NULL)
  }, ignoreInit = TRUE)

  # Gating: the PDF tab is only usable after the user has run a grant
  # search. search_trigger() increments once per confirmed search.
  output$pdf_tab_content <- renderUI({
    # Hard-block when the Python venv couldn't be bootstrapped at startup:
    # scanning would just error out with an unhelpful R stack trace.
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
                 " before using the PDF registration scanner. "
                 ,"PDF-extracted registrations can then be added to this grant's matched-works CSV download.")
        )
      ))
    }
    tagList(
      p("Upload a research paper PDF linked to grant ",
        tags$code(input$grant %||% ""),
        ". The app extracts text fully locally (",
        tags$code("pymupdf4llm"),
        ") and scans for three things: (1) whether the paper is ",
        tags$strong("funded by CIHR"),
        " (only a funded-by declaration counts — passing CIHR mentions are ignored), (2) clinical-trial or systematic-review ",
        tags$strong("registration identifiers"),
        " (NCT, ISRCTN, EudraCT, PROSPERO, ...), and (3) ",
        tags$strong("data-availability statements / public repository deposits"),
        " (GEO, SRA, PRIDE, Zenodo, Dryad, OSF, ...). No LLM, no network; nothing leaves this machine."),
      fluidRow(
        column(8,
          fileInput("pdf_file", "PDF file", accept = c("application/pdf", ".pdf"),
                    buttonLabel = "Browse...", placeholder = "No file selected"),
          actionButton("pdf_detect", "Scan paper", class = "btn-primary"),
          tags$span(style = "margin-left:1em", textOutput("pdf_status", inline = TRUE))
        )
      ),
      hr(),
      tags$h5("CIHR funding"),
      uiOutput("cihr_funding_result"),
      uiOutput("cihr_funding_add_ui"),
      hr(),
      tags$h5("Registration"),
      uiOutput("registration_result"),
      uiOutput("registration_add_ui"),
      hr(),
      tags$h5("Data availability"),
      uiOutput("data_availability_result"),
      uiOutput("data_availability_add_ui")
    )
  })

  observeEvent(input$pdf_detect, {
    f <- input$pdf_file
    if (is.null(f)) {
      showNotification("Pick a PDF first.", type = "warning")
      return()
    }
    try(show_modal_spinner(spin = "atom",
                           text = "Extracting text and scanning for registrations + data deposits (local, no network)..."),
        silent = TRUE)
    ok <- TRUE
    res <- tryCatch(scan_paper(f$datapath),
                    error = function(e) { ok <<- FALSE; conditionMessage(e) })
    try(remove_modal_spinner(), silent = TRUE)
    if (!ok) {
      showNotification(paste("Scan failed:", res), type = "error", duration = 10)
      return()
    }
    reg_result(res$registration)
    da_result(res$data_availability)
    cf_result(res$cihr_funding)
    reg_name(f$name)
    scan_chars(res$markdown_chars)
  })

  output$pdf_status <- renderText({
    n <- scan_chars()
    if (is.null(n)) return("")
    sprintf("Scanned %s characters of extracted text.",
            format(n, big.mark = ","))
  })

  # Build a verification URL for a given registry + id.
  .reg_verify_url <- function(registry, id) {
    switch(registry,
      "ClinicalTrials.gov" = sprintf("https://clinicaltrials.gov/study/%s", id),
      "ISRCTN"             = sprintf("https://www.isrctn.com/%s", id),
      "EudraCT"            = sprintf("https://www.clinicaltrialsregister.eu/ctr-search/search?query=%s", id),
      "ANZCTR"             = sprintf("https://www.anzctr.org.au/Trial/Registration/TrialReview.aspx?id=%s", sub("^ACTRN", "", id)),
      "ChiCTR"             = sprintf("https://www.chictr.org.cn/showproj.html?proj=%s", id),
      "DRKS"               = sprintf("https://drks.de/search/en/trial/%s", id),
      "UMIN"               = sprintf("https://center6.umin.ac.jp/cgi-open-bin/ctr_e/ctr_view.cgi?recptno=%s", id),
      "jRCT"               = sprintf("https://jrct.niph.go.jp/latest-detail/%s", id),
      "CTRI"               = "http://ctri.nic.in/Clinicaltrials/advsearchmain.php",
      "IRCT"               = sprintf("https://en.irct.ir/search/result?query=%s", id),
      "PACTR"              = sprintf("https://pactr.samrc.ac.za/TrialDisplay.aspx?TrialID=%s", sub("^PACTR", "", id)),
      "ReBec"              = "https://ensaiosclinicos.gov.br/",
      "KCT"                = sprintf("https://cris.nih.go.kr/cris/search/detailSearch.do?seq=&search_lang=E&search_type=2&trnNo=%s", id),
      "NTR"                = "https://onderzoekmetmensen.nl/en/trial",
      "WHO UTN"            = "https://trialsearch.who.int/",
      "PROSPERO"           = sprintf("https://www.crd.york.ac.uk/prospero/display_record.php?RecordID=%s",
                                     sub("^CRD", "", id)),
      "INPLASY"            = sprintf("https://inplasy.com/?s=%s", id),
      "OSF"                = if (startsWith(id, "10.17605/")) paste0("https://doi.org/", id)
                             else paste0("https://", id),
      "Research Registry"  = sprintf("https://www.researchregistry.com/browse-the-registry#home/registrationdetails/%s/", id),
      NULL
    )
  }

  # Render a sentence with the matched ID highlighted.
  .highlight_sentence <- function(sentence, id) {
    if (is.null(sentence) || is.na(sentence) || !nzchar(sentence)) return("")
    # Escape for HTML display
    esc <- function(s) htmltools::htmlEscape(s)
    # Build a loose regex to find the ID even if the printed form has
    # whitespace/dash scatter (the extractor already normalised `id`, but
    # the raw sentence still holds the typeset form).
    id_tokens <- strsplit(id, "")[[1]]
    # Allow optional whitespace or dash between characters
    loose <- paste0(vapply(id_tokens, function(ch) {
      if (grepl("[[:alnum:]]", ch)) paste0("[\\s\\-]*", gsub("([][{}().+*?|^$\\\\])", "\\\\\\1", ch))
      else gsub("([][{}().+*?|^$\\\\])", "\\\\\\1", ch)
    }, character(1)), collapse = "")
    pat <- paste0("(?i)", sub("^\\[\\\\s\\\\-\\]\\*", "", loose))
    out <- tryCatch(
      sub(pat, sprintf('<mark>%s</mark>', esc(id)),
          esc(sentence), perl = TRUE),
      error = function(e) esc(sentence)
    )
    # If the regex replace didn't hit (rare), fall back to plain id replace
    if (identical(out, esc(sentence))) {
      out <- sub(esc(id), sprintf('<mark>%s</mark>', esc(id)),
                 esc(sentence), fixed = TRUE)
    }
    out
  }

  output$cihr_funding_result <- renderUI({
    cf <- cf_result()
    if (is.null(cf)) {
      return(tags$p(tags$em("Upload a PDF and press ", tags$b("Scan paper"),
                            " to check whether this paper was funded by CIHR.")))
    }

    if (!isTRUE(cf$funded_by_cihr) || is.null(cf$matches) ||
        nrow(cf$matches) == 0L) {
      return(tagList(
        tags$div(
          class = "alert alert-warning",
          tags$h4(style = "margin-top:0", "Not funded by CIHR (or no CIHR funding declaration found)"),
          tags$p("No funded-by declaration naming CIHR or the Canadian Institutes of Health Research was detected in ",
                 tags$b(reg_name() %||% "this paper"), ".",
                 " Passing CIHR mentions (author disclosures, framework references, papers studied) are intentionally ignored.")
        )
      ))
    }

    conf_badge <- function(c) {
      cls <- switch(c,
        "high"   = "bg-success",
        "medium" = "bg-secondary",
        "low"    = "bg-warning text-dark",
        "bg-secondary")
      tags$span(class = paste("badge", cls),
                style = "margin-left:0.5em", paste0(c, " confidence"))
    }

    cards <- lapply(seq_len(nrow(cf$matches)), function(i) {
      m <- cf$matches[i, , drop = FALSE]
      gids <- if ("grant_ids" %in% names(m)) m$grant_ids[[1]] else character()
      if (is.null(gids) || length(gids) == 0) gids <- character()
      sentence_html <- htmltools::htmlEscape(m$sentence %||% "")
      # Highlight the CIHR mention (case-insensitive).
      sentence_html <- gsub(
        "(CIHR|Canadian Institutes? (of|for) Health Research)",
        "<mark>\\1</mark>", sentence_html, perl = TRUE
      )
      .card_with_tick(
        cb_id = sprintf("cf_sel_%d", i),
        card_body = tagList(
          tags$div(
            tags$strong(sprintf("Evidence (%s)", m$category %||% "")),
            conf_badge(m$confidence %||% "medium"),
            if (length(gids))
              tags$span(style = "margin-left:0.5em;color:#888;font-size:0.85em",
                        sprintf("grant id(s): %s", paste(gids, collapse = ", ")))
            else NULL
          ),
          tags$div(style = "margin-top:0.35em;color:#666;font-size:0.85em",
                   sprintf("Found in section: %s", m$section %||% "body")),
          tags$blockquote(
            style = "margin:0.6em 0 0 0;padding:0.5em 0.8em;border-left:2px solid #ccc;background:#fff;font-size:0.92em",
            HTML(sentence_html)
          )
        )
      )
    })

    tagList(
      tags$div(
        class = "alert alert-success",
        tags$h4(style = "margin-top:0",
                sprintf("Funded by CIHR (%s confidence)", cf$confidence)),
        tags$p(sprintf("%d funding-statement match%s extracted from %s.",
                       cf$match_count,
                       if (cf$match_count == 1) "" else "es",
                       reg_name() %||% "this paper"))
      ),
      cards
    )
  })

  output$registration_result <- renderUI({
    r <- reg_result()
    if (is.null(r)) {
      return(tags$p(tags$em("Upload a PDF and press ", tags$b("Detect registration"),
                            " to see results here.")))
    }

    # No matches -> clear, distinct "none found" message.
    if (!isTRUE(r$is_registered) || is.null(r$matches) ||
        nrow(r$matches) == 0L) {
      return(tagList(
        tags$div(
          class = "alert alert-warning",
          tags$h4(style = "margin-top:0", "No registration detected"),
          tags$p("No clinical-trial or systematic-review registration identifier was found in ",
                 tags$b(reg_name() %||% "this paper"), ".")
        ),
        tags$p(tags$small(style = "color:#888",
          "Registries scanned: ClinicalTrials.gov (NCT), ISRCTN, EudraCT, ACTRN, ChiCTR, DRKS, UMIN, jRCT, CTRI, IRCT, PACTR, ReBec, KCT, NTR, WHO UTN, PROSPERO (CRD), INPLASY, OSF, Research Registry."))
      ))
    }

    hint_label <- switch(r$study_type_hint,
      "trial"             = "Clinical-trial registration detected",
      "systematic_review" = "Systematic-review registration detected",
      "mixed"             = "Multiple registration types detected",
      "Registration detected"
    )

    match_cards <- lapply(seq_len(nrow(r$matches)), function(i) {
      m <- r$matches[i, , drop = FALSE]
      url <- .reg_verify_url(m$registry, m$id)
      conf_badge <- if (identical(m$confidence, "high"))
        tags$span(class = "badge bg-success", style = "margin-left:0.5em", "high confidence")
      else
        tags$span(class = "badge bg-secondary", style = "margin-left:0.5em", "medium confidence")
      anchor_badge <- if (!is.null(m$anchor) && !is.na(m$anchor) && nzchar(m$anchor))
        tags$span(style = "margin-left:0.5em;color:#888;font-size:0.85em",
                  sprintf("anchor: \u201c%s\u201d", m$anchor))
      else NULL

      .card_with_tick(
        cb_id = sprintf("reg_sel_%d", i),
        card_body = tagList(
          tags$div(
            tags$strong(m$registry),
            tags$code(m$id, style = "margin-left:0.5em;font-size:1em;color:#0a5a20"),
            conf_badge,
            anchor_badge
          ),
          tags$div(style = "margin-top:0.35em;color:#666;font-size:0.85em",
                   sprintf("Found in section: %s", m$section %||% "body")),
          tags$blockquote(
            style = "margin:0.6em 0 0 0;padding:0.5em 0.8em;border-left:2px solid #ccc;background:#fff;font-size:0.92em",
            HTML(.highlight_sentence(m$sentence, m$id))
          ),
          if (!is.null(url) && nzchar(url))
            tags$div(style = "margin-top:0.4em;font-size:0.85em",
                     tags$a(href = url, target = "_blank", rel = "noopener",
                            sprintf("verify on %s \u2197", m$registry)))
          else NULL
        )
      )
    })

    tagList(
      tags$div(
        class = "alert alert-success",
        tags$h4(style = "margin-top:0", hint_label),
        tags$p(sprintf("%d identifier%s extracted from %s.",
                       r$match_count,
                       if (r$match_count == 1) "" else "s",
                       reg_name() %||% "this paper"))
      ),
      match_cards
    )
  })

  # "Add to matched works" button + status - only rendered when there
  # is at least one detected registration for the current paper. Only
  # the ticked rows on the card list are written; the selection-status
  # line next to the button previews how many the click will send.
  output$registration_add_ui <- renderUI({
    r <- reg_result()
    if (is.null(r) || !isTRUE(r$is_registered) || is.null(r$matches) ||
        nrow(r$matches) == 0L) return(NULL)
    already <- 0L
    er <- extra_rows()
    if (!is.null(er) && nrow(er) && "pdf_file" %in% names(er)) {
      already <- sum(er$pdf_file == (reg_name() %||% ""))
    }
    tagList(
      hr(),
      actionButton("pdf_add_to_csv",
                   if (already > 0L)
                     sprintf("Already added (%d) \u2013 add ticked rows again", already)
                   else
                     sprintf("Add ticked registration row%s to matched-works CSV",
                             if (r$match_count == 1) "" else "s"),
                   icon = icon("plus"),
                   class = "btn-outline-primary"),
      tags$span(style = "margin-left:1em;color:#555",
                textOutput("registration_selection_status", inline = TRUE)),
      tags$span(style = "margin-left:1em;color:#555",
                textOutput("csv_buffer_status", inline = TRUE))
    )
  })

  output$registration_selection_status <- renderText({
    r <- reg_result()
    if (is.null(r) || is.null(r$matches) || nrow(r$matches) == 0L) return("")
    sel <- .ticked_rows("reg_sel", nrow(r$matches))
    sprintf("%d of %d ticked", length(sel), nrow(r$matches))
  })

  output$csv_buffer_status <- renderText({
    er <- extra_rows()
    if (is.null(er) || !nrow(er)) return("")
    sprintf("%d PDF-sourced row%s queued for this grant's CSV.",
            nrow(er), if (nrow(er) == 1) "" else "s")
  })

  observeEvent(input$pdf_add_to_csv, {
    r <- reg_result()
    if (is.null(r) || is.null(r$matches) || nrow(r$matches) == 0L) return()
    req(input$grant)
    sel_idx <- .ticked_rows("reg_sel", nrow(r$matches))
    if (length(sel_idx) == 0L) {
      showNotification("No registration rows are ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- r$matches[sel_idx, , drop = FALSE]
    pdf_fn <- reg_name() %||% ""
    new_rows <- tibble::tibble(
      source          = sel$registry,
      source_api      = sel$registry,
      match_class     = "pdf_registration",
      doi             = NA_character_,
      title           = pdf_fn,
      url             = vapply(seq_len(nrow(sel)),
                               function(i) .reg_verify_url(sel$registry[i],
                                                           sel$id[i]) %||% "",
                               character(1)),
      matched_award   = input$grant,
      matched_by      = ifelse(!is.na(sel$anchor) & nzchar(sel$anchor),
                               sprintf("PDF extraction (anchor: %s)", sel$anchor),
                               "PDF extraction (regex)"),
      registration_id = sel$id,
      registry        = sel$registry,
      section         = sel$section,
      sentence        = sel$sentence,
      anchor          = sel$anchor,
      confidence      = sel$confidence,
      pdf_file        = pdf_fn
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(
      sprintf("Added %d registration row%s to this grant's CSV download.",
              nrow(new_rows), if (nrow(new_rows) == 1) "" else "s"),
      type = "message", duration = 4
    )
  })

  # ---- CIHR funding: add to CSV ----
  # CIHR-funding matches are evidence that the PDF is linked to a CIHR
  # grant, so ticked rows can be appended to the matched-works CSV as
  # `pdf_cihr_funding` entries (mirrors the pdf_registration /
  # pdf_data_deposit flow).
  output$cihr_funding_add_ui <- renderUI({
    cf <- cf_result()
    if (is.null(cf) || !isTRUE(cf$funded_by_cihr) ||
        is.null(cf$matches) || nrow(cf$matches) == 0L) return(NULL)
    tagList(
      actionButton("pdf_add_cf_to_csv",
                   "Add ticked CIHR-funding rows to matched-works CSV",
                   icon = icon("plus"),
                   class = "btn-outline-primary"),
      tags$span(style = "margin-left:1em;color:#555",
                textOutput("cf_selection_status", inline = TRUE))
    )
  })

  output$cf_selection_status <- renderText({
    cf <- cf_result()
    if (is.null(cf) || is.null(cf$matches) || nrow(cf$matches) == 0L) return("")
    sel <- .ticked_rows("cf_sel", nrow(cf$matches))
    sprintf("%d of %d ticked", length(sel), nrow(cf$matches))
  })

  observeEvent(input$pdf_add_cf_to_csv, {
    cf <- cf_result()
    if (is.null(cf) || is.null(cf$matches) || nrow(cf$matches) == 0L) return()
    req(input$grant)
    sel_idx <- .ticked_rows("cf_sel", nrow(cf$matches))
    if (length(sel_idx) == 0L) {
      showNotification("No CIHR-funding rows are ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- cf$matches[sel_idx, , drop = FALSE]
    pdf_fn <- reg_name() %||% ""
    # Flatten grant_ids list-column to a semicolon-separated string for CSV.
    gids_str <- vapply(seq_len(nrow(sel)), function(i) {
      g <- if ("grant_ids" %in% names(sel)) sel$grant_ids[[i]] else character()
      if (is.null(g) || length(g) == 0) NA_character_ else paste(g, collapse = "; ")
    }, character(1))
    new_rows <- tibble::tibble(
      source          = "PDF (CIHR funding)",
      source_api      = "pdf_cihr_funding",
      match_class     = "pdf_cihr_funding",
      doi             = NA_character_,
      title           = pdf_fn,
      url             = NA_character_,
      matched_award   = input$grant,
      matched_by      = sprintf("PDF extraction (%s)", sel$category),
      registration_id = NA_character_,
      registry        = NA_character_,
      section         = sel$section,
      sentence        = sel$sentence,
      anchor          = NA_character_,
      confidence      = sel$confidence,
      cihr_grant_ids  = gids_str,
      pdf_file        = pdf_fn
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(
      sprintf("Added %d CIHR-funding row%s to this grant's CSV download.",
              nrow(new_rows), if (nrow(new_rows) == 1) "" else "s"),
      type = "message", duration = 4
    )
  })

  # ---- Data-availability rendering ----
  .da_verify_url <- function(repository, accession) {
    if (is.null(accession) || is.na(accession) || !nzchar(accession)) return("")
    # If accession is already a URL, use it
    if (grepl("^https?://", accession)) return(accession)
    # If accession looks like a DOI, resolve via doi.org
    if (grepl("^10\\.", accession)) return(paste0("https://doi.org/", accession))
    switch(repository,
      "GEO"               = sprintf("https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=%s", accession),
      "SRA"               = sprintf("https://www.ncbi.nlm.nih.gov/sra/?term=%s", accession),
      "BioProject"        = sprintf("https://www.ncbi.nlm.nih.gov/bioproject/?term=%s", accession),
      "BioSample"         = sprintf("https://www.ncbi.nlm.nih.gov/biosample/?term=%s", accession),
      "ArrayExpress"      = sprintf("https://www.ebi.ac.uk/biostudies/arrayexpress/studies/%s", accession),
      "BioStudies"        = sprintf("https://www.ebi.ac.uk/biostudies/studies/%s", accession),
      "PRIDE"             = sprintf("https://www.ebi.ac.uk/pride/archive/projects/%s", accession),
      "MassIVE"           = sprintf("https://massive.ucsd.edu/ProteoSAFe/QueryMSV?id=%s", accession),
      "MetaboLights"      = sprintf("https://www.ebi.ac.uk/metabolights/%s", accession),
      "dbGaP"             = sprintf("https://www.ncbi.nlm.nih.gov/projects/gap/cgi-bin/study.cgi?study_id=%s", accession),
      "EGA"               = sprintf("https://ega-archive.org/studies/%s", accession),
      "RefSeq"            = sprintf("https://www.ncbi.nlm.nih.gov/nuccore/%s", accession),
      "Assembly"          = sprintf("https://www.ncbi.nlm.nih.gov/assembly/%s", accession),
      "ClinVar"           = sprintf("https://www.ncbi.nlm.nih.gov/clinvar/variation/%s",
                                    sub("^[VS]CV0*", "", accession)),
      "ChEMBL"            = sprintf("https://www.ebi.ac.uk/chembl/explore/compound/%s", accession),
      "EMPIAR"            = sprintf("https://www.ebi.ac.uk/empiar/%s", accession),
      "EMDB"              = sprintf("https://www.ebi.ac.uk/emdb/%s", sub("^EMDB-", "EMD-", accession)),
      "PDB"               = sprintf("https://www.rcsb.org/structure/%s", accession),
      "UniProt"           = sprintf("https://www.uniprot.org/uniprotkb/%s", accession),
      "OpenNeuro"         = sprintf("https://openneuro.org/datasets/%s", accession),
      "Synapse"           = sprintf("https://www.synapse.org/#!Synapse:%s", accession),
      "GenBank"           = sprintf("https://www.ncbi.nlm.nih.gov/nuccore/%s", accession),
      ""
    )
  }

  output$data_availability_result <- renderUI({
    da <- da_result()
    if (is.null(da)) {
      return(tags$p(tags$em("Upload a PDF and press ", tags$b("Scan paper"),
                            " to detect data availability.")))
    }
    outcome_meta <- switch(da$outcome,
      "deposit_repository"     = list(cls = "alert-success",
                                      h = "Public data deposit detected"),
      "unstructured_repository" = list(cls = "alert-info",
                                      h = "Repository named (no accession found)"),
      "on_request"             = list(cls = "alert-warning",
                                      h = "Data are 'available on request' (not a public deposit)"),
      "no_new_data"            = list(cls = "alert-secondary",
                                      h = "No new data generated by this study"),
      "restricted_access"      = list(cls = "alert-warning",
                                      h = "Restricted / controlled-access data"),
      "none"                   = list(cls = "alert-warning",
                                      h = "No data-availability statement detected"),
      list(cls = "alert-secondary", h = paste0("Outcome: ", da$outcome))
    )
    banner <- tags$div(
      class = paste("alert", outcome_meta$cls),
      tags$h4(style = "margin-top:0", outcome_meta$h),
      tags$p(sprintf("%s data-availability section. %d match%s extracted.",
                     if (isTRUE(da$has_das_section)) "Found a"
                     else "No explicit",
                     da$match_count,
                     if (da$match_count == 1) "" else "es"))
    )

    if (is.null(da$matches) || nrow(da$matches) == 0L) {
      return(tagList(banner,
                     if (!isTRUE(da$has_das_section))
                       tags$p(tags$small(style = "color:#888",
                         "Repositories scanned: GEO, SRA, BioProject, BioSample, ArrayExpress, BioStudies, PRIDE, MassIVE, MetaboLights, dbGaP, EGA, RefSeq, Assembly, ClinVar, ChEMBL, EMPIAR, EMDB, PDB, UniProt, OpenNeuro, Synapse, GenBank, Zenodo, Figshare, Dryad, Harvard Dataverse, Mendeley Data, OpenNeuro DOI, OSF, Hugging Face datasets, GitHub.")) else NULL))
    }

    cards <- lapply(seq_len(nrow(da$matches)), function(i) {
      m <- da$matches[i, , drop = FALSE]
      is_neg <- identical(m$category, "negative_statement")
      stripe_color <- if (is_neg) "#b07a00" else "#0a5a20"
      bg_color     <- if (is_neg) "#fff8e1" else "#f4f8f4"
      url <- if (!is_neg) .da_verify_url(m$repository, m$accession) else ""
      conf_badge <- switch(m$confidence,
        "high"   = tags$span(class = "badge bg-success", style = "margin-left:0.5em", "high confidence"),
        "medium" = tags$span(class = "badge bg-secondary", style = "margin-left:0.5em", "medium confidence"),
        "low"    = tags$span(class = "badge bg-warning text-dark", style = "margin-left:0.5em", "low confidence"))

      header <- if (is_neg) {
        tags$strong(sprintf("Statement: %s",
                            switch(m$repository,
                              "on_request"        = "Data available on request",
                              "no_new_data"       = "No new data generated",
                              "restricted_access" = "Restricted / controlled access",
                              m$repository)))
      } else {
        tags$div(
          tags$strong(m$repository),
          tags$code(m$accession %||% "(repo named)",
                    style = "margin-left:0.5em;color:#0a5a20"),
          conf_badge,
          tags$span(style = "margin-left:0.5em;color:#888;font-size:0.85em",
                    sprintf("category: %s", m$category))
        )
      }

      .card_with_tick(
        cb_id = sprintf("da_sel_%d", i),
        stripe_color = stripe_color,
        bg_color = bg_color,
        card_body = tagList(
          header,
          tags$div(style = "margin-top:0.35em;color:#666;font-size:0.85em",
                   sprintf("Found in section: %s", m$section %||% "body")),
          tags$blockquote(
            style = "margin:0.6em 0 0 0;padding:0.5em 0.8em;border-left:2px solid #ccc;background:#fff;font-size:0.92em",
            m$sentence
          ),
          if (nzchar(url))
            tags$div(style = "margin-top:0.4em;font-size:0.85em",
                     tags$a(href = url, target = "_blank", rel = "noopener",
                            sprintf("verify on %s \u2197", m$repository)))
          else NULL
        )
      )
    })

    tagList(banner, cards)
  })

  output$data_availability_add_ui <- renderUI({
    da <- da_result()
    if (is.null(da) || is.null(da$matches) || nrow(da$matches) == 0L) return(NULL)
    # Negative-statement rows (e.g. "data on request") stay visible in the
    # panel but can't be appended to the matched-works CSV (there's nothing
    # to link). Only data-deposit / DOI / URL rows are addable.
    addable <- sum(da$matches$category %in% c("accession", "doi", "url"))
    if (addable == 0L) return(NULL)
    tagList(
      actionButton("pdf_add_da_to_csv",
                   "Add ticked data-deposit rows to matched-works CSV",
                   icon = icon("plus"),
                   class = "btn-outline-primary"),
      tags$span(style = "margin-left:1em;color:#555",
                textOutput("da_selection_status", inline = TRUE))
    )
  })

  output$da_selection_status <- renderText({
    da <- da_result()
    if (is.null(da) || is.null(da$matches) || nrow(da$matches) == 0L) return("")
    addable_idx <- which(da$matches$category %in% c("accession", "doi", "url"))
    if (length(addable_idx) == 0L) return("")
    ticked <- .ticked_rows("da_sel", nrow(da$matches))
    ticked_addable <- intersect(ticked, addable_idx)
    sprintf("%d of %d addable ticked (negative-statement rows are not exportable)",
            length(ticked_addable), length(addable_idx))
  })

  observeEvent(input$pdf_add_da_to_csv, {
    da <- da_result()
    if (is.null(da) || is.null(da$matches) || nrow(da$matches) == 0L) return()
    req(input$grant)
    addable <- da$matches$category %in% c("accession", "doi", "url")
    ticked <- .ticked_rows("da_sel", nrow(da$matches))
    keep_idx <- intersect(ticked, which(addable))
    if (length(keep_idx) == 0L) {
      showNotification("No addable data-deposit rows are ticked.",
                       type = "warning", duration = 4)
      return()
    }
    sel <- da$matches[keep_idx, , drop = FALSE]
    pdf_fn <- reg_name() %||% ""
    new_rows <- tibble::tibble(
      source          = sel$repository,
      source_api      = sel$repository,
      match_class     = "pdf_data_deposit",
      doi             = ifelse(grepl("^10\\.", sel$accession), sel$accession, NA_character_),
      title           = pdf_fn,
      url             = vapply(seq_len(nrow(sel)),
                               function(i) .da_verify_url(sel$repository[i],
                                                          sel$accession[i]),
                               character(1)),
      matched_award   = input$grant,
      matched_by      = sprintf("PDF extraction (%s; %s)", sel$category, sel$evidence),
      registration_id = NA_character_,
      registry        = NA_character_,
      data_repository = sel$repository,
      data_accession  = sel$accession,
      section         = sel$section,
      sentence        = sel$sentence,
      anchor          = NA_character_,
      confidence      = sel$confidence,
      pdf_file        = pdf_fn
    )
    extra_rows(bind_rows(extra_rows(), new_rows))
    showNotification(
      sprintf("Added %d data-deposit row%s to this grant's CSV download.",
              nrow(new_rows), if (nrow(new_rows) == 1) "" else "s"),
      type = "message", duration = 4
    )
  })

  # ---- CSV export ----
  # Location of the last CSV saved for this grant (used for status display).
  last_saved_path <- reactiveVal(NULL)

  # Build the CSV output data frame from the strict and fallback rows the
  # user has ticked, plus any PDF-extracted extras queued for this grant.
  .build_csv_out <- function() {
    r <- result()
    # Use the deduped view when the toggle is on so the CSV mirrors what
    # the user sees and ticks in the Strict tab.
    strict_view <- strict_for_display()
    strict_rows <- bind_rows(lapply(names(.strict_selection_map), function(api) {
      tbl <- strict_view[[api]]
      sel <- input[[.strict_selection_map[[api]]]]
      if (is.null(tbl) || nrow(tbl) == 0 ||
          is.null(sel) || length(sel) == 0) return(NULL)
      sel <- sel[sel >= 1 & sel <= nrow(tbl)]
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
    if (!is.null(er) && nrow(er)) {
      er$grant_id <- input$grant
      er$pi       <- current_row()$pi_full_name
      out <- bind_rows(out, er)
    }
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
}

shinyApp(ui, server)
