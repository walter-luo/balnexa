"""Executor document validator: the transient SIN/ITN scan of zone Z1 (Addendum A1 Rev 1 §3, §5, §7 DOC-SIN-01/02/03/07).

Everything happens in memory: no temporary file is written by this module, and the OCR engine reads the image from stdin and
writes to stdout. The result is a verdict only (scan_result, rule codes, positional locators); no text, no value and no file
name ever leaves this module. Failure to extract or understand any part fails closed (SCAN_INCOMPLETE).

Formats: PDF, PNG, JPEG, XLSX, CSV, TXT, MD, EML, OFX/QFX. Archives, macro workbooks and unknown formats are refused.
"""
import email
import email.policy
import hashlib
import html
import io
import logging
import re
import shutil
import subprocess
import time
import warnings
import zipfile
import zlib

from . import sin_detector as S

MAX_BYTES = 25 * 1024 * 1024
MAX_DEPTH = 3
MAX_ZIP_MEMBERS = 2000
MAX_ZIP_TOTAL = 100 * 1024 * 1024
BUDGET_SECONDS = 120
TEXT_EXT = (".csv", ".txt", ".md", ".ofx", ".qfx")
OCR_CMD = ["tesseract"]          # replaced only by fault-injection tests (AT-SIN-30, AT-SIN-31)
MIME = {"pdf": "application/pdf", "png": "image/png", "jpeg": "image/jpeg", "eml": "message/rfc822",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
TEXT_MIME = {".csv": "text/csv", ".md": "text/markdown", ".ofx": "application/x-ofx", ".qfx": "application/x-ofx"}
for _lg in ("pypdf", "PIL", "openpyxl"):          # library log lines may quote document content (guard C3): silenced
    logging.getLogger(_lg).disabled = True
JS_MARKERS = (b"/JavaScript", b"/JS ", b"/JS(", b"/JS<", b"/Launch")


class _Scan:
    def __init__(self, deadline):
        self.rules, self.locators, self.incomplete, self.deadline, self.depth = set(), [], set(), deadline, 0

    def check(self, text, loc, origin="native", force_label=False, confidences=None):
        if time.monotonic() > self.deadline:
            self.incomplete.add("R_TIME_BUDGET")
            return
        if not text:
            return
        hits = S.scan(text, origin, confidences=confidences, force_label=force_label) if origin == "ocr" else \
            S.scan(text, origin, force_label=force_label)
        for h in hits:
            self.rules.add(h["rule"])
            if len(self.locators) < 200:
                self.locators.append({**loc, "offset": h["start"], "length": h["end"] - h["start"],
                                      **({"path_depth": self.depth} if self.depth else {})})

    def fail(self, code):
        self.incomplete.add(code)


def detect_format(data, name=None):
    n = (name or "").lower()
    if data.startswith(b"%PDF-"):
        return "pdf"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"PK\x03\x04"):
        try:
            names = set(zipfile.ZipFile(io.BytesIO(data)).namelist())
        except zipfile.BadZipFile:
            return "rejected:R_FORMAT_REJECTED"
        if "xl/workbook.xml" in names:
            return "rejected:R_MACRO_REJECTED" if any(x.lower().endswith("vbaproject.bin") for x in names) else "xlsx"
        return "rejected:R_ARCHIVE_REJECTED"
    if data[:2] in (b"\x1f\x8b", b"BZ") or data[:6] == b"7z\xbc\xaf\x27\x1c" or data[:4] == b"Rar!" or data[257:262] == b"ustar":
        return "rejected:R_ARCHIVE_REJECTED"
    head = data[:2048]
    if b"OFXHEADER" in head or b"<OFX>" in head.upper():
        return "text"
    if n.endswith(".eml") or re.match(rb"(?i)^(received|return-path|from|message-id|mime-version|date|subject|to):", head):
        return "eml"
    if n.endswith(TEXT_EXT) or (not n and b"\0" not in head):
        return "text"
    return "rejected:R_FORMAT_REJECTED"


