#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 V1.2 increment 15 tests: CORE-8 Executor (UA V1.2 §9.2-§9.3, §5.8.2; WP-CORE CORE-8) and migration 9018 (work orders
returned with the lease, the REPORT_RENDER promoter). The Executor package (apps/executor/bnx_exec) runs here for real: the
job loop, the renderer, the BACKUP procedure with pg_dump/pg_restore and age, the RESTORE_DRILL into an isolated database, the
EVIDENCE_VERIFY re-hash, SIGTERM handling and the staging-guard pre-check. The lease and completion go through a shim that
makes the Gateway's two database calls as bnx_worker (the HTTP path is covered by tests/blackbox/api.test.mjs BB-EXEC-02).
Keys are synthetic age keys generated into a temporary directory and deleted afterwards; no key is written to the repository
or to the evidence. Synthetic data only; no cloud resource is contacted.
Usage: run_s4_core15.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, datetime as dt, hashlib, json, os, shutil, subprocess, sys, tempfile, threading, time, traceback, uuid
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core13 as C13
import sin_corpus as SC
from run_g0 import expect_err

sys.path.insert(0, os.path.join(h.ROOT, "apps", "executor"))
from bnx_exec import agecli, gateway, jobs, pgtools, render, restore, runner, store   # noqa: E402

RESULTS, TESTS = [], []
check = C1.check
UTC = dt.timezone.utc
JOB = {"sub": "1000000000001", "email": "bnx-executor@synthetic-project.iam.gserviceaccount.com", "azp": "1000000000001"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


class WorkerShim:
    """the Gateway's two database calls of /exec/v1/lease and /exec/v1/complete (after jwt.js pinned the job identity)"""
    def __init__(self, H):
        self.H = H

    def lease(self, kind, item_id=None):
        try:
            r = self.H.worker.call("wrk_issue_exec_lease", {"job_kind": kind, "item_id": item_id, **JOB})
        except psycopg.Error as e:
            raise gateway.GatewayError(409, (e.diag.message_primary or "").split(":")[0]) from None
        return gateway.Lease(r["lease_id"], r["nonce"], r["expires_at"], r["job_kind"], item_id, r.get("input"))

    def complete(self, lease, stg_kind, payload):
        gateway.check_size(payload)
        return self.H.worker.call("wrk_stage_completion", lease.nonce, stg_kind, payload)


class Keys:
    """synthetic K2 keys (age X25519) in a temporary directory"""
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="bnx-k2-")
        self.owner_id, self.drill_id = self._gen("owner"), self._gen("drill")

    def _gen(self, name):
        p = os.path.join(self.dir, name + ".key")
        subprocess.run([agecli.AGE_KEYGEN, "-o", p], check=True, capture_output=True)
        return p

    def recipient(self, p):
        return agecli.identity_recipient(p)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def register(H, K, owner="owner-k2a", drill="drill-k2a"):
    H.cmd(H.owner, "backup_key_register", key_id=owner, role="OWNER", recipient_fingerprint_sha256=agecli.recipient_fingerprint(K.recipient(K.owner_id)))
    H.cmd(H.owner, "backup_key_register", key_id=drill, role="DRILL", recipient_fingerprint_sha256=agecli.recipient_fingerprint(K.recipient(K.drill_id)))


def ctx_for(server, H, root, K=None, **over):
    env = {"BNX_GATEWAY_URL": "shim", "BNX_EXEC_AUDIENCE": "shim", "BNX_BACKUP_DSN": h.dsn(server, "bnx_backup", H.db),
           "BNX_ARTIFACT_STORE": os.path.join(root, "r2"), "BNX_VAULT_STORE": os.path.join(root, "vault"),
           "BNX_EVIDENCE_STORE": os.path.join(root, "r2"), "BNX_DRILL_CONNINFO": h.SERVERS[server], "BNX_DRILL_KEY_ID": "drill-k2a",
           "BNX_DB_DIR": os.path.join(h.ROOT, "db"), "BNX_SCRATCH": root}
    if K:
        env |= {"BNX_AGE_OWNER_RECIPIENT": K.recipient(K.owner_id), "BNX_AGE_DRILL_RECIPIENT": K.recipient(K.drill_id),
                "BNX_AGE_DRILL_IDENTITY_FILE": K.drill_id}
    env |= over
    cfg = runner.Config(env)
    logs = []
    ctx = runner.Context(cfg, artifacts=store.LocalStore(cfg.artifact_root), vault=store.LocalStore(cfg.vault_root),
                         evidence=store.LocalStore(cfg.evidence_root),
                         provisioner=restore.LocalProvisioner(cfg.drill_conninfo, "postgres", cfg.db_dir, cfg.drill_prefix), log=logs.append)
    return ctx, logs


