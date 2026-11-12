# S4 9013 — Report families, snapshot status, artifacts — Implementation notes

Status: implemented in `db/migrations/9013_s4_report_families_snapshot_status.sql`, branch `s4/9013` (stacked on `s4/9012`).
Evidence grade: `AUTHOR_RUNTIME_EVIDENCE` (author's local runs on PG16.15 and PG17.11 and CI); not independently reviewed.

Authority: UA V1.2 §5.8 (families "as V1.0", snapshot status, artifact side table), UA V1.0 §5.8.1, Owner Requirements Book V1.2
OR-R-01…06, crosswalk R01–R34 V1.1 (families per R code), disposition OBJ-027, OBJ-216, OBJ-250, OBJ-251, OBJ-374.

## What was built

| Object | Content |
|---|---|
| `bnx.report_definition` | Versioned definitions (class E, append-only): `R-BAL/1` (the R1 definition, still replayable), `F1/1`…`F7/1`, `R09/1`, `R28/1`, `R30/1`, `R31/1`, each with its query function, parameters and crosswalk R codes |
| Common envelope | Every result carries `ledger_version`, `as_of`, `reporting_currency`, `fx_policy`, `fx_snapshot_ref` (the latest FX fact version at V), `grants_digest` (SHA-256 of the actor's visible account-currencies), `scope_warnings[]`, `evidence_refs[]`, `rounding`. Amounts are decimal strings; unlike currencies are never summed (OR-R-02) |
| `q_f1_balances` (F1: R03, R11, R16, R27, R33) | Per visible account-currency: institution, account, holders from verified ownership (none → `unknown`), native balance at (as_of, V), the latest final statement closing in its own column (never merged), and the reporting-currency value with rate and quality. Totals per currency; a reporting total only when every rate is present. Grouping is by the internal account id only |
| `q_f2_transactions` (F2: R12, R18, R24) | Journals with a line on a visible account-currency: effective posting date and economic type, flow class, lines (a line on an account the reader cannot see is masked), correction provenance, linked source rows; calendar inflow/outflow per day (OR-U-03) |
| `q_f3_income_expense` (F3: R05–R08) | Income and expense category lines of journals whose every account line is visible (a private account's spending is absent for others — AT-GRANT-01); totals per currency split into operating income, operating expense, operating net, investing results and other |
| `q_cashflow_statement` (R09, P0) | Movements on visible bank, cash and e-wallet accounts by `economic_type_rule.flow_class` of the effective type (OPERATING, TRANSFER, INVESTING, FINANCING, CARD_REPAYMENT, LOAN_PRINCIPAL, CORRECTION), inflow / outflow / net; opening + flows = closing is checked (`reconciles`) |
| `q_f4_investments` (F4: R22–R25, R33) | Per visible investment account-currency: `q_investment_position` (holdings, realized confirmed vs estimated, unrealized, FX effect) plus its movements (F2) |
| `q_f5_networth` (F5: R01, R02, R04, R16, R27, R28, R33) | Book value per visible account-currency (assets, liabilities by account kind); R28 receivable / payable pairs whose both sides are visible household account-currencies are eliminated and shown apart (INV-23b, no double counting); ownership view by verified legal-owner shares, the rest `unknown`; reporting-currency net worth |
| `q_f6_cards` (F6: R17, R19–R21) | Per visible card: owed balance, latest final statement, repayments since it, and the 9012b annual-fee progress (calculated / issuer / posted kept apart) |
| `q_f7_reconciliation` (F7: R13–R15) | The 9012c findings in force, coverage per account-currency (statements with their latest run, gaps after the anchor), open clearing items and transfer-matching decisions |
| `q_r30_review_queue` (R30, P0) | Derived from open facts: open reconciliation findings, open clearing items, pending match proposals, unmatched source rows, plans awaiting approval or not yet activated. There is no dismiss path: an item leaves only when its underlying decision is made. The 9010 `q_review_queue` (plans and registry) is kept |
| `q_evidence_trace` (R31, P0) | From a journal or a source row: source rows → statements → documents → evidence objects (integrity state) → the journal and its correction family → the R-BAL snapshots that included it |
| `bnx.report_snapshot_artifact` (class F, append-only) | Rendered artifact facts (`artifact_ref`, `artifact_sha256`, renderer version, source and ownership revisions, FX/NAV snapshot ref, coverage, warnings), written only by `wrk_snapshot_artifact` (worker role). `bnx.report_snapshot` and `bnx.balance_rows` are untouched (S4B-F04) |
| `q_snapshot_status`, `q_snapshot_list` | `ACCESS_REVOKED` (from `snapshot_decision`; nothing else disclosed), otherwise `STALE` with reasons (`LEDGER_CHANGED_IN_SCOPE` — a posting dated on or before as_of recorded later on a shown account-currency; `BACKDATED_CORRECTION`; `ANCHOR_CHANGED`; `OWNERSHIP_CHANGED`; `FX_CHANGED` for converted snapshots), else `CURRENT`. Over-invalidation is possible, a stale snapshot is never `CURRENT` (OR-R-05) |
| `q_snapshot_artifact` | The O-4 proxy's database call: the current grant decides; `ACCESS_REVOKED` discloses no reference; returns the latest artifact with the status for `X-BNX-Snapshot-Status`; audited |
| `cmd_create_report_snapshot` MODIFY (OBJ-216) | The requested account-currencies pass `pol_scope_filter` before `balance_rows`; the definition version comes from `report_definition`; digests unchanged |

## Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9013-1 | F3 counts income and expense category lines (the accounting P&L), split by the flow class of the journal; investment results are reported apart from operating income | Every operating, fee, interest and refund type posts to categories; transfers and principal never do (B6.1) |
| D-9013-2 | R09 is a cash basis on bank, cash and e-wallet accounts; a card purchase is operating but moves no cash until the card repayment | OR-R-04 "operating flows vs … card repayment"; avoids double counting the card purchase |
| D-9013-3 | F2 masks lines on accounts the reader cannot see; F3/F5 totals exclude journals and balances of such accounts | A visible account's history must match its balance; a private account must be absent from totals (AT-GRANT-01) |
| D-9013-4 | F5 is book value; market value of investments is in F4 | Book value is the ledger's figure at V; valuation has its own quality flags (R33) |
| D-9013-5 | The R30 query is named `q_r30_review_queue` | `q_review_queue` already exists (9010) with a different, narrower contract |
| D-9013-6 | Snapshot staleness is judged on the account-currencies the snapshot shows (its projection), not the whole household content | A posting on an account the audience never saw cannot change what it saw; the audit digest is replayed separately |
| D-9013-7 | Snapshots remain R-BAL only; family results are delivered by the queries with their envelope | The R1 digest machinery (`balance_rows`) is the only replayable content; family snapshots would need a new canonicalisation (L-9013-1) |
| D-9013-8 | Test ids AT-F1, AT-F2-F3, AT-P0-R09, AT-F4-F5-F6, AT-F7-P0 (R11, R13, R15, R30, R31), AT-RPT-STALE, AT-ARCH-ACL (01, 02, 04 and AT-SNAP-03/04 under toggles), AT-9013-CAT in `tests/py/run_s4_core12.py` | Golden figures are derived by hand from the postings (comments in the test) |

## Test results — `AUTHOR_RUNTIME_EVIDENCE`

| Test | Shows |
|---|---|
| AT-F1 | cad 2000.00, card −50.00, USD 100.00; CAD 4150 and USD 100 never summed; reporting USD 3212.50 = 4150 × 0.75 + 100; printed statement closing apart; holders; envelope; a member without the card grant neither sees nor can ask for it |
| AT-F2-F3 | 7 cad journals with provenance; masked card line for a member; calendar; income 3000, expenses 350, net 2650 (owner) vs expenses 200, net 2800 (member, private card absent) |
| AT-P0-R09 | Operating net 2800 apart from card repayment −100, transfers 700/−700, investing −1000; 1500 + flows = 3200 |
| AT-F4-F5-F6 | Market value 1050.00 vs cost 1000.00; R28 pair eliminated, net worth 4150 (USD 3212.50), owner view, private card absent for a member; card owed 50.00, repayments 100, fee spend 150 of 1000 |
| AT-F7-P0 | R15 gap and partial-never-final; R14 matched; R13/R30 queue leaves only through decisions, no dismiss path; R31 row → statement → evidence → journal → correction → snapshot; private journal not traceable by a member |
| AT-RPT-STALE | CURRENT; unaffected by later or unrelated postings; STALE on a backdated posting and a backdated correction; ACCESS_REVOKED after the grant is revoked; another member's snapshot NOT_AVAILABLE |
| AT-ARCH-ACL | Worker-only, append-only artifact facts; owner of the snapshot reads reference and status; another member NOT_AVAILABLE; disabled region → ACCESS_REVOKED with no reference; projection digests verify at every module toggle |
| AT-9013-CAT | 12 definitions, 13 catalog rows, grants, `report_snapshot` shape unchanged |

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-9013-1 | Snapshots are R-BAL only (D-9013-7) | Family snapshot canonicalisation in a later revision |
| L-9013-2 | The Executor `REPORT_RENDER` job, the Drive archive writer and the `GET /api/v1/artifacts/{id}` proxy route are code outside the database; only their database contracts exist here. AT-ARCH-ACL-03 (Drive permissions = instance identity) is a PV-DRV-01 item | WP-DOC / Worker |
| L-9013-3 | R17 minimum payment and due dates (R21 calendar) are not modelled (`DUE_DATE_NOT_MODELLED`); R25 maturities are not modelled (`MATURITIES_NOT_MODELLED`) | Needs card statement extraction and lot maturity data |
| L-9013-4 | R02 net-worth trend and R06 income/expense trend are obtained by calling F5/F3 per period; no stored series | A trend view can compose the queries |
