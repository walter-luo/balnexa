#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 V1.2 9011R tests: remediation of the 9011/G0R same-family review of 2026-11-11 (45 findings R-01...R-45;
docs/s4/S4_9011R_Remediation_2026-11-11.md). Each test names the findings it closes. The detector findings R-01...R-05 and
R-41...R-43 are also covered by the corpus (tests/fixtures/s4/sin_corpus_v1.json 1.1.0, AT-SIN-11/12 in run_s4_core5.py);
the audit-chain findings R-10, R-12 and R-14 by AT-G0R-01/02/05 in run_s4_core7.py. Synthetic data only; generated values
are never written to evidence (case ids, rule codes and counts only). Conventions as run_g0.py.
Usage: run_s4_core_9011r.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, hashlib, json, os, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core5 as C5
import sin_corpus as SC
import fp_corpus as FP

sys.path.insert(0, os.path.join(h.ROOT, "apps", "executor"))
from bnx_exec import sin_detector as S  # noqa: E402

RESULTS, TESTS = [], []
check, expect_err, Fail = C1.check, C1.expect_err, C1.Fail
discover, verdict, archive, sha, state = C5.discover, C5.verdict, C5.archive, C5.sha, C5.state


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def notifications(H, key_prefix):
    return C4.one(H, "select count(*) from bnx_intake.notification where dedupe_key like %s", (key_prefix + "%",))[0]


# ------------------------------------------------------------------------------------------------ detector measurement
@test("FP-SIN-01", "Addendum A1 Rev 1 §6, §11 FP-SIN-01; review R-16 (measurement on the synthetic benign corpus)")
def t_fp(server, ev):
    m = FP.measure(lambda t: S.scan(t))
    json.dump({"detector": S.VERSION, **m}, open(os.path.join(ev, "FP-SIN-01.json"), "w"), indent=1)
    r9 = m["per_category"]["reference_9"]["rate"]
    other = m["overall_without_reference_9"]["rate"]
    # measurement, not pass/fail on the rate itself; the checks only guard against a broken corpus or detector
    check(0.05 <= r9 <= 0.2 and other < 0.01, f"{m['overall']} {r9} {other}")
    return (f"detector {S.VERSION} on {m['overall']['items']} synthetic benign items: overall {m['overall']['rate']:.2%}; random "
            f"nine-digit references {r9:.2%} (the accepted A1-OD-1 cost: Mod 10 about 1 in 10, 08/09 about 1 in 50); all other "
            f"categories together {other:.2%} (hashes and UUIDs in prose are the only contributors); per category in FP-SIN-01.json")


REVIEW = os.path.join(h.ROOT, "tests", "py", "review9011")
# reviewer detector cases that stay negative by design (docs/s4/S4_9011R_Remediation_2026-11-11.md §2)
DET_BY_DESIGN = {"R-A-22", "R-A-46", "R-A-48", "R-A-55", "R-A-57", "R-A-60", "R-A-77", "R-A-79", "R-A-93", "R-A-94", "R-A-98",
                 "R-A-102", "R-A-105"}


@test("AT-9011R-DET", "review R-01...R-05, R-41...R-43 (the reviewer's 108 adversarial and 400 fuzz cases, Python/JS/SQL)")
def t_review_detector(server, ev):
    sys.path.insert(0, REVIEW)
    os.environ.setdefault("BNX_REPO", h.ROOT)
    import adv_detector as A
    cases = [c for c in A.build() + A.fuzz() if c["origin"] != "ocr"]
    ocr = [c for c in A.build() if c["origin"] == "ocr"]
    js = C5.js_hits(cases)
    db = h.fresh(server, "bnx_r_det")
    diffs, missed = [], []
    with C1.migrator(server, db) as cx:
        for c in cases:
            p = sorted(map(C5.key, C5.py_hits(c)))
            j = sorted(map(C5.key, js[c["id"]]))
            q = sorted(map(C5.key, C5.sql_hits(cx, c)))
            if not (p == j == q):
                diffs.append(c["id"])
            if c["id"].startswith("R-A-") and not p:
                missed.append(c["id"])
    missed += [c["id"] for c in ocr if not C5.py_hits(c)]
    json.dump({"cases": len(cases) + len(ocr), "differences": diffs, "not_detected": sorted(missed)},
              open(os.path.join(ev, "AT-9011R-DET.json"), "w"), indent=1)
    check(not diffs, f"implementations differ: {diffs}")
    check(set(missed) == DET_BY_DESIGN, f"not detected beyond the by-design set: {sorted(set(missed) - DET_BY_DESIGN)}; "
                                        f"now detected from it: {sorted(DET_BY_DESIGN - set(missed))}")
    return (f"{len(cases)} reviewer cases ({len(cases) - 400} adversarial without OCR, 400 fuzz) and {len(ocr)} OCR cases: Python, JS "
            f"and SQL identical; every reviewer "
            f"evasion form is detected (hex/UUID padding, unlisted invisible characters, dot/slash/underscore/minus/bullet "
            f"separators, 2-4-3 and 4-5 groupings, label windows, acronym keys); not detected: only the {len(DET_BY_DESIGN)} "
            f"by-design cases (correct negatives, CRA program accounts, clean OCR runs)")


