suppressPackageStartupMessages({
  library(stringr)
})

# Similarity scoring for fallback-tab rows.
#
# Method (selected from a 13-combo bake-off in build/sim_eval.R):
#   BM25 with query = grant.keywords, document = item.title + item.abstract.
#   Best hard-negative AUC (0.89) — pushes same-PI-different-topic noise down.
#
# Trials and DataCite items have no abstract plumbed; their document is the
# title alone.  BM25's length normalisation handles short documents
# gracefully — they tend to score lower, which is correct.

# Stopwords: snowball (English) + research-vocab generic terms that hurt
# discrimination in the bake-off (study/method/result/etc.).  Inlined to
# avoid pulling tidytext into the runtime.
SIM_STOPWORDS <- c(
  # snowball
  "i","me","my","myself","we","our","ours","ourselves","you","your","yours",
  "yourself","yourselves","he","him","his","himself","she","her","hers",
  "herself","it","its","itself","they","them","their","theirs","themselves",
  "what","which","who","whom","this","that","these","those","am","is","are",
  "was","were","be","been","being","have","has","had","having","do","does",
  "did","doing","would","should","could","ought","i'm","you're","he's","she's",
  "it's","we're","they're","i've","you've","we've","they've","i'd","you'd",
  "he'd","she'd","we'd","they'd","i'll","you'll","he'll","she'll","we'll",
  "they'll","isn't","aren't","wasn't","weren't","hasn't","haven't","hadn't",
  "doesn't","don't","didn't","won't","wouldn't","shan't","shouldn't","can't",
  "cannot","couldn't","mustn't","let's","that's","who's","what's","here's",
  "there's","when's","where's","why's","how's","a","an","the","and","but",
  "if","or","because","as","until","while","of","at","by","for","with",
  "about","against","between","into","through","during","before","after",
  "above","below","to","from","up","down","in","out","on","off","over",
  "under","again","further","then","once","here","there","when","where",
  "why","how","all","any","both","each","few","more","most","other","some",
  "such","no","nor","not","only","own","same","so","than","too","very","will",
  # research-vocab
  "study","studies","research","paper","result","results","method","methods",
  "objective","objectives","background","conclusion","conclusions","purpose",
  "aim","aims","report","reported","reports","analysis","analyses","data",
  "based","using","use","used","approach","effect","effects","role","novel",
  "canadian","canada","patient","patients","trial","clinical","grant",
  "funding","funded","project","program"
)

.sim_tokenise <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  x <- x[1]
  if (is.na(x)) return(character(0))
  x <- tolower(x)
  x <- str_replace_all(x, "[^a-z0-9\\s]", " ")
  x <- str_squish(x)
  if (!nzchar(x)) return(character(0))
  tk <- str_split(x, "\\s+")[[1]]
  tk <- tk[nchar(tk) > 2]
  tk[!tk %in% SIM_STOPWORDS]
}

# Per-row document text.  Trials have no abstract; everyone else gets
# title + abstract when both are present, else whichever is non-NA.
.sim_doc_text <- function(rows) {
  has_abs <- "abstract" %in% names(rows)
  ttl <- rows$title %||% rep(NA_character_, nrow(rows))
  abs_ <- if (has_abs) rows$abstract else rep(NA_character_, nrow(rows))
  is_trial <- !is.na(rows$source) & rows$source == "ClinicalTrials.gov"
  out <- ifelse(
    is_trial | is.na(abs_) | !nzchar(as.character(abs_)),
    ifelse(is.na(ttl), "", as.character(ttl)),
    paste(ifelse(is.na(ttl), "", as.character(ttl)),
          as.character(abs_), sep = " ")
  )
  out
}

# BM25.  Returns a list with the raw per-doc score vector and the
# diagnostic sum-of-idf, used by the sparse-grant guard.
.sim_bm25 <- function(q_tokens, docs_tokens, k1 = 1.5, b = 0.75) {
  N <- length(docs_tokens)
  q_tokens <- unique(q_tokens)
  if (!N || !length(q_tokens)) {
    return(list(score = rep(0, N), idf_sum = 0))
  }
  doclen <- vapply(docs_tokens, length, integer(1))
  nz <- doclen > 0
  avgdl <- if (any(nz)) mean(doclen[nz]) else 1
  if (!is.finite(avgdl) || avgdl == 0) avgdl <- 1
  df <- vapply(q_tokens, function(t) {
    sum(vapply(docs_tokens, function(d) t %in% d, logical(1)))
  }, integer(1))
  idf <- log(1 + (N - df + 0.5) / (df + 0.5))
  score <- vapply(seq_len(N), function(i) {
    d <- docs_tokens[[i]]
    if (!length(d)) return(0)
    tf <- table(d)[q_tokens]
    tf[is.na(tf)] <- 0
    num <- as.numeric(tf) * (k1 + 1)
    den <- as.numeric(tf) + k1 * (1 - b + b * length(d) / avgdl)
    sum(idf * num / den)
  }, numeric(1))
  list(score = score, idf_sum = sum(idf))
}

# Tokens used as the BM25 query: grant.keywords (controlled MeSH-like
# terms).  Eval showed these beat title / title+abstract as the query.
grant_query_tokens <- function(grant_row) {
  if (is.null(grant_row)) return(character(0))
  .sim_tokenise(grant_row$keywords)
}

# Public entry point.  Returns a numeric vector aligned to `rows`:
#   - raw BM25 scores min-max normalised to [0, 1] per call;
#   - all NA if the grant has no usable keywords, or if no item gained
#     any meaningful BM25 mass (sparse-grant guard, threshold 5% of idf
#     sum — calibrated against the bake-off).
score_fallback <- function(rows, grant_row) {
  if (is.null(rows) || nrow(rows) == 0) return(numeric(0))
  q <- grant_query_tokens(grant_row)
  if (!length(q)) return(rep(NA_real_, nrow(rows)))
  docs <- .sim_doc_text(rows)
  docs_tok <- lapply(docs, .sim_tokenise)
  bm <- .sim_bm25(q, docs_tok)
  raw <- bm$score
  if (max(raw) < bm$idf_sum * 0.05) {
    return(rep(NA_real_, nrow(rows)))
  }
  raw / max(raw)
}
