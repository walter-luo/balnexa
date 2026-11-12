"""Job loop of the Executor (UA V1.2 §9.2; WP-CORE CORE-8).

One process runs one job kind over a list of items (a Cloud Run Job task, or a local run). For each item:
lease -> handler -> staging-guard pre-check -> completion. Failures of one item do not stop the others.

SIGTERM / SIGINT (Cloud Run sends SIGTERM before it kills a task): the loop stops taking items, the running child process
(pg_dump, pg_restore, age) is terminated and the current item is **abandoned without a completion**: its lease expires after
20 minutes and the item is retried by the next run. A half-done result is never staged.

Logs are one JSON object per line on stderr; nonces, tokens, DSNs and file contents are never logged.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from . import jobs, sin_detector
from .gateway import GatewayError

EXIT_OK, EXIT_CONFIG, EXIT_ITEM_FAILED, EXIT_TERMINATED = 0, 2, 3, 4


class Terminated(Exception):
    pass


class Context:
    def __init__(self, config, artifacts=None, vault=None, evidence=None, provisioner=None, log=None):
        self.config, self.artifacts, self.vault, self.evidence, self.provisioner = config, artifacts, vault, evidence, provisioner
        self.stop = threading.Event()
        self.workdir = None
        self._log = log or (lambda rec: print(json.dumps(rec, sort_keys=True), file=sys.stderr, flush=True))
        self._child = None

    def log(self, event, **kw):
        self._log({"t": round(time.time(), 3), "event": event, **kw})

    def check_stop(self):
        if self.stop.is_set():
            raise Terminated()

    def _spawn(self, args, stdout):
        self.check_stop()
        p = subprocess.Popen(args, stdout=stdout, stderr=subprocess.PIPE)
        self._child = p
        try:
            while True:
                try:
                    p.wait(timeout=0.2)
                    break
                except subprocess.TimeoutExpired:
                    if self.stop.is_set():
                        p.terminate()
                        try:
                            p.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            p.kill()
                        raise Terminated()
        finally:
            self._child = None
        return p

    def run(self, args, step):
        """run a tool; a non-zero exit is a reported job failure named by the step (stderr is not propagated)"""
        with tempfile.TemporaryFile() as out:
            p = self._spawn(args, out)
            p.stderr.close()
            if p.returncode:
                raise jobs.JobFailed(step)
            out.seek(0)
            p.stdout_text = out.read().decode(errors="replace")
        return p

    def run_count(self, args, step):
        """run a tool and return the number of bytes it wrote to stdout"""
        with tempfile.TemporaryFile() as out:
            p = self._spawn(args, out)
            p.stderr.close()
            if p.returncode:
                raise jobs.JobFailed(step)
            return os.fstat(out.fileno()).st_size


def guard_precheck(payload):
    """the staging SIN guard (stage_write, 9011) refuses any Luhn-valid 9-digit run outside hex/UUID values under exempt keys;
    the same reference detector runs here so that a refusal is seen before the one-time nonce is spent"""
    hits = sin_detector.scan_json(payload)
    return [h["path"] for h in hits]


def run_items(ctx, gateway, completer, kind, items, handlers=None):
    handlers = handlers or jobs.JOBS
    if kind not in handlers:
        ctx.log("config_error", reason="UNKNOWN_JOB_KIND", kind=kind)
        return EXIT_CONFIG, []
    results, failed = [], False
    for item in items:
        if ctx.stop.is_set():
            break
        rec = {"kind": kind, "item_id": item}
        wd = tempfile.mkdtemp(prefix="bnx-exec-", dir=ctx.config.scratch)
        ctx.workdir = wd
        try:
            lease = gateway.lease(kind, item)
            rec["lease_id"] = lease.lease_id
            stg_kind, payload = handlers[kind](ctx, lease)
            ctx.check_stop()
            hits = guard_precheck(payload)
            if hits:
                rec.update(status="NOT_STAGED", reason="STAGING_GUARD_WOULD_REFUSE", paths=hits[:5]); failed = True
            else:
                r = completer.complete(lease, stg_kind, payload)
                rec.update(status="STAGED", staging_id=r.get("staging_id"), stg_kind=stg_kind,
                           outcome=payload.get("outcome"), replayed=bool(r.get("replayed")))
        except Terminated:
            rec.update(status="ABANDONED", reason="TERMINATED")
        except jobs.JobFailed as e:
            rec.update(status="NOT_STAGED", reason=str(e)[:120]); failed = True
        except GatewayError as e:
            rec.update(status="REFUSED", http=e.status, reason=e.code); failed = True
        except Exception as e:             # noqa: BLE001 - one item never stops the others; only the type is logged
            rec.update(status="ERROR", reason=type(e).__name__); failed = True
        finally:
            shutil.rmtree(wd, ignore_errors=True)
            ctx.workdir = None
        ctx.log("item", **rec)
        results.append(rec)
    if ctx.stop.is_set():
        return EXIT_TERMINATED, results
    return (EXIT_ITEM_FAILED if failed else EXIT_OK), results


def install_signals(ctx):
    def handler(signum, frame):            # noqa: ARG001
        ctx.log("signal", signum=signum)
        ctx.stop.set()
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


class Config:
    """configuration from the environment (the Cloud Run Job's env and secret mounts)"""
    def __init__(self, env=None):
        e = env if env is not None else os.environ
        self.gateway_url = e.get("BNX_GATEWAY_URL")
        self.exec_audience = e.get("BNX_EXEC_AUDIENCE")
        self.id_token_file = e.get("BNX_ID_TOKEN_FILE")              # local runs; Cloud Run uses the metadata server
        self.complete_via = e.get("BNX_COMPLETE_VIA", "gateway")     # gateway | stager
        self.stager_dsn = e.get("BNX_STAGER_DSN")
        self.backup_dsn = e.get("BNX_BACKUP_DSN")
        self.owner_recipient = e.get("BNX_AGE_OWNER_RECIPIENT", "")
        self.drill_recipient = e.get("BNX_AGE_DRILL_RECIPIENT", "")
        self.drill_identity = e.get("BNX_AGE_DRILL_IDENTITY_FILE")
        self.drill_key_id = e.get("BNX_DRILL_KEY_ID")
        self.artifact_root = e.get("BNX_ARTIFACT_STORE")
        self.vault_root = e.get("BNX_VAULT_STORE")
        self.evidence_root = e.get("BNX_EVIDENCE_STORE")
        self.drill_conninfo = e.get("BNX_DRILL_CONNINFO")
        self.drill_admin = e.get("BNX_DRILL_ADMIN_USER", "postgres")
        self.drill_prefix = e.get("BNX_DRILL_PREFIX", "bnx_drill_")
        self.db_dir = e.get("BNX_DB_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "..", "db"))
        self.scratch = e.get("BNX_SCRATCH") or None

    NEEDS = {"REPORT_RENDER": ("artifact_root",), "BACKUP": ("backup_dsn", "vault_root", "owner_recipient", "drill_recipient", "drill_identity"),
             "RESTORE_DRILL": ("vault_root", "drill_identity", "drill_key_id", "drill_conninfo"), "EVIDENCE_VERIFY": ("evidence_root",)}

    def missing(self, kind):
        m = [k for k in self.NEEDS.get(kind, ()) if not getattr(self, k)]
        if not self.gateway_url:
            m.append("gateway_url")
        if self.complete_via == "stager" and not self.stager_dsn:
            m.append("stager_dsn")
        if not self.id_token_file and not self.exec_audience:
            m.append("exec_audience")
        return m
