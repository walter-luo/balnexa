# S4 V1.2 — 9012 implementation notes

Migration `db/migrations/9012_s4_observations_reconciliation_loans.sql` (UA V1.2 §5.6, §5.7, §10; OBJ-026, OBJ-248,
OBJ-249, OBJ-333, OBJ-373). It is built in sub-stages; the file is not final until the last one, and it has not been
applied to any persistent database. Stage authority: the Owner's delegation of 2026-11-10
(`docs/s4/OWNER_DECISIONS_2026-11-10.md` on `s4/design-addendum-a1`) and the Owner's "继续" ("continue") of 2026-11-11.
All results here are `AUTHOR_RUNTIME_EVIDENCE`.

## Sub-stage plan — `DELEGATED_DECISION` D-9012-1

| Sub-stage | Scope (WP-CORE item) | State |
|---|---|---|
| **9012a** | R28 intra-household loans: `loan_convention`, `loan`, `loan_term_event`, `loan_payment_link`, the engine, `q_r28_loan_position`, commands, the CI oracle (CORE-5, R28 part) | **Done** (this document) |
| 9012b | FX quotes, investment lots, card fee policy and events (CORE-5, the rest) | **Done** (see "9012b — what was built") |
| 9012c | Balance observations, reconciliation exceptions RC-01…14, `statement_period` (CORE-4, BAL01–12, AT-P0-R13/R15) | Not started. It depends on statement extraction (WP-DOC), which does not exist yet |
| 9012d | Imports, cross-source match, payment attributes, onboarding tables, `posting_plan.job_id` FK (CORE-4) | Not started |

**Why R28 first:**

- It is self-contained.
- It has an exact oracle and golden fixtures, so it can be finished and verified in one step.
- Reconciliation (9012c) needs statement rows from document extraction, which comes later.

