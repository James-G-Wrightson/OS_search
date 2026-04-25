suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
  library(stringr)
})

# ---- Constants --------------------------------------------------------------

# CIHR is structured as a parent funder plus 13 thematic institutes and a
# handful of programmatic initiatives (Clinical Trials Fund, SPOR, HIV/AIDS,
# AMR, etc.).  Publishers forward to Crossref / OpenAlex either the parent
# or a specific institute/programme, inconsistently — e.g. the ARTESiA trial
# paper in NEJM is tagged only to "Institute of Circulatory and Respiratory
# Health" (10.13039/501100000028) with no parent-CIHR entry.  Queries that
# match only the parent DOI therefore miss a meaningful slice of CIHR
# output; every client below uses the full union.
CIHR_CROSSREF_FUNDER_DOIS <- c(
  "10.13039/501100000024",  # Canadian Institutes of Health Research (parent)
  "10.13039/501100000025",  # Institute of Aboriginal Peoples Health
  "10.13039/501100000026",  # Institute of Aging
  "10.13039/501100000027",  # Institute of Cancer Research
  "10.13039/501100000028",  # Institute of Circulatory and Respiratory Health
  "10.13039/501100000029",  # Institute of Gender and Health
  "10.13039/501100000030",  # Institute of Genetics
  "10.13039/501100000031",  # Institute of Health Services and Policy Research
  "10.13039/501100000032",  # Institute of Human Development, Child and Youth Health
  "10.13039/501100000033",  # Institute of Infection and Immunity
  "10.13039/501100000034",  # Institute of Musculoskeletal Health and Arthritis
  "10.13039/501100000035",  # Institute of Neurosciences, Mental Health and Addiction
  "10.13039/501100000036",  # Institute of Nutrition, Metabolism and Diabetes
  "10.13039/501100000037",  # Institute of Population and Public Health
  "10.13039/501100007202",  # CIHR Skin Research Training Centre
  "10.13039/501100010928",  # Institute of Indigenous Peoples' Health
  "10.13039/100021557",     # Healthy Cities Research Initiative
  "10.13039/100021570",     # Strategy for Patient-Oriented Research (SPOR)
  "10.13039/100021597",     # Centre for Research on Pandemic Preparedness
  "10.13039/100022991",     # HIV/AIDS and STBBI Research Initiative
  "10.13039/100022992",     # Clinical Trials Fund
  "10.13039/100024134"      # Antimicrobial Resistance Research Initiative
)
# Legacy scalar alias — still used as a default by a couple of helpers.
CIHR_CROSSREF_FUNDER_DOI <- CIHR_CROSSREF_FUNDER_DOIS[1]

CIHR_OPENALEX_FUNDER_IDS <- c(
  "F4320334506",  # Canadian Institutes of Health Research (parent)
  "F4320338061",  # Institute of Aboriginal Peoples Health
  "F4320338062",  # Institute of Aging
  "F4320338030",  # Institute of Cancer Research
  "F4320338063",  # Institute of Circulatory and Respiratory Health
  "F4320338064",  # Institute of Gender and Health
  "F4320338065",  # Institute of Genetics
  "F4320338066",  # Institute of Human Development, Child and Youth Health
  "F4320338067",  # Institute of Infection and Immunity
  "F4320338068",  # Institute of Musculoskeletal Health and Arthritis
  "F4320338069",  # Institute of Neurosciences, Mental Health and Addiction
  "F4320338070",  # Institute of Nutrition, Metabolism and Diabetes
  "F4320338071",  # Institute of Population and Public Health
  "F4320338072",  # Institute of Health Services and Policy Research
  "F4320338133",  # Institute of Indigenous Peoples' Health
  "F5257815122",  # Strategy for Patient-Oriented Research
  "F3340254956",  # Clinical Trials Fund
  "F8691272287",  # HIV/AIDS and STBBI Research Initiative
  "F7565124285",  # Healthy Cities Research Initiative
  "F1660211197"   # Centre for Research on Pandemic Preparedness
)
CIHR_OPENALEX_FUNDER_ID <- CIHR_OPENALEX_FUNDER_IDS[1]

CIHR_ROR <- "https://ror.org/01gavpb45"

# Funder-name strings used by CIHR depositors when they supply a name
# string without an identifier.  Also the agency strings Europe PMC exposes
# via GRANT_AGENCY — EPMC doesn't use the Funder DOI, so we match on name.
# Both short and long CIHR forms appear in CT.gov (the acronym picks up
# ~2.7% more records than the full name); the 20 institute/programme names
# are what EPMC surfaces for papers like the ARTESiA NEJM trial.
CIHR_FUNDER_NAMES <- c(
  "Canadian Institutes of Health Research",
  "CIHR",
  "Institute of Aboriginal Peoples Health",
  "Institute of Aging",
  "Institute of Cancer Research",
  "Institute of Circulatory and Respiratory Health",
  "Institute of Gender and Health",
  "Institute of Genetics",
  "Institute of Health Services and Policy Research",
  "Institute of Human Development, Child and Youth Health",
  "Institute of Infection and Immunity",
  "Institute of Musculoskeletal Health and Arthritis",
  "Institute of Neurosciences, Mental Health and Addiction",
  "Institute of Nutrition, Metabolism and Diabetes",
  "Institute of Population and Public Health",
  "Institute of Indigenous Peoples' Health",
  "CIHR Skin Research Training Centre",
  "Healthy Cities Research Initiative",
  "Strategy for Patient-Oriented Research",
  "Centre for Research on Pandemic Preparedness and Health Emergencies",
  "HIV/AIDS and STBBI Research Initiative",
  "Clinical Trials Fund",
  "Antimicrobial Resistance Research Initiative"
)
# The short subset used where the query needs only the CT.gov sponsor strings
# (CT.gov's query.spons is a substring match on the parent name + acronym).
CIHR_CTGOV_SPONSORS <- c("Canadian Institutes of Health Research", "CIHR")

# Polite-pool contact.  Override via env var if you want.
POLITE_MAILTO <- Sys.getenv("OS_SEARCH_MAILTO", "j.wrightson@ubc.ca")

# ---- Source-priority ranking ------------------------------------------------
# Used by dedup_rows_by_doi() to decide which copy of a DOI to keep when
# the same work is returned by multiple APIs.  Lower rank = preferred.
# OpenAlex wins because it has the richest per-work metadata (OA status,
# OA venue, primary-location URL); Europe PMC is next because it
# contributes PMID/PMCID + grant-linkage metadata that the others lack;
# Crossref is authoritative for funder tags but thin on the rest; DataCite
# and OpenAIRE rarely overlap on paper DOIs and their copies are usually
# the least-populated.  ClinicalTrials.gov has no DOIs so it's excluded.
.SOURCE_PRIORITY <- c(
  "OpenAlex"           = 1L,
  "Europe PMC"         = 2L,
  "Crossref"           = 3L,
  "DataCite"           = 4L,
  "OpenAIRE"           = 5L,
  "ClinicalTrials.gov" = 9L
)

.source_priority_rank <- function(src) {
  r <- .SOURCE_PRIORITY[as.character(src)]
  r[is.na(r)] <- 99L
  as.integer(r)
}

