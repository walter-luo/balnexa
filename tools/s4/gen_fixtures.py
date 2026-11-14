#!/usr/bin/env python3
"""TST-1 synthetic fixture generator (WP matrix V1.2 phase 2.7): fills a mock provider root (BNX_MOCK_ROOT) with a household's
worth of synthetic inputs for the Executor jobs, so DOC_DISCOVER/DOC_PROCESS, INDEX_CONSUME and MAIL_EXACT_FETCH can be run
end to end without any cloud account.

Every value is synthetic. Identification numbers are generated from the test corpus generator (tests/py/sin_corpus.py) and
appear only in the documents meant to be quarantined; they are never printed. Deterministic for a given --seed.

Writes:
  drive/   Inbox: N monthly chequing statements (CSV), N card statements (PDF), one Owner-redacted slip (PDF, label kept,
           number removed), one slip with a visible number (to be QUARANTINED), one ZIP (SCAN_INCOMPLETE)
  index/   index-ref.json: one record per filed Inbox file (contract bnx-shared-index-consumer/1.0) + a CRA notice record
  mail/    mbx-owner-gmail: one statement notice per month with a PDF attachment (digit-free Message-IDs, L-INT-1)
  MANIFEST.json  what was written (ids, kinds, expected verdicts); no values

Usage: gen_fixtures.py --root DIR [--months 3] [--seed 1]"""
import argparse, json, os, random, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "apps", "executor"))
sys.path.insert(0, os.path.join(ROOT, "tests", "py"))
from bnx_exec import providers as P   # noqa: E402
import doc_fixtures as DF             # noqa: E402

LETTERS = "abcdefghijklmnopqrstuvwxyz"


def word(rnd, n=10):
    return "".join(rnd.choice(LETTERS) for _ in range(n))


def statement_csv(rnd, month):
    rows = ["Date,Description,Amount"]
    bal = 0.0
    for day in sorted(rnd.sample(range(1, 28), 6)):
        amt = round(rnd.uniform(-180, -5), 2) if rnd.random() < 0.8 else round(rnd.uniform(500, 3000), 2)
        bal += amt
        rows.append(f"2026-{month:02d}-{day:02d},Synthetic {'payee' if amt < 0 else 'payer'} {word(rnd, 6)},{amt:.2f}")
    return ("\n".join(rows) + "\n").encode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--months", type=int, default=3)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    drive, index, mb = P.MockDrive(a.root), P.MockIndex(a.root), P.MockMailbox(a.root, "mbx-owner-gmail")
    man = {"seed": a.seed, "drive": [], "index": [], "mail": []}
    base = {k: "" for k in P.INDEX_COLUMNS}
    recs = []
    for m in range(1, a.months + 1):
        f = drive.put_inbox(statement_csv(rnd, m), f"Synthetic chequing statement 2026-{m:02d}.csv")
        man["drive"].append({"file_id": f["source_file_id"], "kind": "chequing_csv", "expect": "PENDING_DECLARATION (no classifier)"})
        recs.append({**base, "File ID": f["source_file_id"], "Original Name": f"Synthetic chequing statement {m}", "Domain": "Banking_Tax",
                     "Type": "Statement", "Source": "statements@synthbank.example", "Document Date": f"2026-{m:02d}-28",
                     "Processed Date": f"2026-{m:02d}-28"})
        g = drive.put_inbox(DF.pdf_clean(), f"Synthetic card statement 2026-{m:02d}.pdf")
        man["drive"].append({"file_id": g["source_file_id"], "kind": "card_pdf", "expect": "PENDING_DECLARATION (no classifier)"})
        raw = P.eml_bytes("Statements <statements@synthbank.example>", "owner@family.example", "Your synthetic statement is ready",
                          f"<statement-{word(rnd)}@synthbank.example>", attachments=[("statement.pdf", DF.pdf_clean(), "application/pdf")])
        pid = mb.put(raw)
        man["mail"].append({"provider_message_id": pid, "kind": "statement_notice_with_pdf"})
    r = drive.put_inbox(DF.pdf_redacted_t4(), "Synthetic slip redacted.pdf")
    man["drive"].append({"file_id": r["source_file_id"], "kind": "redacted_slip_pdf", "expect": "PENDING_DECLARATION; admissible after the Owner declares"})
    v = drive.put_inbox(DF.pdf_visible(DF.v("luhn", a.seed + 100)), "Synthetic slip.pdf")
    man["drive"].append({"file_id": v["source_file_id"], "kind": "slip_with_number", "expect": "QUARANTINED"})
    z = drive.put_inbox(b"PK\x03\x04" + bytes(60), "Synthetic archive.zip")
    man["drive"].append({"file_id": z["source_file_id"], "kind": "zip", "expect": "SCAN_INCOMPLETE"})
    recs.append({**base, "File ID": "craNoticeSynthetic", "Original Name": "Notice of assessment", "Domain": "Banking_Tax",
                 "Type": "CRA Notice", "Tags": "CRA", "Source": "notify@cra-arc.gc.ca", "Document Date": f"2026-{a.months:02d}-15",
                 "Processed Date": f"2026-{a.months:02d}-16"})
    index.put("index-ref", recs, open_items=[{"key": "follow up synthetic notice"}])
    man["index"] = [{"location": "index-ref", "records": len(recs), "note": "register with location_secret_ref sm://synthetic/index-ref"}]
    with open(os.path.join(os.path.abspath(a.root), "MANIFEST.json"), "w") as fh:
        json.dump(man, fh, indent=1)
    print(f"ok: {len(man['drive'])} Inbox files, {len(recs)} index records, {len(man['mail'])} messages under {os.path.abspath(a.root)}")


if __name__ == "__main__":
    main()