def expect(fn, substr, *a, **kw):
    """the message of the exception fn raises (any type); fails when it does not raise or the message lacks substr"""
    try:
        fn(*a, **kw)
    except Exception as e:  # noqa: BLE001
        m = str(e)
        check(substr in m, f"expected {substr!r}, got {m!r}")
        return m
    raise AssertionError(f"expected {substr!r}, call succeeded")


def one(H, q, p=None):
    with H.definer() as cx:
        return cx.execute(q, p).fetchone()


def promote_all(H):
    with H.definer() as cx:
        ids = [r[0] for r in cx.execute("select id from bnx_intake.staging_payload where state = 'STAGED' order by staged_at")]
    return {str(i): H.worker.call("wrk_promote_staged", i) for i in ids}


def snapshot(H, as_of="2026-01-31"):
    return H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", as_of=as_of)


# ------------------------------------------------------------------------------------------------- work orders (9018)
@test("AT-EXEC-03", "UA V1.2 §9.2 (the render jobs hold no database credential: the work order travels with the lease); 9018")
def t_orders(server, ev):
    H = C13.world(server, "bnx_c15ord")
    s = snapshot(H)
    W = WorkerShim(H)
    L = W.lease("REPORT_RENDER", s["snapshot_id"])
    o = L.input
    digest_ok = hashlib.sha256(o["rows_text"].encode()).hexdigest() == o["projection_sha256"] == s["projection_sha256"]
    rows_equal = json.loads(o["rows_text"]) == s["rows"]
    n0 = one(H, "select count(*) from bnx.exec_lease")[0]
    refused = {"unknown snapshot": expect_err(H.worker.call, "NOT_FOUND", "wrk_issue_exec_lease", {"job_kind": "REPORT_RENDER", "item_id": str(uuid.uuid4()), **JOB}),
               "no snapshot": expect_err(H.worker.call, "NOT_FOUND", "wrk_issue_exec_lease", {"job_kind": "REPORT_RENDER", "item_id": None, **JOB}),
               "unknown run": expect_err(H.worker.call, "NOT_FOUND", "wrk_issue_exec_lease", {"job_kind": "RESTORE_DRILL", "item_id": str(uuid.uuid4()), **JOB})}
    n1 = one(H, "select count(*) from bnx.exec_lease")[0]
    b0 = W.lease("BACKUP").input                     # no K2 keys registered yet
    C13.keys(H)
    b1 = W.lease("BACKUP").input
    ev_o = W.lease("EVIDENCE_VERIFY").input
    doc = W.lease("DOC_PROCESS", "doc-1").input
    app_denied = expect_err(H.app.sql, "permission denied", "select bnx.exec_work_order('BACKUP', null)")
    H.close()
    json.dump({"render_order": {k: v for k, v in o.items() if k != "rows_text"}, "refused": refused, "backup": [b0, b1]},
              open(os.path.join(ev, "AT-EXEC-03.json"), "w"), indent=1, default=str)
    check(digest_ok and rows_equal and o["source_revision"] == s["ledger_version"] and o["ownership_revision"] > 0
          and len(o["accounts"]) == len(s["rows"]) and o["object_prefix"] == f"bnx-artifacts/rpt/{s['snapshot_id']}/", f"{o}")
    check(n1 == n0 and all(v.startswith("NOT_FOUND") for v in refused.values()), f"{refused} {n0}->{n1}")
    check(b0["due"] is False and b0["reason"] == "K2_RECIPIENTS_MISSING" and b1["due"] is True and b1["recipients"]["drill_key_id"] == "drill-2026a"
          and len(b1["pg_dump_args"]) == 10 and ev_o == {"kind": "EVIDENCE_VERIFY", "items": []} and doc is None, f"{b0} {b1} {ev_o} {doc}")
    return (f"REPORT_RENDER order carries the {len(s['rows'])} projection rows as digested (SHA-256 = projection_sha256), source revision "
            f"V{o['source_revision']}, ownership revision {o['ownership_revision']}, account labels and the object prefix; unknown or missing "
            f"snapshot and unknown backup run refused with no lease row ({n0} -> {n1}); BACKUP order = wrk_backup_due (advisory: "
            f"{b0['reason']} -> due); EVIDENCE_VERIFY lists hashed objects; document kinds keep input null; bnx_app cannot read orders")