# Collapse a combined tibble so each DOI appears only in the row from the
# highest-priority source.  Adds an `also_in` column naming the other
# sources that had the same DOI.  Rows without a DOI pass through
# unchanged (they can't be deduplicated safely).
dedup_rows_by_doi <- function(rows) {
  if (is.null(rows) || nrow(rows) == 0) return(rows)
  if (!all(c("doi", "source") %in% names(rows))) return(rows)
  has_doi <- !is.na(rows$doi) & nzchar(rows$doi)
  if (!any(has_doi)) {
    rows$also_in <- NA_character_
    return(rows)
  }
  to_dd <- rows[has_doi, , drop = FALSE]
  other <- rows[!has_doi, , drop = FALSE]
  to_dd$.rank <- .source_priority_rank(to_dd$source)
  to_dd <- to_dd[order(to_dd$.rank), , drop = FALSE]
  also <- tapply(to_dd$source, to_dd$doi, function(s) {
    u <- unique(s)
    if (length(u) <= 1) NA_character_ else paste(u[-1], collapse = ", ")
  })
  kept <- to_dd[!duplicated(to_dd$doi), , drop = FALSE]
  kept$also_in <- unname(also[kept$doi])
  kept$.rank <- NULL
  if (nrow(other) > 0) {
    other$also_in <- NA_character_
    bind_rows(kept, other)
  } else {
    kept
  }
}

# ---- Low-level helpers ------------------------------------------------------

.first <- function(x, fallback = NA_character_) {
  if (is.null(x) || length(x) == 0) return(fallback)
  if (is.list(x)) {
    v <- x[[1]]
    if (is.null(v) || length(v) == 0) return(fallback)
    return(v)
  }
  x[1]
}

# Extract CIHR award IDs from each API's work record.  Joined with ";".
# Accepts either a scalar DOI or a vector — the vector form is what the
# query side uses now (parent CIHR + 20 institute/programme DOIs).
.crossref_cihr_awards <- function(it, funder_dois = CIHR_CROSSREF_FUNDER_DOIS) {
  f <- it$funder
  if (is.null(f) || !length(f)) return(NA_character_)
  awards <- unlist(lapply(f, \(x) {
    if ((x$DOI %||% "") %in% funder_dois) unlist(x$award) else NULL
  }))
  if (!length(awards)) NA_character_ else paste(unique(awards), collapse = "; ")
}

.openalex_cihr_awards <- function(it, funder_ids = CIHR_OPENALEX_FUNDER_IDS) {
  a <- it$grants %||% it$awards
  if (is.null(a) || !length(a)) return(NA_character_)
  ids <- unlist(lapply(a, \(x) {
    fid <- sub("^https?://openalex.org/", "", x$funder_id %||% x$funder %||% "")
    if (fid %in% funder_ids) x$funder_award_id %||% x$award_id else NULL
  }))
  if (!length(ids)) NA_character_ else paste(unique(ids), collapse = "; ")
}

.datacite_cihr_awards <- function(a, funder_dois = CIHR_CROSSREF_FUNDER_DOIS,
                                  ror = CIHR_ROR,
                                  names = CIHR_FUNDER_NAMES,
                                  award_number = NULL) {
  fr <- a$fundingReferences
  if (is.null(fr) || !length(fr)) return(NA_character_)
  ids <- unlist(lapply(fr, \(x) {
    fid <- x$funderIdentifier %||% ""
    fname <- x$funderName %||% ""
    id_hit <- any(vapply(funder_dois, \(d) grepl(d, fid, fixed = TRUE), logical(1))) ||
              grepl(ror, fid, fixed = TRUE)
    name_hit <- any(vapply(names,
                           \(n) grepl(n, fname, ignore.case = TRUE, fixed = FALSE),
                           logical(1)))
    if (id_hit || name_hit) x$awardNumber else NULL
  }))
  if (!length(ids)) return(NA_character_)
  ids <- unique(ids)
  # Strict-grant call: keep only the award number(s) that actually satisfy
  # the queried grant.  Co-funder award IDs (other CIHR-administered grants
  # on the same record) are dropped from the column so the user sees what
  # caused this row to land in the bucket, not every CIHR award the
  # depositor declared.  Same bare/PJT-prefix tolerance as the query side.
  if (!is.null(award_number) && nzchar(award_number)) {
    pat <- sprintf("(^|[^0-9])%s([^0-9]|$)", award_number)
    ids <- ids[grepl(pat, ids)]
    if (!length(ids)) return(NA_character_)
  }
  paste(ids, collapse = "; ")
}

.do_req <- function(req) {
  req |>
    req_user_agent(sprintf("OS_search_prototype/0.1 (mailto:%s)", POLITE_MAILTO)) |>
    req_timeout(45) |>
    req_retry(max_tries = 3, backoff = ~ 2) |>
    req_perform()
}

.json <- function(resp) resp_body_json(resp, simplifyVector = FALSE)

.safe_get <- function(url, query = list()) {
  tryCatch({
    request(url) |>
      req_url_query(!!!query) |>
      .do_req() |>
      .json()
  }, error = function(e) {
    warning(sprintf("API call failed: %s -- %s", url, conditionMessage(e)))
    NULL
  })
}

# Normalise a CIHR grant_id like "175325_1" -> bare numeric "175325"
grant_award_number <- function(grant_id) {
  stringr::str_extract(grant_id, "^[0-9]+")
}

# ---- Crossref ---------------------------------------------------------------

# Crossref returns abstracts as JATS XML — `<jats:p>...</jats:p>`, sometimes
# wrapped in `<jats:sec><jats:title>Background</jats:title>...</jats:sec>`.
# Strip tags, decode the entities Crossref actually emits, collapse
# whitespace.  Returns NA_character_ if absent or empty after cleaning so
# downstream BM25 doesn't tokenise an empty string.
.crossref_abstract_text <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  s <- as.character(x)[1]
  if (is.na(s) || !nzchar(s)) return(NA_character_)
  s <- gsub("<[^>]+>", " ", s, perl = TRUE)
  s <- gsub("&amp;",  "&", s, fixed = TRUE)
  s <- gsub("&lt;",   "<", s, fixed = TRUE)
  s <- gsub("&gt;",   ">", s, fixed = TRUE)
  s <- gsub("&quot;", '"', s, fixed = TRUE)
  s <- gsub("&#x2014;", "-", s, fixed = TRUE)
  s <- gsub("&#xa;",   " ", s, fixed = TRUE)
  s <- str_squish(s)
  if (!nzchar(s)) NA_character_ else s
}

