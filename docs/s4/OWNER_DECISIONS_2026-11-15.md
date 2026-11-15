# Owner decisions — 2026-11-15

`DRAFT — AI-generated` (Claude) record of the project Owner's instructions; authoritative once the Owner confirms it.

Recorded from the Owner's message of 2026-11-15 06:16 (America/Toronto), which quoted "合并" (merge).

| ID | Decision | Effect |
|---|---|---|
| OD-MRG-1 | Merge #48 (L-R2-1 NULL-guard sweep, 9040) and #49 (card-number guard, 9041) | Merged with merge commits: #48 first, then #49 after it was retargeted to `main` |

Recorded from the Owner's message of 2026-11-15 06:52: "1.Debit prefix各家银行不一样，不要限定死了；其他确认" (1. Debit prefixes differ from bank to bank, so do not hard-code them; the rest is confirmed). It replied to the list of items for the Owner's review: (1) the card-number rule D-PAN-1, its scheme table and its false-positive rate; (2) the NULL-guard limitations L-NULL-1, L-NULL-2 and L-NULL-4; (3) the migration register rows for 9040 and 9041.

| ID | Decision | Effect |
|---|---|---|
| OD-PAN-1 | **D-PAN-1 is confirmed.** A full payment-card number is never stored, logged or echoed; only the last 4 digits are kept. **Debit prefixes are not fixed:** they differ by bank | 9042 (detector v1.1.0): any 16–19 digit number that passes the Luhn check counts, whatever its prefix; the scheme table still decides 13–15 digit numbers. Consequences, recorded in `S4_PAN_Guard_2026-11-14.md`: random 16–19 digit references are refused about one time in ten (was about one in thirty), and machine identifiers that are 16-digit numbers by construction (`generation`, `object_generation`) are exempt by key |
| OD-NULL-1 | L-NULL-1 (AI connection without a resource), L-NULL-2 (admission sizing defaults to zero) and L-NULL-4 (fetched mail without an evidence hash or counts) are **accepted as they are** | `S4_L-R2-1_NULL_Guard_Sweep_2026-11-14.md`; no code change |
| OD-REG-1 | The register dispositions for 9040 and 9041 are **accepted** | `S4_Migration_Register_Addendum_9017_9032.md` §3 |
