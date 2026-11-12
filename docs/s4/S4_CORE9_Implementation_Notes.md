# S4 CORE-9 — PWA: shell, generic renderers, daily screens, closed menu, Draft Confirm — Implementation notes

Status: implemented on branch `s4/core-9` (stacked on `s4/core-8`, PR #10). The PWA lives in `apps/pwa/public/app/` and is
served by the Gateway. Database support is in `db/migrations/9019_s4_pwa_ledger_accounts.sql`. The headless suite in
`tests/pwa/` covers the TST-3 subset.

Evidence grade: `AUTHOR_RUNTIME_EVIDENCE`, from the author's runs in headless Chromium against PG16.15 and PG17.11, plus CI on
the PR. The work has not been independently reviewed and has not run on Cloudflare (M0-A/B).

**Authority:**
- WP matrix V1.2 row CORE-9: "PWA: shell, three generic renderers, five daily screens, Draft-04 onboarding screens, items 1–8,
  Draft Confirm (sealed deep link), bilingual catalogs, accessibility".
- UA V1.2 §12.1–§12.3.
- Owner Requirements Book V1.2 §6 (OR-U-01…08) and §10 (OR-T-01).
- Draft-04 C1 (manual workflows W-M01…W-M17) and E7 (Dynamic UI: the PWA screen is the guaranteed confirmation path).

Gate G2 is an acceptance gate. Nothing here claims it; this is the build that G2 will test.

## What was built

| Part | Content |
|---|---|
| Shell | `index.html` with skip link, landmarks, live status region and bottom navigation (Home, Add, Activity, Review, Reports, Menu, plus Settings in the header). Hash router; plain ES modules with no build step and no third-party code. Mobile-first CSS: 44 px targets, visible focus, dark mode, reduced motion, and status shown by icon plus text, never colour alone. |
| Gateway serving | `GET /app/*` from the `ASSETS` binding, served **before** the binding checks: the shell is static and reveals nothing, while its API calls stay gated. `GET /` redirects to `/app/`. `GET /app/config.json` returns only the Google client id and the release. Every PWA document carries the headers below. |
| PWA response headers | The CSP limits every page to this origin plus exactly the Google Identity Services client, frame and style (`connect-src 'self' https://accounts.google.com/gsi/`). The page therefore has no route to any LLM. Also sent: `Permissions-Policy: camera=(), microphone=(), geolocation=()` (OR-U-06: no forced camera or microphone), `frame-ancestors 'none'`, `nosniff`, `no-referrer`. |
| Three generic renderers (`render.js`) | **Form:** built from a catalog entry's `input_schema`. Typed inputs for dates, date-times, enums, booleans and JSON for arrays/objects. Account-currency and ledger-account pickers come from `q_ledger_accounts`. An "Advanced: request as JSON" field covers any body. **Table:** filter, sortable headers with `aria-sort`, card layout on narrow screens, and CSV export (C-06). The CSV is RFC 4180 with a BOM; a cell beginning with `= + - @` is prefixed with `'`, except plain signed numbers. **Detail:** any record. Nested lists of records become tables; long text such as a handoff prompt becomes verbatim, copyable text. |
| Closed menu (`menu.json`) | Items 1–8 (OR-U-02) plus Settings. Each item lists catalog core functions, and every PWA catalog entry appears at least once. A task is shown only if its function is in the live catalog and within the caller's tier (viewer 1, member 2, owner/admin 3). An item with no visible task is not shown, so there are no dead ends (OR-U-01). |
| Five daily screens | **Home:** identity, items waiting for my approval, notifications, last verified backup (Owner), and today's balances (F1). **Add:** Quick Entry for expense, income or same-currency transfer. It posts directly when the member can post to the accounts; otherwise it creates a `member_draft` for approval (UA §12.1, CROSS-03). **Activity:** month list and calendar (OR-U-03 / C-02) with daily counts and per-currency totals and drill-down by day. The day is the stored transaction date, so it never shifts with the viewer's time zone. The transaction view offers reversal (`correct_transaction`) and a handoff prompt. **Review:** the review queue. **Reports:** F1–F7, R09, R28 and R31; R-BAL snapshot creation; the snapshot list with status, where each row opens its document through the CORE-8 artifact proxy. |
| Draft Confirm (`#/confirm/<plan>?h=<plan_hash>&s=<scope_digest>`) | The guaranteed confirmation path (C-01/C-04). The screen shows the plan exactly as the server holds it, and approval sends that version (`plan_hash`, `scope_digest`). A sealed link from an AI host (Mode H) is compared with the current version. If it matches, the screen says so. If it does not, a warning is shown and approval stays disabled until the member confirms having reviewed the current version. The author of a draft who cannot approve sees why. The page never approves from a link alone. |
| Settings | Sign out, the configuration as a read-only view (AE §6), and the Owner's administrative tasks (prepare a configuration change, household settings, sources, AI connections) through the generic form. |
| Bilingual catalogs | `i18n/en.json` and `zh-Hans.json` have the same 275 keys: screens, errors, roles, field labels, and every menu task. Switching language changes display text and `<html lang>` only; identities, amounts and calculations are untouched (OR-U-08). Categories show their own `name_en` / `name_zh`. |
| Sign-in | Google Identity Services is loaded **only** on the sign-in screen. The ID token goes to the existing `/auth/google/callback`, which sets the HttpOnly session cookie. |
| Service worker | Caches only the application shell, network first. It never caches API answers, the catalog or `config.json`. Offline, the shell opens and states that it is offline, and no figure is shown from a cache. |
| `q_ledger_accounts` (9019) | Tier 0, PWA only: it is not in `function_scope`, so it is never an MCP tool. Returns the caller's visible account-currencies with ledger account, label, kind, institution code and `can_post` (from `actor_can_post`, which also refuses viewers), plus the active income and expense categories. |
| Catalog delta blocks | `tools/s4/catalog_build.py` now writes a **delta block** into the newest marked migration and checks the **merge** of all blocks against the derivation. 9017 keeps its 113 entries unchanged; 9019 carries one. |
| Release | `0.4.0-core9`, extension range 9018…9019. |

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's delegation ("继续完成到底", "继续").

| ID | Decision | Reason |
|---|---|---|
| D-CORE9-1 | Add migration **9019** (`q_ledger_accounts`) outside the V1.2 register | Quick Entry must name ledger accounts. No catalog query returned `ledger_account_id`: F1 and F2 return account-currencies and names only. |
| D-CORE9-2 | Catalog blocks become **per-migration deltas**; a committed migration is never edited | Rewriting the 9017 block would change an applied migration's SHA-256, which the runner and the backup header record. |
| D-CORE9-3 | No framework, no bundler, no third-party runtime code in the PWA | Smallest reusable UI (OR-U-01). The CSP can stay `'self'`, there is no supply chain in the page, and it deploys as static assets. |
| D-CORE9-4 | The PWA is served by the Gateway (same origin) through the Workers static-assets binding | The session cookie is `SameSite=Strict` and commands require the PWA origin. Same origin keeps CSRF protection and the CSP simple. |
| D-CORE9-5 | The menu is a fixed list of catalog core functions, and visibility is computed from the live catalog and the caller's tier | Closed menu (OR-U-02), with no entry that leads to a refusal or an AI dependency (OR-U-01). |
| D-CORE9-6 | Quick Entry covers same-currency expense, income and transfer. Other movements (card, FX, investment, loan) use the menu's generic forms | These have the most varied line shapes. The generic form posts them through the same commands; dedicated screens follow with the Draft-04 flows. |
| D-CORE9-7 | A sealed link whose seal differs requires an explicit "reviewed the current version" before approval; approval always sends the displayed version | The server already refuses a stale version (R1 0109 checks). The screen adds the human step so a changed draft is never approved blind. |
| D-CORE9-8 | Focus moves to the new heading after each navigation but not on first load, and the skip link does not touch the hash | Screen-reader orientation without trapping the skip link; the hash is the router. |
| D-CORE9-9 | Headless tests run with every non-origin host and every AI route (`/mcp`, `/oauth/*`) aborted and recorded; AT-NOAI-00 asserts that both lists stay empty for the whole suite | OR-T-01: "no hidden LLM call". The sign-in screen's Google Identity Services request is the only expected external request and is asserted separately. |

## Tests — `AUTHOR_RUNTIME_EVIDENCE`

**`tests/pwa/pwa.test.mjs`** — 15 tests, run on PG16 and PG17 locally and in CI. Playwright 1.63.0 / Chromium; axe-core 4.13.0, pinned in `tests/pwa/package-lock.json`.

| Test | What it checks |
|---|---|
| AT-UI-00 | Headers, redirect, path traversal refused, and the minimal `config.json`. |
| AT-NOAI-01…08 | One per menu item: identity and the signed-out screen; account creation through the generic form and balances; Quick Entry expense and income, then reversal; member draft, sealed link and Owner approval, then posting (AT-CONF-01…03); reconciliation and matching; F1 with filter and formula-safe CSV, then a snapshot; backup status, and Owner tasks hidden from a viewer and a member (AT-MENU-03); handoff prompt and status. |
| AT-MENU-01/02 | Items 1–8 plus Settings; every PWA catalog entry reachable; a catalog without handoff entries hides item 8. |
| AT-CAL-01 | The same calendar cells in Toronto, Shanghai and Honolulu; counts and totals; drill-down. |
| AT-UI-01 | 中文 labels and `lang`, unchanged figures, equal key sets. |
| AT-A11Y-01/02 | No serious or critical axe violation on ten screen states; skip link; focus after navigation. |
| AT-UI-02 | Offline shell with no cached figures. |
| AT-NOAI-00 | Over the whole suite: 0 external requests, 0 AI routes, and more than 50 requests observed. |

**`tests/py/run_s4_core16.py`** — 2 tests:
- AT-PWA-LA-01: visibility, `can_post`, the viewer rule, categories, and AI bearer refused.
- AT-CAT-02: merged delta blocks equal the derivation; 113 + 1 blocks; 114 live comments.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-CORE9-1 | 9019 needs register and disposition rows (as 9017/9018). | Next register revision. |
| L-CORE9-2 | Not deployed. There is no `wrangler.toml` assets binding, no real Google client id, and nothing has run on a phone or a real browser with Google Identity Services. | M0-A/B; the Owner's device check. |
| L-CORE9-3 | Item 7 "activity, correction, approval and evidence audit trails": no catalog query returns the audit chain. The PWA shows R31 evidence trace, R30, backup/restore and cost status, but not a general audit-trail list. | Add `q_audit_trail` (read-only, tier 0) in a later migration. |
| L-CORE9-4 | The Draft-04 onboarding screens (C5: progress counters, next decision) are served by the generic forms (`onboarding_*`, `q_onboarding_job`), not by a dedicated progress screen. | With WP-DOC / C5 work. |
| L-CORE9-5 | Quick Entry covers same-currency expense, income and transfer only (D-CORE9-6). Card, FX, investment and loan entries use the generic forms; there is no evidence upload widget yet (`register_evidence` and `evidence_upload_target` exist as forms, and R2 is O-7). | CORE-9 follow-up after O-7. |
| L-CORE9-6 | Offline means the shell only: no IndexedDB queue or upload resume (`apps/pwa` M2 item). | M2. |
| L-CORE9-7 | Server error texts are localized by code. Free-text database details are not shown, by design. Generic-form field labels without a catalog key fall back to the English key. | Extend `field.*` keys as screens are dedicated. |
| L-CORE9-8 | AT-NOAI covers the eight items with representative tasks, not every one of the 114 tasks. AT-NOAI-09/10, the remaining TST-3 rows, and CORE-10's dedicated handoff screens are not done here. | TST-3, CORE-10. |
