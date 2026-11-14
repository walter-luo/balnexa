#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 phase 2 tests: TST-5 mock providers and DOC-2 Executor document pipeline (migration 9025: DOC_PROCESS work order and
the due list). The Executor handlers run for real (apps/executor/bnx_exec/docjobs.py) against the mock Drive
(providers.MockDrive) in a temporary directory; the lease, due list and completion go through a shim that makes the Gateway's
database calls as bnx_worker (the HTTP route POST /exec/v1/due is covered by tests/blackbox/api.test.mjs BB-EXEC-03).
Synthetic data only; no cloud resource is contacted.
Usage: run_s4_core18.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, hashlib, json, os, shutil, sys, tempfile, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core15 as C15
import doc_fixtures as DF

sys.path.insert(0, os.path.join(h.ROOT, "apps", "executor"))
from bnx_exec import docjobs, gateway, providers, runner   # noqa: E402

RESULTS, TESTS = [], []
check = C1.check


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


class Shim(C15.WorkerShim):
    def due(self, kind, limit=50):
        return self.H.worker.call("wrk_exec_due", {"job_kind": kind, "limit": limit})["items"]


class Env:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="bnx-mock-")
        self.scratch = tempfile.mkdtemp(prefix="bnx-scratch-")
        self.cfg = runner.Config({"BNX_MOCK_ROOT": self.root, "BNX_SCRATCH": self.scratch})
        self.logs = []
        self.ctx = runner.Context(self.cfg, log=self.logs.append)
        self.drive = providers.MockDrive(self.root)

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)
        shutil.rmtree(self.scratch, ignore_errors=True)


def run(E, shim, kind, items):
    code, res = runner.run_items(E.ctx, shim, shim, kind, items)
    return code, res


def states(H):
    with H.definer() as cx:
        return {str(r[0]): r[1] for r in cx.execute("select discovery_id, state from bnx_doc.document_current")}


def csv_statement(seed):
    rows = ["Date,Description,Amount", f"2026-03-0{seed},Synthetic grocery,-42.10", f"2026-03-1{seed},Synthetic salary,2500.00"]
    return ("\n".join(rows) + "\n").encode()