# ------------------------------------------------------------------------------------------------- REPORT_RENDER
@test("AT-RND-01", "UA V1.2 §5.8.2; L-9013-2 (REPORT_RENDER: verified rows, deterministic artifact, content-addressed object, promoter)")
def t_render(server, ev):
    H = C13.world(server, "bnx_c15rnd")
    s = snapshot(H)
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    ctx, logs = ctx_for(server, H, root)
    W = WorkerShim(H)
    code, res = runner.run_items(ctx, W, W, "REPORT_RENDER", [s["snapshot_id"]])
    prom = promote_all(H)
    art = H.app.call("q_snapshot_artifact", H.owner, {"snapshot_id": s["snapshot_id"]})
    name = art["artifact_ref"][3:]
    data = open(os.path.join(root, "r2", name), "rb").read()
    again, _ = render.render(W.lease("REPORT_RENDER", s["snapshot_id"]).input)
    # a second render of the same snapshot is idempotent in the store and adds seq 2
    code2, _ = runner.run_items(ctx, W, W, "REPORT_RENDER", [s["snapshot_id"]])
    promote_all(H)
    art2 = H.app.call("q_snapshot_artifact", H.owner, {"snapshot_id": s["snapshot_id"]})
    # the renderer refuses rows that do not match the digest
    o = W.lease("REPORT_RENDER", s["snapshot_id"]).input
    tampered = expect(render.render, "PROJECTION_DIGEST", o | {"rows_text": o["rows_text"].replace("2000", "2001")})
    # the promoter binds the result to the leased snapshot and recomputes digest and revisions
    s2 = snapshot(H, "2026-01-20")
    rej = {}
    good = jobs.report_render(type("C", (), {"workdir": tempfile.mkdtemp(dir=root), "artifacts": ctx.artifacts, "check_stop": lambda self=None: None})(),
                              W.lease("REPORT_RENDER", s["snapshot_id"]))[1]
    for label, over in (("other snapshot", {"snapshot_id": s2["snapshot_id"]}), ("digest", {"projection_sha256": "0" * 64}),
                        ("revision", {"source_revision": good["source_revision"] + 1}), ("unknown field", {"artifact_ref": "r2:x"}),
                        ("size", {"size_kib": "12"})):
        L = W.lease("REPORT_RENDER", s["snapshot_id"])
        st = W.complete(L, "render_done", good | over)
        H.worker.call("wrk_promote_staged", st["staging_id"])
        rej[label] = one(H, "select result->>'reason' from bnx_intake.staging_payload where id = %s", (st["staging_id"],))[0]
    wrong_lease = W.complete(W.lease("INDEX_RENDER", s["snapshot_id"]), "render_done", good)
    wl = H.worker.call("wrk_promote_staged", wrong_lease["staging_id"])
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    json.dump({"results": res, "logs": logs, "artifact": art, "artifact2": art2, "rejected": rej, "index_render": wl},
              open(os.path.join(ev, "AT-RND-01.json"), "w"), indent=1, default=str)
    check(code == 0 and res[0]["status"] == "STAGED" and list(prom.values()) == ["promoted"] and art["seq"] == 1
          and hashlib.sha256(data).hexdigest() == art["artifact_sha256"] and data == again and name == f"bnx-artifacts/rpt/{s['snapshot_id']}/{art['artifact_sha256']}.html"
          and art["renderer_version"] == render.RENDERER_VERSION and art["status"] == "CURRENT", f"{res} {prom} {art}")
    check(code2 == 0 and art2["seq"] == 2 and art2["artifact_sha256"] == art["artifact_sha256"] and tampered.startswith("PROJECTION_DIGEST"), f"{art2} {tampered}")
    check(rej == {"other snapshot": "ITEM_MISMATCH", "digest": "PROJECTION_DIGEST", "revision": "REVISION", "unknown field": "FIELD", "size": "ARTIFACT_FACTS"}
          and wl == "awaiting_promoter", f"{rej} {wl}")
    return (f"the job loop leased, rendered {len(data)} bytes ({res[0]['status']}), uploaded to the content-addressed object and staged; the Worker "
            f"promoter recorded artifact seq 1 (q_snapshot_artifact: {art['status']}, SHA-256 equal to the stored bytes); re-render byte-identical "
            f"(seq 2, same digest, idempotent store write); renderer refuses rows that do not match projection_sha256; promoter rejects "
            f"{sorted(rej.items())}; render_done on an INDEX_RENDER lease waits for its promoter")


