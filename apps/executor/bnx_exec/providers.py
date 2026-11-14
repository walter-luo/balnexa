# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""External providers of the Executor (TST-5; WP matrix V1.2 phase 2.1).

The Executor reads documents from the instance's Drive (Inbox, Processed), shared-index sheets (Google Sheets, CSV or
Markdown in Drive) and mailboxes (Gmail, Microsoft Graph). Each provider has a narrow interface. Two implementations exist:

* ``Mock*`` classes, backed by a local directory (``BNX_MOCK_ROOT``). They implement the same contract the real services are
  expected to honour (revision ids, md5, folders, message ids) so that the jobs, the database contracts and the end-to-end
  tests run without any cloud account. Synthetic data only.
* ``Google*`` / ``Graph*`` placeholders that raise ``ProviderNotConfigured``. The real clients need the dedicated Drive
  identity (OD-50), mail credentials and index locations that the M0-B gate authorizes; they are written there, against
  the same interface, and qualified by PV-DRV-01 and M0-B-01…08.

Nothing here logs file names, contents, addresses or message bodies (guard C3); callers log ids and counts only.
"""
import csv
import email
import email.message
import email.policy
import email.utils
import hashlib
import io
import json
import os
import re
import secrets
import time


class ProviderNotConfigured(Exception):
    """the real provider needs a cloud identity or credential that is not authorized in this deployment"""


class ProviderError(Exception):
    """a provider call failed; the code names the step, never the content"""


_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_FOLDER = re.compile(r"^[A-Za-z0-9_./-]{1,120}$")


def _check_id(v, what):
    if not isinstance(v, str) or not _ID.match(v):
        raise ProviderError(f"BAD_{what.upper()}")
    return v


def _new_id(prefix):
    # letters only: provider ids end up in staged payloads, and the staging guard refuses Luhn-valid digit runs (F-M0A-01)
    return prefix + "".join(secrets.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(24))


def _read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


# ------------------------------------------------------------------------------------------------------------------ Drive
class DriveProvider:
    """Inbox listing, revision fetch and the Processed copy (UA V1.2 §10; Addendum A1 Rev 1 §5)."""

    def list_inbox(self):
        """-> [{source_file_id, head_revision_id, md5, size_bytes, source_mtime, name, module, period_key}]"""
        raise NotImplementedError

    def fetch(self, file_id, revision_id):
        """-> bytes of exactly that revision; ProviderError('REVISION_GONE') when the head moved on"""
        raise NotImplementedError

    def head(self, file_id):
        """-> the current identity of the file (same keys as list_inbox), or None when it was removed"""
        raise NotImplementedError

    def copy_to_processed(self, file_id, revision_id, data, name):
        """write the archived copy; -> archived_file_id. Idempotent for the same (file, revision, bytes)."""
        raise NotImplementedError

    def processed_bytes(self, archived_file_id):
        """read the archived copy back (re-hash after the copy)"""
        raise NotImplementedError


class MockDrive(DriveProvider):
    """Directory layout under ``root``:
        drive/inbox.json                 {file_id: {name, module, period_key, revisions: [{rev, md5, size, mtime}]}}
        drive/blobs/<file_id>/<rev>      bytes of a revision
        drive/processed.json             {archived_file_id: {source_file_id, rev, sha256, name}}
        drive/processed/<archived_id>    bytes of the archived copy
    ``put_inbox`` adds a file or a new revision (tests and the fixture generator)."""

    def __init__(self, root):
        self.root = os.path.join(os.path.abspath(root), "drive")

    def _inbox(self):
        return _read_json(os.path.join(self.root, "inbox.json"), {})

    def put_inbox(self, data, name, module="FINANCE", period_key=None, file_id=None):
        inbox = self._inbox()
        fid = file_id or _new_id("drv")
        _check_id(fid, "file_id")
        ent = inbox.setdefault(fid, {"name": name, "module": module, "period_key": period_key, "revisions": []})
        ent["name"] = name
        rev = _new_id("rev")
        md5 = hashlib.md5(data).hexdigest()   # noqa: S324 - Drive's own content checksum, compared, never trusted for integrity
        os.makedirs(os.path.join(self.root, "blobs", fid), exist_ok=True)
        with open(os.path.join(self.root, "blobs", fid, rev), "wb") as f:
            f.write(data)
        ent["revisions"].append({"rev": rev, "md5": md5, "size": len(data),
                                 "mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        _write_json(os.path.join(self.root, "inbox.json"), inbox)
        return {"source_file_id": fid, "head_revision_id": rev, "md5": md5}

    def remove_inbox(self, file_id):
        inbox = self._inbox()
        inbox.pop(file_id, None)
        _write_json(os.path.join(self.root, "inbox.json"), inbox)

    def _ident(self, fid, ent):
        r = ent["revisions"][-1]
        return {"source_file_id": fid, "head_revision_id": r["rev"], "md5": r["md5"], "size_bytes": r["size"],
                "source_mtime": r["mtime"], "name": ent["name"], "module": ent["module"], "period_key": ent.get("period_key")}

    def list_inbox(self):
        return [self._ident(fid, ent) for fid, ent in sorted(self._inbox().items()) if ent["revisions"]]

    def head(self, file_id):
        ent = self._inbox().get(file_id)
        return self._ident(file_id, ent) if ent and ent["revisions"] else None

    def fetch(self, file_id, revision_id):
        _check_id(file_id, "file_id")
        _check_id(revision_id, "revision_id")
        p = os.path.join(self.root, "blobs", file_id, revision_id)
        if not os.path.exists(p):
            raise ProviderError("REVISION_GONE")
        with open(p, "rb") as f:
            return f.read()

    def copy_to_processed(self, file_id, revision_id, data, name):
        idx = _read_json(os.path.join(self.root, "processed.json"), {})
        sha = hashlib.sha256(data).hexdigest()
        for aid, ent in idx.items():
            if ent["source_file_id"] == file_id and ent["rev"] == revision_id and ent["sha256"] == sha:
                return aid
        aid = _new_id("arc")
        os.makedirs(os.path.join(self.root, "processed"), exist_ok=True)
        with open(os.path.join(self.root, "processed", aid), "wb") as f:
            f.write(data)
        idx[aid] = {"source_file_id": file_id, "rev": revision_id, "sha256": sha, "name": name}
        _write_json(os.path.join(self.root, "processed.json"), idx)
        return aid

    def processed_bytes(self, archived_file_id):
        _check_id(archived_file_id, "archived_file_id")
        p = os.path.join(self.root, "processed", archived_file_id)
        if not os.path.exists(p):
            raise ProviderError("ARCHIVE_MISSING")
        with open(p, "rb") as f:
            return f.read()


class GoogleDrive(DriveProvider):
    def __init__(self, *a, **kw):
        raise ProviderNotConfigured("drive: dedicated instance identity (OD-50) is authorized at M0-B")


# ---------------------------------------------------------------------------------------------------------- shared index
# bnx-shared-index-consumer/1.0 column contract (the database checks it, 9010 wrk_consume_shared_index)
INDEX_COLUMNS = ["File ID", "Original Name", "Current Name", "Document Date", "Processed Date", "Domain", "Type", "Tags", "Source",
                 "Sensitivity", "Status", "Summary", "Record Path", "Related Open Item", "Notes"]


class IndexProvider:
    """The upstream shared index (bnx-shared-index-consumer/1.0): tabs Records, Open_Items, Run_Log."""

    def read(self, location):
        """-> {header: [...], records: [{col: value}], open_items: [{key}], run_log: [...]}"""
        raise NotImplementedError


class MockIndex(IndexProvider):
    """``index/<location>.json`` with the three tabs, or ``index/<location>.csv`` (Records only, CSV_IN_DRIVE adapter) or
    ``index/<location>.md`` (a Markdown table, MARKDOWN_TABLE adapter)."""

    def __init__(self, root):
        self.root = os.path.join(os.path.abspath(root), "index")

    def put(self, location, records, open_items=(), run_log=(), header=None, fmt="json"):
        if not _FOLDER.match(location):
            raise ProviderError("BAD_LOCATION")
        header = list(header or INDEX_COLUMNS)
        os.makedirs(self.root, exist_ok=True)
        if fmt == "json":
            _write_json(os.path.join(self.root, location + ".json"),
                        {"header": header, "records": list(records), "open_items": list(open_items), "run_log": list(run_log)})
        elif fmt == "csv":
            with open(os.path.join(self.root, location + ".csv"), "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=header)
                w.writeheader()
                for r in records:
                    w.writerow({k: r.get(k, "") for k in header})
        elif fmt == "md":
            lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
            for r in records:
                lines.append("| " + " | ".join(str(r.get(k, "")).replace("|", "/") for k in header) + " |")
            with open(os.path.join(self.root, location + ".md"), "w") as f:
                f.write("\n".join(lines) + "\n")
        else:
            raise ProviderError("BAD_FORMAT")

    def read(self, location):
        if not _FOLDER.match(location):
            raise ProviderError("BAD_LOCATION")
        base = os.path.join(self.root, location)
        if os.path.exists(base + ".json"):
            d = _read_json(base + ".json", {})
            return {"header": d.get("header", []), "records": d.get("records", []), "open_items": d.get("open_items", []),
                    "run_log": d.get("run_log", [])}
        if os.path.exists(base + ".csv"):
            with open(base + ".csv", newline="") as f:
                rd = csv.DictReader(f)
                return {"header": list(rd.fieldnames or []), "records": [dict(r) for r in rd], "open_items": [], "run_log": []}
        if os.path.exists(base + ".md"):
            return parse_markdown_table(open(base + ".md").read())
        raise ProviderError("INDEX_NOT_FOUND")


def parse_markdown_table(text):
    rows = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("|")]
    if len(rows) < 2:
        return {"header": [], "records": [], "open_items": [], "run_log": []}
    cells = lambda ln: [c.strip() for c in ln.strip("|").split("|")]   # noqa: E731
    header = cells(rows[0])
    body = [r for r in rows[1:] if not re.fullmatch(r"\|?(\s*:?-+:?\s*\|)+\s*", r)]
    return {"header": header, "records": [dict(zip(header, cells(r))) for r in body], "open_items": [], "run_log": []}


class GoogleSheetsIndex(IndexProvider):
    def __init__(self, *a, **kw):
        raise ProviderNotConfigured("shared index: read access to the upstream sheet needs the Owner's authorization")


# ------------------------------------------------------------------------------------------------------------------- mail
class MailProvider:
    """Exact retrieval by RFC 5322 Message-ID and the folder move (OR-EML-03…06; Gmail and Microsoft Graph)."""

    def fetch_exact(self, message_id):
        """-> {provider_message_id, raw (bytes of the .eml), folder_ref, received_at} or None when not found"""
        raise NotImplementedError

    def move(self, provider_message_id, folder_ref):
        """-> True when the message is now in folder_ref"""
        raise NotImplementedError


class MockMailbox(MailProvider):
    """``mail/<source_ref>/index.json`` {provider_message_id: {message_id, folder, received_at}} and
    ``mail/<source_ref>/<provider_message_id>.eml``."""

    def __init__(self, root, source_ref):
        if not re.fullmatch(r"mbx-[a-z0-9-]{3,40}", source_ref or ""):
            raise ProviderError("BAD_SOURCE_REF")
        self.root = os.path.join(os.path.abspath(root), "mail", source_ref)

    def _idx(self):
        return _read_json(os.path.join(self.root, "index.json"), {})

    def put(self, raw, folder="INBOX", received_at=None):
        msg = email.message_from_bytes(raw, policy=email.policy.default)
        mid = (msg.get("Message-ID") or "").strip()
        if not mid:
            raise ProviderError("NO_MESSAGE_ID")
        idx = self._idx()
        pid = _new_id("msg")
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, pid + ".eml"), "wb") as f:
            f.write(raw)
        idx[pid] = {"message_id": mid, "folder": folder,
                    "received_at": received_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        _write_json(os.path.join(self.root, "index.json"), idx)
        return pid

    def fetch_exact(self, message_id):
        for pid, ent in sorted(self._idx().items()):
            if ent["message_id"] == message_id:
                with open(os.path.join(self.root, pid + ".eml"), "rb") as f:
                    return {"provider_message_id": pid, "raw": f.read(), "folder_ref": ent["folder"], "received_at": ent["received_at"]}
        return None

    def move(self, provider_message_id, folder_ref):
        if not _FOLDER.match(folder_ref or ""):
            raise ProviderError("BAD_FOLDER")
        idx = self._idx()
        if provider_message_id not in idx:
            return False
        idx[provider_message_id]["folder"] = folder_ref
        _write_json(os.path.join(self.root, "index.json"), idx)
        return True

    def folder_of(self, provider_message_id):
        return self._idx().get(provider_message_id, {}).get("folder")


class GmailMailbox(MailProvider):
    def __init__(self, *a, **kw):
        raise ProviderNotConfigured("gmail: the mailbox credential is authorized per source (credential_state)")


class GraphMailbox(MailProvider):
    def __init__(self, *a, **kw):
        raise ProviderNotConfigured("outlook: the Microsoft Graph credential is authorized per source (credential_state)")


# --------------------------------------------------------------------------------------------------------------- factory
def drive(config):
    if getattr(config, "mock_root", None):
        return MockDrive(config.mock_root)
    return GoogleDrive()


def index(config):
    if getattr(config, "mock_root", None):
        return MockIndex(config.mock_root)
    return GoogleSheetsIndex()


def mailbox(config, source_ref, provider):
    if getattr(config, "mock_root", None):
        return MockMailbox(config.mock_root, source_ref)
    return GmailMailbox() if provider == "gmail" else GraphMailbox()


def eml_bytes(sender, to, subject, message_id, body="Synthetic statement notice.", attachments=()):
    """a synthetic message for tests and the fixture generator"""
    m = email.message.EmailMessage()
    m["From"], m["To"], m["Subject"], m["Message-ID"] = sender, to, subject, message_id
    m["Date"] = email.utils.formatdate(localtime=False)
    m.set_content(body)
    for name, data, mime in attachments:
        main, sub = mime.split("/", 1)
        m.add_attachment(data, maintype=main, subtype=sub, filename=name)
    buf = io.BytesIO()
    buf.write(m.as_bytes(policy=email.policy.SMTP))
    return buf.getvalue()

