"""Intake jobs: shared-index consumer (INT-2) and exact mail retrieval (INT-3). Contracts: migration 9010
(wrk_consume_shared_index, wrk_mail_evidence_registered, wrk_mail_move_result), 9011 (index payloads are masked at staging)
and 9026 (work orders and due lists).

INDEX_CONSUME      item = source_id. Read the upstream index (adapter and location from the work order), keep the 15-column
                   contract, mark records whose File ID is readable in the instance's Drive as FILED_VERIFIED, mask candidates
                   (the database masks again) and stage index_consumed. Records are sent in Processed Date order and cut at the
                   staging size budget; the next run continues (the promoter dedupes record versions).
MAIL_EXACT_FETCH   item = "<source_ref>|<Message-ID>". Fetch exactly that message, keep the .eml as evidence (content-addressed,
                   never parsed for subject or body), count the attachments and stage mail_fetched (no subject, no body).
MAIL_MOVE          item = canonical key (hex). Move the message to the folder the work order names; stage the result.

Nothing here logs an address, subject, body or file name (guard C3)."""
import hashlib
import json
import os
import tempfile

from . import providers as P
from . import sin_detector as S

BUDGET = 200_000            # bytes of JSON per index_consumed payload (stage_write refuses > 256 KiB)


def _failed(code):
    from .jobs import JobFailed
    return JobFailed(code)


def canonical_key(source_ref, message_id):
    """the mail item key: one per mailbox and RFC 5322 Message-ID (angle brackets and case of the domain part ignored)"""
    mid = message_id.strip().strip("<>")
    local, _, dom = mid.partition("@")
    return hashlib.sha256(f"{source_ref}\n<{local}@{dom.lower()}>".encode()).hexdigest()


def _location(ref, config):
    """resolve location_secret_ref. Mock: the last path segment names the mock index. Real: Secret Manager (M0-B)."""
    if getattr(config, "mock_root", None):
        return ref.rstrip("/").split("/")[-1]
    raise P.ProviderNotConfigured("index location: Secret Manager access is authorized at M0-B")


def index_consume(ctx, lease):
    inp = lease.input or {}
    if inp.get("kind") != "INDEX_CONSUME" or inp.get("source_id") != lease.item_id:
        raise _failed("WORK_ORDER")
    try:
        data = P.index(ctx.config).read(_location(inp["location_secret_ref"], ctx.config))
    except P.ProviderError as e:
        raise _failed(str(e)) from None
    header = data["header"]
    contract = list(inp.get("columns") or P.INDEX_COLUMNS)
    after = inp.get("max_processed_date_seen") or ""
    recs = [{k: (r.get(k) or "") for k in header} for r in data["records"]]
    recs.sort(key=lambda r: (r.get("Processed Date") or "", r.get("File ID") or "", r.get("Record Path") or ""))
    # records at or after the cursor date first, earlier ones afterwards (late corrections are still read)
    recs = [r for r in recs if (r.get("Processed Date") or "") >= after] + [r for r in recs if (r.get("Processed Date") or "") < after]
    drv = P.drive(ctx.config)
    avail = {}
    for r in recs:
        fid = r.get("File ID") or ""
        if fid and P._ID.match(fid) and drv.head(fid):
            avail[fid] = "FILED_VERIFIED"
    payload = {"source_id": inp["source_id"], "header": header, "records": [], "open_items": [{"key": str(o.get("key", ""))[:120]}
               for o in data.get("open_items", [])][:200], "availability": {}, "coverage": {}, "run_log": {"rows_read": len(recs)}}
    size = len(json.dumps(payload))
    for r in recs:
        add = len(json.dumps(r)) + 2
        if size + add > BUDGET:
            break
        payload["records"].append(r)
        size += add
        if r.get("File ID") in avail:
            payload["availability"][r["File ID"]] = "FILED_VERIFIED"
    sent = payload["records"]
    payload["coverage"] = {"records_sent": len(sent), "records_total": len(recs), "complete": len(sent) == len(recs),
                           "max_processed_date": max((r.get("Processed Date") or "" for r in sent), default="") or None,
                           "contract_ok": sorted(header) == sorted(contract)}
    return "index_consumed", S.mask_json(payload)


def _sender_domain(raw):
    import email
    import email.policy
    import email.utils
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    addr = email.utils.parseaddr(str(msg.get("From") or ""))[1]
    return addr.rpartition("@")[2].lower() or None


def mail_exact_fetch(ctx, lease):
    from .docjobs import mail_attachments
    inp = lease.input or {}
    if inp.get("kind") != "MAIL_EXACT_FETCH":
        raise _failed("WORK_ORDER")
    if inp.get("credential_state") != "authorized":
        raise _failed("MAIL_CREDENTIAL_NOT_AUTHORIZED")
    src, mid = inp["source_ref"], inp["message_id"]
    mb = P.mailbox(ctx.config, src, inp.get("provider"))
    m = mb.fetch_exact(mid)
    if not m:
        raise _failed("MESSAGE_NOT_FOUND")
    raw = m["raw"]
    ev_sha = hashlib.sha256(raw).hexdigest()
    if ctx.evidence is not None:                       # content-addressed .eml (R2 at M0-B); write-once
        with tempfile.NamedTemporaryFile(dir=ctx.workdir, delete=False) as f:
            f.write(raw)
        try:
            ctx.evidence.put_file(f"bnx-evidence/mail/{ev_sha}.eml", f.name)
        finally:
            os.unlink(f.name)
    parts = mail_attachments(raw)
    return "mail_fetched", {
        "op": "fetch", "source_ref": src, "canonical_key_sha256": canonical_key(src, mid), "message_id": mid,
        "provider_message_id": m["provider_message_id"], "folder_ref": m["folder_ref"], "received_at": m["received_at"],
        "sender_domain": _sender_domain(raw), "content_class": "attachment_bearing" if parts else "notice_only",
        "attachments_expected": len(parts), "attachments_fetched": sum(1 for p in parts if p[2] > 0), "evidence_sha256": ev_sha}


def mail_move(ctx, lease):
    inp = lease.input or {}
    if inp.get("kind") != "MAIL_MOVE" or inp.get("canonical_key_sha256") != lease.item_id:
        raise _failed("WORK_ORDER")
    if not inp.get("folder_ref"):
        raise _failed("NO_ROUTE")
    mb = P.mailbox(ctx.config, inp["source_ref"], inp.get("provider"))
    ok = bool(mb.move(inp["provider_message_id"], inp["folder_ref"]))
    return "mail_fetched", {"op": "move", "canonical_key_sha256": inp["canonical_key_sha256"], "folder_ref": inp["folder_ref"], "ok": ok}


JOBS = {"INDEX_CONSUME": index_consume, "MAIL_EXACT_FETCH": mail_exact_fetch, "MAIL_MOVE": mail_move}