# ------------------------------------------------------------------------------------------------- BACKUP
def run_backup(server, H, K, root, **over):
    ctx, logs = ctx_for(server, H, root, K, **over)
    W = WorkerShim(H)
    code, res = runner.run_items(ctx, W, W, "BACKUP", [None])
    return code, res, promote_all(H), logs


@test("AT-BAK-01-EXEC", "UA V1.2 §9.3 steps 1-8 (the Executor's BACKUP job: snapshot, header, pg_dump, K2 age, upload, re-download, drill-identity decrypt)")
def t_backup(server, ev):
    H = C13.world(server, "bnx_c15bak")
    K = Keys()
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    try:
        bad_code, bad_res, bad_prom, _ = run_backup(server, H, K, root, BNX_AGE_DRILL_RECIPIENT=K.recipient(K.owner_id))   # before keys: not due
        register(H, K)
        wrong = run_backup(server, H, K, root, BNX_AGE_DRILL_RECIPIENT=K.recipient(K.owner_id))       # drill recipient = the Owner's key
        server_major = pgtools.major_of(one(H, "show server_version")[0])
        have = pgtools.select_dump(server_major)
        code, res, prom, logs = run_backup(server, H, K, root)
        run = one(H, "select run_id, outcome, failure_reason, object_name, pg_dump_version, server_version, anchor_check, header_facts_sha256 is not null "
                     "from bnx.backup_run order by recorded_at desc limit 1")
        again = run_backup(server, H, K, root)                                                         # same local date
        status = H.app.call("q_backup_status", H.owner, {})
        files = sorted(os.path.relpath(os.path.join(d, f), os.path.join(root, "vault")) for d, _, fs in os.walk(os.path.join(root, "vault")) for f in fs)
        plain_leak = any(b"journal_line" in open(os.path.join(root, "vault", f), "rb").read() for f in files if f.endswith(".age"))
    finally:
        K.close()
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    json.dump({"not_due": bad_res, "wrong_recipient": wrong[1], "run": [str(x) for x in run], "results": res, "again": again[1],
               "status_runs": status.get("runs"), "vault": files, "logs": logs}, open(os.path.join(ev, "AT-BAK-01-EXEC.json"), "w"), indent=1, default=str)
    check(bad_res[0]["status"] == "NOT_STAGED" and bad_res[0]["reason"].startswith("NOT_DUE: K2_RECIPIENTS_MISSING") and bad_code == runner.EXIT_ITEM_FAILED, f"{bad_res}")
    check(wrong[1][0]["status"] == "STAGED" and wrong[1][0]["outcome"] == "FAILED", f"{wrong[1]}")
    if have is None:
        check(res[0]["outcome"] == "FAILED" and run[1] == "FAILED" and run[2].startswith("TOOL_MAJOR"), f"{res} {run}")
        return (f"pg_dump >= {server_major} is not installed here (CI runs this path): the job staged a FAILED run ({run[2]}) that the promoter "
                f"recorded; not due before K2 keys -> nothing staged; a drill recipient that is not the registered drill key -> FAILED "
                f"RECIPIENT_FINGERPRINT")
    check(code == 0 and res[0]["outcome"] == "VERIFIED" and list(prom.values()) == ["promoted"] and run[1] == "VERIFIED" and run[6] in ("MATCH", "EMPTY_CHAIN")
          and pgtools.major_of(run[4]) >= server_major and run[7], f"{res} {prom} {run}")
    check(files == sorted([run[3], run[3] + ".bnxmeta"]), f"{files} {run[3]}")
    check(not plain_leak and again[1][0]["reason"].startswith("NOT_DUE: DONE_FOR_LOCAL_DATE"), f"{again[1]}")
    return (f"BACKUP job: bnx_backup snapshot + header facts, pg_dump {run[4]} on server {run[5]} (custom, data only, every schema), deterministic "
            f"tar with backup_header.json, age to the Owner and drill recipients, upload {run[3]}, re-download + drill-identity decrypt + "
            f"pg_restore --list; promoter recorded VERIFIED (anchor {run[6]}); vault holds only ciphertext; second run the same local date "
            f"-> not due; before K2 keys -> not due; a wrong drill recipient -> FAILED RECIPIENT_FINGERPRINT (staged, never VERIFIED)")


