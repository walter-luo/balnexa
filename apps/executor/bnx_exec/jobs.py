"""Job handlers. Each takes (ctx, lease) and returns (staging kind, payload). A handler never posts: its result is a staging
payload that the Worker tick promotes through the wrk_* promoter of that kind (9016, 9018)."""
import datetime as dt
import hashlib
import json
import os
import tarfile
import uuid

import psycopg

from . import agecli, pgtools, render, restore
from .hashing import file_digests, kib, sha256_file

EXECUTOR_RELEASE = "bnx-exec-0.1.0-core8"
UTC = dt.timezone.utc


class JobFailed(Exception):
    """a failure the job reports as its result (FAILED / FAIL) instead of abandoning the lease"""


def now():
    return dt.datetime.now(UTC)


def iso(t):
    return t.astimezone(UTC).isoformat()


# ---------------------------------------------------------------------------------------------------------------------
# REPORT_RENDER (UA §5.8.2; closes the Executor part of L-9013-2)
# ---------------------------------------------------------------------------------------------------------------------
def report_render(ctx, lease):
    order = lease.input or {}
    data, facts = render.render(order)
    sha = hashlib.sha256(data).hexdigest()
    path = os.path.join(ctx.workdir, "artifact.html")
    with open(path, "wb") as f:
        f.write(data)
    ctx.check_stop()
    meta = ctx.artifacts.put_file(order["object_prefix"] + sha + ".html", path)
    if meta["sha256"] != sha:
        raise RuntimeError("artifact store digest")
    return "render_done", {"snapshot_id": order["snapshot_id"], "artifact_sha256": sha, "rendered_at": iso(now()),
                           "renderer_version": render.RENDERER_VERSION, "projection_sha256": order["projection_sha256"],
                           "source_revision": order["source_revision"], "ownership_revision": order["ownership_revision"],
                           "size_kib": kib(len(data)), "coverage": facts["coverage"], "warnings": facts["warnings"]}


# ---------------------------------------------------------------------------------------------------------------------
# BACKUP (UA §9.3 steps 1-8)
# ---------------------------------------------------------------------------------------------------------------------
def backup_object_name(started, run_id):
    """= bnx.backup_object_name (9016): derived on both sides, never sent"""
    return f"bnx-vault-backups/{started.astimezone(UTC):%Y/%m}/{run_id}.age"


def _tar(dst, members):
    """deterministic tar (fixed mtime, owner and mode) of (arcname, path) pairs"""
    with tarfile.open(dst, "w", format=tarfile.PAX_FORMAT) as t:
        for arc, p in members:
            ti = t.gettarinfo(p, arcname=arc)
            ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname, ti.mode = 0, 0, 0, "", "", 0o600
            with open(p, "rb") as f:
                t.addfile(ti, f)


def _untar(src, dst_dir, names):
    with tarfile.open(src) as t:
        got = sorted(m.name for m in t.getmembers())
        if got != sorted(names):
            raise JobFailed("ARCHIVE_MEMBERS")
        for n in names:
            m = t.getmember(n)
            if not m.isfile():
                raise JobFailed("ARCHIVE_MEMBERS")
            with t.extractfile(m) as fi, open(os.path.join(dst_dir, n), "wb") as fo:
                while True:
                    b = fi.read(1 << 20)
                    if not b:
                        break
                    fo.write(b)


