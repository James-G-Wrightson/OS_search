# OS_search — User Guide for Research Assistants

A practical, no-jargon walkthrough for extracting open-science outputs of a CIHR Project Grant. Your supervisor will give you a list of grant numbers; this guide walks through one of them as an example. Plan around 15–30 minutes per grant, depending on how prolific the PI is.

---

## What you'll do, at a glance

For each grant on your list:

1. Open the app and search the grant number.
2. Review the **Strict match** tab — untick anything that doesn't belong.
3. Review the **Fallback match** tab — tick the rows that *do* belong.
4. The app has already auto-downloaded most PDFs in the background. Manually save any that failed into the folder shown.
5. Use the **Strict PDFs** and **Fallback PDFs** tabs to add registrations and data deposits to the CSV.
6. Download the matched-works CSV.

---

## 1. Launch the app

From a terminal, in the project folder, run:

```sh
Rscript -e 'shiny::runApp("app.R", launch.browser = TRUE)'
```

Wait for a line like `Listening on http://127.0.0.1:<port>` to appear — the browser opens automatically once it does. The first launch takes about 30 seconds while the grant workbooks are parsed and cached; later launches start in under a second.

If your supervisor has set this up as a desktop shortcut, just double-click that instead.

---

## 2. Find your grant

The app opens with a sidebar on the left and tabs across the top.

In the sidebar, use the **Find grant by number (across all FYs)** field. Type the grant number from your list (for example `155957_1`) and pick it from the dropdown.

The grey info box below fills in with PI name, institution, fiscal year, funding period, total awarded, title, and abstract. **Spot-check that this matches the grant you've been assigned** — typing the wrong number is the most common slip-up.

---

## 3. Run the search

Click **Search linked works**. A spinner appears while the app does two things at once:

1. Queries six external sources (Crossref, OpenAlex, DataCite, ClinicalTrials.gov, OpenAIRE, Europe PMC).
2. Auto-downloads the open-access PDF for every strict match plus every fallback match above the similarity threshold, into per-grant folders on disk.

The whole thing usually takes 30–90 seconds. When it finishes, the **Summary** tab opens automatically. Take a glance at the counts so you know roughly what you're about to wade through.

---

## 4. Review the Strict match tab

Click **Strict match (grant ID + funder)**. These are works that explicitly cite the CIHR award number — they're authoritative, but you should still scan each row before accepting it.

The tab shows up to five separate tables:

- **OpenAlex**, **Europe PMC**, **Crossref** — published papers
- **DataCite** — datasets, preprints, OSF registrations
- **ClinicalTrials.gov** — trial registrations

**Every Strict row is pre-ticked by default.** That means it goes into the final CSV unless you actively untick it. Read the title and PI for each row; untick anything that's obviously a duplicate or wrong.

There's no PDF work to do on this tab — the app has already downloaded what it could. You'll handle anything that didn't auto-download on the **Strict PDFs** tab (section 6).

---

## 5. Review the Fallback match tab

Click **Fallback match (PI / ORCID / keywords)**. These rows aren't tied to the grant by award number — they're just other works by the same PI. Some are legitimate outputs of this grant; others belong to a different grant, a co-authored side project, or even a different person with the same name. Your judgment is the whole point of this tab.

Layout:

- **Source** filter — tick / untick sources to narrow the table.
- **Match type** — leave both ticked. If the table is overwhelming, uncheck `PI (any)` first to keep only the funder-filtered rows.
- **Similarity** column — a coloured score from comparing the grant's keywords to the paper's title and abstract:
  - Green `≥0.6 high` — most likely the right grant.
  - Amber `0.20–0.60 plausible` — read carefully before deciding.
  - Grey `<0.20 off-topic` — usually wrong topic; safe to skip.

**Important defaults:** rows scoring above the similarity threshold are pre-ticked for you, and those are the ones the app has already auto-downloaded as PDFs. Lower-scoring rows are unticked — tick any you decide should be in the CSV after reviewing.

For every plausible-or-better row:

1. Click the **verify ↗** link. Does the title / abstract match the grant's research area? Is the publication date after the grant started?
2. If yes, leave it ticked (or tick it, for low-similarity rows).

### Quick rejection checklist

Untick a fallback row when:

- The PI name matches but the topic is clearly unrelated (PI homonyms — different person with the same name).
- The paper was published before the grant started.
- The funding statement names a completely different grant and there's no plausible link to this one.

---

## 6. Strict PDFs tab — fill the gaps and harvest signals

Click **Strict PDFs**. This tab is the workshop: it shows you which PDFs need a manual save, then surfaces every registration ID and data deposit found across the strict folder.

### 6a. Manual download box

At the top, an orange `XX PDFs need manual download` panel lists every paper the auto-downloader couldn't fetch (paywalls, broken OA links, etc.). For each entry:

