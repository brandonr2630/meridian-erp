# Meridian ERP Handoff

---

## Session 3 — GitHub Infrastructure

**Date:** 2026-05-16
**Commit:** `f6ca401`

### What Changed

Switched to the centralised reusable deploy workflow. All deploy logic now lives in `brandonr2630/projects`.

| Change | Detail |
|--------|--------|
| Reusable deploy workflow | `deploy.yml` reduced from 130 lines to 14 — calls `brandonr2630/projects/.github/workflows/deploy.yml@master` |
| Auto-merge enabled | PRs merge as soon as opened (no required status checks) |
| GitHub Projects board | [github.com/users/brandonr2630/projects/1](https://github.com/users/brandonr2630/projects/1) — all 5 repos linked |

### Outstanding

- No known outstanding items

---

## Session 2 — Infrastructure Overhaul

**Date:** 2026-05-16
**Commits:** `7334849`, `3a23b33`, `7cc0edb`, `f227ba2`

### What Changed

Brought the deploy pipeline up to the same standard as q2m-website. Fixed binary file corruption, added manual redeploy trigger, moved credentials to secrets, cleaned up dead files.

### Changes Made

| Change | Commit |
|--------|--------|
| Deploy workflow: hybrid binary upload, directory creation, `workflow_dispatch` | `7334849` |
| Removed dead `.cpanel.yml` | `3a23b33` |
| Moved `HOST` and `CPANEL_USER` from hardcoded to GitHub Secrets | `7cc0edb` |
| README: corrected live URL and deploy section | `f227ba2` |
| Branch protection ruleset on `master` (requires PR) | — |

### Deploy Workflow Behaviour

| Trigger | Files uploaded |
|---------|---------------|
| Push to `master` (via PR) | Only files changed in the push |
| Manual `workflow_dispatch` | All tracked files (`git ls-files`) |

Binary files (images, fonts) go through `Fileman/upload_files` (multipart). Text files go through `Fileman/save_file_content`.

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `CPANEL_API_TOKEN` | cPanel API token (rotate in cPanel → Security → Manage API Tokens) |
| `CPANEL_HOST` | `https://chi203.greengeeks.net:2083` |
| `CPANEL_USER` | `terranre` |

### Outstanding

- No known outstanding items for this repo

---

## Session 1 — Deploy Pipeline Fix

**Date:** 2026-05-09
**Commit:** `c5ba3cf`

### What Changed

Replaced the original git-pull based deploy with direct Fileman API upload via GitHub Actions. The previous approach used cPanel Git Version Control which required server-side git access — unreliable on shared hosting.

### Fix Applied

Rewrote `.github/workflows/deploy.yml` to upload files directly via `Fileman/save_file_content` on push to `master`. Incremental deploy only (files changed in the push).

**Note:** This initial version used `save_file_content` for all files (text-only). Binary file support was added in Session 2.

---

## Architecture Reference

### Application

The entire app is `index.html` — approximately 8,400 lines of inline CSS and JavaScript. **Never edit `index2–5.html`; those are archives.**

### Backend

- **Supabase** — primary data store, called directly via a thin fetch wrapper
- All DB access goes through `sb()` → `sbGet / sbPost / sbPatch / sbPatchWhere / sbDelete / sbDeleteWhere`
- **Auth:** Supabase JWT. Session (access token + refresh token) persisted to `localStorage`, restored on load by `tryRestoreSession()`
- **Multi-company:** every record scoped to `currentCompany.id`. Company switcher in topbar; `switchCompany(id)` reloads view data

### Navigation & State

- `navigate(view)` sets `currentView` and calls `loadViewData(view)`
- Global state declared at `// ── STATE ──` (~line 3373): `currentUser`, `currentCompany`, `companies`, `accounts`, `contacts`, `journalEntries`, `bankAccounts`, etc.

### Roles

`super_admin` > `admin` > `sales` > `user`

Finance modules (AP, Bank, CoA, Journal, Reports) are admin-only. Check `canPost()`, `canVoid()`, `canFinance()` before rendering controls.

### Modules

Dashboard · Chart of Accounts · Journal Entries · AR · AP · Vendor Payments · Clients · Vendors · ERP Companies · Settings · Bank Accounts · Bank Transactions & Reconciliation · Bills · Financial Reports · Quotations · Sales Leads

### Currencies

TTD (`TT$`) · USD (`US$`) · GYD (`G$`) — formatted via `fmt(amount, currency)`

### PDF & Exports

PDFs rendered client-side with a custom multi-page renderer. SheetJS lazy-loaded from CDN on first Excel export. Report download menu is a shared fixed component.

---

## References

- **Repository:** https://github.com/brandonr2630/meridian-erp
- **Live Site:** https://erp.terranresources.com
- **Deploy workflow:** `.github/workflows/deploy.yml`
- **Deployment:** cPanel Fileman API → GreenGeeks (`chi203.greengeeks.net`)

---

**Last Updated:** 2026-05-16 (Session 3)