crossref_works_by_grant <- function(award_number,
                                    funder_dois = CIHR_CROSSREF_FUNDER_DOIS,
                                    rows = 100) {
  if (is.na(award_number) || !nzchar(award_number)) return(tibble())
  # Depositors send CIHR Project Grant IDs as either a bare 6-digit number
  # ("159682") or with a "PJT-" prefix ("PJT-159682").  For pre-2020
  # competitions the prefixed form is the more common deposit style, so
  # bare-only misses most strict hits.  Query both and union the raw items;
  # the post-filter below requires the bare number bounded by non-digits,
  # which accepts either form and rejects near-collisions.
  #
  # Crossref's filter grammar ORs repeated same-field values, so listing
  # multiple `funder:` entries reads as "parent CIHR OR any institute".
  variants <- c(award_number, sprintf("PJT-%s", award_number))
  funder_clause <- paste(sprintf("funder:%s", funder_dois), collapse = ",")
  items <- list()
  for (v in variants) {
    q <- list(
      filter = sprintf("%s,award.number:%s", funder_clause, v),
      rows   = rows,
      mailto = POLITE_MAILTO
    )
    r <- .safe_get("https://api.crossref.org/works", q)
    if (!is.null(r) && length(r$message$items)) {
      items <- c(items, r$message$items)
    }
  }
  if (!length(items)) return(tibble())
  dois <- vapply(items, \(it) it$DOI %||% "", character(1))
  items <- items[!duplicated(dois) | !nzchar(dois)]
  # Crossref's compound filter matches "has CIHR funder AND has award=X on any
  # funder", not "has award=X on the CIHR funder".  Post-filter so only works
  # where CIHR itself lists the award survive.
  want_pat <- sprintf("(^|[^0-9])%s([^0-9]|$)", award_number)
  items <- Filter(function(it) {
    a <- .crossref_cihr_awards(it, funder_dois)
    !is.na(a) && grepl(want_pat, a)
  }, items)
  if (!length(items)) return(tibble())
  map_dfr(items, \(it) tibble(
    source        = "Crossref",
    doi           = it$DOI %||% NA_character_,
    title         = .first(it$title, NA_character_),
    abstract      = .crossref_abstract_text(it$abstract),
    year          = suppressWarnings(as.integer(.first(.first(it$issued$`date-parts`, list(NA)), NA))),
    venue         = .first(it$`container-title`, NA_character_),
    type          = it$type %||% NA_character_,
    is_oa         = NA,
    oa_status     = NA_character_,
    url           = it$URL %||% NA_character_,
    matched_award = .crossref_cihr_awards(it),
    matched_by    = "grant+funder"
  ))
}

crossref_works_by_pi_funder <- function(pi_name,
                                        funder_dois = CIHR_CROSSREF_FUNDER_DOIS,
                                        from_year = 2021, rows = 50) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  funder_clause <- paste(sprintf("funder:%s", funder_dois), collapse = ",")
  q <- list(
    filter = sprintf("%s,from-pub-date:%d", funder_clause, from_year),
    query.author = pi_name,
    rows   = rows,
    mailto = POLITE_MAILTO
  )
  r <- .safe_get("https://api.crossref.org/works", q)
  if (is.null(r)) return(tibble())
  items <- r$message$items
  if (!length(items)) return(tibble())
  map_dfr(items, \(it) tibble(
    source        = "Crossref",
    doi           = it$DOI %||% NA_character_,
    title         = .first(it$title, NA_character_),
    abstract      = .crossref_abstract_text(it$abstract),
    year          = suppressWarnings(as.integer(.first(.first(it$issued$`date-parts`, list(NA)), NA))),
    venue         = .first(it$`container-title`, NA_character_),
    type          = it$type %||% NA_character_,
    is_oa         = NA,
    oa_status     = NA_character_,
    url           = it$URL %||% NA_character_,
    matched_award = .crossref_cihr_awards(it),
    matched_by    = "PI+funder"
  ))
}

# PI-only Crossref (no funder filter). Potentially very broad — capped
# by `rows` (default 50). For the fallback "PI (any)" match type.
crossref_works_by_pi_any <- function(pi_name, from_year = 2021, rows = 50) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  q <- list(
    filter = sprintf("from-pub-date:%d", from_year),
    query.author = pi_name,
    rows   = rows,
    mailto = POLITE_MAILTO
  )
  r <- .safe_get("https://api.crossref.org/works", q)
  if (is.null(r)) return(tibble())
  items <- r$message$items
  if (!length(items)) return(tibble())
  map_dfr(items, \(it) tibble(
    source        = "Crossref",
    doi           = it$DOI %||% NA_character_,
    title         = .first(it$title, NA_character_),
    abstract      = .crossref_abstract_text(it$abstract),
    year          = suppressWarnings(as.integer(.first(.first(it$issued$`date-parts`, list(NA)), NA))),
    venue         = .first(it$`container-title`, NA_character_),
    type          = it$type %||% NA_character_,
    is_oa         = NA,
    oa_status     = NA_character_,
    url           = it$URL %||% NA_character_,
    matched_award = .crossref_cihr_awards(it),
    matched_by    = "PI (any sponsor)"
  ))
}

# ---- OpenAlex ---------------------------------------------------------------

# Reconstruct abstract text from OpenAlex's inverted-index format.
# `abstract_inverted_index` is a named list: word -> integer positions.
# Build a position-ordered word vector and paste.  Returns NA_character_ if
# the field is missing or empty (common for older works / non-papers).
.openalex_abstract_text <- function(idx) {
  if (is.null(idx) || length(idx) == 0) return(NA_character_)
  words <- names(idx)
  positions <- unlist(idx, use.names = FALSE)
  if (!length(positions)) return(NA_character_)
  rep_words <- rep(words, lengths(idx))
  out <- character(max(positions) + 1L)
  out[positions + 1L] <- rep_words
  txt <- paste(out, collapse = " ")
  txt <- stringr::str_squish(txt)
  if (!nzchar(txt)) NA_character_ else txt
}

.openalex_work_tbl <- function(items, matched_by) {
  map_dfr(items, \(it) tibble(
    source        = "OpenAlex",
    openalex_id   = it$id %||% NA_character_,
    doi           = if (!is.null(it$doi)) sub("^https?://doi.org/", "", it$doi) else NA_character_,
    title         = it$title %||% it$display_name %||% NA_character_,
    abstract      = .openalex_abstract_text(it$abstract_inverted_index),
    year          = it$publication_year %||% NA_integer_,
    venue         = it$primary_location$source$display_name %||% NA_character_,
    type          = it$type %||% NA_character_,
    is_oa         = it$open_access$is_oa %||% NA,
    oa_status     = it$open_access$oa_status %||% NA_character_,
    oa_pdf_url    = it$best_oa_location$pdf_url %||% NA_character_,
    url           = it$primary_location$landing_page_url %||%
                    (if (!is.null(it$doi)) it$doi else NA_character_),
    matched_award = .openalex_cihr_awards(it),
    matched_by    = matched_by
  ))
}

openalex_works_by_grant <- function(award_number,
                                    funder_ids = CIHR_OPENALEX_FUNDER_IDS,
                                    per_page = 100) {
  if (is.na(award_number) || !nzchar(award_number)) return(tibble())
  # Both "159682" and "PJT-159682" forms exist in OpenAlex awards records
  # (same comment as the Crossref client).  Union the two queries; the bare-
  # number post-filter accepts either form.  OpenAlex `|` is OR within a
  # single filter value, so the 20-institute union is one clause.
  variants <- c(award_number, sprintf("PJT-%s", award_number))
  funder_clause <- paste(funder_ids, collapse = "|")
  results <- list()
  for (v in variants) {
    q <- list(
      filter   = sprintf("awards.funder_id:%s,awards.funder_award_id:%s",
                         funder_clause, v),
      per_page = per_page,
      mailto   = POLITE_MAILTO
    )
    r <- .safe_get("https://api.openalex.org/works", q)
    if (!is.null(r) && length(r$results)) {
      results <- c(results, r$results)
    }
  }
  if (!length(results)) return(tibble())
  ids <- vapply(results, \(it) it$id %||% "", character(1))
  results <- results[!duplicated(ids) | !nzchar(ids)]
  # OpenAlex's compound filter cross-joins across a work's award items
  # (matches if any award has funder=CIHR and any award has id=X).  Keep only
  # works where the CIHR-specific award id actually matches.
  want_pat <- sprintf("(^|[^0-9])%s([^0-9]|$)", award_number)
  keep <- vapply(results, function(it) {
    a <- .openalex_cihr_awards(it, funder_ids)
    !is.na(a) && grepl(want_pat, a)
  }, logical(1))
  if (!any(keep)) return(tibble())
  .openalex_work_tbl(results[keep], "grant+funder")
}

