suppressPackageStartupMessages({
  library(tools)
  library(jsonlite)
})

PDF_PY_MIN_VERSION <- c(3L, 10L)

.venv_py_path      <- function() file.path(getwd(), ".venv", "bin", "python")
.requirements_path <- function() file.path(getwd(), "python", "requirements.lock.txt")

.parse_py_version <- function(s) {
  m <- regmatches(s, regexpr("[0-9]+\\.[0-9]+(\\.[0-9]+)?", s))
  if (!length(m)) return(NULL)
  as.integer(strsplit(m, "\\.")[[1]])
}

.py_version_ok <- function(ver, min = PDF_PY_MIN_VERSION) {
  if (is.null(ver) || length(ver) < 2) return(FALSE)
  if (ver[1] != min[1]) return(ver[1] > min[1])
  ver[2] >= min[2]
}

.py_version_str <- function(ver) {
  if (is.null(ver) || length(ver) < 2) return("?")
  paste(ver, collapse = ".")
}

# Probe an interpreter path and return list(path, version) if it's
# usable, NULL otherwise. Prefers `-V` over `--version` because some
# older builds print to stderr on --version.
.probe_python <- function(path) {
  if (!nzchar(path)) return(NULL)
  out <- tryCatch(
    suppressWarnings(system2(path, "-V", stdout = TRUE, stderr = TRUE)),
    error = function(e) character()
  )
  ver <- .parse_py_version(paste(out, collapse = " "))
  if (is.null(ver)) return(NULL)
  list(path = unname(path), version = ver)
}

# Locate a system Python that meets PDF_PY_MIN_VERSION. Checks PATH
# first, then a few common Homebrew locations on macOS where
# `python3` may not be symlinked to the newest interpreter.
.find_system_python <- function() {
  candidates <- c(
    unname(Sys.which("python3")),
    unname(Sys.which("python")),
    "/opt/homebrew/bin/python3.13",
    "/opt/homebrew/bin/python3.12",
    "/opt/homebrew/bin/python3.11",
    "/opt/homebrew/bin/python3.10",
    "/usr/local/bin/python3.13",
    "/usr/local/bin/python3.12",
    "/usr/local/bin/python3.11",
    "/usr/local/bin/python3.10"
  )
  candidates <- unique(candidates[nzchar(candidates) & file.exists(candidates)])
  for (p in candidates) {
    info <- .probe_python(p)
    if (!is.null(info) && .py_version_ok(info$version)) return(info)
  }
  best_seen <- NULL
  for (p in candidates) {
    info <- .probe_python(p)
    if (!is.null(info) &&
        (is.null(best_seen) ||
         paste(info$version, collapse = ".") >
         paste(best_seen$version, collapse = "."))) {
      best_seen <- info
    }
  }
  list(ok = FALSE, best = best_seen)
}

.venv_has_pymupdf4llm <- function() {
  py <- .venv_py_path()
  if (!file.exists(py)) return(FALSE)
  status <- suppressWarnings(
    system2(py, c("-c", shQuote("import pymupdf4llm")),
            stdout = FALSE, stderr = FALSE)
  )
  identical(as.integer(status), 0L)
}