# ------------------------------------------------------------------------------------------------- RESTORE_DRILL
@test("AT-BKP-DRILL-EXEC", "UA V1.2 §9.3 step 9; Backup §7-§8; AT-BKP-20 (the Executor's drill: drill identity only, isolated target, generated preamble)")
def t_drill(server, ev):
    H = C13.world(server, "bnx_c15dri")
    K = Keys()
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    try:
        register(H, K)
        server_major = pgtools.major_of(one(H, "show server_version")[0])
        if pgtools.select_dump(server_major) is None:
            return f"SKIPPED: pg_dump >= {server_major} not available here (CI runs this path)"
        code, res, prom, _ = run_backup(server, H, K, root)
        run_id = str(one(H, "select run_id from bnx.backup_run where outcome = 'VERIFIED'")[0])
        ctx, logs = ctx_for(server, H, root, K)
        W = WorkerShim(H)
        # G0 R2: the drill must not depend on whichever "python3" is first on PATH; a decoy that always fails is put first
        decoy = os.path.join(root, "decoy-bin"); os.makedirs(decoy)
        open(os.path.join(decoy, "python3"), "w").write("#!/bin/sh\necho decoy >&2\nexit 1\n"); os.chmod(os.path.join(decoy, "python3"), 0o755)
        path0 = os.environ.get("PATH", "")
        os.environ["PATH"] = decoy + os.pathsep + path0
        try:
            dcode, dres = runner.run_items(ctx, W, W, "RESTORE_DRILL", [run_id])
        finally:
            os.environ["PATH"] = path0
        dprom = promote_all(H)
        d = one(H, "select outcome, reasons, decrypt_key_id, cleanup_verified from bnx.restore_drill order by recorded_at desc limit 1")
        left = one(H, "select count(*) from pg_database where datname like 'bnx\\_drill\\_%%'")[0]
        status = H.app.call("q_backup_status", H.owner, {})
        restorable = [r for r in status["runs"] if r["run_id"] == run_id][0]["restorable"]
        # negative: the Owner identity in the drill job (not the registered drill recipient) -> FAIL before any decrypt
        ctx2, _ = ctx_for(server, H, root, K, BNX_AGE_DRILL_IDENTITY_FILE=K.owner_id)
        _, nres = runner.run_items(ctx2, W, W, "RESTORE_DRILL", [run_id])
        promote_all(H)
        n = one(H, "select outcome, reasons from bnx.restore_drill order by recorded_at desc limit 1")
        # negative: a tampered vault object -> FAIL (decrypt or digest), the database stores FAIL
        obj = os.path.join(root, "vault", one(H, "select object_name from bnx.backup_run where run_id = %s", (run_id,))[0])
        b = bytearray(open(obj, "rb").read()); b[-10] ^= 0xFF; open(obj, "wb").write(bytes(b))
        _, tres = runner.run_items(ctx, W, W, "RESTORE_DRILL", [run_id])
        promote_all(H)
        t = one(H, "select outcome, reasons from bnx.restore_drill order by recorded_at desc limit 1")
        left2 = one(H, "select count(*) from pg_database where datname like 'bnx\\_drill\\_%%'")[0]
    finally:
        K.close()
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    json.dump({"drill": dres, "promoted": dprom, "row": [str(x) for x in d], "owner_identity": [nres, [str(x) for x in n]],
               "tampered": [tres, [str(x) for x in t]], "logs": logs}, open(os.path.join(ev, "AT-BKP-DRILL-EXEC.json"), "w"), indent=1, default=str)
    check(code == 0 and dcode == 0 and dres[0]["outcome"] == "PASS" and list(dprom.values()) == ["promoted"] and d[0] == "PASS" and d[3] is True
          and d[2] == "drill-k2a" and left == 0 and restorable is True, f"{dres} {dprom} {d} {left} {restorable}")
    check(nres[0]["outcome"] == "FAIL" and n[0] == "FAIL" and "DRILL_KEY_NOT_RECIPIENT" in json.dumps(n[1]), f"{nres} {n}")
    check(tres[0]["outcome"] == "FAIL" and t[0] == "FAIL" and left2 == 0, f"{tres} {t}")
    # a failed runner is reported by its exception class only (never the message: it can quote a DSN)
    exc = [restore._exc_name("Traceback (most recent call last):\n  File \"x\"\nModuleNotFoundError: No module named 'psycopg'"),
           restore._exc_name("psycopg.OperationalError: connection to server failed: host=/x user=bnx_migrator"), restore._exc_name("")]
    check(exc == ["ModuleNotFoundError", "OperationalError", "no output"], f"{exc}")
    return (f"RESTORE_DRILL job (a failing decoy python3 first on PATH: the runner uses the Executor's interpreter): vault object downloaded, generation checked, decrypted with the drill identity, digests checked, isolated target "
            f"bootstrapped and migrated to the recorded versions (equal), loaded through the generated preamble, post-checks (audit_verify 0, "
            f"journals re-asserted), restored header facts staged; promoter stored PASS (key {d[2]}, cleanup verified, no drill database left) and "
            f"the run is restorable; Owner identity in the drill job -> FAIL DRILL_KEY_NOT_RECIPIENT; tampered object -> FAIL ({t[1]})")