openalex_find_author <- function(pi_name, institution_hint = NULL) {
  if (!nzchar(pi_name %||% "")) return(NULL)
  q <- list(search = pi_name, per_page = 5, mailto = POLITE_MAILTO)
  r <- .safe_get("https://api.openalex.org/authors", q)
  if (is.null(r) || !length(r$results)) return(NULL)
  authors <- r$results
  # Prefer an affiliation hint if given
  if (!is.null(institution_hint) && !is.na(institution_hint) && nzchar(institution_hint)) {
    tok <- str_to_lower(str_split(institution_hint, "\\s+")[[1]])
    tok <- tok[nchar(tok) > 3]
    if (length(tok)) {
      score <- map_int(authors, \(a) {
        aff <- str_to_lower(a$last_known_institution$display_name %||% "")
        sum(map_int(tok, \(t) as.integer(str_detect(aff, fixed(t)))))
      })
      if (length(score) && max(score, 0, na.rm = TRUE) > 0) {
        authors <- authors[score == max(score)]
      }
    }
  }
  authors[[1]]
}

openalex_works_by_author <- function(author_id,
                                     funder_ids = CIHR_OPENALEX_FUNDER_IDS,
                                     from_year = 2021, per_page = 100) {
  if (is.null(author_id) || !nzchar(author_id)) return(tibble())
  funder_clause <- paste(funder_ids, collapse = "|")
  q <- list(
    filter   = sprintf("author.id:%s,awards.funder_id:%s,from_publication_date:%d-01-01",
                       author_id, funder_clause, from_year),
    per_page = per_page,
    mailto   = POLITE_MAILTO
  )
  r <- .safe_get("https://api.openalex.org/works", q)
  if (is.null(r) || !length(r$results)) return(tibble())
  .openalex_work_tbl(r$results, "PI+funder")
}

# PI-only OpenAlex (no funder filter). Used by the fallback "PI (any)"
# match type: surfaces author outputs that don't self-report CIHR funding.
# Can be noisy (homonyms, large author corpora) — human review required.
openalex_works_by_author_any <- function(author_id, from_year = 2021,
                                         per_page = 100) {
  if (is.null(author_id) || !nzchar(author_id)) return(tibble())
  q <- list(
    filter   = sprintf("author.id:%s,from_publication_date:%d-01-01",
                       author_id, from_year),
    per_page = per_page,
    mailto   = POLITE_MAILTO
  )
  r <- .safe_get("https://api.openalex.org/works", q)
  if (is.null(r) || !length(r$results)) return(tibble())
  .openalex_work_tbl(r$results, "PI (any sponsor)")
}

# Extract bare 0000-0000-0000-0000 ORCID from whatever form OpenAlex returns.
extract_orcid <- function(x) {
  if (is.null(x) || !nzchar(x)) return(NA_character_)
  m <- stringr::str_extract(x, "[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]")
  if (is.na(m)) NA_character_ else m
}

openalex_works_by_orcid <- function(orcid,
                                    funder_ids = CIHR_OPENALEX_FUNDER_IDS,
                                    from_year = 2021, per_page = 100) {
  if (is.null(orcid) || is.na(orcid) || !nzchar(orcid)) return(tibble())
  funder_clause <- paste(funder_ids, collapse = "|")
  q <- list(
    filter   = sprintf("author.orcid:%s,awards.funder_id:%s,from_publication_date:%d-01-01",
                       orcid, funder_clause, from_year),
    per_page = per_page,
    mailto   = POLITE_MAILTO
  )
  r <- .safe_get("https://api.openalex.org/works", q)
  if (is.null(r) || !length(r$results)) return(tibble())
  .openalex_work_tbl(r$results, "ORCID+funder")
}

# ---- DataCite ---------------------------------------------------------------

.datacite_tbl <- function(items, matched_by, award_number = NULL) {
  map_dfr(items, \(it) {
    a <- it$attributes
    tibble(
      source        = "DataCite",
      doi           = a$doi %||% NA_character_,
      title         = {
        t <- a$titles
        if (is.null(t) || length(t) == 0) NA_character_
        else (t[[1]]$title %||% NA_character_)
      },
      year          = a$publicationYear %||% NA_integer_,
      venue         = a$publisher %||% NA_character_,
      type          = a$types$resourceTypeGeneral %||% a$types$resourceType %||% NA_character_,
      url           = a$url %||% sprintf("https://doi.org/%s", a$doi %||% ""),
      matched_award = .datacite_cihr_awards(a, award_number = award_number),
      matched_by    = matched_by
    )
  })
}

datacite_by_grant <- function(award_number,
                              funder_dois = CIHR_CROSSREF_FUNDER_DOIS,
                              ror = CIHR_ROR, funder_names = CIHR_FUNDER_NAMES,
                              page_size = 100) {
  if (is.na(award_number) || !nzchar(award_number)) return(tibble())
  # Three passes: (1) funder-identifier = any CIHR Funder DOI (parent or
  # institute), (2) funder-identifier = ROR form,
  # (3) funder-name = any CIHR / institute name.
  # Depositors use any of the three; union deduplicated by DOI.  Each pass
  # also ORs the two award-number forms ("159682" and "PJT-159682") since
  # depositors (especially for pre-2020 competitions) favour the prefix.
  award_clause <- sprintf(
    '(fundingReferences.awardNumber:"%s" OR fundingReferences.awardNumber:"PJT-%s")',
    award_number, award_number
  )
  dois_clause <- paste(
    sprintf('fundingReferences.funderIdentifier:"%s"', funder_dois),
    collapse = " OR "
  )
  names_clause <- paste(sprintf('fundingReferences.funderName:"%s"', funder_names),
                        collapse = " OR ")
  queries <- c(
    sprintf('(%s) AND %s', dois_clause, award_clause),
    sprintf('fundingReferences.funderIdentifier:"%s" AND %s', ror, award_clause),
    sprintf('(%s) AND %s', names_clause, award_clause)
  )
  out <- tibble()
  for (q_expr in queries) {
    r <- .safe_get("https://api.datacite.org/dois",
                   list(query = q_expr, `page[size]` = page_size))
    if (!is.null(r) && length(r$data)) {
      out <- bind_rows(out, .datacite_tbl(r$data, "grant+funder",
                                          award_number = award_number))
    }
  }
  if (nrow(out) == 0) return(out)
  distinct(out, doi, .keep_all = TRUE)
}

