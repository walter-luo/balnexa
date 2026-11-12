"""Document pipeline jobs (DOC-2; Addendum A1 Rev 1 §4-§5; UA V1.2 §10). Contracts: migrations 9011 (promoters
wrk_doc_discovered / wrk_doc_validated / wrk_doc_archived) and 9025 (DOC_PROCESS work order, due list).

DOC_DISCOVER  item "drive:<file_id>": stage the file's current identity (no bytes, no content). The file name is sent only
              when it holds no candidate (D-9011b-5). A repeat of a known revision is a no-op in the promoter.
DOC_PROCESS   item = discovery id; the lease input names the step:
              VALIDATE  fetch exactly the discovered revision, check its md5, scan it in the isolated validator (zone Z1),
                        stage the verdict only (sha256, rule codes, positional locators). The bytes are dropped.
              ARCHIVE   fetch the same revision again, write the Processed copy, read the copy back and re-hash it, stage
                        the hash, size and type. The database admits only if identity and hash are unchanged (DOC-SIN-12).

No document class is assigned: there is no classifier yet (L-13), so every verdict is class_uncertain and the Owner declares
(D-9011c-5). Nothing here logs a file name, content or message header (guard C3)."""
import email
import email.policy
import hashlib

from . import doc_validator as V
from . import providers as P


class DocJobFailed(Exception):
    pass


def _failed(code):
    from .jobs import JobFailed
    return JobFailed(code)


def mail_part(raw, mime_part):
    """the bytes and file name of attachment number ``mime_part`` (1-based, in walk order of the parts that carry a file name).
    The same numbering is used by the mail discovery (INT-3)."""
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    n = 0
    for part in msg.walk():
        if part.is_multipart() or not part.get_filename():
            continue
        n += 1
        if str(n) == str(mime_part):
            return part.get_payload(decode=True) or b"", part.get_filename()
    raise _failed("MIME_PART_GONE")


def mail_attachments(raw):
    """[(mime_part, name, size_bytes)] of a message, numbered as in mail_part"""
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    out, n = [], 0
    for part in msg.walk():
        if part.is_multipart() or not part.get_filename():
            continue
        n += 1
        out.append((str(n), part.get_filename(), len(part.get_payload(decode=True) or b"")))
    return out


def _fetch(ctx, inp):
    """the exact bytes of the discovered revision (Drive) or attachment (mail), and the name for format detection"""
    if inp["source_kind"] == "DRIVE_INBOX":
        drv = P.drive(ctx.config)
        try:
            data = drv.fetch(inp["source_file_id"], inp["head_revision_id"])
        except P.ProviderError as e:
            raise _failed(str(e)) from None
        if hashlib.md5(data).hexdigest() != inp.get("md5"):    # noqa: S324 - comparison with the provider's checksum
            raise _failed("MD5_MISMATCH")
        head = drv.head(inp["source_file_id"]) or {}
        return data, head.get("name")
    if inp["source_kind"] == "MAIL_ATTACHMENT":
        if not inp.get("mail_source_ref"):
            raise _failed("MAIL_SOURCE_UNKNOWN")
        mb = P.mailbox(ctx.config, inp["mail_source_ref"], inp.get("mail_provider"))
        m = mb.fetch_exact(inp["mail_message_id"])
        if not m:
            raise _failed("MESSAGE_GONE")
        return mail_part(m["raw"], inp["mime_part"])
    raise _failed("SOURCE_KIND")


def doc_discover(ctx, lease):
    item = lease.item_id or ""
    if item.startswith("mail:"):
        return _discover_mail_part(ctx, lease, item[len("mail:"):])
    if not item.startswith("drive:"):
        raise _failed("ITEM")
    drv = P.drive(ctx.config)
    ident = drv.head(item[len("drive:"):])
    if not ident:
        raise _failed("FILE_GONE")
    identity = {"source_kind": "DRIVE_INBOX", **{k: ident[k] for k in ("source_file_id", "head_revision_id", "md5", "size_bytes",
                                                                       "source_mtime")}}
    module = ident.get("module") or "FINANCE"
    return "doc_discovered", V.discovered_payload(identity, ident.get("name"), module, ident.get("period_key"))


def _discover_mail_part(ctx, lease, rest):
    """item "mail:<source_ref>|<Message-ID>|<part>": an attachment of a message fetched by MAIL_EXACT_FETCH (INT-3). The
    lease input (9026) carries the mailbox provider; the identity is the message id and part number, no bytes."""
    try:
        src, mid, part = rest.split("|")
    except ValueError:
        raise _failed("ITEM") from None
    inp = lease.input or {}
    mb = P.mailbox(ctx.config, src, inp.get("provider"))
    m = mb.fetch_exact(mid)
    if not m:
        raise _failed("MESSAGE_GONE")
    found = [a for a in mail_attachments(m["raw"]) if a[0] == part]
    if not found:
        raise _failed("MIME_PART_GONE")
    _, name, size = found[0]
    identity = {"source_kind": "MAIL_ATTACHMENT", "mail_message_id": mid, "mime_part": part, "size_bytes": size}
    return "doc_discovered", V.discovered_payload(identity, name, inp.get("module") or "FINANCE")


def doc_process(ctx, lease):
    inp = lease.input or {}
    if inp.get("kind") != "DOC_PROCESS" or inp.get("discovery_id") != lease.item_id:
        raise _failed("WORK_ORDER")
    if inp.get("step") == "NONE":
        raise _failed("NOTHING_TO_DO")
    data, name = _fetch(ctx, inp)
    ctx.check_stop()
    if inp["step"] == "VALIDATE":
        return "doc_validated", V.validated_payload(inp["discovery_id"], data, name)
    if inp["step"] == "ARCHIVE":
        sha = hashlib.sha256(data).hexdigest()
        if sha != inp.get("scan_sha256"):
            # the bytes changed since the scan: stage them anyway; the gate returns the document to DISCOVERED (HASH_MISMATCH)
            ctx.log("doc_archive_hash_changed", discovery_id=inp["discovery_id"])
        identity = {k: inp.get(k) for k in ("source_file_id", "head_revision_id", "md5", "mail_message_id", "mime_part")}
        if inp["source_kind"] == "DRIVE_INBOX":
            drv = P.drive(ctx.config)
            aid = drv.copy_to_processed(inp["source_file_id"], inp["head_revision_id"], data, name)
            back = drv.processed_bytes(aid)
            if hashlib.sha256(back).hexdigest() != sha:
                raise _failed("ARCHIVE_REHASH_MISMATCH")
        else:
            # a mail attachment's archived copy is the evidence object itself (mail_exact_fetch); the id names the part
            aid = "mail-" + hashlib.sha256((inp["mail_message_id"] + "#" + inp["mime_part"]).encode()).hexdigest()[:40]
            aid = aid.translate(str.maketrans("0123456789", "ghijklmnop"))   # no digit run in a staged id (F-M0A-01)
        return "doc_archived", V.archived_payload(inp["discovery_id"], data, identity, aid, name)
    raise _failed("STEP")


def plan_discover(ctx):
    """items for DOC_DISCOVER: every file revision in the Inbox (the promoter ignores revisions it already knows)"""
    return ["drive:" + f["source_file_id"] for f in P.drive(ctx.config).list_inbox()]


JOBS = {"DOC_DISCOVER": doc_discover, "DOC_PROCESS": doc_process}