def backup(ctx, lease):
    order, cfg = lease.input or {}, ctx.config
    if order.get("due") is not True:                  # the hourly C2 decision of wrk_backup_due (nothing is staged)
        raise JobFailed("NOT_DUE: " + str(order.get("reason")))
    st = now()
    run_id = str(uuid.uuid4())
    base = {"run_id": run_id, "started_at": iso(st), "local_date": order.get("local_date"), "tier": order.get("tier"),
            "retain_until": order.get("retain_until"), "destination": order.get("destination", "OFF_PROVIDER")}
    tools = {}
    try:
        rec = order.get("recipients") or {}
        # K2 recipients: the public keys of this job must be the ones the registry fingerprints (S4B-F24)
        if agecli.recipient_fingerprint(cfg.owner_recipient) != rec.get("owner_fingerprint_sha256") \
           or agecli.recipient_fingerprint(cfg.drill_recipient) != rec.get("drill_fingerprint_sha256"):
            raise JobFailed("RECIPIENT_FINGERPRINT")
        w = ctx.workdir
        dump, hdr, plain, arch = (os.path.join(w, n) for n in ("data.dump", "backup_header.json", "plain.tar", "archive.age"))
        # steps 1-3: bnx_backup on the direct endpoint; REPEATABLE READ READ ONLY; exported snapshot; header facts inside it
        with psycopg.connect(cfg.backup_dsn) as bk:
            bk.execute("begin isolation level repeatable read read only")
            snap = bk.execute("select pg_export_snapshot()").fetchone()[0]
            header = bk.execute("select bnx.bkp_header_facts()").fetchone()[0]
            server = bk.execute("show server_version").fetchone()[0]
            tools["server"] = pgtools.version_text(server)
            mj = pgtools.select_dump(pgtools.major_of(server))
            if mj is None:
                raise JobFailed(f"TOOL_MAJOR: no pg_dump >= {pgtools.major_of(server)}")
            pg_dump, pg_restore = pgtools.tool("pg_dump", mj), pgtools.tool("pg_restore", mj)
            tools["pg_dump"], tools["pg_restore"] = pgtools.version(pg_dump), pgtools.version(pg_restore)
            # step 4: one pg_dump in that snapshot, every registered schema, custom format, data only, single job
            ctx.run([pg_dump, "--dbname", cfg.backup_dsn, f"--snapshot={snap}", *order["pg_dump_args"], "-f", dump], "PG_DUMP")
            lst = ctx.run([pg_restore, "--list", dump], "PG_RESTORE_LIST")
            wire = ctx.run_count([pg_restore, "--data-only", "-f", "-", dump], "PG_RESTORE_SIZE")
            bk.rollback()                                   # step 6: the export transaction ends after every pg_dump exited
        dd = file_digests(dump)
        # step 7: backup_header.json
        hj = {"format": "bnx-backup-header/1", "run_id": run_id, "started_at": iso(st), "release": EXECUTOR_RELEASE,
              "instance": header.get("instance"), "config": header.get("config"), "tools": tools, "dump_sha256": dd["sha256"],
              "recipients": {k: rec.get(k) for k in ("owner_key_id", "owner_fingerprint_sha256", "drill_key_id", "drill_fingerprint_sha256")},
              "header_facts": header}
        with open(hdr, "w") as f:
            json.dump(hj, f, sort_keys=True, separators=(",", ":"))
        _tar(plain, [("backup_header.json", hdr), ("data.dump", dump)])
        plain_sha = sha256_file(plain)
        # step 8: age to the K2 recipients; upload; re-download; decrypt with the drill identity; pg_restore --list; compare
        agecli.encrypt(plain, arch, [cfg.owner_recipient, cfg.drill_recipient])
        ad = file_digests(arch)
        ctx.check_stop()
        meta = ctx.vault.put_file(backup_object_name(st, run_id), arch)
        back, dec, vdir = os.path.join(w, "redownload.age"), os.path.join(w, "redownload.tar"), os.path.join(w, "verify")
        ctx.vault.get_file(backup_object_name(st, run_id), back)
        same = sha256_file(back) == ad["sha256"] and meta["sha256"] == ad["sha256"]
        agecli.decrypt(back, dec, cfg.drill_identity)
        os.makedirs(vdir, exist_ok=True)
        _untar(dec, vdir, ["backup_header.json", "data.dump"])
        list_ok = sha256_file(dec) == plain_sha and sha256_file(os.path.join(vdir, "data.dump")) == dd["sha256"] \
            and ctx.run([pg_restore, "--list", os.path.join(vdir, "data.dump")], "PG_RESTORE_LIST").returncode == 0 \
            and lst.returncode == 0
        if not (same and list_ok):
            raise JobFailed("VERIFY")
        return "backup_recorded", {**base, "ended_at": iso(now()), "outcome": "VERIFIED", "object": {"generation": meta["generation"]},
            "sizes": {"compressed_kib": kib(ad["size"]), "wire_kib": kib(wire)},
            "dump_sha256": dd["sha256"], "plaintext_sha256": plain_sha, "header_sha256": sha256_file(hdr), "tools": tools,
            "verify": {"redownload_sha256_equal": same, "pg_restore_list_ok": list_ok, "decrypted_with": rec.get("drill_key_id")},
            "recipients": hj["recipients"], "header": header}
    except (JobFailed, agecli.AgeError, psycopg.Error, OSError) as e:
        if not isinstance(e, (JobFailed, agecli.AgeError)):
            e = type(e).__name__                # a driver or I/O error: the type only (messages can carry a DSN)
        return "backup_recorded", {**base, "ended_at": iso(now()), "outcome": "FAILED", "failure_reason": str(e)[:200]}


