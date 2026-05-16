# Meridian ERP

Internal ERP system for the Terran Resources group of companies.

**Live:** internal use only (not publicly hosted)

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

No automated deploy workflow — this is an internal tool, not hosted on GreenGeeks.

## Repository

https://github.com/brandonr2630/meridian-erp