datacite_by_orcid <- function(orcid, from_year = 2021, page_size = 100) {
  if (is.null(orcid) || is.na(orcid) || !nzchar(orcid)) return(tibble())
  # The full-URL form of the identifier is the best-populated variant in practice.
  q_expr <- sprintf(
    '(creators.nameIdentifiers.nameIdentifier:"https\\://orcid.org/%s" OR contributors.nameIdentifiers.nameIdentifier:"https\\://orcid.org/%s") AND publicationYear:[%d TO *]',
    orcid, orcid, from_year
  )
  r <- .safe_get("https://api.datacite.org/dois",
                 list(query = q_expr, `page[size]` = page_size))
  if (is.null(r) || !length(r$data)) return(tibble())
  out <- .datacite_tbl(r$data, "ORCID")
  if (nrow(out) == 0) out else distinct(out, doi, .keep_all = TRUE)
}

datacite_by_pi <- function(pi_name,
                           funder_dois = CIHR_CROSSREF_FUNDER_DOIS,
                           ror = CIHR_ROR, funder_names = CIHR_FUNDER_NAMES,
                           from_year = 2021, page_size = 100) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  # Three funder fallbacks: Funder-DOI union, ROR, funderName union.
  pi_clause <- sprintf('(creators.name:"%s" OR contributors.name:"%s")',
                       pi_name, pi_name)
  year_clause <- sprintf('publicationYear:[%d TO *]', from_year)
  dois_clause <- paste(
    sprintf('fundingReferences.funderIdentifier:"%s"', funder_dois),
    collapse = " OR "
  )
  names_clause <- paste(sprintf('fundingReferences.funderName:"%s"', funder_names),
                        collapse = " OR ")
  queries <- c(
    sprintf('%s AND (%s) AND %s', pi_clause, dois_clause, year_clause),
    sprintf('%s AND fundingReferences.funderIdentifier:"%s" AND %s',
            pi_clause, ror, year_clause),
    sprintf('%s AND (%s) AND %s', pi_clause, names_clause, year_clause)
  )
  out <- tibble()
  for (q_expr in queries) {
    r <- .safe_get("https://api.datacite.org/dois",
                   list(query = q_expr, `page[size]` = page_size))
    if (!is.null(r) && length(r$data)) {
      out <- bind_rows(out, .datacite_tbl(r$data, "PI+funder"))
    }
  }
  if (nrow(out) == 0) return(out)
  distinct(out, doi, .keep_all = TRUE)
}

# PI-only DataCite (no funder filter). Used by the "PI (any)" match
# type. DataCite's query is Lucene-style so we quote the name to keep
# it as a phrase match on creators/contributors.
datacite_by_pi_any <- function(pi_name, from_year = 2021, page_size = 100) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  q_expr <- sprintf(
    '(creators.name:"%s" OR contributors.name:"%s") AND publicationYear:[%d TO *]',
    pi_name, pi_name, from_year
  )
  r <- .safe_get("https://api.datacite.org/dois",
                 list(query = q_expr, `page[size]` = page_size))
  if (is.null(r) || !length(r$data)) return(tibble())
  out <- .datacite_tbl(r$data, "PI (any sponsor)")
  if (nrow(out) == 0) out else distinct(out, doi, .keep_all = TRUE)
}

# Backchain: given a set of paper DOIs that have already been strictly
# matched to the grant, find DataCite records whose `relatedIdentifiers`
# point to any of those papers.  Catches datasets / supplements that
# don't self-report CIHR funding but are cited by a CIHR-funded paper.
# Queries in batches with an OR clause to limit the number of calls.
datacite_by_related_dois <- function(paper_dois, batch_size = 10,
                                     page_size = 100) {
  dois <- unique(paper_dois[!is.na(paper_dois) & nzchar(paper_dois)])
  if (!length(dois)) return(tibble())
  out <- tibble()
  chunks <- split(dois, ceiling(seq_along(dois) / batch_size))
  for (chunk in chunks) {
    # Depositors store related identifiers in both bare-DOI ("10.x/y")
    # and URL ("https://doi.org/10.x/y") form.  Try both.
    clauses <- unlist(lapply(chunk, \(d) c(
      sprintf('relatedIdentifiers.relatedIdentifier:"%s"', d),
      sprintf('relatedIdentifiers.relatedIdentifier:"https\\://doi.org/%s"', d)
    )))
    q_expr <- sprintf("(%s)", paste(clauses, collapse = " OR "))
    r <- .safe_get("https://api.datacite.org/dois",
                   list(query = q_expr, `page[size]` = page_size))
    if (is.null(r) || !length(r$data)) next
    # Label each row with the specific paper DOI(s) it relates to, so the
    # user can see the provenance in the matched-works table.
    tbl <- .datacite_tbl(r$data, "related-to-strict-paper")
    rel_dois <- vapply(r$data, function(d) {
      ris <- d$attributes$relatedIdentifiers %||% list()
      hits <- vapply(ris, function(ri) {
        rid <- ri$relatedIdentifier %||% ""
        bare <- sub("^https?://(dx\\.)?doi.org/", "", rid, ignore.case = TRUE)
        if (bare %in% chunk) bare else NA_character_
      }, character(1))
      hits <- unique(hits[!is.na(hits)])
      if (!length(hits)) NA_character_ else paste(hits, collapse = "; ")
    }, character(1))
    tbl$matched_by <- ifelse(is.na(rel_dois), "related-to-strict-paper",
                             sprintf("related-to:%s", rel_dois))
    out <- bind_rows(out, tbl)
  }
  if (nrow(out) == 0) return(out)
  distinct(out, doi, .keep_all = TRUE)
}

# ---- ClinicalTrials.gov v2 --------------------------------------------------

.safe_pluck <- function(x, ...) {
  keys <- c(...)
  for (k in keys) {
    if (is.null(x) || !is.list(x)) return(NULL)
    x <- x[[k]]
  }
  x
}

.ctgov_tbl <- function(studies, matched_by) {
  map_dfr(studies, \(s) {
    p  <- s$protocolSection
    id <- p$identificationModule %||% list()
    sp <- p$sponsorCollaboratorsModule %||% list()
    status <- p$statusModule %||% list()
    tibble(
      source      = "ClinicalTrials.gov",
      nct_id      = id$nctId %||% NA_character_,
      title       = id$briefTitle %||% NA_character_,
      status      = status$overallStatus %||% NA_character_,
      start_date  = .safe_pluck(status, "startDateStruct", "date") %||% NA_character_,
      lead_sponsor= .safe_pluck(sp, "leadSponsor", "name") %||% NA_character_,
      collaborators = paste(map_chr(sp$collaborators %||% list(),
                                    \(cl) cl$name %||% ""), collapse = "; "),
      url         = sprintf("https://clinicaltrials.gov/study/%s", id$nctId %||% ""),
      matched_by  = matched_by
    )
  })
}