@test("AT-DOC2-01", "DOC-2; Addendum A1 Rev 1 §4-§5, DOC-SIN-04/05/12; 9025 (Executor discover -> validate -> declare -> archive on the mock Drive)")
def t_pipeline(server, ev):
    E = Env()
    H = C4.v2_full(server, "bnx_c18doc")
    shim = Shim(H)
    try:
        clean = csv_statement(1)
        val = DF.v("luhn", 31)
        bad = DF.pdf_visible(val)
        f_clean = E.drive.put_inbox(clean, "Synthetic chequing statement March.csv")
        f_bad = E.drive.put_inbox(bad, "Synthetic slip.pdf")
        f_zip = E.drive.put_inbox(b"PK\x03\x04" + b"\x00" * 60, "Synthetic archive.zip")
        # 1. discover: one lease per file, identities only
        items = docjobs.plan_discover(E.ctx)
        c1, r1 = run(E, shim, "DOC_DISCOVER", items)
        p1 = C15.promote_all(H)
        again = run(E, shim, "DOC_DISCOVER", items)[1]            # repeats: staged, promoted as known (new = false)
        p1b = C15.promote_all(H)
        st1 = states(H)
        # 2. validate what is due
        due1 = shim.due("DOC_PROCESS")
        c2, r2 = run(E, shim, "DOC_PROCESS", due1)
        C15.promote_all(H)
        st2 = states(H)
        by_file = {}
        with H.definer() as cx:
            for did, fid in cx.execute("select id, source_file_id from bnx_doc.document_discovery"):
                by_file[fid] = str(did)
        d_clean, d_bad, d_zip = by_file[f_clean["source_file_id"]], by_file[f_bad["source_file_id"]], by_file[f_zip["source_file_id"]]
        # quarantined and incomplete documents are not due; a lease for them is refused (no lease row)
        due2 = shim.due("DOC_PROCESS")
        cq, rq = run(E, shim, "DOC_PROCESS", [d_bad])           # leased anyway: the work order says step NONE, nothing staged
        refused = rq[0].get("reason")
        # 3. the Owner declares the clean (class-uncertain) statement; it becomes due for ARCHIVE
        H.cmd(H.owner, "doc_declare_redacted", discovery_id=d_clean, sha256=hashlib.sha256(clean).hexdigest())
        due3 = shim.due("DOC_PROCESS")
        c3, r3 = run(E, shim, "DOC_PROCESS", due3)
        C15.promote_all(H)
        st3 = states(H)
        with H.definer() as cx:
            arch = cx.execute("select e.archived_file_id, encode(o.sha256, 'hex'), o.size_bytes from bnx_doc.document_evidence e "
                              "join bnx.evidence_object o on o.id = e.evidence_object_id where e.discovery_id = %s", (d_clean,)).fetchone()
            ev_status = cx.execute("select bnx.evidence_status(e.evidence_object_id) from bnx_doc.document_evidence e "
                                   "where e.discovery_id = %s", (d_clean,)).fetchone()[0]
        copy_ok = arch is not None and hashlib.sha256(E.drive.processed_bytes(arch[0])).hexdigest() == arch[1] == hashlib.sha256(clean).hexdigest()
        # 4. bytes changed behind the discovered identity: md5 check fails, nothing staged
        newer = csv_statement(2)
        f2 = E.drive.put_inbox(newer, "Synthetic chequing statement April.csv")
        run(E, shim, "DOC_DISCOVER", ["drive:" + f2["source_file_id"]]); C15.promote_all(H)
        with H.definer() as cx:
            d_new = str(cx.execute("select id from bnx_doc.document_discovery where source_file_id = %s", (f2["source_file_id"],)).fetchone()[0])
        blob = os.path.join(E.root, "drive", "blobs", f2["source_file_id"], f2["head_revision_id"])
        open(blob, "wb").write(b"tampered synthetic bytes\n")
        c4, r4 = run(E, shim, "DOC_PROCESS", [d_new])
        # 5. a new revision of an archived file: discovered as a new document; the archived one keeps its evidence
        rev2 = E.drive.put_inbox(csv_statement(3), "Synthetic chequing statement March.csv", file_id=f_clean["source_file_id"])
        run(E, shim, "DOC_DISCOVER", ["drive:" + f_clean["source_file_id"]]); C15.promote_all(H)
        st5 = states(H)
        with H.definer() as cx:
            n_disc = cx.execute("select count(*) from bnx_doc.document_discovery where source_file_id = %s", (f_clean["source_file_id"],)).fetchone()[0]
            dump = " ".join(str(r) for r in cx.execute("select payload::text from bnx_intake.staging_payload"))
            audit_ok = cx.execute("select bnx.audit_verify()").fetchone()[0]
        out = {"discover": [r.get("status") for r in r1], "repeat": [r.get("status") for r in again],
               "states_after_validate": {"clean": st2[d_clean], "pdf_with_value": st2[d_bad], "zip": st2[d_zip]},
               "due_after_validate": due2, "lease_quarantined": refused, "due_after_declare": due3, "archive": [r.get("status") for r in r3],
               "state_after_archive": st3[d_clean], "evidence_status": ev_status, "processed_copy_rehash": copy_ok,
               "tampered": [(r.get("status"), r.get("reason")) for r in r4], "new_revision_discoveries": n_disc,
               "archived_kept": st5[d_clean], "audit_verify": audit_ok}
        json.dump(out, open(os.path.join(ev, "AT-DOC2-01.json"), "w"), indent=1)
    finally:
        H.close(); E.close()
    check(c1 == 0 and all(s == "STAGED" for s in out["discover"]) and len(st1) == 3, f"discover {out['discover']} {st1}")
    check(out["states_after_validate"] == {"clean": "PENDING_DECLARATION", "pdf_with_value": "QUARANTINED", "zip": "SCAN_INCOMPLETE"}, f"{out}")
    check(due2 == [] and refused == "NOTHING_TO_DO" and due3 == [d_clean] and out["archive"] == ["STAGED"], f"{out}")
    check(out["state_after_archive"] == "ARCHIVED" and ev_status == "USABLE" and copy_ok, f"{out}")
    check(out["tampered"] == [("NOT_STAGED", "MD5_MISMATCH")] and n_disc == 2 and out["archived_kept"] == "ARCHIVED", f"{out}")
    check(val.replace(" ", "") not in dump.replace(" ", "") and audit_ok == 0, "a value reached staging or the chain broke")
    return (f"mock Drive, 3 files: discover stages identities only (repeats promoted as known); validate -> clean statement "
            f"PENDING_DECLARATION (no classifier), PDF with a value QUARANTINED, ZIP SCAN_INCOMPLETE; nothing else due and a run "
            f"for the quarantined one stages nothing ({refused}); after the Owner's declaration the statement is due for ARCHIVE: Processed "
            f"copy written, re-hashed, admitted -> ARCHIVED, evidence USABLE; bytes changed behind the identity -> MD5_MISMATCH, not "
            f"staged; a new revision is a new discovery and the archived one is kept; no value in staging; audit_verify 0")