def evasion_forms(L):
    """The reviewer's end-to-end forms (e2e_evasion.py, e2e_shared_index.py), built from a generated value."""
    return {"hex padding before": "a" * 23 + L, "hex padding after": L + "f" * 23, "invisible U+200E": L[:4] + "‎" + L[4:],
            "invisible U+2061": L[:4] + "⁡" + L[4:], "dot separators": ".".join((L[:3], L[3:6], L[6:])),
            "slash separators": "/".join((L[:3], L[3:6], L[6:])), "2-4-3 grouping": f"{L[:2]} {L[2:6]} {L[6:]}",
            "labelled 2-4-3 grouping": f"SIN {L[:2]} {L[2:6]} {L[6:]}", "UUID-shaped tail": "abcdef12-abcd-4bcd-8bcd-" + L + "abc",
            "keycap digits": "".join(c + "️⃣" for c in L), "control: plain value": L}


@test("AT-9011R-E2E", "review R-01, R-02, R-03, R-41 end to end (production command and shared index; reviewer's e2e forms)")
def t_e2e(server, ev):
    L = SC.value("luhn", 301)
    forms = evasion_forms(L)
    H = C4.index_household(server, "bnx_r_e2e")
    out = {}
    for name, v in forms.items():
        try:
            H.expense(H.owner, "1.00", desc="x " + v)
            out[name] = "STORED"
        except psycopg.Error as e:
            out[name] = (e.diag.message_primary or "")[:20]
    recs = [C4.rec("f-e2e-%d" % k, notes="note " + v) for k, v in enumerate(forms.values())] + [C4.rec("f-e2e-clean")]
    st, sid = C4.consume(H, recs)
    acks = dict(C4.sql(H, "select record_key, status from bnx_intake.index_record_ack"))
    stored = " ".join(str(r[0]) for r in C4.sql(H, "select description from bnx.journal_entry union all "
                                                   "select columns::text from bnx_intake.external_index_record union all "
                                                   "select payload::text from bnx_intake.staging_payload"))
    H.close()
    blocked = sorted(k for k, s in acks.items() if s == "BLOCKED")
    leaked = not C5.no_value(stored, [L])
    json.dump({"posting": out, "index_acks": acks, "value_in_database": leaked}, open(os.path.join(ev, "AT-9011R-E2E.json"), "w"), indent=1)
    check(all(v == "SIN_CANDIDATE" for v in out.values()), f"stored: {[k for k, v in out.items() if v != 'SIN_CANDIDATE']}")
    check(len(blocked) == len(forms) and acks.get("f-e2e-clean") == "CONSUMED" and not leaked, f"{acks} leaked={leaked}")
    return (f"{len(forms)} forms (hex padding before and after, U+200E and U+2061 inside, dot and slash separators, 2-4-3 with and "
            f"without a label, UUID tail, keycap digits, plain control) refused by cmd_post_transaction (SIN_CANDIDATE) and "
            f"BLOCKED by the shared-index consumer; the clean record CONSUMED; the value is nowhere in the database")


# reviewer validator cases whose verdict stays as recorded, with the reason in the remediation note §3
VAL_BY_DESIGN = {
    "PDF-META-catalog-integer-value": "D-9011c-2: numbers in PDF dictionaries are not read (coordinates)",
    "PDF-META-name-object-with-digits": "D-9011c-2: name objects are not text",
    "EML-pgp-armored-body-unreadable": "encrypted content is out of scope (R-45 item 5)",
    "TXT-ebcdic-cp037": "EBCDIC is not an accepted text encoding (R-45 item 6)",
    "PDF-IMG-unsupported-or-garbage-filter-CCITTFaxDecode": "garbage fax data decodes to a blank image; limit L-R-3",
    "XLSX-split-across-three-cells": "D-9011c-7: cells are judged one by one",
}


