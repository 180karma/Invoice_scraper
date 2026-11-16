# Invoice Scraper

A single-file browser invoice scraper.

Open `invoice_scraper.html` locally in Chrome, Edge, or Safari. PDF rendering uses PDF.js from cdnjs. No build step.

Drop in supplier invoices (PDF or image) to extract line items, header fields, and CSV.

## Shared kitchen library

Signed-in staff share **one** Supabase library (invoices, items, layouts, settings). The library id lives in `app_meta.library_user_id` (created by [`supabase-schema.sql`](supabase-schema.sql)); the page loads it after sign-in and syncs every account to that id.

- Run `supabase-schema.sql` once in the Supabase SQL editor (safe to re-run). It creates the `staff` list and makes `180karma@gmail.com` the first admin; change that line for another kitchen.
- The page opens on a sign-in screen. Only emails on the staff list can sign in; they get a code by email.
- **Staff** see the whole library and add invoices to it with the invoice reader. They can correct an invoice they added themselves for 24 hours. They can't change or delete anything else.
- **Admins** can also change and delete library records, hide items, change shared settings, and add or remove people under Settings → Staff.
- The staff list is managed by the Edge Function `supabase/functions/staff-admin`. Supabase gives it the service key, which never reaches the browser. Adding someone also creates their sign-in account, and removing them deletes it.
- The limits are enforced in the database by row-level security and triggers, not only by hiding buttons.
- The Email provider must be enabled under Authentication → Sign In / Providers. Turning off “Allow new users to sign up” there is recommended. The page never signs people up by itself.

## Keys

- **Supabase URL and anon/publishable key** come from `config.js`, which is generated, never committed.
  - On GitHub Pages, `.github/workflows/pages.yml` writes it from the repository variables `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Pages must be set to deploy from GitHub Actions.
  - Locally: copy `.env.example` to `.env`, fill it in, run `node scripts/make-config.mjs`, then serve the folder (for example `python3 -m http.server`).
  - Without `config.js` the page still works: paste the key in Settings, as before. A key pasted in Settings overrides the site's key.
  - The script refuses service_role and secret keys. The anon/publishable key is public by design; row-level security protects the data.
- **Gemini key** never goes to the browser. Scans go through the Supabase Edge Function `supabase/functions/gemini-extract`, which reads `GEMINI_API_KEY` from the Supabase project secrets and only answers signed-in users.
  - `.github/workflows/gemini-function.yml` deploys it and stores the secret, using the repository secrets `SUPABASE_ACCESS_TOKEN` and `GEMINI_API_KEY`. Optional `GEMINI_ALLOWED_EMAILS` (comma-separated) limits scanning to those accounts.
  - A Gemini key saved in the browser's Settings is only a fallback, used when the function can't be reached.