@test("AT-TST5-01", "TST-5 (mock providers: Drive revisions and Processed copies, shared index in JSON/CSV/Markdown, mailbox exact fetch and move)")
def t_mocks(server, ev):    # noqa: ARG001 - no database needed
    E = Env()
    try:
        d = E.drive
        a = d.put_inbox(b"one", "a.csv")
        b = d.put_inbox(b"two", "a.csv", file_id=a["source_file_id"])
        head = d.head(a["source_file_id"])
        gone = None
        try:
            d.fetch(a["source_file_id"], "revUnknown")
        except providers.ProviderError as e:
            gone = str(e)
        aid = d.copy_to_processed(a["source_file_id"], b["head_revision_id"], b"two", "a.csv")
        aid2 = d.copy_to_processed(a["source_file_id"], b["head_revision_id"], b"two", "a.csv")
        ix = providers.MockIndex(E.root)
        rec = [{"File ID": "fileA", "Domain": "Banking_Tax", "Processed Date": "2026-03-01"}]
        reads = {}
        for fmt in ("json", "csv", "md"):
            ix.put("idx-" + fmt, rec, fmt=fmt)
            reads[fmt] = ix.read("idx-" + fmt)["records"][0]["File ID"]
        mb = providers.MockMailbox(E.root, "mbx-synthetic")
        raw = providers.eml_bytes("statements@bank.example", "owner@family.example", "Synthetic statement", "<s-1@bank.example>",
                                  attachments=[("statement.pdf", DF.pdf_clean(), "application/pdf")])
        pid = mb.put(raw)
        got = mb.fetch_exact("<s-1@bank.example>")
        parts = docjobs.mail_attachments(got["raw"])
        part_ok = docjobs.mail_part(got["raw"], "1")[0] == DF.pdf_clean()
        moved = mb.move(pid, "Banking/Synthetic") and mb.folder_of(pid) == "Banking/Synthetic"
        real = {}
        for name, fn in (("drive", providers.GoogleDrive), ("sheets", providers.GoogleSheetsIndex), ("gmail", providers.GmailMailbox),
                         ("graph", providers.GraphMailbox)):
            try:
                fn(); real[name] = "constructed"
            except providers.ProviderNotConfigured:
                real[name] = "NOT_CONFIGURED"
        ids = [a["source_file_id"], a["head_revision_id"], b["head_revision_id"], aid, pid]
    finally:
        E.close()
    check(head["head_revision_id"] == b["head_revision_id"] and gone == "REVISION_GONE" and aid == aid2, f"{head} {gone} {aid} {aid2}")
    check(reads == {"json": "fileA", "csv": "fileA", "md": "fileA"} and got["provider_message_id"] == pid and len(parts) == 1 and part_ok and moved, f"{reads} {parts}")
    check(set(real.values()) == {"NOT_CONFIGURED"} and not any(ch.isdigit() for i in ids for ch in i), f"{real} {ids}")
    return (f"Drive: revisions, head, REVISION_GONE, idempotent Processed copy; index read back from JSON, CSV and Markdown; "
            f"mailbox: exact fetch by Message-ID, attachment numbering, move; real providers refuse until M0-B ({real}); "
            f"generated ids carry no digit")


