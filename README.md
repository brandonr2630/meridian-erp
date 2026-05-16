# Meridian ERP

Internal ERP system for the Terran Resources group of companies.

**Live:** https://erp.terranresources.com

## Structure

| File | Purpose |
|------|---------|
| `index.html` | The entire application — ~8400 lines of inline CSS + JS |
| `index2–5.html` | Archives — do not edit |

## Architecture

- **Backend:** Supabase (direct fetch, no server layer)
- **Auth:** Supabase JWT, persisted to localStorage
- **Multi-company:** every record scoped to `currentCompany.id`

## Modules

Dashboard · Chart of Accounts · Journal Entries · AR · AP · Vendor Payments · Clients · Vendors · ERP Companies · Settings · Bank Accounts · Bank Transactions & Reconciliation · Bills · Financial Reports · Quotations · Sales Leads

## Deployment

Every push to `master` auto-deploys via GitHub Actions → cPanel Fileman API (GreenGeeks).

- **Incremental push:** only files changed in the push are uploaded
- **Full redeploy:** trigger manually via Actions → Deploy to cPanel → Run workflow

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `CPANEL_API_TOKEN` | cPanel API token |
| `CPANEL_HOST` | `https://chi203.greengeeks.net:2083` |
| `CPANEL_USER` | `terranre` |

## Repository

https://github.com/brandonr2630/meridian-erp