# ---------------------------------------------------------------------------------------------------------------------
# RESTORE_DRILL (UA §9.3 step 9; Backup §7-§8). The database decides PASS; the job reports what it observed.
# ---------------------------------------------------------------------------------------------------------------------
def restore_drill(ctx, lease):
    order, cfg = lease.input or {}, ctx.config
    st = now()
    drill_id = str(uuid.uuid4())
    out = {"drill_id": drill_id, "backup_run_id": order.get("backup_run_id"), "kind": "DRILL", "target": "ISOLATED_DRILL",
           "decrypt_key_id": cfg.drill_key_id, "started_at": iso(st)}
    tools, restored, why, target_name, cleanup = {}, None, None, None, False
    try:
        if agecli.recipient_fingerprint(agecli.identity_recipient(cfg.drill_identity)) != order.get("drill_fingerprint_sha256"):
            raise JobFailed("DRILL_KEY_NOT_RECIPIENT")
        w = ctx.workdir
        arch, plain, xdir = os.path.join(w, "drill.age"), os.path.join(w, "drill.tar"), os.path.join(w, "drill")
        meta = ctx.vault.get_file(order["object_name"], arch)
        if str(meta.get("generation")) != str(order.get("object_generation")):
            raise JobFailed("OBJECT_GENERATION")
        agecli.decrypt(arch, plain, cfg.drill_identity)
        if sha256_file(plain) != order.get("plaintext_sha256"):
            raise JobFailed("PLAINTEXT_DIGEST")
        os.makedirs(xdir, exist_ok=True)
        _untar(plain, xdir, ["backup_header.json", "data.dump"])
        dump = os.path.join(xdir, "data.dump")
        if sha256_file(dump) != order.get("dump_sha256") or sha256_file(os.path.join(xdir, "backup_header.json")) != order.get("header_file_sha256"):
            raise JobFailed("FILE_DIGEST")
        mj = pgtools.select_restore(pgtools.major_of(order.get("pg_dump_version")) or 99)
        if mj is None:
            raise JobFailed("TOOL_MAJOR: no pg_restore for the dump")
        upto = max(m["version"] for m in order["migrations"])
        target_name = cfg.drill_prefix + drill_id.replace("-", "")[:16]
        ctx.check_stop()
        tgt = ctx.provisioner.create(target_name, upto)
        tools["server"] = pgtools.version_text(_server_version(tgt))
        before = restore.header_facts(tgt.dsn("bnx_backup"))
        if before["migrations"] != order["migrations"]:
            raise JobFailed("MIGRATIONS_MISMATCH")
        r = restore.load_dump(tgt, dump, mj)
        tools["pg_restore"] = r["pg_restore"]
        pc = restore.post_checks(tgt)
        restored = restore.header_facts(tgt.dsn("bnx_backup"))
        mism = restore.header_compare(tgt.dsn("bnx_backup"), order["header_facts"], restored)
        if pc["audit_verify"] != 0:
            why = "AUDIT_VERIFY"
        elif mism:
            why = "HEADER_MISMATCH:" + ",".join(mism[:5])
    except (JobFailed, agecli.AgeError, restore.RestoreError) as e:
        why = str(e)[:120]
    except (psycopg.Error, OSError) as e:
        why = type(e).__name__
    finally:
        if target_name:
            try:
                cleanup = ctx.provisioner.drop(target_name)
            except Exception:                 # noqa: BLE001 - reported as cleanup_verified = false
                cleanup = False
        else:
            cleanup = True                    # no target was created: nothing to clean up
    out.update({"ended_at": iso(now()), "outcome": "FAIL" if why else "PASS", "cleanup_verified": cleanup, "tools": tools})
    if restored is not None:
        out["restored_header"] = restored
    if why:
        out["failure_reason"] = why
    return "restore_drill_recorded", out


def _server_version(tgt):
    with psycopg.connect(tgt.dsn("bnx_backup")) as cx:
        return cx.execute("show server_version").fetchone()[0]


# ---------------------------------------------------------------------------------------------------------------------
# EVIDENCE_VERIFY (Backup §9; R-09): re-hash the R2 copy of each evidence object the work order names
# ---------------------------------------------------------------------------------------------------------------------
def evidence_verify(ctx, lease):
    order = lease.input or {}
    st, items, missing = now(), [], []
    for it in order.get("items", []):
        ctx.check_stop()
        p = os.path.join(ctx.workdir, "ev.bin")
        try:
            ctx.evidence.get_file(it["r2_key"], p)
        except Exception:                     # noqa: BLE001 - a missing copy is logged; the payload has no field for it (L-CORE8-6)
            missing.append(it["evidence_object_id"]); continue
        items.append({"evidence_object_id": it["evidence_object_id"], "copy": it.get("copy", "R2"), "observed_sha256": sha256_file(p)})
        os.remove(p)
    ctx.log("evidence_verify", checked=len(items), missing=len(missing))
    if not items:
        raise JobFailed("NO_ITEMS" if not missing else "ALL_COPIES_MISSING")
    return "backup_recorded", {"items": items, "started_at": iso(st), "ended_at": iso(now())}


JOBS = {"REPORT_RENDER": report_render, "BACKUP": backup, "RESTORE_DRILL": restore_drill, "EVIDENCE_VERIFY": evidence_verify}
