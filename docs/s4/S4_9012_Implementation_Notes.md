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
| 9012b | FX quotes, investment lots, card fee policy and events (CORE-5, the rest) | Not started |
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

| Test | Shows |
|---|---|
| AT-R28-GOLD | 41 fixtures (30 from V1.1, 11 from V1.2). The engine's canonical JSON, including every rounding event, is byte-equal to the oracle's and matches each fixture's expected fields. The S2 oracle and the V1.1 fixtures are hash-checked |
| AT-R28-NEG | Three mutants, each killed by its fixture: HALF_EVEN in place of HALF_UP (12a); daily compounding (03b; NEG-02); rounding per rate segment (22; gap G1) |
| AT-R28-HIST-01 | Fixtures 04a and 04b on the command path. After the backdated correction the position is 132.60, and with `terms_recorded_as_of` set to the first recording it is still 124.11. Events are only appended |
| AT-R28-05,20 | Fixture 05 on posted, linked journals. The second payment is corrected at N+1: the position at N+1 counts one payment and re-emits the rounding events, while the position at N is unchanged |
| AT-R28-09 | No grant → `NOT_FOUND`, the same answer as an unknown id. A view grant on one side gives `partial_view`. Terms need post rights on every household side. Revoking the grants hides the loan. A viewer cannot declare |
| AT-R28-11 | Idempotency: replaying the same key returns the same result, and a different payload under that key is `IDEMPOTENCY_CONFLICT`. A failed term batch writes nothing. `INVALID_PRINCIPAL` on scale. Versioned links (0 / 1 / 0 payments). A loan without terms is `TERMS_UNVERIFIED` with null figures |
| AT-R28-CONS | `household_internal` comes only from ownership facts. The three `t_scope_flag_*` triggers are present |

## Limits

| ID | Item | Handling |
|---|---|---|
| L-9012-1 | Loan accounts (`loan_receivable` and `loan_payable`) need a registry institution, because 9006 requires one for every account except cash and other assets. A loan between family members has no institution; the tests use the synthetic bank | Needs an Owner decision: either allow region `NONE` or a declared region for loan accounts, or accept an "intra-household" pseudo-institution |
| L-9012-2 | No exception queue for `REJECTED` loans yet (BNX-S2-08 §1.2) | It comes with the reconciliation and exception work (9012c) |
| L-9012-3 | F3/F5 consolidation and interest reconciliation are not implemented (AT-R28-CONS covers only the flag) | Report families (9013/9015) |
| L-9012-4 | AT-R28-09/11 "on the plan path" (approval through posting plans) is not covered: loan commands are direct tier-2 commands | Plan kinds for loans need a design decision; recorded for the plan work |
| L-9012-5 | AT-INV-01 still scopes the disposition register up to 9010; the 9012 objects are not yet checked against OBJ-248/249. The engine helpers and `cmd_declare_loan` are declared in its helper list, and AT-FLG-11 lists the two loan tables that are enforcement points beyond §4.4.1 | When 9012 is complete (after 9012d), 9011 and 9012 join the inventory scope |
| L-9012-6 | Disposition register gap: OBJ-249 does not name `cmd_declare_loan`, although a loan must be declared before its terms can be. OBJ-248 does not name `loan_term_event`'s retraction rule | Register update proposed for the next design revision |