ctgov_by_pi <- function(pi_name, sponsor_terms = CIHR_CTGOV_SPONSORS,
                        page_size = 50) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  # CT.gov's `query.spons` is a substring match.  Records that spell out
  # "Canadian Institutes of Health Research" won't match the acronym and
  # vice versa (empirically +2.7% studies on the acronym), so union both.
  out <- tibble()
  for (sp in sponsor_terms) {
    q <- list(
      `query.lead` = pi_name,
      `query.spons` = sp,
      pageSize = page_size,
      countTotal = "true"
    )
    r <- .safe_get("https://clinicaltrials.gov/api/v2/studies", q)
    if (!is.null(r) && length(r$studies)) {
      out <- bind_rows(out, .ctgov_tbl(r$studies, "PI+sponsor"))
    }
  }
  if (nrow(out) == 0) return(out)
  distinct(out, nct_id, .keep_all = TRUE)
}

ctgov_by_pi_broad <- function(pi_name, page_size = 50) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  q <- list(`query.term` = pi_name, pageSize = page_size, countTotal = "true")
  r <- .safe_get("https://clinicaltrials.gov/api/v2/studies", q)
  if (is.null(r) || !length(r$studies)) return(tibble())
  .ctgov_tbl(r$studies, "PI (any sponsor)")
}

ctgov_by_term <- function(term, page_size = 20) {
  if (!nzchar(term %||% "")) return(tibble())
  q <- list(`query.term` = term, pageSize = page_size, countTotal = "true")
  r <- .safe_get("https://clinicaltrials.gov/api/v2/studies", q)
  if (is.null(r) || !length(r$studies)) return(tibble())
  .ctgov_tbl(r$studies, sprintf("term:%s", term))
}

# --- helper: pick the most distinctive tokens from a grant title + keyword field
CTGOV_STOPWORDS <- c(
  "the","and","for","with","from","into","upon","a","an","of","in","to","on","by",
  "at","is","as","or","be","are","was","were","it","we","our","this","that","these",
  "those","patient","patients","study","trial","randomized","controlled","clinical",
  "research","project","program","grant","development","novel","new","based",
  "role","effect","effects","using","use","using","evaluation","assessment",
  "analysis","canadian","canada","health","care"
)

grant_keywords <- function(grant_row, max_tokens = 6) {
  tokenise <- function(x) {
    stringr::str_to_lower(x %||% "") |>
      stringr::str_replace_all("[^a-z0-9 ;,-]", " ") |>
      stringr::str_split("[;,\\s]+") |> unlist() |>
      (\(t) t[nchar(t) > 4 & !t %in% CTGOV_STOPWORDS])()
  }
  # Prefer long / distinctive title words first, then controlled keywords
  long_title <- tokenise(grant_row$title)
  long_title <- long_title[order(-nchar(long_title))]
  kw_field   <- tokenise(grant_row$keywords)
  out <- unique(c(long_title, kw_field))
  head(out, max_tokens)
}

# Search CT.gov using PI surname + keywords drawn from the grant.
# Returns separate rows per keyword so the user can see which term matched.
ctgov_by_pi_keywords <- function(pi_name, grant_row, page_size = 10) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  surname <- stringr::str_split(pi_name, "\\s+")[[1]]
  surname <- surname[length(surname)]
  kws <- grant_keywords(grant_row)
  if (!length(kws)) return(tibble())
  out <- tibble()
  for (kw in kws) {
    term <- sprintf("%s %s", surname, kw)
    q <- list(`query.term` = term, pageSize = page_size, countTotal = "true")
    r <- .safe_get("https://clinicaltrials.gov/api/v2/studies", q)
    if (!is.null(r) && length(r$studies)) {
      tbl <- .ctgov_tbl(r$studies, sprintf("PI+kw:%s", kw))
      out <- bind_rows(out, tbl)
    }
  }
  if (nrow(out) == 0) out else distinct(out, nct_id, .keep_all = TRUE)
}

# ---- Europe PMC -------------------------------------------------------------
# EPMC's publications REST API supports grant-linked search via the
# GRANT_ID + GRANT_AGENCY fields.  CIHR appears in grantsList under two
# agency strings ("CIHR" and "Canadian Institutes of Health Research")
# sometimes on the same paper, so we OR both when filtering.

EPMC_SEARCH_URL <- "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
# EPMC's `grantsList.grant.agency` is a free-text string — sometimes the
# parent CIHR, sometimes a specific institute (e.g. ARTESiA NEJM paper is
# tagged only to "Institute of Circulatory and Respiratory Health").  Union
# all the name variants CIHR-Funder-DOI-mapped entities appear under.
EPMC_CIHR_AGENCIES <- CIHR_FUNDER_NAMES
EPMC_FUNDER_QUERY <- sprintf(
  "(%s)",
  paste(sprintf('GRANT_AGENCY:"%s"', EPMC_CIHR_AGENCIES), collapse = " OR ")
)

.epmc_cihr_awards <- function(grants_list) {
  if (is.null(grants_list) || !length(grants_list)) return(NA_character_)
  grants <- grants_list$grant %||% grants_list
  if (is.null(grants) || !length(grants)) return(NA_character_)
  ids <- unlist(lapply(grants, function(g) {
    ag <- g$agency %||% ""
    if (ag %in% EPMC_CIHR_AGENCIES) g$grantId else NULL
  }))
  if (!length(ids)) NA_character_ else paste(unique(ids), collapse = "; ")
}

.epmc_tbl <- function(results, matched_by) {
  # Coerce any JSON-returned scalar/list/vector into a single string, or
  # NA_character_ if empty.  EPMC returns multi-valued fields (e.g. pubType
  # as a list of strings, occasionally doi as a short vector) that have to
  # be flattened before they'll fit into a tibble column.
  pick1 <- function(x) {
    if (is.null(x) || length(x) == 0) return(NA_character_)
    v <- as.character(unlist(x, use.names = FALSE))
    if (!length(v)) return(NA_character_)
    v1 <- v[1]
    if (is.na(v1) || !nzchar(v1)) NA_character_ else v1
  }
  # Pull a direct OA PDF URL from EPMC's fullTextUrlList. Prefer
  # documentStyle="pdf" with availabilityCode="OA"; fall back to any pdf
  # entry if no explicit OA flag is present.
  pick_oa_pdf <- function(ftul) {
    entries <- ftul$fullTextUrl
    if (is.null(entries) || !length(entries)) return(NA_character_)
    if (is.data.frame(entries)) {
      style <- tolower(entries$documentStyle %||% rep("", nrow(entries)))
      avail <- toupper(entries$availabilityCode %||% rep("", nrow(entries)))
      url   <- entries$url %||% rep(NA_character_, nrow(entries))
      hit <- which(style == "pdf" & avail == "OA")
      if (!length(hit)) hit <- which(style == "pdf")
      if (!length(hit)) return(NA_character_)
      u <- url[hit[1]]
      if (is.na(u) || !nzchar(u)) NA_character_ else u
    } else {
      pdf_oa <- Filter(function(e) {
        identical(tolower(e$documentStyle %||% ""), "pdf") &&
          identical(toupper(e$availabilityCode %||% ""), "OA")
      }, entries)
      if (!length(pdf_oa)) {
        pdf_oa <- Filter(function(e) identical(tolower(e$documentStyle %||% ""), "pdf"),
                         entries)
      }
      if (!length(pdf_oa)) return(NA_character_)
      pick1(pdf_oa[[1]]$url)
    }
  }
  map_dfr(results, function(r) {
    pmid <- pick1(r$pmid)
    src  <- pick1(r$source); if (is.na(src)) src <- "MED"
    doi  <- pick1(r$doi)
    type_str  <- pick1(r$pubType %||% r$pubTypeList$pubType)
    venue_str <- pick1(r$journalInfo$journal$title %||% r$journalTitle)
    title_str <- pick1(r$title)
    abstract_str <- pick1(r$abstractText)
    year_int  <- suppressWarnings(as.integer(pick1(r$pubYear)))
    is_oa_v   <- if (!is.null(r$isOpenAccess)) identical(pick1(r$isOpenAccess), "Y") else NA
    url <- if (!is.na(doi)) sprintf("https://doi.org/%s", doi)
           else if (!is.na(pmid)) sprintf("https://europepmc.org/article/%s/%s", src, pmid)
           else NA_character_
    tibble(
      source        = "Europe PMC",
      doi           = doi,
      title         = title_str,
      abstract      = abstract_str,
      year          = year_int,
      venue         = venue_str,
      type          = type_str,
      is_oa         = is_oa_v,
      oa_status     = NA_character_,
      oa_pdf_url    = pick_oa_pdf(r$fullTextUrlList),
      url           = url,
      matched_award = .epmc_cihr_awards(r$grantsList),
      matched_by    = matched_by,
      pmid          = pmid,
      epmc_source   = src
    )
  })
}