# ------------------------------------------------------------------------------------------------- EVIDENCE_VERIFY
@test("AT-EVV-01", "Backup §9; R-09 (the Executor re-hashes the R2 copy of each hashed evidence object; mismatch alerts the Owner)")
def t_evidence(server, ev):
    H = C13.world(server, "bnx_c15evv")
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    ctx, logs = ctx_for(server, H, root)
    A, B = b"synthetic statement A", b"synthetic statement B"
    with H.definer() as cx:
        ids = [str(cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, sha256, integrity_state) values (gen_random_uuid(), %s, 21, %s, 'verified') returning id",
                              (k, hashlib.sha256(c).digest())).fetchone()[0]) for k, c in (("evidence/a.pdf", A), ("evidence/b.pdf", B), ("evidence/c.pdf", A + b"!"))]
    for k, c in (("evidence/a.pdf", A), ("evidence/b.pdf", b"tampered B")):       # c is missing from the store
        p = os.path.join(root, "src.bin"); open(p, "wb").write(c); ctx.evidence.put_file(k, p)
    W = WorkerShim(H)
    code, res = runner.run_items(ctx, W, W, "EVIDENCE_VERIFY", [None])
    prom = promote_all(H)
    rows = dict((str(a), b) for a, b in H.definer().execute("select evidence_object_id, result from bnx.evidence_verification").fetchall())
    alerts = C13.notes(H, "EVIDENCE_HASH_MISMATCH")
    order2 = W.lease("EVIDENCE_VERIFY").input["items"]
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    json.dump({"results": res, "rows": rows, "alerts": alerts, "logs": logs, "next_order": order2}, open(os.path.join(ev, "AT-EVV-01.json"), "w"), indent=1, default=str)
    miss = [l for l in logs if l.get("event") == "evidence_verify"]
    check(code == 0 and list(prom.values()) == ["promoted"] and rows == {ids[0]: "MATCH", ids[1]: "MISMATCH"} and alerts == [ids[1]]
          and miss and miss[0]["missing"] == 1, f"{res} {prom} {rows} {alerts} {logs}")
    check(order2[0]["evidence_object_id"] == ids[2], f"never-verified object first in the next order: {order2}")
    return (f"EVIDENCE_VERIFY job re-hashed {miss[0]['checked']} R2 copies: MATCH, MISMATCH (Owner alert {alerts}); a missing copy is logged "
            f"(missing={miss[0]['missing']}, no payload field: L-CORE8-6) and comes first in the next order (least recently verified first)")