@test("AT-INT-01", "INT-2; SI §2-§7 (shared-index consumer through the Executor: contract, availability, masking, CRA notice, replay)")
def t_index(server, ev):
    E = Env()
    H = C4.index_household(server, "bnx_c18idx")
    shim = Shim(H)
    try:
        filed = E.drive.put_inbox(csv_statement(4), "Synthetic statement filed.csv")
        val = DF.v("luhn", 41, group="none")
        base = {k: "" for k in providers.INDEX_COLUMNS}
        recs = [
            {**base, "File ID": filed["source_file_id"], "Original Name": "Synthetic statement", "Domain": "Banking_Tax", "Type": "Statement",
             "Source": "statements@synthbank.example", "Document Date": "2026-03-31", "Processed Date": "2026-04-01"},
            {**base, "File ID": "fileNotInDrive", "Original Name": "Notice of assessment", "Domain": "Banking_Tax", "Type": "CRA Notice",
             "Tags": "CRA", "Source": "notify@cra-arc.gc.ca", "Document Date": "2026-04-02", "Processed Date": "2026-04-03"},
            {**base, "File ID": "fileWithNote", "Original Name": "Synthetic letter", "Domain": "Banking_Tax", "Type": "Letter",
             "Source": "statements@synthbank.example", "Notes": "reference " + val, "Processed Date": "2026-04-04"},
        ]
        providers.MockIndex(E.root).put("index-ref", recs, open_items=[{"key": "follow up synthetic letter"}], fmt="json")
        due = shim.due("INDEX_CONSUME")
        c1, r1 = run(E, shim, "INDEX_CONSUME", due)
        p1 = C15.promote_all(H)
        c2, r2 = run(E, shim, "INDEX_CONSUME", due)          # same index again: versions replayed, nothing new
        p2 = C15.promote_all(H)
        with H.definer() as cx:
            rows = {r[0]: r[1] for r in cx.execute("select record_key, availability from bnx_intake.external_index_record")}
            dump = " ".join(str(r) for r in cx.execute("select payload::text from bnx_intake.staging_payload"))
            dump += " ".join(str(r) for r in cx.execute("select columns::text from bnx_intake.external_index_record"))
            ack = dict(cx.execute("select status, count(*) from bnx_intake.index_record_ack group by 1").fetchall())
        notes = [n["kind"] for n in H.q(H.owner, "notifications")["notifications"]]
        res2 = list(p2.values())
        out = {"due": due, "staged": [x.get("status") for x in r1], "records": rows, "acks": ack, "notifications": notes,
               "second_run": res2}
        json.dump(out, open(os.path.join(ev, "AT-INT-01.json"), "w"), indent=1, default=str)
    finally:
        H.close(); E.close()
    check(due == ["idx-family-01"] and out["staged"] == ["STAGED"] and len(rows) == 3, f"{out}")
    check(rows.get(filed["source_file_id"]) == "FILED_VERIFIED" and rows.get("fileNotInDrive") != "FILED_VERIFIED", f"{rows}")
    check("CRA_CORRESPONDENCE" in notes and val not in dump, f"{notes} masked={val not in dump}")
    return (f"due {due}; one lease stages the masked index (15-column contract); 3 records stored, the Drive-readable one "
            f"FILED_VERIFIED, the other not; CRA notice -> notification; a value in Notes never reaches staging or the record table; "
            f"acks {ack}; a second run replays without new records")


