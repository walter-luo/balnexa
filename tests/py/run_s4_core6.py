#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 V1.2 increment 6 tests: 9011c Executor document validator (zone Z1) and Z3 registration at admission (Addendum A1 Rev 1
§3, §5, §7 DOC-SIN-01/02/03/07/12; tests AT-SIN-01..07, 13, 29, 30, 31). Conventions as run_g0.py.

Fixtures are synthetic and built in memory at test time (tests/py/doc_fixtures.py); generated values are never written to
evidence: evidence holds fixture ids, verdicts, rule codes, locator kinds and counts only.
Usage: run_s4_core6.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core5 as C5
import sin_corpus as SC
import doc_fixtures as F

sys.path.insert(0, os.path.join(h.ROOT, "apps", "executor"))
from bnx_exec import sin_detector as S  # noqa: E402
from bnx_exec import doc_validator as V  # noqa: E402

RESULTS, TESTS = [], []
check = C1.check
HERE = os.path.dirname(os.path.abspath(__file__))


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def verdict(data, name=None, **kw):
    r = V.validate(data, name, **kw)
    return {"scan_result": r["scan_result"], "rules": r["rule_codes"], "kinds": sorted({l.get("kind", "") for l in r["locators"]}),
            "revisions": sorted({l["revision"] for l in r["locators"] if "revision" in l}),
            "max_depth": max([l.get("path_depth", 0) for l in r["locators"]] or [0]), "_locators": r["locators"]}


def public(v):
    return {k: x for k, x in v.items() if not k.startswith("_")}


def leak_free(obj, values):
    return C5.no_value(json.dumps(obj, default=str), [x.replace(" ", "").replace("-", "") for x in values])


# ------------------------------------------------------------------------------------------------ end-to-end helpers
def identity(fid, data, rev="r1"):
    return {"source_kind": "DRIVE_INBOX", "source_file_id": fid, "head_revision_id": rev, "md5": hashlib.md5(data).hexdigest(),
            "size_bytes": len(data), "source_mtime": "2026-03-01T10:00:00Z"}


def e2e_scan(H, fid, data, name, cls, module="TAX", uncertain=False, sin_bearing=None):
    ident = identity(fid, data)
    did = C5.promote(H, "DOC_DISCOVER", "doc_discovered", V.discovered_payload(ident, name, module, "2025"))["discovery_id"]
    vp = V.validated_payload(did, data, name, doc_class=cls, class_uncertain=uncertain,
                             sin_bearing=(cls == "T4") if sin_bearing is None else sin_bearing)
    res = C5.promote(H, "DOC_PROCESS", "doc_validated", vp)
    return did, ident, res, vp


def e2e_archive(H, did, refetched, ident, name):
    return C5.promote(H, "DOC_PROCESS", "doc_archived", V.archived_payload(did, refetched, ident, "processed-" + ident["source_file_id"], name))


def z3(H, did):
    return C4.one(H, """select encode(o.sha256, 'hex'), o.storage_kind, o.integrity_state, o.archive_state, o.r2_key is null, o.size_bytes,
                              f.acquired_via, f.mime, f.storage_state, f.original_name, e.source_fidelity, e.declaration_id is not null,
                              e.archived_file_id
                         from bnx_doc.document_evidence e join bnx.evidence_object o on o.id = e.evidence_object_id
                         join bnx.evidence_file f on f.id = e.evidence_file_id where e.discovery_id = %s""", (did,))


def z3_count(H):
    return C4.one(H, "select (select count(*) from bnx.evidence_object), (select count(*) from bnx.evidence_file), "
                     "(select count(*) from bnx_doc.document_evidence)")


# ------------------------------------------------------------------------------------------------ AT-SIN-01..04 PDF
@test("AT-SIN-01-04", "Addendum A1 §7 AT-SIN-01..04, Rev 1 §5, DOC-SIN-01/02/03 (PDF: visible, under a box, earlier revision, "
                      "Info, XMP, annotation, form field, hidden layer, embedded file)")