def _decode_text(b):
    if b.startswith(b"\xef\xbb\xbf"):
        return b[3:].decode("utf-8", errors="replace")
    if b.startswith((b"\xff\xfe", b"\xfe\xff")):
        return b.decode("utf-16", errors="replace")
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b.decode("cp1252", errors="replace")


# ---------------------------------------------------------------------------------------------------------- OCR
def ocr_available():
    return shutil.which(OCR_CMD[0]) is not None


def ocr_image(sc, img, loc):
    """OCR one PIL image through tesseract stdin/stdout (TSV with word confidences); origin 'ocr'."""
    if not ocr_available():
        sc.fail("R_OCR_UNAVAILABLE")
        return
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="PNG")
    try:
        r = subprocess.run(OCR_CMD + ["stdin", "stdout", "--psm", "6", "tsv"], input=buf.getvalue(), capture_output=True,
                           timeout=max(1.0, sc.deadline - time.monotonic()), env={"PATH": "/usr/bin:/bin:/usr/local/bin", "OMP_THREAD_LIMIT": "1"})
    except subprocess.TimeoutExpired:
        sc.fail("R_OCR_TIMEOUT")
        return
    except OSError:
        sc.fail("R_OCR_UNAVAILABLE")
        return
    if r.returncode != 0:
        sc.fail("R_OCR_FAILED")
        return
    lines, conf = {}, {}
    for row in r.stdout.decode("utf-8", errors="replace").splitlines()[1:]:
        f = row.split("\t")
        if len(f) < 12 or f[0] != "5" or not f[11].strip():
            continue
        key = (int(f[2]), int(f[3]), int(f[4]))
        lines.setdefault(key, []).append((f[11], float(f[10]) / 100.0))
    for key in sorted(lines):
        text, cf = "", []
        for word, c in lines[key]:
            if text:
                text += " "; cf.append(c)
            text += word; cf.extend([c] * len(word))
        sc.check(text, {**loc, "kind": "ocr"}, origin="ocr", confidences=cf)


# ---------------------------------------------------------------------------------------------------------- images
def scan_image(sc, data, loc):
    from PIL import Image, IptcImagePlugin
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    meta = []
    try:
        for _k, v in img.getexif().items():
            meta.append(v.decode("latin-1", errors="replace") if isinstance(v, bytes) else str(v))
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    for k in ("xmp", "XML:com.adobe.xmp", "comment", "Description"):
        v = img.info.get(k)
        if v:
            meta.append(v.decode("utf-8", errors="replace") if isinstance(v, bytes) else str(v))
    for k, v in getattr(img, "text", {}).items():
        meta.append(f"{k} {v}")
    try:
        for v in (IptcImagePlugin.getiptcinfo(img) or {}).values():
            meta.append(v.decode("utf-8", errors="replace") if isinstance(v, bytes) else str(v))
    except Exception:  # noqa: BLE001
        pass
    for m in meta:
        sc.check(m, {**loc, "kind": "image_metadata"})
    ocr_image(sc, img, loc)


# ---------------------------------------------------------------------------------------------------------- PDF
# Two passes over a PDF (DELEGATED_DECISION D-9011c-2):
#  1. a carve pass over the raw file, independent of any cross-reference table: every string operand (literal and hex) in
#     the file and in every decoded stream, every metadata stream and every embedded file, including objects that no
#     revision references any more. Graphics operands (coordinates, widths) are never scanned: "100 600 300" in a /Rect
#     is not a nine-digit number.
#  2. a structural pass per revision (each %%EOF prefix): the text layer of every page (hidden layers, text under boxes),
#     annotations, form fields (a field named or described as a SIN field is labelled), Info and XMP metadata, attachments
#     and OCR of every page image.
_STREAM = re.compile(rb"stream\r?\n")
_FONT_KEYS = (b"/Length1", b"/Length2", b"/Length3", b"/Type1C", b"/CIDFontType0C", b"/OpenType")
_CONTENT_OPS = re.compile(rb"(?:^|\s)(?:BT|ET|Tj|TJ|Tf|re|cm|Do|BDC|EMC|q|Q)(?=\s|$)")


