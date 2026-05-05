suppressPackageStartupMessages({
  library(httr2); library(tibble); library(purrr)
})

# Build a filename for a row in a strict/fallback table. Uses the row's DOI
# (slashes and other path-unsafe characters replaced with '_'), preserving
# the suffix so match_doi_from_filename() in pdf_convert.R can recover the
# DOI from the filename later. Returns NA_character_ when no DOI is present
# (the row simply isn't downloadable).
.pdf_filename_for_row <- function(row) {
  doi <- row$doi %||% NA_character_
  if (length(doi) != 1 || is.na(doi) || !nzchar(doi)) return(NA_character_)
  paste0(gsub("[^A-Za-z0-9._-]", "_", doi), ".pdf")
}

# Fetch a single PDF to disk. Returns:
#   list(ok = TRUE/FALSE, path = ..., reason = ..., bytes = ...)
# Validates by *both* signals because publishers commonly serve "you are
# blocked" HTML with `Content-Type: application/pdf`. Magic-bytes check
# covers that.
#
# Honours OS_SEARCH_DISABLE_PDF_DOWNLOAD: when set, every call short-circuits
# to ok = FALSE without touching the network. Used by smoke_test.R.
download_pdf <- function(url, dest_path, timeout_s = 30L) {
  if (nzchar(Sys.getenv("OS_SEARCH_DISABLE_PDF_DOWNLOAD"))) {
    return(list(ok = FALSE, path = dest_path, reason = "disabled_by_env",
                bytes = 0L))
  }
  if (length(url) != 1 || is.na(url) || !nzchar(url)) {
    return(list(ok = FALSE, path = dest_path, reason = "no_url", bytes = 0L))
  }
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)
  resp <- tryCatch(
    httr2::request(url) |>
      httr2::req_timeout(timeout_s) |>
      httr2::req_user_agent("OS_search/0.1 (+https://github.com/jgwrightson/OS_search)") |>
      httr2::req_options(followlocation = TRUE) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform(),
    error = function(e) e
  )
  if (inherits(resp, "error")) {
    return(list(ok = FALSE, path = dest_path,
                reason = paste0("network_error: ", conditionMessage(resp)),
                bytes = 0L))
  }
  status <- httr2::resp_status(resp)
  if (status != 200) {
    return(list(ok = FALSE, path = dest_path,
                reason = sprintf("http_%d", status), bytes = 0L))
  }
  raw <- tryCatch(httr2::resp_body_raw(resp),
                  error = function(e) NULL)
  if (is.null(raw) || length(raw) < 5) {
    return(list(ok = FALSE, path = dest_path, reason = "empty_body", bytes = 0L))
  }
  # Magic-bytes check: %PDF-
  magic_ok <- identical(as.integer(raw[1:5]),
                        as.integer(charToRaw("%PDF-")))
  if (!magic_ok) {
    return(list(ok = FALSE, path = dest_path,
                reason = "not_a_pdf", bytes = length(raw)))
  }
  writeBin(raw, dest_path)
  list(ok = TRUE, path = dest_path, reason = "ok", bytes = length(raw))
}

# Iterate over a tibble of rows, downloading each row's `oa_pdf_url` into
# `folder/<filename-from-doi>`. Idempotent: rows whose dest path already
# exists on disk are skipped (treated as ok=TRUE, reason="already_present")
# so re-running search after a manual drop does not clobber existing files.
#
# Returns a tibble with one row per input row:
#   row_id (integer), title, doi, url (the oa_pdf_url tried),
#   dest, ok, reason, bytes.
# Rows with no `oa_pdf_url` or no DOI surface as ok=FALSE so the caller can
# render them in the "manual download needed" panel.
download_pdfs_for_rows <- function(rows, folder) {
  empty <- tibble::tibble(
    row_id = integer(), title = character(), doi = character(),
    url = character(), dest = character(),
    ok = logical(), reason = character(), bytes = integer()
  )
  if (is.null(rows) || nrow(rows) == 0) return(empty)
  dir.create(folder, recursive = TRUE, showWarnings = FALSE)
  outcomes <- vector("list", nrow(rows))
  for (i in seq_len(nrow(rows))) {
    row <- rows[i, , drop = FALSE]
    fname <- .pdf_filename_for_row(row)
    title <- row$title %||% NA_character_
    doi   <- row$doi   %||% NA_character_
    url   <- row$oa_pdf_url %||% NA_character_
    if (is.na(fname)) {
      outcomes[[i]] <- list(row_id = i, title = title, doi = doi, url = url,
                            dest = NA_character_, ok = FALSE,
                            reason = "no_doi_for_filename", bytes = 0L)
      next
    }
    dest <- file.path(folder, fname)
    if (file.exists(dest)) {
      outcomes[[i]] <- list(row_id = i, title = title, doi = doi, url = url,
                            dest = dest, ok = TRUE,
                            reason = "already_present",
                            bytes = file.info(dest)$size)
      next
    }
    res <- download_pdf(url, dest)
    outcomes[[i]] <- list(row_id = i, title = title, doi = doi, url = url,
                          dest = dest, ok = res$ok,
                          reason = res$reason, bytes = res$bytes)
  }
  do.call(rbind.data.frame, c(outcomes, stringsAsFactors = FALSE)) |>
    tibble::as_tibble()
}
