# apps/pwa — status (S4 CORE-9)

Status: **PARTIAL (built, not deployed, not claimed for G2).** The PWA is in `public/app/` and is served by the Gateway
(`apps/worker`, `GET /app/*`). Details: `docs/s4/S4_CORE9_Implementation_Notes.md`.

What it has:
- the shell, three generic renderers and five daily screens;
- the closed menu (items 1–8 plus Settings) derived from the live catalog;
- Draft Confirm with sealed links;
- EN/中文 catalogs, accessibility, and an offline shell.

It is exercised headless by `tests/pwa/pwa.test.mjs` with every AI route and every other host blocked.

| Item | Owning milestone | Objective acceptance tests |
|---|---|---|
| Deployment (Workers static-assets binding, real Google client id), device check on phones | M0-A/B | G2 axis-1 rows A1-01…A1-14 on the deployed instance |
| General audit-trail list (item 7) | later migration (`q_audit_trail`) | AT-NOAI-07 extended |
| Dedicated onboarding progress screens (Draft-04 C5) | WP-DOC | AT-NOAI-03 extended, C5 tests |
| Evidence upload widget (needs R2, O-7), IndexedDB queue / upload resume | M2 / O-7 | AT-PWA-* (Architecture), G2 |
| Dedicated handoff screens (CORE-10), remaining TST-3 rows (AT-NOAI-09/10) | CORE-10 / TST-3 | AT-HX-01…08, AT-NOAI-09/10 |
