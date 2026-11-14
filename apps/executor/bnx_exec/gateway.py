# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Executor side of the lease protocol (UA V1.2 §9.2; S4B-F12).

The Executor never holds a posting-capable credential. For every job it asks the Gateway for a lease
(``POST /exec/v1/lease`` with the job's Google ID token); the Gateway pins ``sub``/``email``/``azp`` to the configured job
identity and returns a one-time nonce, a 20-minute expiry and the job's work order (``input``, migration 9018). The result
goes back with ``POST /exec/v1/complete`` (the Gateway writes it through ``wrk_stage_completion``), or, when ``bnx_stager``
LOGIN is enabled, directly through ``bnx.stg_<kind>`` as ``bnx_stager``. Staging rows never post: the Worker tick promotes
them.

The nonce is a secret for its 20 minutes: it is never logged and never written to disk.
"""
import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

METADATA_IDENTITY = ("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity"
                     "?audience={aud}&format=full")
MAX_COMPLETION_BYTES = 262144          # stage_write refuses larger payloads; the Gateway refuses > 300000 bytes of body


class GatewayError(Exception):
    def __init__(self, status, code, detail=None):
        super().__init__(f"{status} {code}")
        self.status, self.code, self.detail = status, code, detail


@dataclass
class Lease:
    lease_id: str
    nonce: str = field(repr=False)
    expires_at: str
    job_kind: str
    item_id: object
    input: object

    def __repr__(self):                 # the nonce never reaches a log line
        return f"Lease({self.lease_id}, {self.job_kind}, item={self.item_id})"


class StaticTokenProvider:
    """A token from a value or a file (tests; local runs). The file is re-read on every call so it can be rotated."""
    def __init__(self, token=None, path=None):
        if not token and not path:
            raise ValueError("token or path required")
        self._token, self._path = token, path

    def __call__(self):
        if self._path:
            with open(self._path) as f:
                return f.read().strip()
        return self._token


class MetadataTokenProvider:
    """Google-signed ID token of the job's service account from the Cloud Run metadata server (audience = the Gateway's
    EXEC_AUDIENCE). Cached until one minute before its expiry."""
    def __init__(self, audience, opener=None):
        self.audience, self._opener = audience, opener or urllib.request.urlopen
        self._tok, self._exp = None, 0

    def __call__(self):
        if self._tok and time.time() < self._exp - 60:
            return self._tok
        req = urllib.request.Request(METADATA_IDENTITY.format(aud=urllib.request.quote(self.audience, safe="")),
                                     headers={"Metadata-Flavor": "Google"})
        with self._opener(req, timeout=10) as r:
            tok = r.read().decode().strip()
        import base64
        try:
            body = tok.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
            self._exp = float(claims.get("exp", 0))
        except (IndexError, ValueError):
            self._exp = time.time() + 300
        self._tok = tok
        return tok


class GatewayClient:
    """HTTP client of /exec/v1/lease and /exec/v1/complete."""
    def __init__(self, base_url, tokens, opener=None, timeout=30, retries=3, backoff=1.0):
        self.base, self.tokens = base_url.rstrip("/"), tokens
        self._open = opener or urllib.request.urlopen
        self.timeout, self.retries, self.backoff = timeout, retries, backoff

    def _post(self, path, body):
        data = json.dumps(body, separators=(",", ":")).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST",
                                     headers={"content-type": "application/json", "authorization": "Bearer " + self.tokens()})
        try:
            with self._open(req, timeout=self.timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            try:
                j = json.loads(e.read() or b"null")
            except ValueError:
                j = None
            return e.code, j

    def _call(self, path, body, replay_ok=None):
        last = None
        for attempt in range(self.retries + 1):
            try:
                st, j = self._post(path, body)
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
                last = GatewayError(0, "NETWORK", type(e).__name__)
            else:
                if st == 200:
                    return j
                code = (j or {}).get("error", "HTTP_" + str(st)) if isinstance(j, dict) else "HTTP_" + str(st)
                if attempt > 0 and replay_ok and replay_ok(st, code):
                    return {"state": "STAGED", "replayed": True}
                if st < 500 and st != 429:
                    raise GatewayError(st, code)
                last = GatewayError(st, code)
            if attempt < self.retries:
                time.sleep(self.backoff * (2 ** attempt))
        raise last

    def lease(self, kind, item_id=None):
        # a lease request is not idempotent; a retry after a lost response leaves an unused lease that expires in 20 minutes
        r = self._call("/exec/v1/lease", {"job_kind": kind, "item_id": item_id})
        return Lease(r["lease_id"], r["nonce"], r["expires_at"], r["job_kind"], item_id, r.get("input"))

    def due(self, kind, limit=50):
        """items this job kind can lease now (9025 bnx.wrk_exec_due; DOC_PROCESS)"""
        return self._call("/exec/v1/due", {"job_kind": kind, "limit": limit}).get("items", [])

    def complete(self, lease, stg_kind, payload):
        body = {"job_kind": lease.job_kind, "nonce": lease.nonce, "stg_kind": stg_kind, "payload": payload}
        check_size(payload)
        # the nonce is one-time and only this process holds it: LEASE_USED on a retry means the first attempt was staged
        return self._call("/exec/v1/complete", body, replay_ok=lambda st, code: st == 409 and code == "LEASE_USED")


class StagerCompleter:
    """Direct completion as bnx_stager (UA §9.2, when bnx_stager LOGIN is enabled): EXECUTE on bnx.stg_* only."""
    KINDS = ("doc_discovered", "doc_validated", "doc_archived", "doc_rows", "index_consumed", "mail_fetched", "render_done",
             "backup_recorded", "restore_drill_recorded", "tax_artifact")

    def __init__(self, dsn):
        self.dsn = dsn

    def complete(self, lease, stg_kind, payload):
        import psycopg
        if stg_kind not in self.KINDS:
            raise GatewayError(422, "VALIDATION_FAILED", "staging kind")
        check_size(payload)
        with psycopg.connect(self.dsn) as cx:
            try:
                r = cx.execute(f"select bnx.stg_{stg_kind}(%s, %s::jsonb)", (lease.nonce, json.dumps(payload))).fetchone()[0]
            except psycopg.Error as e:
                msg = (e.diag.message_primary or "").split(":")[0].split(" ")[0]
                raise GatewayError(422, msg or "STAGING_REFUSED") from None
        return {"staging_id": r["staging_id"], "state": r["state"]}


def check_size(payload):
    n = len(json.dumps(payload, separators=(",", ":")).encode())
    if n > MAX_COMPLETION_BYTES:
        raise GatewayError(413, "PAYLOAD_TOO_LARGE", n)