# ------------------------------------------------------------------------------------------------- loop: SIGTERM, guard, replay
@test("AT-EXEC-04", "UA §9.2; M0-A-03/04 shape (SIGTERM: the current item is abandoned unstaged; lease expires; staging-guard pre-check; replay)")
def t_loop(server, ev):
    H = C13.world(server, "bnx_c15loop")
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    ctx, logs = ctx_for(server, H, root)
    W = WorkerShim(H)
    seen = []

    def slow(c, lease):
        seen.append(lease.lease_id)
        c.run(["sleep", "30"], "SLEEP")
        return "backup_recorded", {}
    t = threading.Timer(0.6, ctx.stop.set); t.start()
    t0 = time.time()
    code, res = runner.run_items(ctx, W, W, "EVIDENCE_VERIFY", [None, None], handlers={"EVIDENCE_VERIFY": slow})
    took = time.time() - t0
    lease_state = one(H, "select completed_at is null from bnx.exec_lease where lease_id = %s", (seen[0],))[0]
    staged = one(H, "select count(*) from bnx_intake.staging_payload")[0]
    # staging-guard pre-check: a Luhn-valid 9-digit run is refused before the one-time nonce is spent
    ctx2, _ = ctx_for(server, H, root)
    lid = []

    def sin_like(c, lease):
        lid.append(lease.lease_id)
        return "backup_recorded", {"items": [{"evidence_object_id": str(uuid.uuid4()), "copy": "R2", "observed_sha256": "0" * 64}], "note": "id " + SC.GROUPS["space"](SC.value("luhn", 41))}
    code2, res2 = runner.run_items(ctx2, W, W, "EVIDENCE_VERIFY", [None], handlers={"EVIDENCE_VERIFY": sin_like})
    unspent = one(H, "select completed_at is null from bnx.exec_lease where lease_id = %s", (lid[0],))[0]
    # completion replay: a lost response followed by LEASE_USED is a success (the nonce is one-time and held by this job only)
    calls = []

    class Resp:
        def __init__(self, st, body): self.status, self._b = st, body
        def read(self): return json.dumps(self._b).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def opener(req, timeout=None):
        calls.append(req.full_url)
        if len(calls) == 1:
            raise ConnectionResetError()
        import urllib.error, io
        raise urllib.error.HTTPError(req.full_url, 409, "conflict", {}, io.BytesIO(b'{"error":"LEASE_USED"}'))
    gc = gateway.GatewayClient("https://gw.test", gateway.StaticTokenProvider("t"), opener=opener, backoff=0)
    rep = gc.complete(gateway.Lease("l", "n-secret", "x", "BACKUP", None, None), "backup_recorded", {"items": []})
    no_retry = []

    def opener422(req, timeout=None):
        no_retry.append(1)
        import urllib.error, io
        raise urllib.error.HTTPError(req.full_url, 422, "x", {}, io.BytesIO(b'{"error":"VALIDATION_FAILED"}'))
    e422 = expect(gateway.GatewayClient("https://gw.test", gateway.StaticTokenProvider("t"), opener=opener422, backoff=0).lease, "VALIDATION_FAILED", "BACKUP")
    nonce_hidden = "n-secret" not in repr(gateway.Lease("l", "n-secret", "x", "BACKUP", None, None)) and all("nonce" not in json.dumps(l) for l in logs)
    big = expect(gateway.check_size, "PAYLOAD_TOO_LARGE", {"x": "a" * 300000})
    # CLI: missing configuration -> exit 2 without contacting anything
    cli = subprocess.run([sys.executable, "-m", "bnx_exec", "run", "--kind", "BACKUP"], cwd=os.path.join(h.ROOT, "apps", "executor"),
                         env={"PATH": os.environ["PATH"]}, capture_output=True, text=True)
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    json.dump({"terminated": res, "guard": res2, "replay": rep, "cli": cli.stderr[-400:]}, open(os.path.join(ev, "AT-EXEC-04.json"), "w"), indent=1, default=str)
    check(code == runner.EXIT_TERMINATED and len(res) == 1 and res[0]["status"] == "ABANDONED" and took < 10 and lease_state is True and staged == 0, f"{code} {res} {took}")
    check(code2 == runner.EXIT_ITEM_FAILED and res2[0]["reason"] == "STAGING_GUARD_WOULD_REFUSE" and res2[0]["paths"] == ["$.note"] and unspent is True, f"{res2}")
    check(rep == {"state": "STAGED", "replayed": True} and len(calls) == 2 and len(no_retry) == 1 and e422.startswith("422")
          and nonce_hidden and big.startswith("413"), f"{rep} {calls} {no_retry} {e422}")
    check(cli.returncode == runner.EXIT_CONFIG and "MISSING" in cli.stderr, cli.stderr)
    return (f"SIGTERM during an item: child process terminated after {took:.1f}s, item ABANDONED with no completion (lease open, expires), loop "
            f"stopped before item 2, exit {code}; staging-guard pre-check stops a Luhn-valid run at {res2[0]['paths']} before the nonce is spent; "
            f"lost response + LEASE_USED = staged (replay), 4xx never retried, nonce never in a repr or log, > 256 KiB refused locally; CLI without "
            f"configuration exits {cli.returncode}")