europepmc_by_grant <- function(award_number, page_size = 100) {
  if (is.na(award_number) || !nzchar(award_number)) return(tibble())
  # EPMC's GRANT_ID is tokenised as a phrase, so "159682" won't match
  # "PJT-159682" and vice versa.  OR both forms — pre-2020 CIHR Project
  # Grants are predominantly deposited with the PJT- prefix.
  query <- sprintf('(GRANT_ID:"%s" OR GRANT_ID:"PJT-%s") AND %s',
                   award_number, award_number, EPMC_FUNDER_QUERY)
  q <- list(query = query, format = "json", resultType = "core",
            pageSize = page_size)
  r <- .safe_get(EPMC_SEARCH_URL, q)
  if (is.null(r) || !length(r$resultList$result)) return(tibble())
  # Defensive post-filter: keep only hits where the CIHR-tagged grantId
  # actually matches the bare award number.  EPMC's GRANT_ID is
  # substring-tokenised so a query for "175325" could in theory match
  # "1753250" etc.
  want_pat <- sprintf("(^|[^0-9])%s([^0-9]|$)", award_number)
  results <- r$resultList$result
  keep <- vapply(results, function(x) {
    a <- .epmc_cihr_awards(x$grantsList)
    !is.na(a) && grepl(want_pat, a)
  }, logical(1))
  if (!any(keep)) return(tibble())
  .epmc_tbl(results[keep], "grant+funder")
}

europepmc_by_pi <- function(pi_name, from_year = 2021, page_size = 100) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  query <- sprintf('AUTH:"%s" AND %s AND FIRST_PDATE:[%d-01-01 TO *]',
                   pi_name, EPMC_FUNDER_QUERY, from_year)
  q <- list(query = query, format = "json", resultType = "core",
            pageSize = page_size)
  r <- .safe_get(EPMC_SEARCH_URL, q)
  if (is.null(r) || !length(r$resultList$result)) return(tibble())
  .epmc_tbl(r$resultList$result, "PI+funder")
}

# PI-only Europe PMC (no funder filter). Used by the "PI (any)" match type.
europepmc_by_pi_any <- function(pi_name, from_year = 2021, page_size = 100) {
  if (!nzchar(pi_name %||% "")) return(tibble())
  query <- sprintf('AUTH:"%s" AND FIRST_PDATE:[%d-01-01 TO *]',
                   pi_name, from_year)
  q <- list(query = query, format = "json", resultType = "core",
            pageSize = page_size)
  r <- .safe_get(EPMC_SEARCH_URL, q)
  if (is.null(r) || !length(r$resultList$result)) return(tibble())
  .epmc_tbl(r$resultList$result, "PI (any sponsor)")
}

# ---- OpenAIRE ---------------------------------------------------------------
# Note: OpenAIRE does not index CIHR projects in their graph, so direct
# grant-ID matches return very few results.  We include it mainly as a
# PI-search fallback (via author name / ORCID).

openaire_by_pi <- function(pi_name, from_year = 2021, size = 25,
                            funder = "cihr",
                            matched_by = "PI+funder(OpenAIRE)") {
  if (!nzchar(pi_name %||% "")) return(tibble())
  q <- list(
    author = pi_name,
    fromDateAccepted = sprintf("%d-01-01", from_year),
    format = "json",
    size = size
  )
  if (!is.null(funder) && nzchar(funder)) q$funder <- funder
  r <- .safe_get("https://api.openaire.eu/search/publications", q)
  if (is.null(r)) return(tibble())
  results <- r$response$results$result %||% list()
  if (!length(results)) return(tibble())
  map_dfr(results, \(res) {
    md <- res$metadata$`oaf:entity`$`oaf:result`
    tryCatch(tibble(
      source      = "OpenAIRE",
      title       = if (is.list(md$title)) md$title[[1]]$`$` else md$title$`$` %||% NA_character_,
      year        = suppressWarnings(as.integer(substr(md$dateofacceptance$`$` %||% NA_character_, 1, 4))),
      doi         = {
        pid <- md$pid
        if (is.null(pid)) NA_character_ else {
          if (!is.null(pid$`$`)) pid$`$` else pid[[1]]$`$` %||% NA_character_
        }
      },
      is_oa       = NA,
      oa_status   = NA_character_,
      url         = NA_character_,
      matched_by  = matched_by
    ), error = function(e) tibble())
  })
}

# PI-only OpenAIRE (no funder filter). Used by the "PI (any)" match type.
openaire_by_pi_any <- function(pi_name, from_year = 2021, size = 25) {
  openaire_by_pi(pi_name, from_year = from_year, size = size,
                 funder = NULL, matched_by = "PI (any sponsor)")
}

# ---- Aggregator -------------------------------------------------------------

# Drop rows from a results tibble whose year predates the grant's
# competition fiscal year. CT.gov has no `year` column; use start_date
# (YYYY-MM-DD or YYYY Month DD) as a proxy. Rows with unknown year are
# kept (we'd rather surface an unknown-year row for the user to check
# than silently drop it).
.filter_by_year <- function(tbl, from_year) {
  if (is.null(tbl) || nrow(tbl) == 0) return(tbl)
  if ("year" %in% names(tbl)) {
    keep <- is.na(tbl$year) | tbl$year >= from_year
    return(tbl[keep, , drop = FALSE])
  }
  if ("start_date" %in% names(tbl)) {
    yr <- suppressWarnings(as.integer(substr(tbl$start_date, 1, 4)))
    keep <- is.na(yr) | yr >= from_year
    return(tbl[keep, , drop = FALSE])
  }
  tbl
}