@test("AT-INT-02", "INT-3; SI §4, §10; OR-EML-03…06 (exact fetch by Message-ID, evidence .eml, attachment discovery, route and move)")
def t_mail(server, ev):
    E = Env()
    H = C4.index_household(server, "bnx_c18mail")
    shim = Shim(H)
    try:
        H.cmd(H.owner, "register_mail_source", source_ref="mbx-owner-gmail", provider="gmail", address="owner@family.example")
        H.cmd(H.owner, "register_mail_source", source_ref="mbx-owner-gmail", provider="gmail", address="owner@family.example",
              credential_state="authorized")                    # a new source starts not_authorized; the Owner authorizes it
        mb = providers.MockMailbox(E.root, "mbx-owner-gmail")
        mid = "<statement-march@synthbank.example>"
        raw = providers.eml_bytes("Statements <statements@synthbank.example>", "owner@family.example", "Your synthetic statement", mid,
                                  attachments=[("statement.pdf", DF.pdf_clean(), "application/pdf")])
        pid = mb.put(raw, folder="INBOX")
        evdir = tempfile.mkdtemp(prefix="bnx-ev-")
        from bnx_exec import store
        E.ctx.evidence = store.LocalStore(evdir)
        c1, r1 = run(E, shim, "MAIL_EXACT_FETCH", ["mbx-owner-gmail|" + mid])
        p1 = C15.promote_all(H)
        # unknown message and unauthorized mailbox
        c_nf, r_nf = run(E, shim, "MAIL_EXACT_FETCH", ["mbx-owner-gmail|<missing@synthbank.example>"])
        H.cmd(H.owner, "register_mail_source", source_ref="mbx-other-gmail", provider="gmail", address="other@family.example")
        lease_refused = run(E, shim, "MAIL_EXACT_FETCH", ["mbx-other-gmail|" + mid])[1][0].get("reason")
        # attachment -> discovery (source MAIL_ATTACHMENT) -> validation through the mailbox
        c2, r2 = run(E, shim, "DOC_DISCOVER", ["mail:mbx-owner-gmail|" + mid + "|1"]); C15.promote_all(H)
        due_doc = shim.due("DOC_PROCESS")
        c3, r3 = run(E, shim, "DOC_PROCESS", due_doc); C15.promote_all(H)
        # route: the bank's institution -> folder; then MAIL_MOVE
        before_route = shim.due("MAIL_MOVE")
        inst = H._inst["Synthetic Bank"]
        route = H.cmd(H.owner, "set_mail_route", source_ref="mbx-owner-gmail", institution_id=inst, folder_ref="Banking/SynthBank",
                      effective_from="2026-01-01")                                     # 9028: the Owner's command (L-INT-2)
        route_member = C4.err(H.cmd, H.member, "set_mail_route", source_ref="mbx-owner-gmail", institution_id=inst, folder_ref="X",
                              effective_from="2026-01-01")[0]
        routes = H.q(H.owner, "mail_routes")["routes"]
        due_mv = shim.due("MAIL_MOVE")
        c4, r4 = run(E, shim, "MAIL_MOVE", due_mv); C15.promote_all(H)
        after = shim.due("MAIL_MOVE")
        with H.definer() as cx:
            item = cx.execute("select state, sender_validation, attachments_expected, attachments_fetched, folder_ref, "
                              "encode(evidence_sha256, 'hex') from bnx_intake.mail_item where source_ref = 'mbx-owner-gmail'").fetchone()
            disc = cx.execute("select d.source_kind, d.mime_part, c.state from bnx_doc.document_discovery d "
                              "join bnx_doc.document_current c on c.discovery_id = d.id").fetchall()
            staged = " ".join(str(r) for r in cx.execute("select payload::text from bnx_intake.staging_payload"))
        ev_ok = os.path.exists(os.path.join(evdir, "bnx-evidence", "mail", item[5] + ".eml"))
        out = {"fetch": [x.get("status") for x in r1], "not_found": [(x.get("status"), x.get("reason")) for x in r_nf],
               "unauthorized_lease": lease_refused, "mail_item": item[:5], "evidence_file": ev_ok, "discoveries": disc,
               "due_move_before_route": before_route, "due_move": due_mv, "move": [x.get("status") for x in r4], "due_after": after,
               "folder_now": mb.folder_of(pid), "subject_or_body_staged": ("synthetic statement" in staged.lower()),
               "route": route.get("kind"), "route_member": route_member, "routes": [(r["kind"], r["folder_ref"]) for r in routes]}
        json.dump(out, open(os.path.join(ev, "AT-INT-02.json"), "w"), indent=1, default=str)
        shutil.rmtree(evdir, ignore_errors=True)
    finally:
        H.close(); E.close()
    check(out["fetch"] == ["STAGED"] and out["not_found"] == [("NOT_STAGED", "MESSAGE_NOT_FOUND")] and lease_refused == "MAIL_CREDENTIAL_NOT_AUTHORIZED", f"{out}")
    check(item[0] == "MOVED" and item[1] == "verified" and item[2] == 1 and item[3] == 1 and item[4] == "Banking/SynthBank" and ev_ok, f"{out}")
    check(disc == [("MAIL_ATTACHMENT", "1", "PENDING_DECLARATION")] and before_route == [] and len(due_mv) == 1 and after == [], f"{out}")
    check(out["folder_now"] == "Banking/SynthBank" and not out["subject_or_body_staged"], f"{out}")
    check(out["route"] == "institution" and "FORBIDDEN" in str(out["route_member"]) and out["routes"] == [("institution", "Banking/SynthBank")], f"{out}")
    return (f"exact fetch by Message-ID staged (no subject or body), .eml kept as content-addressed evidence; missing message "
            f"MESSAGE_NOT_FOUND; a mailbox without an authorized credential stages nothing; the PDF attachment is discovered as MAIL_ATTACHMENT part 1 and "
            f"validated through the mailbox (PENDING_DECLARATION, no classifier); no move before a route; with the institution route the "
            f"message moves to its folder and the item is MOVED; nothing left due")