def pdf_strings(data, skip_comments=True):
    """String operands of a PDF byte sequence, decoded. Strings inside one array (a TJ array) are concatenated."""
    out, arr, i, n, depth_arr = [], None, 0, len(data), 0
    while i < n:
        c = data[i]
        if c == 0x25 and skip_comments:                                     # % comment
            j = data.find(b"\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == 0x28:                                                       # ( literal string )
            buf, lvl, i = bytearray(), 1, i + 1
            while i < n and lvl:
                ch = data[i]
                if ch == 0x5C and i + 1 < n:
                    e = data[i + 1]
                    if 0x30 <= e <= 0x37:
                        k = i + 1
                        while k < n and k < i + 4 and 0x30 <= data[k] <= 0x37:
                            k += 1
                        buf.append(int(data[i + 1:k], 8) & 0xFF); i = k; continue
                    buf += {0x6E: b"\n", 0x72: b"\r", 0x74: b"\t", 0x62: b"\b", 0x66: b"\f"}.get(e, bytes([e]) if e not in (0x0A, 0x0D) else b"")
                    i += 2; continue
                if ch == 0x28:
                    lvl += 1
                elif ch == 0x29:
                    lvl -= 1
                    if not lvl:
                        i += 1; break
                buf.append(ch); i += 1
            t = _pdf_text(bytes(buf))
        elif c == 0x3C and i + 1 < n and data[i + 1] != 0x3C:               # <hex string>
            j = data.find(b">", i)
            if j < 0:
                break
            hx = re.sub(rb"[^0-9A-Fa-f]", b"", data[i + 1:j])
            i = j + 1
            if len(hx) % 2:
                hx += b"0"
            try:
                t = _pdf_text(bytes.fromhex(hx.decode()))
            except ValueError:
                continue
        elif c == 0x3C:
            i += 2; continue
        elif c == 0x5B:
            depth_arr += 1
            if depth_arr == 1:
                arr = []
            i += 1; continue
        elif c == 0x5D:
            depth_arr = max(0, depth_arr - 1)
            if depth_arr == 0 and arr is not None:
                out.append("".join(arr)); arr = None
            i += 1; continue
        else:
            i += 1; continue
        if arr is not None:
            arr.append(t)
        else:
            out.append(t)
    if arr:
        out.append("".join(arr))
    return out


def _pdf_text(b):
    if b[:2] == b"\xfe\xff":
        return b[2:].decode("utf-16-be", errors="replace")
    if b[:3] == b"\xef\xbb\xbf":
        return b[3:].decode("utf-8", errors="replace")
    return b.decode("latin-1")


def _scan_strings(sc, strings, loc):
    """Each string is judged on its own context; strings are joined with a separator that no sequence can span."""
    if strings:
        sc.check(" | ".join(s for s in strings if s), loc)


def _carve_pdf(sc, data, depth):
    pos, gaps, k = 0, [], 0
    for m in _STREAM.finditer(data):
        if m.start() < pos:
            continue
        end = data.find(b"endstream", m.end())
        if end < 0:
            sc.fail("R_EXTRACTION_FAILED")
            break
        head = data[max(pos, m.start() - 2048):m.start()]
        d0 = head.rfind(b"<<")
        hdr = head[d0:] if d0 >= 0 else b""
        gaps.append(data[pos:m.start()])
        raw = data[m.end():end].rstrip(b"\r\n")
        pos = end + len(b"endstream")
        k += 1
        if b"/Image" in hdr and b"/Subtype" in hdr:
            continue                                                          # images: OCR in the structural pass
        body = raw
        if b"/FlateDecode" in hdr or b"/Fl " in hdr or b"/Fl]" in hdr:
            try:
                body = zlib.decompressobj().decompress(raw, MAX_BYTES)
            except zlib.error:
                sc.fail("R_EXTRACTION_FAILED")
                continue
        elif re.search(rb"/Filter\s*(\[\s*)?/(?!FlateDecode)", hdr):
            if b"/EmbeddedFile" in hdr or b"/Metadata" in hdr:
                sc.fail("R_FILTER_UNSUPPORTED")                            # an embedded file or metadata we cannot decode
            continue
        if b"/EmbeddedFile" in hdr:
            _scan(sc, body, None, depth + 1, {"part": "attachment", "kind": "embedded_file"})
        elif b"/Metadata" in hdr or body.lstrip()[:5] in (b"<?xpa", b"<x:xm"):
            sc.check(html.unescape(re.sub(r"<[^>]+>", " | ", body.decode("utf-8", errors="replace"))),
                     {"part": "document", "kind": "metadata_xmp"})
        elif any(f in hdr for f in _FONT_KEYS) or b"begincmap" in body[:4096]:
            continue                                                          # font programs and CMaps carry no document text
        elif b"/ObjStm" in hdr:
            _scan_strings(sc, pdf_strings(body), {"part": "object", "kind": "object_stream"})
        else:
            _scan_strings(sc, pdf_strings(body, skip_comments=False), {"part": "object", "kind": "stream_strings"})
            printable = sum(32 <= x < 127 or x in (9, 10, 13) for x in body[:65536])
            if body and printable > 0.95 * min(len(body), 65536) and not _CONTENT_OPS.search(body[:65536]):
                sc.check(_decode_text(body), {"part": "object", "kind": "stream_text"})   # plain text hidden in a stream
    gaps.append(data[pos:])
    _scan_strings(sc, pdf_strings(b"".join(gaps)), {"part": "object", "kind": "object_strings"})


def _pdf_str(v):
    try:
        if hasattr(v, "get_object"):
            v = v.get_object()
        return str(v)
    except Exception:  # noqa: BLE001
        return ""


def _scan_pdf_revision(sc, data, rev, depth, final, seen_images):
    from pypdf import PdfReader
    try:
        rd = PdfReader(io.BytesIO(data), strict=False)
        if rd.is_encrypted:
            sc.fail("R_ENCRYPTED")
            return
        pages = list(rd.pages)
    except Exception:  # noqa: BLE001
        if final:
            sc.fail("R_EXTRACTION_FAILED")
        return
    base = {"revision": rev}
    for i, pg in enumerate(pages):
        try:
            sc.check(pg.extract_text() or "", {**base, "part": "page", "page": i + 1, "kind": "text_layer"})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
        try:
            for a in (pg.get("/Annots") or []):
                a = a.get_object()
                for k in ("/Contents", "/T", "/RC", "/Subj", "/TU"):
                    if k in a:
                        sc.check(_pdf_str(a[k]), {**base, "part": "page", "page": i + 1, "kind": "annotation"})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
        try:
            for im in pg.images:
                h = hashlib.sha256(im.data).digest()
                if h in seen_images:
                    continue
                seen_images.add(h)
                from PIL import Image
                ocr_image(sc, Image.open(io.BytesIO(im.data)), {**base, "part": "page", "page": i + 1})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
    try:
        for name, f in (rd.get_fields() or {}).items():
            labelled = S.key_is_label(name) or S.key_is_label(_pdf_str(f.get("/TU", "")))
            for k in ("/V", "/DV", "/TU", "/T"):
                if k in f:
                    sc.check(_pdf_str(f[k]), {**base, "part": "form", "kind": "form_field"}, force_label=labelled and k in ("/V", "/DV"))
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    try:
        for k, v in (rd.metadata or {}).items():
            sc.check(f"{k} | {_pdf_str(v)}", {**base, "part": "document", "kind": "metadata_info"})
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    if final:
        try:
            for name, blobs in (rd.attachments or {}).items():
                for b in blobs:
                    _scan(sc, b, name, depth + 1, {"part": "attachment", "kind": "embedded_file", "revision": rev})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")


def scan_pdf(sc, data, depth):
    if any(m in data for m in JS_MARKERS):
        sc.fail("R_JS_REJECTED")
    if re.search(rb"/Encrypt\s", data):
        sc.fail("R_ENCRYPTED")
        return
    _carve_pdf(sc, data, depth)
    ends = [m.end() for m in re.finditer(rb"%%EOF", data)]
    if not ends:
        sc.fail("R_EXTRACTION_FAILED")
        ends = [len(data)]
    seen = set()
    for rev, e in enumerate(ends):
        _scan_pdf_revision(sc, data[:e] + b"\n", rev, depth, final=(rev == len(ends) - 1), seen_images=seen)


# ---------------------------------------------------------------------------------------------------------- XLSX
def scan_xlsx(sc, data, depth):
    import openpyxl
    zf = zipfile.ZipFile(io.BytesIO(data))
    infos = zf.infolist()
    if len(infos) > MAX_ZIP_MEMBERS or sum(i.file_size for i in infos) > MAX_ZIP_TOTAL or any(i.flag_bits & 0x1 for i in infos):
        sc.fail("R_LIMIT")
        return
    for i in infos:
        raw = zf.read(i)
        low = i.filename.lower()
        if low.endswith((".xml", ".rels", ".vml")):
            txt = html.unescape(re.sub(r"<[^>]+>", " | ", raw.decode("utf-8", errors="replace")))
            sc.check(txt, {"part": "member", "kind": "xlsx_part"})
        elif low.startswith(("xl/embeddings/", "xl/media/")):
            _scan(sc, raw, i.filename, depth + 1, {"part": "member", "kind": "embedded_object"})
        elif low.endswith(".bin"):
            sc.fail("R_EMBEDDED_UNSUPPORTED")
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=False, data_only=False)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    for si, ws in enumerate(wb.worksheets):                         # every sheet, hidden and very hidden included
        labelled_cols = set()
        for ri, row in enumerate(ws.iter_rows(), start=1):
            vals = ["" if c.value is None else str(c.value) for c in row]
            if ri == 1:
                labelled_cols = {ci for ci, v in enumerate(vals) if v and (S.key_is_label(v) or S.label_spans(S.fold(S.normalize(v)[0])))}
            sc.check(" | ".join(vals), {"part": "sheet", "page": si + 1, "kind": "cell_row"})
            for ci in labelled_cols:
                if ci < len(vals) and ri > 1:
                    sc.check(vals[ci], {"part": "sheet", "page": si + 1, "kind": "labelled_column"}, force_label=True)
            for c in row:
                if c.comment is not None:
                    sc.check(c.comment.text, {"part": "sheet", "page": si + 1, "kind": "comment"})
    try:
        for name, dn in wb.defined_names.items():
            sc.check(f"{name} {dn.attr_text}", {"part": "workbook", "kind": "defined_name"})
    except Exception:  # noqa: BLE001
        pass
    p = wb.properties
    for k in ("title", "subject", "creator", "keywords", "description", "category", "lastModifiedBy", "identifier", "contentStatus"):
        sc.check(str(getattr(p, k, "") or ""), {"part": "workbook", "kind": "property"})