def t_pdf(server, ev):
    val, nl = F.v("luhn", 11), F.v("nonluhn", 12)
    cases = {
        "01_visible": (F.pdf_visible(val), "SIN_CANDIDATE", "text_layer"),
        "02_black_box_text_layer": (F.pdf_black_box(nl), "SIN_CANDIDATE", "text_layer"),
        "03_earlier_revision": (F.pdf_incremental(val), "SIN_CANDIDATE", "text_layer"),
        "04_info": (F.pdf_info(val), "SIN_CANDIDATE", "metadata_info"),
        "04_xmp": (F.pdf_xmp(val), "SIN_CANDIDATE", "metadata_xmp"),
        "04_annotation": (F.pdf_annotation(val), "SIN_CANDIDATE", "annotation"),
        "04_form_field": (F.pdf_form(val), "SIN_CANDIDATE", "form_field"),
        "04_hidden_ocg": (F.pdf_ocg(val), "SIN_CANDIDATE", "text_layer"),
        "04_embedded_file": (F.pdf_embedded(val), "SIN_CANDIDATE", "embedded_file"),
        "clean": (F.pdf_clean(), "PASSED", None),
        "redacted_t4": (F.pdf_redacted_t4(), "PASSED", None),
    }
    out, bad = {}, []
    for cid, (data, want, kind) in cases.items():
        v = verdict(data, "synthetic.pdf")
        out[cid] = public(v)
        if v["scan_result"] != want or (kind and kind not in v["kinds"]):
            bad.append(cid)
    # the earlier revision is where the value is: the last revision alone is clean
    rev_last = [l for l in verdict(F.pdf_incremental(val))["_locators"] if l.get("kind") == "text_layer" and l.get("revision") == 1]
    # a field named as a SIN field is labelled: a Mod-10-invalid value there is a candidate (R_LABEL)
    lab = verdict(F.simple_pdf(F.text_ops(["Synthetic form"]),
                               extra_objs={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (sin) /Rect [1 1 2 2] /P 3 0 R /V " + F.hexstr(nl) + b" >>"},
                               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"))
    # graphics operands are not numbers in text: three-digit coordinates in a clean page stay clean
    coords = verdict(F.simple_pdf(F.text_ops(["Synthetic"]) + F.nums(100, 600, 300, 620) + b" re S " + F.nums(123, 456, 789, 0, 0) + b" cm\n",
                                  extra_objs={6: b"<< /Type /Annot /Subtype /Square /Rect [" + F.nums(100, 100, 120, 120) + b"] >>"}, page_extra=b"/Annots [6 0 R]"))
    # quarantine end to end: nothing archived, nothing in Z3, no value stored anywhere
    H = C4.v2_full(server, "bnx_s4c6pdf")
    did, ident, res, vp = e2e_scan(H, "f-pdf-1", F.pdf_visible(val), "Synthetic slip.pdf", "T4")
    arch = e2e_archive(H, did, F.pdf_visible(val), ident, "Synthetic slip.pdf")
    dump = C1.installer_sql(server, H.db, "select string_agg(t::text, ' ') from (select payload::text t from bnx_intake.staging_payload "
                                          "union all select row(s.*)::text from bnx_doc.document_scan s union all select minimal_metadata::text "
                                          "from bnx_intake.notification union all select subject::text from bnx.audit_event) x")[0][0] or ""
    counts = z3_count(H)
    H.close()
    out |= {"last_revision_hits": len(rev_last), "labelled_field": public(lab), "coordinates": public(coords),
            "e2e": {"state": res["state"], "archive": arch.get("reason"), "z3_rows": list(counts)}}
    json.dump(out, open(os.path.join(ev, "AT-SIN-01-04.json"), "w"), indent=1)
    check(not bad, f"unexpected verdicts {bad}: {json.dumps({k: out[k] for k in bad})}")
    check(out["03_earlier_revision"]["revisions"] == [0] and not rev_last, f"revision locators {out['03_earlier_revision']}")
    check(lab["rules"] == ["R_LABEL"] and coords["scan_result"] == "PASSED", f"{public(lab)} {public(coords)}")
    check(res["state"] == "QUARANTINED" and arch.get("reason") == "NOT_ADMISSIBLE" and list(counts) == [0, 0, 0], f"{out['e2e']}")
    check(C5.no_value(dump, [val.replace(" ", "")]) and leak_free(vp, [val]), "a value reached the database")
    return (f"{len(cases)} synthetic PDFs: visible value, value under a black box (text layer), value only in revision 0 of an "
            f"incremental update (last revision clean), Info, XMP, annotation, form field, hidden optional-content layer and "
            f"embedded file -> SIN_CANDIDATE, each through its own extraction path; clean and properly redacted -> PASSED; a field "
            f"named 'sin' labels its value; graphics coordinates are not read as numbers. End to end: QUARANTINED, archive refused, "
            f"Z3 rows {list(counts)}, no value in staging, scans, notifications or audit")


# ------------------------------------------------------------------------------------------------ AT-SIN-05, 07 scans and admission
@test("AT-SIN-05,07", "Addendum A1 §7 AT-SIN-05/07, Rev 1 A1-OD-3, DOC-SIN-05/06/12 (OCR scans; Owner-redacted copy admitted to Z3)")
def t_scans(server, ev):
    val = F.v("luhn", 21)
    vis, _ = F.image(["Synthetic T4 2025", "Social insurance number " + val, "Box 14 52,000.00"])
    red, _ = F.image(["Synthetic T4 2025", "Social insurance number " + val, "Box 14 52,000.00"], redact=(1, 24))
    jv, (w, hh) = F.image(["Synthetic T4 2025", "SIN " + val], fmt="JPEG")
    jr, _ = F.image(["Synthetic T4 2025", "SIN " + val], redact=(1, 4), fmt="JPEG")
    out = {"png_visible": public(verdict(vis)), "png_redacted": public(verdict(red)),
           "pdf_scan_visible": public(verdict(F.pdf_image_only(jv, w, hh))), "pdf_scan_redacted": public(verdict(F.pdf_image_only(jr, w, hh)))}
    H = C4.v2_full(server, "bnx_s4c6scan")
    d1, _, r1, _ = e2e_scan(H, "f-scan-1", vis, "Synthetic T4 scan.png", "T4")
    d2, i2, r2, _ = e2e_scan(H, "f-scan-2", red, "Synthetic T4 scan redacted.png", "T4")
    before = e2e_archive(H, d2, red, i2, "x.png").get("reason")
    dec = H.cmd(H.owner, "doc_declare_redacted", discovery_id=d2, sha256=hashlib.sha256(red).hexdigest())
    label = [i["label"] for i in H.q(H.owner, "doc_redaction_queue")["items"] if i["discovery_id"] == d2]
    a2 = e2e_archive(H, d2, red, i2, "Synthetic T4 scan redacted.png")
    view = C4.one(H, "select state, declaration_status, scan_result, sin_detector_version, source_fidelity, module, period_key "
                     "from bnx_doc.document_current where discovery_id = %s", (d2,))
    reg = z3(H, d2)
    # the redacted T4 PDF (text layer) follows the same path
    pdf = F.pdf_redacted_t4()
    d3, i3, r3, _ = e2e_scan(H, "f-t4pdf-1", pdf, "Synthetic T4 redacted.pdf", "T4")
    H.cmd(H.owner, "doc_declare_redacted", discovery_id=d3, sha256=hashlib.sha256(pdf).hexdigest())
    a3 = e2e_archive(H, d3, pdf, i3, "Synthetic T4 redacted.pdf")
    reg3 = z3(H, d3)
    # write-once: Z3 rows refuse change even for the definer
    blocked = {}
    for name, q in (("evidence_object", "update bnx.evidence_object set size_bytes = size_bytes + 1 where sha256 = decode(%s, 'hex')"),
                    ("document_evidence", "update bnx_doc.document_evidence set source_fidelity = 'AS_RECEIVED_FROM_OWNER' where discovery_id = %s")):
        try:
            C1.installer_sql(server, H.db, q + " returning 1", (reg[0] if name == "evidence_object" else d2,))
            blocked[name] = "accepted"
        except psycopg.Error as e:
            blocked[name] = e.diag.message_primary.split(":")[0]
    verify = C4.one(H, "select bnx.audit_verify()")[0]
    H.close()
    out |= {"e2e_visible": r1["state"], "e2e_redacted": r2["state"], "archive_before_declaration": before, "label": label,
            "archived": a2["state"], "view": list(view), "z3": list(reg[1:]), "z3_sha_matches": reg[0] == hashlib.sha256(red).hexdigest(),
            "pdf": [r3["state"], a3["state"], list(reg3[1:])], "write_once": blocked, "audit_verify": verify}
    json.dump(out, open(os.path.join(ev, "AT-SIN-05_07.json"), "w"), indent=1, default=str)
    check(out["png_visible"]["rules"] == ["R_OCR9"] and out["pdf_scan_visible"]["scan_result"] == "SIN_CANDIDATE", f"{out}")
    check(out["png_redacted"]["scan_result"] == "PASSED" and out["pdf_scan_redacted"]["scan_result"] == "PASSED", f"{out}")
    check(r1["state"] == "QUARANTINED" and r2["state"] == "PENDING_DECLARATION" and before == "NOT_ADMISSIBLE", f"{out}")
    check(dec["declaration_status"] == "DECLARED" and label == ["Owner-redacted copy — not the issuer's original"], f"{dec} {label}")
    check(a2["state"] == "ARCHIVED" and list(view) == ["ARCHIVED", "DECLARED", "PASSED", S.VERSION, "OWNER_REDACTED_SOURCE", "TAX", "2025"], f"{out}")
    check(out["z3_sha_matches"] and list(reg[1:6]) == ["drive_processed", "verified", "single_copy", True, len(red)], f"{reg}")
    check(list(reg[6:12]) == ["drive_inbox", "image/png", "archived", "Synthetic T4 scan redacted.png", "OWNER_REDACTED_SOURCE", True], f"{reg}")
    check(r3["state"] == "PENDING_DECLARATION" and a3["state"] == "ARCHIVED" and reg3[7] == "application/pdf", f"{out['pdf']}")
    check(all(v in ("WRITE_ONCE", "APPEND_ONLY") for v in blocked.values()) and verify == 0, f"{blocked} {verify}")
    return ("OCR: visible value in a PNG scan and in an image-only PDF -> SIN_CANDIDATE (R_OCR9); the same scans with a black box "
            "over the number -> PASSED. End to end: the visible scan is QUARANTINED; the redacted T4 waits in PENDING_DECLARATION "
            "(archive refused), the Owner declares it, the queue labels it 'Owner-redacted copy', and admission registers it in Z3: "
            "evidence_object (SHA-256 of the re-fetched bytes, drive_processed, verified, single_copy), evidence_file (drive_inbox, "
            "image/png, archived) and document_evidence (OWNER_REDACTED_SOURCE with the declaration); declaration_status, scan_result "
            f"and sin_detector_version are separate fields; the redacted T4 PDF follows the same path; Z3 rows are write-once; "
            f"audit_verify {verify}")


# ------------------------------------------------------------------------------------------------ AT-SIN-06 XLSX, EML, text
@test("AT-SIN-06", "Addendum A1 §7 AT-SIN-06, DOC-SIN-02 (XLSX very hidden sheet, comment, property; EML nested attachment; CSV, OFX)")
def t_office(server, ev):
    val, nl = F.v("luhn", 41), F.v("nonluhn", 42)
    cases = {
        "xlsx_very_hidden_sheet": (F.xlsx(very_hidden=val), None, "SIN_CANDIDATE", "cell_row"),
        "xlsx_comment": (F.xlsx(comment=val), None, "SIN_CANDIDATE", "comment"),
        "xlsx_property": (F.xlsx(prop=val), None, "SIN_CANDIDATE", "property"),
        "xlsx_labelled_column": (F.xlsx(clean_rows=[["Name", "SIN"], ["Synthetic", nl.replace(" ", "")]]), None, "SIN_CANDIDATE", "labelled_column"),
        "xlsx_clean_numbers": (F.xlsx(clean_rows=[["a", "b", "c"], [100, 600, 300], [123, 456, 789]]), None, "PASSED", None),
        "eml_nested_attachment": (F.eml_nested(val), None, "SIN_CANDIDATE", "eml_attachment"),
        "eml_clean": (F.eml(), None, "PASSED", None),
        "csv": (("ref,amount\n" + val + ",1\n").encode(), "statement.csv", "SIN_CANDIDATE", "text"),
        "ofx_clean": (F.ofx(), "statement.ofx", "PASSED", None),
        "ofx_value": (F.ofx(val.replace(" ", "")), "statement.ofx", "SIN_CANDIDATE", "text"),
    }
    out, bad = {}, []
    for cid, (data, name, want, kind) in cases.items():
        v = verdict(data, name)
        out[cid] = public(v)
        if v["scan_result"] != want or (kind and kind not in v["kinds"]):
            bad.append(cid)
    json.dump(out, open(os.path.join(ev, "AT-SIN-06.json"), "w"), indent=1)
    check(not bad, f"unexpected verdicts {bad}: {json.dumps({k: out[k] for k in bad})}")
    check(out["eml_nested_attachment"]["max_depth"] >= 1, f"{out['eml_nested_attachment']}")
    return (f"{len(cases)} synthetic files: XLSX value in a very hidden sheet, a cell comment, a document property and under a "
            f"'SIN' column header (Mod-10-invalid) -> SIN_CANDIDATE; three-digit numbers in adjacent cells stay clean; EML value "
            f"in an attachment of an attached message -> SIN_CANDIDATE; CSV and OFX scanned as text")


# ------------------------------------------------------------------------------------------------ AT-SIN-13 OCR rules with a real engine
@test("AT-SIN-13", "Addendum A1 Rev 1 AT-SIN-13, §3.5 (OCR: any nine digits; 8/10-digit runs with a weak glyph); D-A1-4 t_ocr")
def t_ocr(server, ev):
    if not V.ocr_available():
        return "SKIP:no OCR engine (tesseract) on this host"
    out, bad = {}, []
    for seed in range(3):
        n9 = SC.value("nonluhn", 130 + seed)
        out[f"nonluhn9_{seed}"] = verdict(F.image(["Reference " + n9[:3] + " " + n9[3:6] + " " + n9[6:]])[0])["rules"]
        for n, letter in ((8, "S"), (10, "B")):
            d = "4" + SC._body(140 + 10 * seed + n, n - 1)
            out[f"run{n}_{letter}_{seed}"] = verdict(F.image(["Reference " + d[:4] + letter + d[5:]])[0])["rules"]
        d8 = "4" + SC._body(170 + seed, 7)
        out[f"run8_clean_{seed}"] = verdict(F.image(["Reference " + d8])[0])["rules"]
    for k, v in out.items():
        want = ["R_OCR9"] if k.startswith("nonluhn9") else ([] if "clean" in k else ["R_OCR_RUN"])
        if v != want:
            bad.append(k)
    # D-A1-4: word confidences of clean synthetic digit lines at four sizes (t_ocr 0.90 sits below every clean reading)
    confs = {}
    for size in (18, 24, 32, 44):
        cs = []
        for seed in range(6):
            v9 = SC.value("luhn", 150 + seed)
            r = subprocess.run(V.OCR_CMD + ["stdin", "stdout", "--psm", "6", "tsv"], input=F.image(["Amount " + v9[:3] + " " + v9[3:6] + " " + v9[6:]], size=size)[0],
                               capture_output=True)
            cs += [float(f.split("\t")[10]) / 100 for f in r.stdout.decode().splitlines()[1:]
                   if f.split("\t")[0] == "5" and any(c.isdigit() for c in f.split("\t")[11])]
        confs[size] = round(min(cs), 3)
    json.dump({"rules": out, "min_clean_digit_confidence": confs, "t_ocr": S.SPEC["ocr"]["t_ocr"]}, open(os.path.join(ev, "AT-SIN-13.json"), "w"), indent=1)
    check(not bad, f"unexpected OCR verdicts {bad}: {out}")
    check(all(c > S.SPEC["ocr"]["t_ocr"] for c in confs.values()), f"clean digits below t_ocr: {confs}")
    return (f"tesseract on rendered synthetic lines: Mod-10-invalid nine digits -> R_OCR9; 8- and 10-digit runs containing a "
            f"confusable glyph (S, B) -> R_OCR_RUN; a clean 8-digit run -> no hit; lowest clean digit confidence per size {confs} "
            f"is above t_ocr {S.SPEC['ocr']['t_ocr']}")


# ------------------------------------------------------------------------------------------------ AT-SIN-29 re-fetch
@test("AT-SIN-29", "Addendum A1 Rev 1 AT-SIN-29, DOC-SIN-12 (bytes changed between scan and archive: nothing written)")
def t_refetch(server, ev):
    H = C4.v2_full(server, "bnx_s4c6refetch")
    a, b = F.pdf_clean(), F.pdf_clean() + b"%changed\n"
    did, ident, res, _ = e2e_scan(H, "f-bank-29", a, "Synthetic statement.pdf", "BANK_STATEMENT", module="FINANCE")
    c0 = z3_count(H)
    changed = e2e_archive(H, did, b, ident, "Synthetic statement.pdf")
    c1 = z3_count(H)
    st1 = C4.one(H, "select state from bnx_doc.document_current where discovery_id = %s", (did,))[0]
    vp = V.validated_payload(did, a, doc_class="BANK_STATEMENT", class_uncertain=False)
    again = C5.promote(H, "DOC_PROCESS", "doc_validated", vp)["state"]
    ok = e2e_archive(H, did, a, ident, "Synthetic statement.pdf")
    reg = z3(H, did)
    # the same bytes arriving by mail share the evidence object (R1 unique SHA-256), with their own evidence_file
    mid = {"source_kind": "MAIL_ATTACHMENT", "mail_message_id": "<synthetic-29@example.invalid>", "mime_part": "2", "size_bytes": len(a)}
    d2 = C5.promote(H, "DOC_DISCOVER", "doc_discovered", V.discovered_payload(mid, "Synthetic statement.pdf", "FINANCE", "2025"))["discovery_id"]
    C5.promote(H, "DOC_PROCESS", "doc_validated", V.validated_payload(d2, a, doc_class="BANK_STATEMENT", class_uncertain=False))
    m = C5.promote(H, "DOC_PROCESS", "doc_archived", V.archived_payload(d2, a, mid, "processed-mail-29", "Synthetic statement.pdf"))
    c2 = z3_count(H)
    same_obj = m.get("evidence_object_id") == ok.get("evidence_object_id")
    # a size that disagrees with the registered object is refused
    H.close()
    out = {"scan": res["state"], "changed": changed.get("reason"), "state_after": st1, "z3_before_after": [list(c0), list(c1)],
           "rescan": again, "archived": ok["state"], "z3": list(reg[1:]), "mail_copy": m.get("state"), "shared_object": same_obj, "z3_final": list(c2)}
    json.dump(out, open(os.path.join(ev, "AT-SIN-29.json"), "w"), indent=1, default=str)
    check(res["state"] == "ADMISSIBLE" and changed.get("reason") == "HASH_MISMATCH" and st1 == "DISCOVERED", f"{out}")
    check(list(c0) == [0, 0, 0] and list(c1) == [0, 0, 0], f"{out}")
    check(again == "ADMISSIBLE" and ok["state"] == "ARCHIVED" and reg[10] == "AS_RECEIVED_FROM_OWNER" and reg[11] is False, f"{out}")
    check(m.get("state") == "ARCHIVED" and same_obj and list(c2) == [1, 2, 2] and reg[6] == "drive_inbox", f"{out}")
    return ("bytes changed between scan and archive -> HASH_MISMATCH, back to DISCOVERED, no Z3 row; after a fresh scan the "
            "statement is admitted as AS_RECEIVED_FROM_OWNER without a declaration; the same bytes arriving by mail share the "
            "evidence object (one object, two evidence files, two links)")


# ------------------------------------------------------------------------------------------------ AT-SIN-30 fail closed
@test("AT-SIN-30", "Addendum A1 Rev 1 AT-SIN-30, §3.7, DOC-SIN-07 (fail closed: SCAN_INCOMPLETE or PENDING_DECLARATION, never ADMISSIBLE)")
def t_fail_closed(server, ev):
    val = F.v("luhn", 51)
    img, _ = F.image(["Synthetic slip", "Reference only"])
    saved = V.OCR_CMD
    try:
        V.OCR_CMD = [sys.executable, "-c", "import time; time.sleep(5)"]
        timeout = verdict(img, budget_seconds=1)
        V.OCR_CMD = ["/nonexistent/ocr-engine"]
        unavailable = verdict(img)
    finally:
        V.OCR_CMD = saved
    big = b"%PDF-1.7\n" + b"0" * (V.MAX_BYTES + 1)
    cases = {"encrypted_pdf": verdict(F.pdf_encrypted()), "damaged_image": verdict(F.damaged_png()), "ocr_timeout": timeout,
             "ocr_unavailable": unavailable, "javascript_pdf": verdict(F.pdf_javascript()), "zip_archive": verdict(F.zip_archive(val)),
             "macro_workbook": verdict(F.xlsx(macro=True)), "unknown_binary": verdict(b"\x00\x01binary", "x.bin"),
             "oversize": verdict(big), "truncated_pdf": verdict(F.pdf_clean()[:200])}
    want = {"encrypted_pdf": "R_ENCRYPTED", "damaged_image": "R_EXTRACTION_FAILED", "ocr_timeout": "R_OCR_TIMEOUT",
            "ocr_unavailable": "R_OCR_UNAVAILABLE", "javascript_pdf": "R_JS_REJECTED", "zip_archive": "R_ARCHIVE_REJECTED",
            "macro_workbook": "R_MACRO_REJECTED", "unknown_binary": "R_FORMAT_REJECTED", "oversize": "R_SIZE_LIMIT",
            "truncated_pdf": "R_EXTRACTION_FAILED"}
    bad = [k for k, v in cases.items() if v["scan_result"] != "SCAN_INCOMPLETE" or want[k] not in v["rules"]]
    H = C4.v2_full(server, "bnx_s4c6fail")
    enc = F.pdf_encrypted()
    d1, i1, r1, _ = e2e_scan(H, "f-enc-1", enc, "Synthetic.pdf", "BANK_STATEMENT", module="FINANCE")
    a1 = e2e_archive(H, d1, enc, i1, "Synthetic.pdf").get("reason")
    clean = F.pdf_clean()
    d2, i2, r2, _ = e2e_scan(H, "f-unc-1", clean, "Synthetic.pdf", "BANK_STATEMENT", module="FINANCE", uncertain=True)
    a2 = e2e_archive(H, d2, clean, i2, "Synthetic.pdf").get("reason")
    d3, i3, r3, _ = e2e_scan(H, "f-def-1", clean + b"\n", "Synthetic.pdf", None, module="FINANCE")   # validator default: class unknown
    counts = z3_count(H)
    H.close()
    out = {"verdicts": {k: public(v) for k, v in cases.items()}, "e2e": {"encrypted": [r1["state"], a1], "uncertain_class": [r2["state"], a2],
           "no_class": r3["state"], "z3": list(counts)}}
    json.dump(out, open(os.path.join(ev, "AT-SIN-30.json"), "w"), indent=1)
    check(not bad, f"not failing closed: {bad}: {json.dumps({k: public(cases[k]) for k in bad})}")
    check(r1["state"] == "SCAN_INCOMPLETE" and a1 == "NOT_ADMISSIBLE" and r2["state"] == "PENDING_DECLARATION" and a2 == "NOT_ADMISSIBLE", f"{out['e2e']}")
    check(r3["state"] == "PENDING_DECLARATION" and list(counts) == [0, 0, 0], f"{out['e2e']}")
    return ("encrypted PDF, damaged image, OCR timeout, OCR engine missing, JavaScript, ZIP archive, macro workbook, unknown "
            "binary, oversize and truncated PDF -> SCAN_INCOMPLETE with a rule code each; end to end the encrypted PDF stays "
            "SCAN_INCOMPLETE and an uncertain or missing class stays PENDING_DECLARATION, archive refused, no Z3 row")


# ------------------------------------------------------------------------------------------------ AT-SIN-31 nothing on disk, nothing in logs
WRITE_FLAGS = re.compile(r"O_(?:WRONLY|RDWR|CREAT|TRUNC|APPEND)")
ALLOWED = ("/dev/null", "/dev/tty", "/dev/pts/", "/dev/shm/")


@test("AT-SIN-31", "Addendum A1 Rev 1 AT-SIN-31, §4 zone Z1 (no file on disk, no content in logs after success, quarantine, "
                   "timeout or crash)")
def t_z1(server, ev):
    strace = shutil.which("strace")
    val = F.v("luhn", 31)
    out = {}
    for mode in ("success", "quarantine", "timeout", "crash"):
        work = tempfile.mkdtemp(prefix="bnx-z1-")
        dirs = {k: os.path.join(work, k) for k in ("tmp", "cwd", "home")}
        for d in dirs.values():
            os.makedirs(d)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TMPDIR": dirs["tmp"], "TMP": dirs["tmp"], "TEMP": dirs["tmp"],
               "HOME": dirs["home"], "PYTHONDONTWRITEBYTECODE": "1", "LANG": "C.UTF-8"}
        trace = os.path.join(work, "trace.txt")
        cmd = [sys.executable, "-B", "-I", os.path.join(HERE, "doc_z1_probe.py"), h.ROOT, mode]
        if strace:
            cmd = [strace, "-f", "-qq", "-e", "trace=open,openat,creat,mkdir,mkdirat,rename,renameat,renameat2,link,linkat,symlink,"
                   "symlinkat,unlink,unlinkat,truncate", "-o", trace] + cmd
        r = subprocess.run(cmd, cwd=dirs["cwd"], env=env, capture_output=True, text=True, timeout=120)
        writes, traced = [], 0
        if strace:
            for ln in open(trace, encoding="utf-8", errors="replace"):
                traced += 1
                m = re.search(r'(open|openat|creat|mkdir|mkdirat|rename\w*|link\w*|symlink\w*|unlink\w*|truncate)\((?:AT_FDCWD, |\d+, )?"([^"]*)"', ln)
                if not m or "ENOENT" in ln or "= -1" in ln:
                    continue
                call, path = m.group(1), m.group(2)
                if call.startswith("open") and not WRITE_FLAGS.search(ln):
                    continue
                if path.startswith(ALLOWED):
                    continue
                writes.append(call + " " + path)
        left = {k: os.listdir(d) for k, d in dirs.items()}
        logs_clean = C5.no_value(r.stdout + r.stderr, [val.replace(" ", "")])
        out[mode] = {"exit": r.returncode, "verdict": r.stdout.strip()[-200:] if mode != "crash" else None, "file_writes": writes[:20],
                     "left_in_dirs": left, "logs_clean": logs_clean, "traced_calls": traced,
                     "stderr_lines": len(r.stderr.splitlines())}
        shutil.rmtree(work, ignore_errors=True)
    json.dump({"strace": bool(strace), "runs": out}, open(os.path.join(ev, "AT-SIN-31.json"), "w"), indent=1)
    ok = {m: (not o["file_writes"] and not any(o["left_in_dirs"].values()) and o["logs_clean"]
              and (not strace or o["traced_calls"] > 50)) for m, o in out.items()}
    check(all(ok.values()), f"Z1 left traces: {json.dumps(out)}")
    check(out["success"]["exit"] == 0 and '"PASSED"' in out["success"]["verdict"] and '"SIN_CANDIDATE"' in out["quarantine"]["verdict"]
          and "R_OCR_TIMEOUT" in out["timeout"]["verdict"] and out["crash"]["exit"] != 0, f"{out}")
    how = "strace of every open/creat/mkdir/rename/link/unlink/truncate in the validator and its OCR child" if strace else \
          "directory checks only (strace not installed)"
    return (f"success, quarantine, OCR timeout and a SIGKILL during OCR: no file created or written ({how}), TMPDIR, HOME and "
            f"the working directory left empty, stdout and stderr hold no value")


# ------------------------------------------------------------------------------------------------ parity of the file path
@test("AT-SIN-11c", "Addendum A1 Rev 1 guard C1 (the validator's text path gives the reference detector's verdict for every corpus case)")
def t_parity(server, ev):
    cases = [c for c in SC.cases() if c["kind"] != "json" and c["origin"] == "native"]
    bad = []
    for c in cases:
        hits = S.scan(c["input"], "native")
        v = V.validate(c["input"].encode("utf-8"), "corpus.txt")
        want = ("SIN_CANDIDATE", sorted({x["rule"] for x in hits})) if hits else ("PASSED", [])
        if (v["scan_result"], v["rule_codes"]) != want or len(v["locators"]) != min(len(hits), 200):
            bad.append(c["id"])
    json.dump({"cases": len(cases), "mismatch": bad}, open(os.path.join(ev, "AT-SIN-11c.json"), "w"), indent=1)
    check(not bad, f"validator text path differs from the reference detector for {bad}")
    return f"{len(cases)} native corpus cases as UTF-8 text files: verdict, rule codes and hit count identical to sin_detector.scan"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core6", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "SKIP" if isinstance(msg, str) and msg.startswith("SKIP:") else "PASS"
            msg = msg[5:] if status == "SKIP" else msg
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    import pypdf, openpyxl, PIL
    ocr = subprocess.run(["tesseract", "--version"], capture_output=True, text=True).stdout.splitlines()[:1] if V.ocr_available() else []
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__,
               "pypdf": pypdf.__version__, "openpyxl": openpyxl.__version__, "pillow": PIL.__version__, "ocr": ocr,
               "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core6_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