# Drop open-peer-review artifacts that share a DOI family with a paper but
# aren't the paper.  Two signals, ORed (belt-and-braces):
#   - DOI suffix matches a known review-report scheme:
#       eLife          10.7554/elife.<N>.sa0|sa1|sa2     ("supplementary article")
#       F1000-family   10.5256|10.12688/<journal>.<N>.r<M>  (per-reviewer reports)
#   - Crossref / OpenAlex `type` is "peer-review" (catches publishers whose
#     DOI scheme doesn't telegraph the artifact type, e.g. some BMJ / MDPI).
# Without the filter, these slip into the fallback candidate set with the
# parent paper's title verbatim, no abstract, and (post-normalisation) often
# float to similarity = 1.00.
.filter_peer_reviews <- function(tbl) {
  if (is.null(tbl) || nrow(tbl) == 0) return(tbl)
  drop <- logical(nrow(tbl))
  if ("doi" %in% names(tbl)) {
    d <- tolower(ifelse(is.na(tbl$doi), "", tbl$doi))
    drop <- drop | grepl("\\.sa\\d+$", d) | grepl("\\.r\\d+$", d)
  }
  if ("type" %in% names(tbl)) {
    ty <- tolower(ifelse(is.na(tbl$type), "", as.character(tbl$type)))
    drop <- drop | ty == "peer-review"
  }
  tbl[!drop, , drop = FALSE]
}

search_grant_all_sources <- function(grant_row, verbose = TRUE) {
  award   <- grant_award_number(grant_row$grant_id)
  pi_name <- grant_row$pi_full_name
  inst    <- grant_row$institution
  from_y  <- as.integer(substr(grant_row$competition_fy %||% "2021", 1, 4))
  if (is.na(from_y) || from_y < 2015) from_y <- 2021

  if (verbose) message(sprintf("--- %s | %s (award=%s, from_year=%d)",
                               grant_row$grant_id, pi_name, award, from_y))

  # Author lookup (used by OpenAlex PI fallback + ORCID extraction)
  author_obj <- openalex_find_author(pi_name, institution_hint = inst)
  author_id  <- if (!is.null(author_obj)) author_obj$id else NULL
  orcid      <- extract_orcid(author_obj$orcid %||% NA_character_)

  if (verbose && !is.na(orcid)) message("  ORCID resolved: ", orcid)

  strict <- list(
    openalex  = openalex_works_by_grant(award),
    crossref  = crossref_works_by_grant(award),
    datacite  = datacite_by_grant(award),
    ctgov     = ctgov_by_term(award),      # long-shot; award IDs rarely in CT.gov
    europepmc = europepmc_by_grant(award)
  )

  # Backchain: find DataCite records whose relatedIdentifiers cite any of
  # the papers we've already strictly matched.  Captures datasets and
  # supplements that don't self-report CIHR funding.  Appended to the
  # strict DataCite bucket with matched_by="related-to:<paper_doi>".
  strict_paper_dois <- unique(unlist(lapply(
    list(strict$openalex, strict$crossref, strict$europepmc),
    \(t) if (nrow(t) && "doi" %in% names(t)) t$doi else character()
  )))
  related_dc <- datacite_by_related_dois(strict_paper_dois)
  if (nrow(related_dc)) {
    strict$datacite <- bind_rows(strict$datacite, related_dc) |>
      distinct(doi, .keep_all = TRUE)
  }

  # Fallback match types: only two supported on the UI now —
  #   "PI + CIHR funder" (per-source PI + funder filter) and
  #   "PI (any sponsor)" (per-source PI-only, no funder filter).
  # One slot per (source, match type).
  fallback <- list(
    openalex_pi      = openalex_works_by_author(author_id, from_year = from_y),
    openalex_any     = openalex_works_by_author_any(author_id, from_year = from_y),
    crossref_pi      = crossref_works_by_pi_funder(pi_name, from_year = from_y),
    crossref_any     = crossref_works_by_pi_any(pi_name, from_year = from_y),
    datacite_pi      = datacite_by_pi(pi_name, from_year = from_y),
    datacite_any     = datacite_by_pi_any(pi_name, from_year = from_y),
    ctgov_pi         = ctgov_by_pi(pi_name),
    ctgov_any        = ctgov_by_pi_broad(pi_name),
    openaire         = openaire_by_pi(pi_name, from_year = from_y),
    openaire_any     = openaire_by_pi_any(pi_name, from_year = from_y),
    europepmc_pi     = europepmc_by_pi(pi_name, from_year = from_y),
    europepmc_any    = europepmc_by_pi_any(pi_name, from_year = from_y)
  )

  # Apply the competition-year floor to every bucket so the UI mirrors
  # the requirement that only outputs from the grant's competition year
  # or later are ever shown. Some APIs already filter at query time
  # (OpenAlex, Crossref with from-pub-date); this catches the rest
  # (DataCite strict, CT.gov, OpenAIRE) and keeps behaviour consistent
  # across tabs and the CSV export.
  strict   <- lapply(strict,   .filter_by_year, from_year = from_y)
  fallback <- lapply(fallback, .filter_by_year, from_year = from_y)
  strict   <- lapply(strict,   .filter_peer_reviews)
  fallback <- lapply(fallback, .filter_peer_reviews)

  list(
    grant    = grant_row,
    award    = award,
    author   = author_obj,
    orcid    = orcid,
    keywords = grant_keywords(grant_row),
    from_year = from_y,
    strict   = strict,
    fallback = fallback
  )
}

# ---- Outcome summary --------------------------------------------------------

summarise_outcomes <- function(search_result) {
  s <- search_result$strict
  f <- search_result$fallback
  oa_papers <- bind_rows(s$openalex, s$europepmc,
                         f$openalex_pi, f$europepmc_pi)
  if (nrow(oa_papers) == 0 || !"is_oa" %in% names(oa_papers)) {
    oa_papers <- tibble()
  } else {
    oa_papers <- oa_papers |> filter(!is.na(is_oa) & is_oa == TRUE)
  }
  all_papers <- bind_rows(s$openalex, s$crossref, s$europepmc,
                          f$openalex_pi, f$crossref_pi, f$europepmc_pi)
  trials <- bind_rows(s$ctgov, f$ctgov_pi)
  # OSF registrations often show up as DataCite type "Text" (registration) with OSF publisher
  all_data <- bind_rows(s$datacite, f$datacite_pi)
  osf <- if (nrow(all_data) == 0 || !"doi" %in% names(all_data)) {
    all_data
  } else {
    all_data |>
      filter(grepl("osf", tolower(doi %||% "")) |
             grepl("Center for Open Science", venue %||% "", ignore.case = TRUE))
  }

  tibble::tibble(
    outcome = c("Open-access paper linked?",
                "Trial registration linked?",
                "Open data linked?"),
    answer  = c(
      if (nrow(oa_papers) > 0)
        sprintf("Yes (%d OA paper(s))",
                nrow(distinct(oa_papers[, "doi", drop = FALSE])))
      else if (nrow(all_papers) > 0) "Papers found but OA status unknown/closed"
      else "No papers linked",
      if (nrow(trials) > 0)
        sprintf("Yes (%d trial(s) on ClinicalTrials.gov)", nrow(distinct(trials, nct_id)))
      else if (nrow(osf) > 0)
        sprintf("Yes (%d OSF registration(s) via DataCite)", nrow(osf))
      else "No trial/registration found",
      if (nrow(all_data) > 0)
        sprintf("Yes (%d dataset/record(s) in DataCite)", nrow(distinct(all_data, doi)))
      else "No open data records linked"
    )
  )
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