# ---------------------------------------------------------------------------------------------------------- EML
def scan_eml(sc, data, depth):
    try:
        msg = email.message_from_bytes(data, policy=email.policy.default)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    for k, v in msg.raw_items():
        sc.check(f"{k}: {v}", {"part": "message", "kind": "eml_header"})
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        try:
            payload = part.get_payload(decode=True)
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
            continue
        if ctype == "message/rfc822":
            inner = part.get_payload()
            inner = inner[0] if isinstance(inner, list) else inner
            _scan(sc, inner.as_bytes() if hasattr(inner, "as_bytes") else bytes(inner), "inner.eml", depth + 1,
                  {"part": "message", "kind": "eml_nested"})
            continue
        if payload is None:
            continue
        fname = part.get_filename()
        if ctype.startswith("text/") and not fname:
            txt = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
            if ctype == "text/html":
                sc.check(html.unescape(re.sub(r"<[^>]+>", " | ", txt)), {"part": "message", "kind": "eml_part"})
            sc.check(txt, {"part": "message", "kind": "eml_part"})
        else:
            _scan(sc, payload, fname or "attachment", depth + 1, {"part": "message", "kind": "eml_attachment"})


# ---------------------------------------------------------------------------------------------------------- dispatch
def _scan(sc, data, name, depth, loc=None):
    if depth > MAX_DEPTH:
        sc.fail("R_LIMIT")
        return
    if len(data) > MAX_BYTES:
        sc.fail("R_SIZE_LIMIT")
        return
    fmt = detect_format(data, name)
    outer, sc.depth = sc.depth, depth
    try:
        if fmt.startswith("rejected:"):
            sc.fail(fmt.split(":", 1)[1])
        elif fmt == "pdf":
            scan_pdf(sc, data, depth)
        elif fmt in ("png", "jpeg"):
            scan_image(sc, data, loc or {"part": "image"})
        elif fmt == "xlsx":
            scan_xlsx(sc, data, depth)
        elif fmt == "eml":
            scan_eml(sc, data, depth)
        else:
            sc.check(_decode_text(data), loc or {"part": "document", "kind": "text"})
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    finally:
        sc.depth = outer