# Bootstrap the project Python venv if needed. Returns a list with:
#   ok      logical scalar - is the PDF pipeline usable
#   python  path to venv python (when ok) or NA
#   message user-facing explanation (shown in the UI on failure)
# Safe to call repeatedly: if the venv already has pymupdf4llm, this is
# essentially a single import-check and returns immediately.
ensure_pdf_venv <- function(verbose = TRUE) {
  if (.venv_has_pymupdf4llm()) {
    return(list(ok = TRUE, python = .venv_py_path(),
                message = "Python venv ready."))
  }

  sys <- .find_system_python()
  if (is.list(sys) && isFALSE(sys$ok)) {
    best <- sys$best
    msg <- if (is.null(best)) {
      sprintf("No Python interpreter found on PATH. The Paper → Registration tab needs Python %s+ with pymupdf4llm. Install Python and relaunch the app.",
              .py_version_str(PDF_PY_MIN_VERSION))
    } else {
      sprintf("Found Python %s at %s, but the Paper → Registration tab needs Python %s+. Install a newer Python and relaunch.",
              .py_version_str(best$version), best$path,
              .py_version_str(PDF_PY_MIN_VERSION))
    }
    if (verbose) message(msg)
    return(list(ok = FALSE, python = NA_character_, message = msg))
  }

  venv_dir <- file.path(getwd(), ".venv")
  if (!file.exists(.venv_py_path())) {
    if (verbose) {
      message(sprintf("Creating Python venv at %s using %s (v%s)...",
                      venv_dir, sys$path, .py_version_str(sys$version)))
    }
    status <- tryCatch(
      system2(sys$path, c("-m", "venv", shQuote(venv_dir))),
      error = function(e) -1L
    )
    if (!identical(as.integer(status), 0L) || !file.exists(.venv_py_path())) {
      msg <- sprintf("Failed to create Python venv at %s (status %s). Try manually: %s -m venv %s",
                     venv_dir, status, sys$path, venv_dir)
      if (verbose) message(msg)
      return(list(ok = FALSE, python = NA_character_, message = msg))
    }
  }

  py  <- .venv_py_path()
  req <- .requirements_path()
  pip_args <- if (file.exists(req)) {
    c("-m", "pip", "install", "--quiet", "--disable-pip-version-check",
      "-r", shQuote(req))
  } else {
    c("-m", "pip", "install", "--quiet", "--disable-pip-version-check",
      "pymupdf4llm")
  }
  if (verbose) message("Installing Python dependencies (pymupdf4llm, PyMuPDF)... this is a one-time step.")
  status <- tryCatch(system2(py, pip_args), error = function(e) -1L)
  if (!identical(as.integer(status), 0L) || !.venv_has_pymupdf4llm()) {
    hint <- if (file.exists(req)) sprintf("%s -m pip install -r %s", py, req)
            else sprintf("%s -m pip install pymupdf4llm", py)
    msg <- sprintf("pip install failed (status %s). Try manually: %s",
                   status, hint)
    if (verbose) message(msg)
    return(list(ok = FALSE, python = NA_character_, message = msg))
  }

  if (verbose) message("Python venv bootstrapped.")
  list(ok = TRUE, python = py, message = "Python venv ready.")
}

# Resolve the python interpreter to use for PDF -> markdown conversion.
# Prefers the project venv at .venv/bin/python (created at setup time with
# pymupdf4llm installed). Falls back to the system python3.
.pdf_py_bin <- function() {
  venv_py <- .venv_py_path()
  if (file.exists(venv_py)) return(venv_py)
  sys_py <- Sys.which("python3")
  if (nzchar(sys_py)) return(unname(sys_py))
  stop("No python3 found; create a venv with pymupdf4llm installed (.venv/bin/python).")
}

.pdf_script <- function() {
  file.path(getwd(), "py", "pdf_to_md.py")
}

.registration_script <- function() {
  file.path(getwd(), "py", "extract_registrations.py")
}

.scan_script <- function() {
  file.path(getwd(), "py", "scan_paper.py")
}