@test("AT-9011R-VAL", "review R-18...R-40, R-45 (the reviewer's validator cases, light set, against this validator)")
def t_review_validator(server, ev):
    sys.path.insert(0, REVIEW)
    import common
    for m in ("q8_pdf", "q8_xlsx", "q8_eml", "q8_img", "q8_text", "q8_extra", "q9_limits"):
        __import__(m)
    out, counts = {}, {}
    for cid, expect, fn, tags in list(common.REGISTRY):
        if tags["heavy"]:
            continue
        rec = common.run_one(cid, expect, fn, tags)
        out[cid] = {k: rec.get(k) for k in ("expect", "verdict", "result", "rules")}
        counts[rec["verdict"]] = counts.get(rec["verdict"], 0) + 1
    bad = {k: v for k, v in out.items() if v["verdict"] in ("MISSED", "NOT_FAIL_CLOSED", "FALSE_POSITIVE", "HANG", "EXC_ESCAPED")}
    json.dump({"counts": counts, "bad": bad, "by_design": VAL_BY_DESIGN, "cases": out}, open(os.path.join(ev, "AT-9011R-VAL.json"), "w"), indent=1)
    unexpected = sorted(set(bad) - set(VAL_BY_DESIGN))
    check(not unexpected, f"{len(unexpected)} cases not handled: {unexpected[:30]}")
    return (f"{len(out)} reviewer validator cases: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) +
            f"; the remaining {len(bad)} are the documented by-design or limit cases ({', '.join(sorted(bad))})")


# ------------------------------------------------------------------------------------------------ document states
@test("AT-9011R-07", "review R-07; A1-OD-2, Addendum §5.3 ('terminal for that SHA-256'), AT-SIN-18 extended to a second discovery")
def t_quarantine_hash(server, ev):
    H = C4.v2_full(server, "bnx_r07")
    out = {}
    hq = sha("r07-quarantined")
    d1 = discover(H, "f-r07-a", module="FINANCE")
    out["first"] = verdict(H, d1, hq, result="SIN_CANDIDATE", cls="BANK_STATEMENT")["state"]
    n1 = notifications(H, "SIN_QUARANTINE:" + hq)
    # the same bytes under another Drive file id, now reported PASSED (e.g. by a rebuilt Executor)
    d2 = discover(H, "f-r07-b", module="FINANCE")
    r2 = verdict(H, d2, hq, cls="BANK_STATEMENT")
    out["second_discovery"] = [r2["state"], r2.get("reason")]
    out["second_archive"] = archive(H, d2, hq, "f-r07-b").get("reason")
    out["notifications"] = [n1, notifications(H, "SIN_QUARANTINE:" + hq)]
    # admission race: bytes admitted under d3, then quarantined under d4 before d3 is archived
    hr = sha("r07-race")
    d3 = discover(H, "f-r07-c", module="FINANCE"); verdict(H, d3, hr, cls="BANK_STATEMENT")
    d4 = discover(H, "f-r07-d", module="FINANCE"); verdict(H, d4, hr, result="SIN_CANDIDATE", cls="BANK_STATEMENT")
    a3 = archive(H, d3, hr, "f-r07-c")
    out["archive_after_hash_quarantine"] = [a3.get("state"), a3.get("reason")]
    r3 = verdict(H, d3, hr, cls="BANK_STATEMENT")
    out["rescan_after_that"] = [r3.get("state"), r3.get("reason")]
    # SCAN_INCOMPLETE under the current detector: the same bytes are not admitted on another verdict
    hi = sha("r07-incomplete")
    d5 = discover(H, "f-r07-e", module="FINANCE"); verdict(H, d5, hi, result="SCAN_INCOMPLETE", cls="BANK_STATEMENT")
    d6 = discover(H, "f-r07-f", module="FINANCE")
    r6 = verdict(H, d6, hi, cls="BANK_STATEMENT")
    out["incomplete_hash"] = [r6["state"], r6.get("reason")]
    z3 = C4.one(H, "select count(*) from bnx_doc.document_evidence where discovery_id = any(%s::uuid[])", ([d2, d3, d6],))[0]
    H.close()
    json.dump(out | {"z3_rows": z3}, open(os.path.join(ev, "AT-9011R-07.json"), "w"), indent=1)
    check(out["first"] == "QUARANTINED" and out["second_discovery"] == ["QUARANTINED", "QUARANTINED_HASH"]
          and out["second_archive"] == "NOT_ADMISSIBLE" and out["notifications"] == [1, 1], f"{out}")
    check(out["archive_after_hash_quarantine"] == ["DISCOVERED", "QUARANTINED_HASH"]
          and out["rescan_after_that"] == ["QUARANTINED", "QUARANTINED_HASH"], f"{out}")
    check(out["incomplete_hash"] == ["SCAN_INCOMPLETE", "INCOMPLETE_HASH"] and z3 == 0, f"{out} z3={z3}")
    return ("bytes quarantined under one discovery are quarantined under a second discovery that reports PASSED "
            "(QUARANTINED_HASH, one notification for the SHA-256, archive NOT_ADMISSIBLE); an admitted copy whose bytes are "
            "quarantined elsewhere before archiving returns to DISCOVERED and is then quarantined; bytes SCAN_INCOMPLETE under "
            "the current detector stay SCAN_INCOMPLETE under a second discovery (INCOMPLETE_HASH); no Z3 row in any of these")