@test("AT-TST1-01", "TST-1 (tools/s4/gen_fixtures.py: a generated household runs through discover and validate with the expected verdicts)")
def t_generator(server, ev):
    import subprocess
    E = Env()
    H = C4.v2_full(server, "bnx_c18gen")
    shim = Shim(H)
    try:
        r = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools", "s4", "gen_fixtures.py"), "--root", E.root, "--months", "2", "--seed", "7"],
                           capture_output=True, text=True, check=True)
        man = json.load(open(os.path.join(E.root, "MANIFEST.json")))
        run(E, shim, "DOC_DISCOVER", docjobs.plan_discover(E.ctx)); C15.promote_all(H)
        run(E, shim, "DOC_PROCESS", shim.due("DOC_PROCESS")); C15.promote_all(H)
        with H.definer() as cx:
            got = {fid: st for fid, st in cx.execute("select d.source_file_id, c.state from bnx_doc.document_discovery d "
                                                       "join bnx_doc.document_current c on c.discovery_id = d.id")}
        want = {d["file_id"]: d["expect"].split(" ")[0].rstrip(";") for d in man["drive"]}
        mails = len(providers.MockMailbox(E.root, "mbx-owner-gmail")._idx())
        recs = len(providers.MockIndex(E.root).read("index-ref")["records"])
        json.dump({"stdout": r.stdout.strip(), "want": want, "got": got}, open(os.path.join(ev, "AT-TST1-01.json"), "w"), indent=1)
    finally:
        H.close(); E.close()
    check(got == want and mails == 2 and recs == 3, f"{want} {got} {mails} {recs}")
    kinds = sorted({v for v in want.values()})
    return f"generator: {len(want)} Inbox files, {recs} index records, {mails} messages; every file reached its expected state {kinds}"


