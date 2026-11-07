# Owner decisions — 2026-11-06

Recorded from the Owner's message of 2026-11-06 22:34 America/Toronto ("PayPal、Apple Pay = CA，其他同意") answering the five open items listed on 2026-11-06 22:19, each with a stated recommendation. Grade: `OWNER_DECISION`.

| Item | Question | Decision | Implemented in |
|---|---|---|---|
| F-C2-04 | After the upgrade, R1 accounts on free-text institutions have region UNKNOWN and stay fail-closed (no posting, balances hidden) until the Owner verifies the institution | **Accepted** as designed | no change (9006/9007 behaviour; AT-MIG-10, AT-REG-17) |
| F-C2-05 | Jurisdictions of the payment providers, which the Amendment 02 seed does not carry | **Alipay, WeChat Pay, UnionPay = CN; PayPal, Apple Pay = CA** (the Owner changed the proposed US to CA for PayPal and Apple Pay) | 9006 data step after the seed load; AT-REG-01-03,09 and AT-REG-15 |
| F-C2-13 | Grants on accounts of a disabled region | **Reductions allowed, additions and widening refused** | 9007 `trg_scope_flag` mode `account_grant`; AT-FLG-01-09 |
| F-C1-12 | `household_setting.data_class` values | **`synthetic`, `owner_test`, `real`** (as proposed) | no change (9004) |
| F-C3-05 | `flow_class` for the 26 economic types | **Proposed mapping accepted**; intra-household loan rules to be refined with R28 (9012) | no change (9008) |

Correction to F-C2-13 as first reported (2026-11-05): the report said a grant on a disabled region could be "neither added nor revoked". In fact a **full** revocation was always possible: R1 `cmd_set_grant` deletes the row when `can_view` is false, and the gate covered only INSERT/UPDATE. What was blocked was a **partial** reduction (keep view, drop post), because `cmd_set_grant` upserts and the BEFORE INSERT gate fired. The rule now compares an upsert with the existing grant and gates only additions and widening.

## Addendum — increment 4 (9010)

Recorded from the Owner's message of 2026-11-06 23:20 America/Toronto ("同意") answering the two open items of increment 4 (F-C4-06, F-C4-09), each presented with the implemented behaviour as the proposal. Grade: `OWNER_DECISION`.

| Item | Question | Decision | Implemented in |
|---|---|---|---|
| F-C4-06 | Derived owner type of a shared-index record with no owner tag | **Accepted as implemented**: no owner tag ⇒ `PERSONAL`; Tags `Corporate`/`Business` ⇒ `CORPORATE` and `Owner:Unknown` ⇒ `UNKNOWN`, both `BLOCKED (OWNER_TYPE_AMBIGUOUS)` on a household instance | no change (9010 `wrk_consume_shared_index`; AT-EML-01-04) |
| F-C4-09 | Withdrawing or re-validating a held non-draft plan (V1.2 names no command) | **Accepted**: `cmd_withdraw_plan` and `cmd_validate_plan` (PWA, T2, `can_post` on the plan account) are kept | no change (9010; AT-PLAN-05, AT-PLAN-05b) |