**Branch:** `s4/9012`, stacked on `s4/9011a` (PR #5), because 9012 sorts after 9011 and needs B003.

## 9012a — what was built

| Object | Content |
|---|---|
| `bnx.loan_convention` | Registry (OBJ-248), seeded and registered as migration-seeded:<br>• day counts ACT/365F, ACT/360, 30/360-BB and 30E/360<br>• period rule `start_inclusive_end_exclusive`<br>• interest models simple and compound<br>• rounding modes HALF_UP and HALF_EVEN, rounding event `payment_and_as_of`<br>• waterfall `interest_then_principal`<br>Adding a convention means adding data and an oracle change (BNX-S2-08 §3) |
| `bnx.loan` (class E, append-only) | Fields:<br>• currency and principal (> 0);<br>• start, plus optional maturity and due dates (open-ended loans, OR-L-02);<br>• lender and borrower parties;<br>• the household's receivable and/or payable account-currency (at least one);<br>• evidence |
| `bnx.loan_term_event` (class F, append-only) | Bitemporal terms (DD-70). Each event has `event_seq`, `recorded_at` and `evidence_ref`. A RATE event needs `effective_from`. A correction appends an event with `retracts_event_seq` and then the new event; nothing is updated |
| `bnx.loan_payment_link` (class F, append-only) | Links a posted journal to the loan, or unlinks it. Each link event carries a ledger version. The payment amount is the journal's movement on the named cash account-currency; the currency is that account's currency (OR-L-04) |
| `bnx.r28_evaluate(contract)` | The only R28 arithmetic in the product (OR-AIH-01): exact `numeric` (no floating point), with the validation order below.<br>• Simple interest is computed as `Σ balance × rate × days / basis`.<br>• Compound interest uses the nominal rate per contracted period, plus a simple stub on the compounded balance.<br>• Each accrual uses a single division, at 40 decimals.<br>• Rounding happens once per event (each payment and the as-of date), with an explicit HALF_EVEN (S4B-F19).<br>• The output includes the rounding-event ledger |
| `bnx.r28_contract(loan, as_of, V, T)` | Builds the engine input from stored facts:<br>• terms recorded at or before T, minus retracted ones;<br>• payments linked at or before ledger version V, from journals visible at V and not corrected at or before V |
| `bnx.q_r28_loan_position(cred, {loan_id, as_of, ledger_version?, terms_recorded_as_of?})` | Returns status `OK` / `TERMS_UNVERIFIED` / `REJECTED` with the refusal code. The position is null when it is not computed, never zero (OR-L-03). Also returns the rounding events, `payments_counted`, `partial_view` (OR-L-05) and `household_internal` (OR-L-06). Visibility follows the account grants; an invisible or unknown loan is `NOT_FOUND`. It is in the function catalog as `finance.read` with an account-currency subset |
| `cmd_declare_loan`, `cmd_declare_loan_terms`, `cmd_link_loan_payment` | Tier 2 (no MCP writes). Rules:<br>• the actor must be able to post on every household side of the loan;<br>• commands are idempotent and audited;<br>• a term batch is all or nothing;<br>• one journal can pay only one loan;<br>• link and unlink alternate (`LINK_STATE`) |
| FAMILY pseudo-institution (L-9012-1, `OWNER_DECISION`) | Registry row `FAMILY`, seeded by 9012:<br>• kind `other`, no jurisdiction, status `ACTIVE_SEED`, classification `HOUSEHOLD_PSEUDO_INSTITUTION`;<br>• display names "Family" (en) and "家庭" (zh-CN).<br>A loan account on FAMILY declares its `region_scope`, through the existing path for institutions without a jurisdiction (F-C2-05). The trigger `t_account_family_institution` (`bnx.trg_account_family_institution`, before insert or update of `institution_id` or `kind` on `bnx.account`) refuses FAMILY for any kind other than `loan_receivable` and `loan_payable`, with `INSTITUTION_NOT_ELIGIBLE`. It covers every writer: create, reassignment, and a kind change |
| Module flags (F-C2-07) | `flag_enforcement_point` rows and `t_scope_flag_*` triggers on the three account-scoped tables. `bnx.trg_scope_flag` MODIFY adds the modes `loan`, `loan_id` and `loan_payment_link` |

### Validation order (UA V1.2 §10.4)

1. **V0a.** The principal is a decimal string > 0. Otherwise `REJECT:INVALID_PRINCIPAL`.
2. **V0b.** Each payment amount is a decimal string > 0 (otherwise `REJECT:INVALID_PAYMENT`), and its date is not before the start (otherwise `REJECT:PAYMENT_BEFORE_START`).
3. **V1.** The currency is known. Otherwise `REJECT:UNKNOWN_CURRENCY`.
4. **V1a.** The principal's scale is at most the currency's minor units.
5. **V1b.** Each same-currency payment's scale is at most the currency's minor units.
6. **V2…V14.** Exactly as BNX-S2-08 §1.2.

V0a and V0b must precede V1, but a scale check needs the currency's minor units. So the scale parts are checked right after V1 (D-9012a-3).

## Decisions taken under the delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9012-1 | 9012 is split into 9012a–d (table above); R28 comes first | Each sub-stage is reviewable and testable on its own; R28 has an oracle; reconciliation waits for statement extraction |
| D-9012a-1 | One engine function holds all R28 arithmetic, and `q_r28_loan_position` only assembles its input | OR-AIH-01: no R28 arithmetic anywhere else. The golden tests can then call the engine directly on the fixture contracts |
| D-9012a-2 | The oracle is upgraded to V1.2 (`tests/oracle/r28_reference.py`) and uses exact fractions. The S2 oracle (`r28_reference_s2_v1_0.py`, SHA-256 `ead5a9f8…22f18`) and the V1.1 fixtures (`84f68f54…98254`) are kept unchanged and hash-checked in CI | With exact fractions, "engine = oracle" can be compared byte for byte, including the rounding-event ledger. The V1.2 oracle reproduces all 30 V1.1 fixtures |
| D-9012a-3 | Validation order V0a, V0b, V1, V1a (principal scale), V1b (payment scale), then V2…V14 | Resolves the ambiguity explained under "Validation order" |
| D-9012a-4 | Fixtures V1.2 were authored here (WP-TEST TST-2 issues them). Expected values are the oracle's, checked by hand below. AT-R28-20 is a database test, because it needs ledger versions | The fixtures were "to be issued"; nothing else could produce exact outputs |
| D-9012a-5 | In the rounding-event ledger, the unrounded value is the exact accrual truncated toward zero to 12 decimals (`unrounded_trunc12`) | A non-terminating exact value has no finite representation. Truncation is the same in Python and SQL, so the ledger can be compared byte for byte |
| D-9012a-6 | A payment's date is the journal's `transaction_date`; its amount is the journal's movement on the linked cash account | Payments are posted journals (OR-L-04). The cash account is where the lender received the money |
| D-9012a-7 | `household_internal` is computed at query time, never stored. It is true only when both sides are accounts in this household's books and `ownership_at(as_of, V)` names the lender on the receivable account and the borrower on the payable account | OR-L-06, INV-23b: from verified ownership facts, never from names |
| D-9012a-8 | Terms are bitemporal by `recorded_at` (`terms_recorded_as_of`); payment links are versioned by ledger version | This matches the signature `q_r28_loan_position(loan_id, as_of, ledger_version, terms_recorded_as_of)` in UA §10 |
| D-9012a-9 | Accrued interest is never posted automatically. Reconciling posted interest journals against the accrual (BNX-S2-08 §1.6) is left for the F3/F5 report work | No report family exists yet (9013/9015) |

## 9012b — what was built

Authority: UA V1.2 §5.7 ("as V1.0"), UA V1.0 §5.7, BNX-S2-02 §4.7 and BNX-S2-14 (OR-R-07, OR-R-08, OR-R-09). The R1 tables
`bnx.fx_override_event` (OBJ-081) and `bnx.valuation` (OBJ-083) are reused unchanged, as the disposition says.

| Object | Content |
|---|---|
| `bnx.fx_quote` (class F, append-only) | base, quote, rate (null exactly when the quality is `MISSING`), `as_of`, source, quality in `REFERENCE`, `EVIDENCED_SETTLEMENT`, `MISSING`, `STALE`. A settlement rate needs evidence or a posted journal. Versioned by `recorded_version` |
| `bnx.fx_rate_at(base, quote, date, V)` | The only rate selection (D-9012b-1). Order: Owner override for that date → evidenced settlement for that date → latest reference on or before the date (`STALE` when older than 7 days or recorded as stale) → `MISSING` with a null rate. Each quality is tried directly, then as the inverse pair (1 / rate at 10 decimals, HALF_EVEN). The same currency is `IDENTITY` |
| `q_fx_rate`, `cmd_record_fx_quote`, `cmd_fx_override` | The query returns the rate, its quality, its date, its source or override id, and `fx_policy`. Recording is tier 2. The override is tier 3 (owner or admin, PWA only, as `fin.fx.override`), needs a reason and is audited; it writes the R1 `bnx.fx_override_event` |
| `bnx.investment_lot`, `bnx.investment_lot_disposal` (class F, append-only) | A lot: investment account-currency, instrument id, units (8 decimals), cost, acquisition date, optional source journal. A disposal: units of one lot, proceeds, `ESTIMATED` or `CONFIRMED` (needs the posted journal), optionally superseding one `ESTIMATED` disposal of the same lot. Disposed units never exceed the lot (`UNITS_EXCEEDED`) |
| `cmd_record_investment_lot`, `cmd_record_lot_disposal`, `cmd_record_valuation` | Tier 2; post rights on the account-currency. A valuation is a price for an instrument held in a lot the actor can post on (R1 `bnx.valuation`) |
| `q_investment_position(account_currency_id, as_of, ledger_version, reporting_currency)` | Per instrument: units held and disposed, remaining cost, realized gain split into confirmed and estimated, the latest NAV on or before `as_of`, market value and unrealized gain. `MISSING_NAV`, `NAV_FX_MISSING`, `NAV_FX_STALE`, `FX_STALE`, `ESTIMATED_PROCEEDS` and `STALE_NAV` (older than 31 days) are flagged; a figure that cannot be computed is null, never zero, and the totals are then null too. With a reporting currency: cost at each lot's acquisition-date rate, proceeds at the disposal-date rate, market value at the `as_of` rate, and the FX effect shown separately for unrealized and realized gains (D-9012b-3) |
| `bnx.card_fee_policy` (class F, append-only) | Versions per card: `effective_from`/`effective_to`, annual fee and currency, `CARD_YEAR` (with an anniversary) or `CALENDAR_YEAR`, closed criteria (`qualifying_spend`, `qualifying_count`, `excluded_economic_types`, `combine` ALL/ANY), `issuer_confirmed`, evidence |
| `bnx.card_fee_event` (class F, append-only) | `CALCULATED_QUALIFICATION` (the server's own calculation, stored with its ledger version), `ISSUER_CONFIRMED_WAIVER` (needs evidence), `FEE_POSTED` / `FEE_REFUNDED` (link a posted fee / refund journal on the card; the amount is the journal's movement). One journal links to one event. R19 ≠ R20 ≠ posting |
| `q_card_fee_progress(card_account_id, as_of, ledger_version, period_start)` | Spend, purchase and refund totals and counts, targets and what remains; then three separate blocks: `calculated` (QUALIFIED / NOT_YET_QUALIFIED / NOT_QUALIFIED / NO_CRITERIA), `issuer` (waiver confirmed or not) and `fee` (NOT_POSTED / POSTED / PARTIALLY_REFUNDED / REFUNDED), plus the last recorded calculation and warnings (`POLICY_NOT_ISSUER_CONFIRMED`, `QUALIFICATION_NOT_CONFIRMED_BY_ISSUER`, `FEE_POSTED_DESPITE_QUALIFICATION_OR_WAIVER`) |
| `cmd_set_card_fee_policy`, `cmd_record_card_fee_event` | Tier 2; post rights on every currency of the card |
| Module flags (F-C2-07) | `t_scope_flag_*` on `investment_lot` (mode `account_currency_id`), `investment_lot_disposal` (new mode `lot_id`), `card_fee_policy` and `card_fee_event` (new mode `card_fee`). `card_fee_event` is a UA §4.4.1 table. The FX tables are household reference data and carry no account scope |
| Function catalog | `q_fx_rate`, `q_investment_position`, `q_card_fee_progress` are `finance.read` (`fin.fx.rate`, `fin.investments.holdings`, `fin.cards.fee_eligibility`); the two position queries need an account-currency subset on an MCP connection. Commands are tier ≥ 2 and therefore never available to MCP |

### 9012b decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9012b-1 | One function selects every rate, with the order override → settlement (same date only) → reference (on or before; stale after 7 days) → missing; quality first, then direct before inverse | OR-R-09 "evidenced settlement authoritative", "override audited", quotes labelled. A settlement rate belongs to its transaction date, so it is not carried to other days. Seven days covers weekends and holidays of reference feeds |
| D-9012b-2 | `STALE` is both a recordable quality (a source may say so) and derived from age; `MISSING` is never replaced by 1 or 0 | UA lists STALE among the qualities; OR-L-03 style "null, never zero" |
| D-9012b-3 | Cost of disposed units is pro rata within the lot named by the disposal (specific identification); FX effect = translation difference of the remaining cost (as_of rate minus acquisition rate) and of the disposed cost (disposal rate minus acquisition rate) | Lots are recorded individually (S2 `investment_lot`), so the disposal names its lot; tax cost methods (for example Canadian average cost) belong to the CRA module, not to this report |
| D-9012b-4 | A NAV older than 31 days is `STALE_NAV` (computed, flagged); a NAV in another currency is converted at the valuation date's rate, and a stale rate is used but flagged (`NAV_FX_STALE`; `FX_STALE` for the reporting rate) | Monthly fund statements are the slowest normal NAV source; a labelled stale rate is more useful than no figure, and the label keeps it visible (OR-R-09) |
| D-9012b-5 | Card spend counts `card_spend` and `consumption_expense` purchases minus `refund` journals on the card in the policy currency, by effective posting date; repayments, transfers, fees, interest, FX, clearing and openings never count; journals linked to a fee event do not count; a correction counts by its replacement's original type | OR-R-07 "refund regresses progress"; a fee refund is not a purchase refund |
| D-9012b-6 | The policy in force on the `as_of` (or `period_start`) date governs the period that contains it; a later policy version affects only periods that start under it | Effective-dated policies (OR-R-07); avoids re-judging a period mid-way |
| D-9012b-7 | The count criterion counts purchase journals; refunds reduce spend, not the count | Issuers count qualifying transactions; a partial refund does not undo a transaction |
| D-9012b-8 | A 29 February anniversary falls on 28 February in other years | Card-year arithmetic must be total |
| D-9012b-9 | `CALCULATED_QUALIFICATION` is computed by the server when recorded; the client cannot supply its figures | A recorded calculation must be reproducible from the ledger at its version |
| D-9012b-10 | Test ids: AT-FX-01, AT-INVL-01 (BNX-S2-14 names it AT-INV-01, which is already the catalog inventory test of core1), AT-P0-R19, AT-9012b-CAT, in the new suite `tests/py/run_s4_core9.py` | Avoids an id collision |

### 9012b test results — `AUTHOR_RUNTIME_EVIDENCE`

New suite `tests/py/run_s4_core9.py` (CI runs it with the other `run_s4_core*.py`). Every expected figure is computed in the
test with Python `Decimal` and HALF_EVEN, never read back from the database.

| Test | Shows |
|---|---|
| AT-FX-01 (OR-R-09) | No quote → `MISSING`, rate null. A reference quote is `REFERENCE` for 7 days, then `STALE`. The inverse pair is 1/rate at 10 decimals. A settlement rate wins over the reference on its own date only. The Owner override wins over both, is audited and is versioned (the earlier ledger version still answers the settlement rate). Same currency → `IDENTITY`. Member override `FORBIDDEN_ROLE`; a viewer reads but cannot record. Six malformed quotes refused. An override reason that holds a SIN candidate is refused and nothing is stored. `fx_quote` is append-only |
| AT-INVL-01 (OR-R-08) | Two lots, 40 units of the first sold. Without a NAV: market value and unrealized gain null, `MISSING_NAV`. With a NAV of 12.50: cost 1200.00, market value 1375.00, unrealized 175.00; in USD unrealized 96.00 of which FX −30.00, realized FX −4.00. The estimate (520.00) superseded by confirmed proceeds (515.00) from the posted redemption; the earlier version still shows the estimate. `STALE_NAV`, `NAV_FX_MISSING` (totals null), `NAV_FX_STALE`. Six invalid commands refused; no grant → `NOT_FOUND` / `NOT_POSTABLE` |
| AT-P0-R19 (OR-R-07, R20) | Card year from 15 February: purchases 550.00 → `QUALIFIED` (a purchase before the year, a repayment and the fee excluded). A refund of 100.00 regresses it to 450.00 `NOT_YET_QUALIFIED`; the earlier version still answers 550.00. A corrected purchase counts by its replacement. The recorded calculation, the issuer's waiver and the posted fee are three separate blocks and events; "posted despite qualified" is warned; the fee refund is not a purchase refund. A new policy version governs the next year only. 29 February anniversaries. Nine invalid or unauthorised commands refused; a view grant reads but cannot record |
| AT-9012b-CAT | Append-only and `t_scope_flag_*` triggers, enforcement points, function catalog rows, table classes, grants (10 commands and queries to `bnx_app`, internal helpers not granted). `bnx.journal_counts_at` equals the R1 rule (`visible_at`, not corrected) on every (journal, version) pair, including a plan posting and a correction. With the region disabled, the lot and the disposal are `SCOPE_DISABLED` and the position is `NOT_FOUND` (9007 visibility) |

Local full regression on PG16.15 and PG17.11: R1 40/0/0 and 38/0/2 (pg_dump 17 is not installed locally), core1–core8 and
core_9011r unchanged and green, core9 4/0/0 on both majors, black-box 8/8, simulation exit 0. `core1` (AT-INV-01) declares the
new helpers and `core2` (AT-FLG-11) the three new enforcement points beyond §4.4.1.

## Owner decisions — `OWNER_DECISION`

| ID | Decision | Implementation |
|---|---|---|
| L-9012-1 (2026-11-11 08:00) | Option 2: create a "Family" pseudo-institution for loan accounts between family members. The Owner chose this over option 1 (a declared region with no institution) | See FAMILY in the table above. Loans with a real lender, such as a mortgage, still name the bank. FAMILY is not restricted to loans whose counterparty is inside the household; `household_internal` still comes only from ownership facts (D-9012a-7). The seed is a migration-seeded row of `bnx.institution`, as the 9006 seeds are |

## Hand checks of the new fixtures

| Fixture | Computation | Expected |
|---|---|---|
| AT-R28-21 | 90 days at 4 % on 5000.00 = 49.315068 → 49.32. The payment of 1000.00 pays 49.32 interest and 950.68 principal. The as-of event accrues 0.00. The payment dated after the as-of date is ignored | principal 4049.32, interest paid 49.32 |
| AT-R28-22 | Single rounding: 7 days at 3.65 % on 3650 = 2.555 plus 24 days at 2.19 % = 5.256, total 7.811 → **7.81**. Rounding each segment with HALF_EVEN would give 2.56 + 5.26 = 7.82, which mutant NEG-03 produces and the fixture rejects. From 2026-02-01 the rate is 3 % on 3557.81 for 28 days = 8.1878 → 8.19 | accrued 16.00, principal 3557.81 |
| AT-R28-23 | 10000 × 1.005¹² = 10616.778118. Stub: 10616.778118 × 0.06 × 15/365 = 26.1783. Interest 642.9565 → **642.96** | 642.96 |

## Test results — `AUTHOR_RUNTIME_EVIDENCE`

Local runs on PG16.15 and PG17.11:

- **Full regression:** R1 40/0/0 on PG16 and 38/0/2 on PG17 (pg_dump 17 is not installed locally); core3–core7 all PASS; the new core8 7/0/0 on both majors; black-box 8/8; simulation exit 0.
- **core1 and core2:** in that run each had one failure, AT-INV-01 and AT-FLG-11, because their declared object lists did not include the new 9012a objects. After the lists were updated, both tests were re-run and pass on both majors.
- **CI:** runs every suite on both majors with PGDG builds.
- **FAMILY re-run (L-9012-1, commit 65179fb):** local full regression green again on PG16.15 and PG17.11, with the same R1 counts (40/0/0 and 38/0/2), core1–core7 unchanged, core8 8/0/0 including AT-R28-FAM, black-box 8/8, simulation exit 0. CI run 43026225677 green on both majors, with PG17 R1 at 40/0/0. AT-REG-01-03 now counts 29 seed institutions with 29 unique codes (FAMILY added).

| Test | Shows |
|---|---|
| AT-R28-GOLD | 41 fixtures (30 from V1.1, 11 from V1.2). The engine's canonical JSON, including every rounding event, is byte-equal to the oracle's and matches each fixture's expected fields. The S2 oracle and the V1.1 fixtures are hash-checked |
| AT-R28-NEG | Three mutants, each killed by its fixture: HALF_EVEN in place of HALF_UP (12a); daily compounding (03b; NEG-02); rounding per rate segment (22; gap G1) |
| AT-R28-HIST-01 | Fixtures 04a and 04b on the command path. After the backdated correction the position is 132.60, and with `terms_recorded_as_of` set to the first recording it is still 124.11. Events are only appended |
| AT-R28-05,20 | Fixture 05 on posted, linked journals. The second payment is corrected at N+1: the position at N+1 counts one payment and re-emits the rounding events, while the position at N is unchanged |
| AT-R28-09 | No grant → `NOT_FOUND`, the same answer as an unknown id. A view grant on one side gives `partial_view`. Terms need post rights on every household side. Revoking the grants hides the loan. A viewer cannot declare |
| AT-R28-11 | Idempotency: replaying the same key returns the same result, and a different payload under that key is `IDEMPOTENCY_CONFLICT`. A failed term batch writes nothing. `INVALID_PRINCIPAL` on scale. Versioned links (0 / 1 / 0 payments). A loan without terms is `TERMS_UNVERIFIED` with null figures |
| AT-R28-CONS | `household_internal` comes only from ownership facts. The three `t_scope_flag_*` triggers are present |
| AT-R28-FAM | The FAMILY seed row and its names. Loan accounts on FAMILY are refused without a declared region. `bank_deposit`, `credit_card`, `e_wallet` and `investment` on FAMILY are refused at create; a reassignment to FAMILY and a kind change of a FAMILY loan account are refused by the trigger. A proposal named "Family" resolves to the seed. A loan between the two FAMILY accounts evaluates `OK` with `household_internal` true. The other core8 tests now use FAMILY loan accounts |

## Limits

| ID | Item | Handling |
|---|---|---|
| L-9012-1 | Loan accounts need a registry institution (9006), and a loan between family members has none | **Resolved** by `OWNER_DECISION` 2026-11-11 (option 2): the FAMILY pseudo-institution (see "Owner decisions") |
| L-9012-2 | No exception queue for `REJECTED` loans yet (BNX-S2-08 §1.2) | It comes with the reconciliation and exception work (9012c) |
| L-9012-3 | F3/F5 consolidation and interest reconciliation are not implemented (AT-R28-CONS covers only the flag) | Report families (9013/9015) |
| L-9012-4 | AT-R28-09/11 "on the plan path" (approval through posting plans) is not covered: loan commands are direct tier-2 commands | Plan kinds for loans need a design decision; recorded for the plan work |
| L-9012-5 | AT-INV-01 still scopes the disposition register up to 9010; the 9012 objects are not yet checked against OBJ-248/249. The engine helpers and `cmd_declare_loan` are declared in its helper list, and AT-FLG-11 lists the two loan tables that are enforcement points beyond §4.4.1 | When 9012 is complete (after 9012d), 9011 and 9012 join the inventory scope |
| L-9012-6 | Disposition register gap: OBJ-249 does not name `cmd_declare_loan`, although a loan must be declared before its terms can be. OBJ-248 does not name `loan_term_event`'s retraction rule. 9012b adds `investment_lot_disposal` and the commands and queries that OBJ-248/249 do not name (`q_fx_rate`, `q_investment_position`, `q_card_fee_progress`, `cmd_record_fx_quote`, `cmd_record_investment_lot`, `cmd_record_lot_disposal`, `cmd_record_valuation`, `cmd_record_card_fee_event`) | Register update proposed for the next design revision; declared in AT-INV-01's helper list meanwhile |
| L-9012-7 | No instrument registry: `instrument_id` is the caller's identifier, shared by `investment_lot` and the R1 `valuation` (which has no foreign key) | An instrument registry belongs to the F4 report work (9013) |
| L-9012-8 | No automatic FX feed (`fx_selection_log`, R1, stays unused) and no automatic card-fee evaluation job | Feeds and jobs need cloud egress and scheduling, outside this stage |