@test("AT-INS-01", "INS-2 (installer validator and plan: every input checked before anything is touched)")
def t_installer(server, ev):    # noqa: ARG001 - no database needed
    import importlib.util, subprocess, types
    spec = importlib.util.spec_from_file_location("install_instance", os.path.join(h.ROOT, "deploy", "install_instance.py"))
    I = importlib.util.module_from_spec(spec); spec.loader.exec_module(I)
    good = dict(pg="host=127.0.0.1 dbname=balnexa user=balnexa_owner", runtime_host="ep-synthetic.c-8.us-east-2.aws.neon.tech",
                project_id="synthetic-test-01", modules='{"Canada":"YES","International":"YES","CRA":"NO"}', worker_name="balnexa-test",
                app_origin="https://balnexa-test.synthetic.workers.dev", kv_id="0" * 32,
                google_client_id="1000000000001-abcdefghijklmnop.apps.googleusercontent.com", bind_owner_sub=None, secrets_dir="/nonexistent")
    ok = I.validate(types.SimpleNamespace(**good))
    bad = {k: I.validate(types.SimpleNamespace(**{**good, k: v})) for k, v in (
        ("pg", "host=x dbname=balnexa user=bnx_installer"), ("modules", '{"Canada":"YES","International":"YES","CRA":"YES"}'),
        ("app_origin", "http://balnexa-test.synthetic.workers.dev"), ("kv_id", "abc"), ("project_id", "Bad_Id"),
        ("google_client_id", "client"), ("bind_owner_sub", "pending-owner-probe"))}
    r = subprocess.run([sys.executable, os.path.join(h.ROOT, "deploy", "install_instance.py"), "--pg", good["pg"], "--runtime-host", good["runtime_host"],
                        "--project-id", good["project_id"], "--app-origin", good["app_origin"], "--kv-id", good["kv_id"],
                        "--google-client-id", good["google_client_id"], "--secrets-dir", "/nonexistent-dir", "--plan"], capture_output=True, text=True)
    check(ok == [] and all(len(v) == 1 for v in bad.values()) and r.returncode == 0 and "nothing done" in r.stdout
          and not os.path.exists("/nonexistent-dir"), f"{ok} {bad} {r.returncode} {r.stdout} {r.stderr}")
    return f"valid inputs pass; each of {len(bad)} bad inputs gives exactly one problem ({', '.join(bad)}); --plan prints the steps and creates nothing"


@test("AT-DPL-01", "INS-1 deploy rule; 9029 (activation refused when the deployed Worker's schema range excludes the applied head)")
def t_deploy_rule(server, ev):
    import json as _j
    import run_s4_core1 as C1c
    import run_s4_core2 as C2c
    H = C1c.v2_household(server, "bnx_c18dpl")
    head = C2c.sql(H, "select max(version) from bnx.schema_migrations where version >= '9000'")[0][0]
    env_ok = _j.loads(C1c.env(H, C1c.MODULES))
    old = {**env_ok, "worker_supports_extension": ["9017", "9023"]}
    refused = C4.err(C1c.installer_sql, server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)", (C1c.DIGEST, _j.dumps(old)))
    # 9039: a range that is not exactly two versions is refused too (an empty range used to skip the check)
    malformed = {json_r: C4.err(C1c.installer_sql, server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)",
                                (C1c.DIGEST, _j.dumps({**env_ok, "worker_supports_extension": _j.loads(json_r)})))
                 for json_r in ("[]", f'["{head}"]', f'[null, "{head}"]', f'["{head}", "9xx9"]', '{"lo": "9000"}')}
    good = {**env_ok, "worker_supports_extension": [str(int(head) - 1).zfill(4), head]}
    C1c.installer_sql(server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)", (C1c.DIGEST, _j.dumps(good)))
    state = C2c.sql(H, "select state from bnx.config_version_anchor where config_version = 1")[0][0]
    H.close()
    check(refused[0] == "BNX_BINDING_MISMATCH" and "B3" in (refused[1] or "") and state == "ACTIVE", f"{refused} {state}")
    check(all(v[0] == "BNX_BINDING_MISMATCH" and "B3" in (v[1] or "") for v in malformed.values()), f"{malformed}")
    return (f"schema head {head}: a Worker supporting 9017-9023 is refused (B3); malformed ranges {sorted(malformed)} are refused (B3, 9039); "
            f"one supporting N-1..{head} activates the configuration")


