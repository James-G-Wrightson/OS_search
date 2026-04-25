# OS_search — User Guide for Research Assistants

A practical, no-jargon walkthrough for extracting open-science outputs of a CIHR Project Grant. Your supervisor will give you a list of grant numbers; this guide walks through one of them as an example. Plan around 20–40 minutes per grant, depending on how prolific the PI is.

---

## What you'll do, at a glance

For each grant on your list:

1. Open the app and search the grant number.
2. Review the **Strict match** tab — untick anything that doesn't belong.
3. Download the PDF for every paper or preprint there, upload them one by one to the app, and use it to capture registrations and data deposits.
4. Move to the **Fallback match** tab and repeat the review + PDF process.
5. Download the matched-works CSV.

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

Click **Search linked works**. A spinner appears while the app queries six external sources at once (Crossref, OpenAlex, DataCite, ClinicalTrials.gov, OpenAIRE, Europe PMC). It usually takes 10–45 seconds.

When it finishes, the **Summary** tab opens automatically. Take a glance at the counts so you know roughly what you're about to wade through.

---

## 4. Review the Strict match tab

Click **Strict match (grant ID + funder)**. These are works that explicitly cite the CIHR award number — they're authoritative, but you should still scan each row before accepting it.

The tab shows up to five separate tables:

- **OpenAlex**, **Europe PMC**, **Crossref** — published papers
- **DataCite** — datasets, preprints, OSF registrations
- **ClinicalTrials.gov** — trial registrations

**Every Strict row is pre-ticked by default.** That means it goes into the final CSV unless you actively untick it. Read the title and PI for each row; untick anything that's obviously a duplicate or wrong.

### 4a. Download each paper's PDF

For each row in the OpenAlex / Europe PMC / Crossref / DataCite tables that is a paper or preprint:

1. Look in the **OA PDF** column.
   - If you see a `PDF ⬇` link, click it. A popup window opens with a free open-access copy. Save it to a folder on your computer.
   - If you see `—`, no free copy is indexed.

2. When there's no OA PDF, use one of these to track down a copy:
   - **UBC Library** with your student credentials — search the title at <https://library.ubc.ca>; the most reliable route when the journal is in UBC's subscriptions.
   - **Google Scholar** — paste the title; copies often show up under the "All N versions" link.
   - The **verify ↗** link in the row opens the publisher's landing page if the other two fail.

Save every PDF you find. You'll upload them to the app next.

### 4b. Upload each PDF, one at a time

For every PDF you saved:

1. Click the **PDF extraction** tab.
2. Click **Browse…** and pick one PDF file.
3. The app auto-fills the **Linked source paper** dropdown by matching the filename to a DOI from the search results. Confirm the right source paper is selected, or pick a different one. (If the PDF doesn't correspond to any row, leave it as `(no source paper — keep PDF row standalone)`.)
4. Click **Scan paper**. The scan takes 3–15 seconds and runs entirely on this machine — nothing is uploaded anywhere.
5. Three result panels appear below:

   - **CIHR funding** — confirms the paper declares CIHR as a funder of this study. Useful as evidence; usually leave the rows ticked.
   - **Registration** — clinical-trial or systematic-review IDs (NCT, ISRCTN, PROSPERO, OSF, etc.). Click `verify on …` to confirm the ID really belongs to this paper, then leave it ticked.
   - **Data availability** — public repository deposits (GEO, Zenodo, Dryad, GitHub, OSF, …). Same drill: click verify, sanity-check, leave ticked.

6. Below each panel is an **Add ticked … rows to matched-works CSV** button. Click each one that found something. You'll see a green notification confirming how many rows were added.

7. **Important:** before uploading the next PDF, make sure you've added every ticked row from this scan. Picking a new PDF clears the previous results — anything you didn't add is lost.

8. Repeat for the next PDF: Browse, confirm the source-paper link, Scan, Add.

---

## 5. Review the Fallback match tab

Click **Fallback match (PI / ORCID / keywords)**. These rows aren't tied to the grant by award number — they're just other works by the same PI. Some are legitimate outputs of this grant; others belong to a different grant, a co-authored side project, or even a different person with the same name. Your judgment is the whole point of this tab.

Layout:

- **Source** radio button — work through one source at a time, starting with OpenAlex (the highest-quality coverage).
- **Match type** — leave both ticked. If the table is overwhelming, uncheck `PI (any)` first to keep only the funder-filtered rows.
- **Similarity** column — a coloured score from comparing the grant's keywords to the paper's title and abstract:
  - Green `≥0.6 high` — most likely the right grant.
  - Amber `0.20–0.60 plausible` — read carefully before deciding.
  - Grey `<0.20 off-topic` — usually wrong topic; safe to skip.

**Crucial difference from Strict:** Fallback rows are NOT pre-ticked. **You must tick each row you want to include** in the CSV. Unticked rows are ignored by the exporter.

For every plausible-or-better row:

1. Click the **verify ↗** link. Does the title / abstract match the grant's research area? Is the publication date after the grant started?
2. If yes, tick the row.
3. Download the PDF (OA PDF column if available, otherwise UBC Library / Google Scholar as before).
4. Upload it to the **PDF extraction** tab the same way as in section 4b — scan, then add the registration / data-deposit / CIHR-funding rows.

When you finish one source, click the next radio button (Europe PMC → Crossref → DataCite → OpenAIRE → ClinicalTrials.gov) and repeat.

### Quick rejection checklist

Don't tick a fallback row when:

- The PI name matches but the topic is clearly unrelated (PI homonyms — different person with the same name).
- The paper was published before the grant started.
- The PDF's funding statement names a completely different grant and there's no plausible link to this one.

---

## 6. Download the CSV

When both tabs are reviewed and all the PDFs you could find are uploaded:

1. Go to the **Summary** tab.
2. Click **Download matched works (CSV)**.
3. The file lands at:

   ```
   downloads/{grant_id}_{PI_surname}/cihr_{grant_id}_linked_works.csv
   ```

   relative to the project folder. Your supervisor will tell you where to put it (shared drive, Dropbox, etc.).

The CSV contains every ticked Strict row, every ticked Fallback row, and every PDF-derived registration / data-deposit / CIHR-funding row you added.

---

## 7. Move to the next grant

Type the next grant number into **Find grant by number (across all FYs)**. If a folder already exists for that grant the app asks you to confirm — click **Continue** to redo it.

Switching grants resets all the tabs, so make sure you've downloaded the CSV for the current grant before you switch.

---

## Tips and traps

- **One PDF at a time.** Picking a new PDF clears the previous scan results. Always click the relevant `Add ticked … rows` buttons before uploading the next file.
- **Save as you go.** Clicking *Download CSV* any time is fine — the file gets overwritten with the latest state. If you need to stop mid-grant, save the CSV; you'll need to re-search and re-tick when you come back, because the app doesn't remember tab state between sessions.
- **A scan with very low text count.** If the status line says something like "Scanned 1,234 characters", the PDF is probably an image-only scan and the app can't read it. Note the paper for your supervisor and move on.
- **Transient failures.** If the search or a PDF scan times out or returns a 502, try again once. If it fails repeatedly, flag it for your supervisor and continue with the rest of the grant.
- **A grant with zero results.** Brand-new grants (funded 2021 or later) may legitimately have no published outputs yet. If both tabs are empty after a search, note "no outputs found yet" on your tracking sheet and move on.

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