def validate(data, name=None, budget_seconds=BUDGET_SECONDS):
    """Transient scan of one file (Z1). Returns the verdict; never text, values or the file name."""
    sc = _Scan(time.monotonic() + budget_seconds)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        _scan(sc, bytes(data), name, 0)
    result = "SIN_CANDIDATE" if sc.rules else ("SCAN_INCOMPLETE" if sc.incomplete else "PASSED")
    return {"sha256": hashlib.sha256(data).hexdigest(), "sin_detector_version": S.VERSION, "scan_result": result,
            "rule_codes": sorted(sc.rules | sc.incomplete), "locators": sc.locators}


# ---------------------------------------------------------------------------------------------------------- staging payloads
def discovered_payload(identity, name, module, period_key=None):
    """doc_discovered (9011b). The file name is sent only when it holds no candidate (D-9011b-5)."""
    p = {**identity, "module": module}
    if period_key:
        p["period_key"] = period_key
    if name and not S.candidate(name):
        p["original_name"] = name
    return p


def validated_payload(discovery_id, data, name=None, doc_class=None, class_uncertain=True, sin_bearing=False):
    v = validate(data, name)
    return {"discovery_id": discovery_id, "sha256": v["sha256"], "sin_detector_version": v["sin_detector_version"],
            "scan_result": v["scan_result"], "rule_codes": v["rule_codes"], "locators": v["locators"],
            "doc_class": doc_class, "class_uncertain": class_uncertain, "sin_bearing": sin_bearing}


def mime_of(data, name=None):
    fmt = detect_format(data, name)
    if fmt == "text":
        n = (name or "").lower()
        return next((m for e, m in TEXT_MIME.items() if n.endswith(e)), "text/plain")
    return MIME.get(fmt)


def archived_payload(discovery_id, refetched, identity, archived_file_id, name=None):
    """doc_archived (9011b admission gate): the hash, size and type of the bytes fetched again for archiving, and the identity
    they came from. The database registers the evidence object from these (9011c)."""
    return {"discovery_id": discovery_id, "sha256": hashlib.sha256(refetched).hexdigest(), "archived_file_id": archived_file_id,
            "size_bytes": len(refetched), "mime": mime_of(refetched, name),
            **{k: identity.get(k) for k in ("source_file_id", "head_revision_id", "md5", "mail_message_id", "mime_part") if identity.get(k)}}