@test("AT-AUD-01", "F-AUD-01; 9030 (correct_transaction: journal UUIDs in the audit subject sit under *_id keys, so guard C2 exempts them)")
def t_audit_ids(server, ev):
    import run_s4_core2 as C2c
    H = C4.v2_full(server, "bnx_c18aud")
    j = H.expense(H.owner, "12.00", date="2026-02-03")["journal_id"]
    r = H.cmd(H.owner, "correct_transaction", journal_id=j, reason="synthetic fix", replacement={"transaction_date": "2026-02-03",
        "description": "fixed", "lines": [{"ledger_account_id": H.groceries, "currency": "CAD", "amount": "13.00"},
                                          {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-13.00"}]})
    subj = C2c.sql(H, "select subject from bnx_audit.audit_event where command = 'correct_transaction' order by seq desc limit 1")[0][0]
    # the old subject shape with a UUID group holding a Mod-10 run is refused by the guard; the new shape is not
    from run_s4_core17 import luhn_run
    u = "aaaaaaaa-bbbb-cccc-dddd-e" + luhn_run("04645428") + "ff"           # built at run time: no literal run in the repository
    old_shape = C2c.sql(H, "select bnx.sin_json_has(jsonb_build_object('original', %s::text))", (u,))[0][0]
    new_shape = C2c.sql(H, "select bnx.sin_json_has(jsonb_build_object('original_journal_id', %s::text))", (u,))[0][0]
    H.close()
    check(set(subj) == {"original_journal_id", "reversal_journal_id", "replacement_journal_id"} and old_shape is True and new_shape is False
          and r["replacement_journal_id"], f"{subj} {old_shape} {new_shape}")
    return f"subject keys {sorted(subj)}; a UUID with a Mod-10 run in a group: refused under 'original' (old), exempt under 'original_journal_id' (9030)"


@test("AT-NULL-01", "G0 R2 remediation; 9039 (a command without a required array is refused: guards are NULL-safe)")
def t_null_guards(server, ev):
    H = C4.v2_full(server, "bnx_c18nul")
    ac = H.cad["account_currency_id"]
    plans0 = C2s(H, "select count(*) from bnx.posting_plan")
    accts0 = C2s(H, "select count(*) from bnx.account")
    out = {
        "import plan without items": C4.err(H.cmd, H.owner, "create_import_plan", account_currency_id=ac, date_from="2026-04-01", date_to="2026-04-30"),
        "import plan with items null": C4.err(H.cmd, H.owner, "create_import_plan", account_currency_id=ac, date_from="2026-04-01", date_to="2026-04-30", items=None),
        "import plan with items []": C4.err(H.cmd, H.owner, "create_import_plan", account_currency_id=ac, date_from="2026-04-01", date_to="2026-04-30", items=[]),
        "account without currencies": C4.err(H.cmd, H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="NoCur"),
        "account without kind": C4.err(H.cmd, H.owner, "create_account", **H.inst("Synthetic Bank"), label="NoKind", currencies=["CAD"]),
    }
    plans1 = C2s(H, "select count(*) from bnx.posting_plan")
    accts1 = C2s(H, "select count(*) from bnx.account")
    ok = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="WithCur", currencies=["CAD"])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-NULL-01.json"), "w"), indent=1, default=str)
    check(all(v[0] == "VALIDATION_FAILED" for v in out.values()) and (plans1, accts1) == (plans0, accts0) and len(ok["account_currencies"]) == 1,
          f"{out} {plans0}->{plans1} {accts0}->{accts1} {ok}")
    return (f"{len(out)} commands with an absent, null or empty required field -> VALIDATION_FAILED and nothing stored "
            f"({sorted(set(v[1] for v in out.values()))}); the same account with currencies is created")


def C2s(H, q):
    import run_s4_core2 as C2c
    return C2c.sql(H, q)[0][0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core18", a.server)
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
    summary = {"server": a.server, "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core18_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