1. Click `open PDF link` (or use the `verify ↗` route if there isn't one) to find the paper.
2. If the OA route didn't work, fall back to:
   - **UBC Library** with your student credentials — search the title at <https://library.ubc.ca>; the most reliable route when the journal is in UBC's subscriptions.
   - **Google Scholar** — paste the title; copies often show up under the "All N versions" link.
3. Save the PDF into the folder shown at the top of the tab (something like `downloads/155957_1_smith/strict_papers/`). The filename can be anything — the app matches by DOI in the filename if present, but you don't need to rename it as long as the DOI shows up somewhere in the name.
4. Once you've saved one or more PDFs, click **Re-scan folder**. Saved files drop off the orange list and the count of "already downloaded" goes up.

Repeat until the orange box is gone or you've exhausted the routes for the remaining ones.

### 6b. Registrations + data availability tables

Below the manual-download panel are two tables:

- **Registrations** — every clinical-trial / systematic-review ID found across the strict PDFs (NCT, ISRCTN, PROSPERO, OSF, …). Duplicates are collapsed automatically — you only see one row per registration.
- **Data availability** — every public-repository deposit (GEO, SRA, Zenodo, Dryad, GitHub, …). Same dedup.

Every row is pre-ticked. For each one:

1. Read the surrounding sentence column — does the registration / deposit really belong to this grant's research?
2. Click the row's verify link to confirm the ID resolves.
3. Untick anything that looks wrong (e.g. a sentence that names a different study).

Then click:

- **Add ticked registrations to CSV**
- **Add ticked data-availability rows to CSV**

A green notification confirms how many rows were added.

---

## 7. Fallback PDFs tab — pick which PDFs count

Click **Fallback PDFs**. This tab works slightly differently from Strict PDFs because fallback PDFs aren't guaranteed to belong to this grant.

### 7a. Manual download box

Same drill as section 6a, but the folder is `…/fallback_papers/`. Save any failed downloads, then **Re-scan folder**.

### 7b. Current grant in PDF — the gate

The first results table is **Current grant in PDF**. One row per scanned fallback PDF. The `grant_id_in_pdf` column tells you whether the current grant's CIHR ID appears anywhere in the PDF text. Rows where it does are pre-ticked.

**This table acts as a filter for everything below it.** The Registrations and Data-availability tables show findings *only* from the PDFs you tick here.

For each row:

1. If the grant ID was found in the PDF (pre-ticked), it's almost certainly a real grant output — leave it ticked.
2. If the row is unticked but the paper is clearly relevant from the title / abstract you reviewed in section 5, tick it manually.
3. Untick anything that turned out not to belong to this grant after you read its PDF.

Click **Add ticked grant-match rows to CSV** to write the per-PDF "this grant ID was found in this paper" evidence into the CSV.

### 7c. Registrations + data availability — filtered to ticked PDFs

The two tables below now show registrations and data deposits only from the PDFs you ticked above. Anything already shown on the Strict PDFs tab is filtered out, so you only see *new* fallback findings.

If the tables are empty, you haven't ticked any PDFs in 7b yet — go back and tick the relevant ones.

For each row, check the sentence and verify, untick wrong matches, then:

- **Add ticked registrations to CSV**
- **Add ticked data-availability rows to CSV**

---

## 8. Download the CSV

When both tabs are reviewed and all the registrations / data deposits you want are added:

1. Go to the **Summary** tab.
2. Click **Download matched works (CSV)**.
3. The file lands at:

   ```
   downloads/{grant_id}_{PI_surname}/cihr_{grant_id}_linked_works.csv
   ```

   relative to the project folder. Your supervisor will tell you where to put it (shared drive, Dropbox, etc.).

The CSV contains every ticked Strict row, every ticked Fallback row, and every PDF-extracted registration / data-deposit / grant-match row you added.

---

## 9. Move to the next grant

Type the next grant number into **Find grant by number (across all FYs)** and click **Search linked works**.

The previous grant's downloaded PDFs stay on disk under their own `downloads/{grant_id}_{PI_surname}/` folder — you can revisit them later if needed. Switching grants resets all the tabs in the browser, so make sure you've downloaded the CSV for the current grant before you switch.

---

## Tips and traps

- **Re-scan after every manual save.** The orange "needs manual download" panel and the registrations / data-availability tables only refresh when you click **Re-scan folder**.
- **Filename doesn't matter much.** The app matches PDFs to papers by looking for the DOI inside the filename. The auto-downloader names them DOI-style; if you save manually, leaving the DOI somewhere in the filename helps the app link the PDF back to the right paper row.
- **Image-only PDFs.** A few old PDFs are scanned images with no text layer, and the registration / data-availability tables can't see anything in them. If a paper looks important, note it for your supervisor and move on.
- **Transient failures.** If the search or a PDF scan times out or returns a 502, try again once. If it fails repeatedly, flag it for your supervisor and continue with the rest of the grant.
- **A grant with zero results.** Brand-new grants (funded 2021 or later) may legitimately have no published outputs yet. If both tabs are empty after a search, note "no outputs found yet" on your tracking sheet and move on.
- **Strict findings hide from Fallback.** If a registration ID or data accession is already shown on the Strict PDFs tab, it won't appear again on the Fallback PDFs tab — that's intentional, to stop duplicates from creeping into the CSV.

---

## Glossary

- **Strict match** — the registry itself confirmed the funder + award-ID link. Authoritative.
- **Fallback match** — same PI, but no award ID present. Needs your review.
- **OA / OA PDF** — open-access; freely downloadable.
- **Preprint** — a pre-publication draft (bioRxiv, medRxiv, OSF Preprints, arXiv). Treat the same as a paper for this workflow.
- **Registration** — public record of a clinical trial or systematic review (IDs like `NCT12345678`, `CRD42021234567`).
- **Data deposit** — a dataset uploaded to a public repository (GEO, SRA, Zenodo, Dryad, OSF, GitHub, …).
- **DOI** — the unique digital identifier for a published paper or dataset.
- **ORCID** — the unique identifier for a researcher.

If anything in the app doesn't match what's described here, ask your supervisor — the tool is updated regularly and this guide may lag a small change.
