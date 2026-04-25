suppressPackageStartupMessages({
  library(dplyr)
})

.data_loader_file <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
CACHE_PATH <- if (is.null(.data_loader_file) || !nzchar(.data_loader_file)) {
  file.path(getwd(), "cache", "project_grants.rds")
} else {
  file.path(dirname(dirname(.data_loader_file)), "cache", "project_grants.rds")
}

load_project_grants <- function(cache_path = CACHE_PATH) {
  if (!file.exists(cache_path)) {
    stop("Grant cache not found at ", cache_path,
         ". Run `Rscript build/refresh_cache.R` to build it.",
         call. = FALSE)
  }
  readRDS(cache_path)
}

unique_grants <- function(pg) {
  pg |>
    group_by(grant_id) |>
    arrange(desc(fiscal_year)) |>
    slice(1) |>
    ungroup()
}

`%||%` <- function(a, b) if (is.null(a)) b else a
