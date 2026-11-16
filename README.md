# Invoice Scraper

A single-file browser invoice scraper.

Open `invoice_scraper.html` locally in Chrome, Edge, or Safari. PDF rendering uses PDF.js from cdnjs. No build step.

Drop in supplier invoices (PDF or image) to extract line items, header fields, and CSV.

## Shared kitchen library

Signed-in staff share **one** Supabase library (invoices, items, layouts, settings). The library id lives in `app_meta.library_user_id` (created by [`supabase-schema.sql`](supabase-schema.sql)); the page loads it after sign-in and syncs every account to that id.

- Run `supabase-schema.sql` once in the Supabase SQL editor (safe to re-run).
- Staff open the GitHub Pages site, email-sign-in under Settings → Supabase copy, then scan or upload as usual.
- Prefer **invite-only** users (Authentication → Users) if the Pages URL is public: anyone who can sign up joins the same kitchen data. Or turn on “Allow new users to sign up” only while onboarding trusted staff.
- Email provider must be enabled under Authentication → Sign In / Providers.

## Keys

- **Supabase URL and anon/publishable key** come from `config.js`, which is generated, never committed.
  - On GitHub Pages, `.github/workflows/pages.yml` writes it from the repository variables `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Pages must be set to deploy from GitHub Actions.
  - Locally: copy `.env.example` to `.env`, fill it in, run `node scripts/make-config.mjs`, then serve the folder (for example `python3 -m http.server`).
  - Without `config.js` the page still works: paste the key in Settings, as before. A key pasted in Settings overrides the site's key.
  - The script refuses service_role and secret keys. The anon/publishable key is public by design; row-level security protects the data.
- **Gemini key** never goes to the browser. Scans go through the Supabase Edge Function `supabase/functions/gemini-extract`, which reads `GEMINI_API_KEY` from the Supabase project secrets and only answers signed-in users.
  - `.github/workflows/gemini-function.yml` deploys it and stores the secret, using the repository secrets `SUPABASE_ACCESS_TOKEN` and `GEMINI_API_KEY`. Optional `GEMINI_ALLOWED_EMAILS` (comma-separated) limits scanning to those accounts.
  - A Gemini key saved in the browser's Settings is only a fallback, used when the function can't be reached.