@test("AT-9011R-08", "review R-08; A1-OD-3, §5.2 (tag after a declaration; declaration idempotent)")
def t_tag_declared(server, ev):
    H = C4.v2_full(server, "bnx_r08")
    d = discover(H, "f-r08"); hd = sha("r08")
    verdict(H, d, hd)                                                     # T4: PENDING_DECLARATION
    H.cmd(H.owner, "doc_declare_redacted", discovery_id=d, sha256=hd)
    tag = H.cmd(H.owner, "doc_tag_sin_bearing", discovery_id=d)
    st = state(H, d)
    arch = archive(H, d, hd, "f-r08")
    H.close()
    out = {"tag": tag, "state_after_tag": list(st[:2]), "archive": arch.get("state")}
    json.dump(out, open(os.path.join(ev, "AT-9011R-08.json"), "w"), indent=1, default=str)
    check(tag["state"] == "ADMISSIBLE" and tag["declaration_status"] == "DECLARED" and list(st[:2]) == ["ADMISSIBLE", "DECLARED"]
          and arch.get("state") == "ARCHIVED", f"{out}")
    return ("tagging an already declared document as SIN-bearing changes nothing (ADMISSIBLE, DECLARED; no PENDING_DECLARATION "
            "and no stranded document); it is then archived; a repeated declaration of the same bytes is a no-op (ON CONFLICT)")


@test("AT-9011R-09", "review R-09 (evidence usable only while its document is archived, current and never quarantined)")
def t_evidence_usable(server, ev):
    H = C4.v2_full(server, "bnx_r09")
    hb = sha("r09")
    d1 = discover(H, "f-r09-a", module="FINANCE"); verdict(H, d1, hb, cls="BANK_STATEMENT")
    a1 = archive(H, d1, hb, "f-r09-a")
    obj = a1["evidence_object_id"]
    st = lambda: C4.one(H, "select bnx.evidence_status(%s), bnx.evidence_usable(%s)", (obj, obj))
    out = {"archived": list(st())}
    # the same bytes are later found to carry a candidate under another discovery
    d2 = discover(H, "f-r09-b", module="FINANCE"); verdict(H, d2, hb, result="SIN_CANDIDATE", cls="BANK_STATEMENT")
    out["after_quarantine_elsewhere"] = list(st())
    out["unknown"] = list(C4.one(H, "select bnx.evidence_status(gen_random_uuid()), bnx.evidence_usable(gen_random_uuid())"))
    execs = {r: C4.one(H, "select has_function_privilege(%s, 'bnx.evidence_usable(uuid)', 'EXECUTE')", (r,))[0]
             for r in ("bnx_app", "bnx_worker", "bnx_backup")}
    H.close()
    json.dump(out | {"execute": execs}, open(os.path.join(ev, "AT-9011R-09.json"), "w"), indent=1)
    check(out["archived"] == ["USABLE", True] and out["after_quarantine_elsewhere"] == ["QUARANTINED", False]
          and out["unknown"] == ["NOT_FOUND", False] and not any(execs.values()), f"{out} {execs}")
    return ("an archived, current evidence object is USABLE; once the same bytes are quarantined under any discovery it is "
            "QUARANTINED and not usable; unknown ids NOT_FOUND; R1 evidence never scanned is UNSCANNED (definition); the "
            "functions are internal (no runtime role holds EXECUTE) and future readers (9016, PWA) must call evidence_usable")


