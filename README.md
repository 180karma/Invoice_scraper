# Invoice Scraper

A single-file browser invoice scraper.

Open `invoice_scraper.html` locally in Chrome, Edge, or Safari. PDF rendering uses PDF.js from cdnjs. No build step.

Drop in supplier invoices (PDF or image) to extract line items, header fields, and CSV.

## Shared kitchen library

The page opens straight into the app. There is no sign-in screen. The library is kept in this browser.

- Run `supabase-schema.sql` once in the Supabase SQL editor (safe to re-run). Run it again if an admin delete of a logo is refused: the file ends with the `admin delete supplier logos` policy.
- Deleting stored data stays off the screen until an admin unlocks it for this visit. A refresh locks it again. Settings → Admin then deletes one kind of data at a time (one invoice and its lines, all invoices, line items, one supplier and its invoices, lines, layout and logo, all suppliers, contacts, price history, one or all layouts, one or all logos, or everything). The confirm step names what will be removed. The delete is kept in this browser. Supabase still only accepts a delete from a signed-in admin session, and this page does not start one, so the server copy is not changed.

## Keys

- **Supabase URL and anon/publishable key** come from `config.js`, which is generated, never committed.
  - On GitHub Pages, `.github/workflows/pages.yml` writes it from the repository variables `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Pages must be set to deploy from GitHub Actions.
  - Locally: copy `.env.example` to `.env`, fill it in, run `node scripts/make-config.mjs`, then serve the folder (for example `python3 -m http.server`).
  - The kitchen project's anon key is also built into `invoice_scraper.html`, so any copy of the page (Pages, a downloaded file, any device) connects and syncs without setup. Settings no longer asks for a key.
  - The script refuses service_role and secret keys. The anon/publishable key is public by design; row-level security protects the data.
- **Gemini key** never goes to the browser. Scans go through the Supabase Edge Function `supabase/functions/gemini-extract`, which reads `GEMINI_API_KEY` from the Supabase project secrets and only answers signed-in users. Every scan uses Gemini 3.8 Flash (`gemini-3.8-flash`). There is no model picker and no key field on the page.
  - `.github/workflows/gemini-function.yml` deploys it and stores the secret, using the repository secrets `SUPABASE_ACCESS_TOKEN` and `GEMINI_API_KEY`. Optional `GEMINI_ALLOWED_EMAILS` (comma-separated) limits scanning to those accounts.
- **Supplier logos** are image files in the private Storage bucket `supplier-logos`, at `{supplier id}.jpg` (the ABN when there is one, otherwise the normalised name with spaces as hyphens). Signed-in staff load them with their session. The bucket does not need to be public. The SQL at the end of `supabase-schema.sql` creates the bucket and the staff policies.
