# Owner decision — SIN handling (2026-11-07, 12:09 America/Toronto)

Grade: `OWNER_DECISION`. Closes the open point "SIN printed on original evidence" recorded in `OWNER_DECISIONS_2026-11-07.md`. The decision of 2026-11-07 09:13 (SIN never enters Balnexa; the Owner enters it by hand at filing) stands.

**Option (b): the Owner redacts the SIN before uploading a document into Balnexa.** Originals of T4, T5, NOA and every other SIN-bearing document are kept securely outside Balnexa.

Balnexa must:

- never receive or store an unredacted SIN-bearing original;
- accept redacted source copies and identify them accurately as `OWNER_REDACTED_SOURCE`;
- preserve the uploaded copy's SHA-256, provenance, document period and redaction status;
- never claim that a redacted copy is byte-identical to the issuing authority's original;
- reject SIN values in structured fields, logs, indexes, AI inputs and generated forms;
- leave SIN fields blank in generated tax forms (the Owner enters the SIN by hand outside Balnexa when required);
- check for hidden PDF text, attachments and metadata that could retain the SIN after visible redaction.

Recorded in `docs/s4/design/Balnexa_S4_V1.2_Addendum_A1_SIN_Redaction.md` (requirements for 9011 and 9014) and `docs/s4/design/Balnexa_S4_Owner_Decision_Register_V1.2-A1.csv` (ODR row `SIN` closed; open items A1-OD-1…3). **Not implemented**: it is built only when the applicable work package (9011, 9014) is authorized. PR #1–#4 are not changed by this record.