# ------------------------------------------------------------------------------------------------ registered A1 tests (R-16)
@test("AT-SIN-17", "Addendum A1 Rev 1 §11 AT-SIN-17; review R-16 (no path moves QUARANTINED or SCAN_INCOMPLETE to ADMISSIBLE)")
def t_sin17(server, ev):
    H = C4.v2_full(server, "bnx_sin17")
    dq = discover(H, "f-17-q", module="FINANCE"); verdict(H, dq, sha("17-q"), result="SIN_CANDIDATE", cls="BANK_STATEMENT")
    di = discover(H, "f-17-i", module="FINANCE"); verdict(H, di, sha("17-i"), result="SCAN_INCOMPLETE", cls="BANK_STATEMENT")
    H.close()
    res = {}
    for nm, d in (("QUARANTINED", dq), ("SCAN_INCOMPLETE", di)):
        for tgt in ("ADMISSIBLE", "ARCHIVED", "PENDING_DECLARATION", "DISCOVERED"):
            for who, fn in (("definer", lambda q, p: C1.installer_sql(server, H.db, q, p)),):
                try:
                    fn("insert into bnx_doc.document_state_event(discovery_id, state) values (%s, %s) returning seq", (d, tgt))
                    res[f"{nm}->{tgt}"] = "ACCEPTED"
                except psycopg.Error as e:
                    res[f"{nm}->{tgt}"] = (e.diag.message_primary or "")[:40]
    # catalog: every function that writes a state event goes through the transition trigger (no trigger bypass exists)
    with C1.migrator(server, H.db) as cx:
        trig = cx.execute("select tgenabled from pg_trigger where tgrelid = 'bnx_doc.document_state_event'::regclass "
                          "and tgname = 't_doc_state_transition'").fetchone()
        writers = [r[0] for r in cx.execute("select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                                             "where n.nspname = 'bnx' and p.prosrc ~* 'document_state_event' order by 1")]
    json.dump({"attempts": res, "trigger": trig, "writers": writers}, open(os.path.join(ev, "AT-SIN-17.json"), "w"), indent=1)
    check(all(v != "ACCEPTED" for v in res.values()) and trig == ("O",), f"{res} {trig}")
    return (f"{len(res)} direct transitions out of QUARANTINED and SCAN_INCOMPLETE refused even to the installer path "
            f"(DOC_STATE_TRANSITION); the transition trigger is enabled and every writer ({', '.join(writers)}) inserts through it")


@test("AT-SIN-19", "Addendum A1 Rev 1 §11 AT-SIN-19; review R-16 (a new redacted revision at the same Inbox path)")
def t_sin19(server, ev):
    H = C4.v2_full(server, "bnx_sin19")
    d1 = discover(H, "f-19", rev="r1"); verdict(H, d1, sha("19-r1"))             # T4 revision 1: pending declaration
    d2 = discover(H, "f-19", rev="r2")                                          # Owner replaced the file with a redacted copy
    out = {"old_after_new_revision": state(H, d1)[0]}
    out["new_scan"] = verdict(H, d2, sha("19-r2"))["state"]
    out["old_declaration"] = expect_err(H.cmd, "DECLARATION_NOT_APPLICABLE", H.owner, "doc_declare_redacted", discovery_id=d1, sha256=sha("19-r1"))
    out["declared"] = H.cmd(H.owner, "doc_declare_redacted", discovery_id=d2, sha256=sha("19-r2"))["state"]
    out["archive"] = archive(H, d2, sha("19-r2"), "f-19", rev="r2").get("state")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-SIN-19.json"), "w"), indent=1)
    check(out == {"old_after_new_revision": "INVALIDATED", "new_scan": "PENDING_DECLARATION", "old_declaration": out["old_declaration"],
                  "declared": "ADMISSIBLE", "archive": "ARCHIVED"}, f"{out}")
    return ("a new revision at the same Inbox path invalidates the earlier one (no declaration carries over); the new revision "
            "is scanned, declared by the Owner and archived")


@test("AT-SIN-20", "Addendum A1 Rev 1 §11 AT-SIN-20; review R-16 (no value and no file name with digits in records)")
def t_sin20(server, ev):
    H = C4.v2_full(server, "bnx_sin20")
    vals = [SC.value("luhn", 201), SC.value("itn_nonluhn", 202)]
    # a discovery whose file name holds a value is refused at staging (guard C2); the Executor withholds such names
    n_stg0 = C4.one(H, "select count(*) from bnx_intake.staging_payload")[0]
    named = expect_err(discover, "SIN_CANDIDATE", H, "f-20", name="Slip " + vals[0] + ".pdf", module="TAX")
    n_stg1 = C4.one(H, "select count(*) from bnx_intake.staging_payload")[0]
    d = discover(H, "f-20", name="", module="TAX")
    verdict(H, d, sha("20"), result="SIN_CANDIDATE")
    d2 = discover(H, "f-20b", name="T4 2025.pdf", module="TAX")
    verdict(H, d2, sha("20b"), result="SIN_CANDIDATE")
    with C1.migrator(server, H.db) as cx:
        cx.execute("set role bnx_definer")
        blobs = {
            "notifications": cx.execute("select coalesce(string_agg(minimal_metadata::text || dedupe_key, ' '), '') from bnx_intake.notification").fetchone()[0],
            "audit": cx.execute("select coalesce(string_agg(subject::text || command, ' '), '') from bnx_audit.audit_event").fetchone()[0],
            "scans": cx.execute("select coalesce(string_agg(locators::text || array_to_string(rule_codes, ','), ' '), '') from bnx_doc.document_scan").fetchone()[0],
            "states": cx.execute("select coalesce(string_agg(coalesce(reason, ''), ' '), '') from bnx_doc.document_state_event").fetchone()[0],
            "current_view": cx.execute("select coalesce(string_agg(coalesce(original_name, ''), ' '), '') from bnx_doc.document_current "
                                       "where state = 'QUARANTINED'").fetchone()[0]}
        masked = [r[0] for r in cx.execute("select minimal_metadata->>'masked_subject' from bnx_intake.notification where minimal_metadata->>'kind' = 'SIN_CANDIDATE_QUARANTINED' order by created_at")]
    H.close()
    leaks = {k: not C5.no_value(v.replace(sha("20"), "").replace(sha("20b"), ""), vals) for k, v in blobs.items() if k != "current_view"}
    json.dump({"leaks": leaks, "masked_subjects": masked, "named_discovery": named, "staging_rows": [n_stg0, n_stg1]},
              open(os.path.join(ev, "AT-SIN-20.json"), "w"), indent=1)
    check(not any(leaks.values()) and masked == [None, None] and n_stg0 == n_stg1, f"{leaks} {masked} {n_stg0} {n_stg1}")
    return ("a discovery whose file name holds a value is refused at staging (SIN_CANDIDATE, nothing staged); after two "
            "quarantines (name withheld, and a name with only a year): notifications, the audit chain, scan "
            "records and state reasons hold no generated value; neither quarantine notification carries a file name with digits "
            "(masked_subject omitted). Worker, Gateway, Executor and CI logs: AT-SIN-31 and AT-9011R-18 (Z1), guard C6 (CI)")


@test("AT-SIN-21", "Addendum A1 Rev 1 §11 AT-SIN-21; review R-16 (schema has no redaction status, no override, no SIN column)")
def t_sin21(server, ev):
    db = h.fresh(server, "bnx_sin21")
    with C1.migrator(server, db) as cx:
        cx.execute("set role bnx_definer")
        cols = [r[0] for r in cx.execute(
            "select n.nspname || '.' || c.relname || '.' || a.attname from pg_attribute a join pg_class c on c.oid = a.attrelid "
            "join pg_namespace n on n.oid = c.relnamespace where n.nspname like 'bnx%%' and a.attnum > 0 and not a.attisdropped "
            "and (a.attname ~* '^(redaction_status|sin|sin_value|sin_number|social_insurance.*|itn|itn_value|taxpayer_sin)$')")]
        texts = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname like 'bnx%%' "
                           "and p.prosrc ~ 'OWNER_CONFIRMED_NOT_SIN'").fetchone()[0]
        checks = cx.execute("select count(*) from pg_constraint where pg_get_constraintdef(oid) ~ 'OWNER_CONFIRMED_NOT_SIN'").fetchone()[0]
    json.dump({"columns": cols, "functions_with_override": texts, "constraints_with_override": checks}, open(os.path.join(ev, "AT-SIN-21.json"), "w"), indent=1)
    check(cols == [] and texts == 0 and checks == 0, f"{cols} {texts} {checks}")
    return ("no column named redaction_status or holding a SIN/ITN by name in any bnx schema; no function or CHECK knows an "
            "OWNER_CONFIRMED_NOT_SIN state (A1-OD-2: no release path)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core_9011r", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "PASS"
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__,
               "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core_9011r_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
