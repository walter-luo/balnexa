# apps/pwa — NOT_IMPLEMENTED (R6.2-R1)

Status: **NOT_IMPLEMENTED.** No PWA code exists. The REST surface it will call (`/api/v1/commands/*`, `/api/v1/queries/*`,
`/auth/google/callback`, `/oauth/authorize` consent submit) is implemented in `apps/worker` for the M0 vertical slice and
is exercised by `tests/blackbox/api.test.mjs` (7/7 on PG16 and PG17).

The PWA is **not** complete and is **not** claimed complete before G2. Full acceptance follows the three-axis matrix in
`docs/AUD-048_Acceptance_Matrix.md` (axis 1: every routine bookkeeping function with **both AI hosts disconnected**).

| Item | Owning milestone | Objective acceptance tests |
|---|---|---|
| Five core mobile experiences (EN/中文) | M2–M4 | G2 axis-1 rows A1-01…A1-14 |
| Offline client reconnect, IndexedDB upload resume | M2 | AT-PWA-* (Architecture), G2 |
| Accessibility and error communication | M4 | G2 |