@test("AT-EXEC-02-STG", "UA §9.2 (direct completion as bnx_stager through stg_* when bnx_stager LOGIN is enabled)")
def t_stager(server, ev):
    H = C13.world(server, "bnx_c15stg")
    s = snapshot(H)
    root = tempfile.mkdtemp(prefix="bnx-c15-")
    ctx, _ = ctx_for(server, H, root)
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as su:
        su.execute("alter role bnx_stager login")
    try:
        W = WorkerShim(H)
        S = gateway.StagerCompleter(h.dsn(server, "bnx_stager", H.db))
        code, res = runner.run_items(ctx, W, S, "REPORT_RENDER", [s["snapshot_id"]])
        by = one(H, "select staged_by from bnx_intake.staging_payload where id = %s", (res[0]["staging_id"],))[0]
        prom = promote_all(H)
        bad = expect(S.complete, "LEASE_INVALID", gateway.Lease("l", "not-a-nonce", "x", "REPORT_RENDER", None, None), "render_done", {"snapshot_id": "x"})
    finally:
        with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as su:
            su.execute("alter role bnx_stager nologin")
    H.close()
    shutil.rmtree(root, ignore_errors=True)
    check(code == 0 and by == "bnx_stager" and list(prom.values()) == ["promoted"] and bad.startswith("422"), f"{res} {by} {prom} {bad}")
    return f"REPORT_RENDER completed through bnx.stg_render_done as bnx_stager (staged_by {by}), promoted by the Worker; an invalid nonce -> {bad}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core15", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "SKIP" if str(msg).startswith("SKIPPED") else "PASS"
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__, "age": agecli.version(),
               "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core15_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