# Convert a PDF on disk to markdown, returning the markdown text.
# Extraction is fully local: pymupdf4llm (rule-based, no ML, no network).
pdf_to_markdown <- function(pdf_path) {
  stopifnot(file.exists(pdf_path))
  md_tmp <- tempfile(fileext = ".md")
  on.exit(unlink(md_tmp), add = TRUE)

  res <- system2(
    .pdf_py_bin(),
    args = shQuote(c(.pdf_script(), pdf_path, md_tmp)),
    stdout = TRUE, stderr = TRUE
  )
  status <- attr(res, "status") %||% 0L
  if (!file.exists(md_tmp) || status != 0L) {
    stop("PDF conversion failed:\n", paste(res, collapse = "\n"))
  }
  readr_ok <- requireNamespace("readr", quietly = TRUE)
  if (readr_ok) {
    readr::read_file(md_tmp)
  } else {
    paste(readLines(md_tmp, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  }
}

# Detect trial / systematic-review registration identifiers in a PDF.
# Returns a list:
#   is_registered    (logical scalar)
#   study_type_hint  ("trial"|"systematic_review"|"mixed"|"unknown")
#   match_count      (integer)
#   matches          (data.frame with columns:
#                       registry, id, section, sentence, anchor, confidence)
#   markdown_chars   (integer)
#
# Fully local. No LLM, no network.
detect_registrations <- function(pdf_path) {
  stopifnot(file.exists(pdf_path))

  out <- system2(
    .pdf_py_bin(),
    args = shQuote(c(.registration_script(), pdf_path)),
    stdout = TRUE, stderr = TRUE
  )
  status <- attr(out, "status") %||% 0L
  # Python prints JSON on stdout and may print warnings on stderr; system2
  # merges both when stderr = TRUE. Separate them by looking for the first '{'.
  txt <- paste(out, collapse = "\n")
  brace <- regexpr("\\{", txt)[1]
  if (status != 0L || brace < 1L) {
    stop("Registration detection failed:\n", txt)
  }
  json_txt <- substr(txt, brace, nchar(txt))
  res <- fromJSON(json_txt, simplifyDataFrame = TRUE)

  # Ensure `matches` is always a data.frame with the expected columns.
  want_cols <- c("registry", "id", "section", "sentence", "anchor", "confidence")
  if (is.null(res$matches) || length(res$matches) == 0L ||
      (is.list(res$matches) && !is.data.frame(res$matches))) {
    res$matches <- data.frame(matrix(character(0), ncol = length(want_cols),
                                     dimnames = list(NULL, want_cols)),
                              stringsAsFactors = FALSE)
  }
  res
}

# Run the combined paper scan: PDF -> markdown (once) -> registration +
# data-availability extraction. Returns a list with two top-level
# elements `registration` and `data_availability`, plus markdown_chars.
scan_paper <- function(pdf_path) {
  stopifnot(file.exists(pdf_path))
  out <- system2(
    .pdf_py_bin(),
    args = shQuote(c(.scan_script(), pdf_path)),
    stdout = TRUE, stderr = TRUE
  )
  status <- attr(out, "status") %||% 0L
  txt <- paste(out, collapse = "\n")
  brace <- regexpr("\\{", txt)[1]
  if (status != 0L || brace < 1L) {
    stop("Paper scan failed:\n", txt)
  }
  res <- fromJSON(substr(txt, brace, nchar(txt)), simplifyDataFrame = TRUE)

  # Normalise the registration matches table.
  reg_cols <- c("registry", "id", "section", "sentence", "anchor", "confidence")
  if (is.null(res$registration$matches) || length(res$registration$matches) == 0L ||
      (is.list(res$registration$matches) && !is.data.frame(res$registration$matches))) {
    res$registration$matches <- data.frame(
      matrix(character(0), ncol = length(reg_cols),
             dimnames = list(NULL, reg_cols)),
      stringsAsFactors = FALSE
    )
  }
  # Normalise the data-availability matches table.
  da_cols <- c("repository", "accession", "category", "section",
               "sentence", "evidence", "confidence")
  if (is.null(res$data_availability$matches) ||
      length(res$data_availability$matches) == 0L ||
      (is.list(res$data_availability$matches) &&
       !is.data.frame(res$data_availability$matches))) {
    res$data_availability$matches <- data.frame(
      matrix(character(0), ncol = length(da_cols),
             dimnames = list(NULL, da_cols)),
      stringsAsFactors = FALSE
    )
  }
  # Normalise the CIHR-funding matches table. Shape mirrors the other
  # two extractors so the Shiny UI can treat it uniformly. `grant_ids`
  # is a list-column (zero or more IDs per match).
  cf_cols <- c("section", "sentence", "evidence", "category", "confidence")
  cf <- res$cihr_funding
  if (is.null(cf)) {
    cf <- list(funded_by_cihr = FALSE, confidence = "none",
               match_count = 0L, matches = NULL)
  }
  if (is.null(cf$matches) || length(cf$matches) == 0L ||
      (is.list(cf$matches) && !is.data.frame(cf$matches))) {
    cf$matches <- data.frame(
      matrix(character(0), ncol = length(cf_cols),
             dimnames = list(NULL, cf_cols)),
      stringsAsFactors = FALSE
    )
    cf$matches$grant_ids <- list()
  }
  res$cihr_funding <- cf
  res
}
