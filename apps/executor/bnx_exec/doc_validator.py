"""Executor document validator: the transient SIN/ITN scan of zone Z1 (Addendum A1 Rev 1 §3, §5, §7 DOC-SIN-01/02/03/07).

Everything happens in memory: no temporary file is written by this module, and the OCR engine reads the image from stdin and
writes to stdout. The result is a verdict only (scan_result, rule codes, positional locators); no text, no value and no file
name ever leaves this module. Failure to extract or understand any part fails closed (SCAN_INCOMPLETE).

9011R (review of 2026-11-11, findings R-18...R-40): the scan runs in a forked child process with a hard memory limit and a
hard wall-clock limit, library logging disabled and the child's stderr discarded through a pipe (R-18...R-21). Every reader
either reads a part completely or fails closed: PDF objects are parsed (not guessed from header text), every stream filter is
decoded, every image is OCRed, pages are also rendered and OCRed, page text is read in stream and layout order, comments and
data outside objects are read; XLSX parts are parsed as XML (text, attributes, comments), unknown members are read by format,
formulas without a cached value fail closed and number formats are rendered; e-mail headers are decoded in every part;
images are read frame by frame with all metadata segments, alpha flattened and orientations tried; text is read in every
encoding that decodes cleanly; the file name never overrides the bytes (docs/s4/S4_9011R_Remediation_2026-11-11.md).

Formats: PDF, PNG, JPEG, XLSX, CSV, TXT, MD, EML, OFX/QFX. Archives, macro workbooks and unknown formats are refused.
"""
import email
import email.policy
import hashlib
import html
import io
import json
import logging
import os
import re
import select
import shutil
import signal
import struct
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
MAX_STREAM_OUT = 64 * 1024 * 1024        # decoded bytes per PDF stream; more fails closed (R_LIMIT), never a silent cut
MAX_DECODED_TOTAL = 256 * 1024 * 1024    # decoded bytes per document
MAX_IMAGES = 300
MAX_FRAMES = 50
MAX_PAGES_RENDER = 100
MAX_PIXELS = 60_000_000
MEM_LIMIT = 3 * 1024 * 1024 * 1024       # address space of the scan child (R-19)
BUDGET_SECONDS = 120
GRACE_SECONDS = 3                        # the child reports its own budget breaches; the parent kills it after this grace
RENDER_SCALE = 2.0                       # 144 dpi
TEXT_EXT = (".csv", ".txt", ".md", ".ofx", ".qfx")
OCR_CMD = ["tesseract"]                  # replaced only by fault-injection tests (AT-SIN-30, AT-SIN-31)
MIME = {"pdf": "application/pdf", "png": "image/png", "jpeg": "image/jpeg", "eml": "message/rfc822",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
TEXT_MIME = {".csv": "text/csv", ".md": "text/markdown", ".ofx": "application/x-ofx", ".qfx": "application/x-ofx"}
SEP = " | "                              # joins independent strings: '|' links no digit groups (detector v1.1)


class _Scan:
    def __init__(self, deadline):
        self.rules, self.locators, self.incomplete, self.deadline, self.depth = set(), [], set(), deadline, 0
        self.decoded, self.images, self.seen_images = 0, 0, set()

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

    def check_variants(self, texts, loc, force_label=False):
        seen = set()
        for t in texts:
            if t and t not in seen:
                seen.add(t)
                self.check(t, loc, force_label=force_label)

    def fail(self, code):
        self.incomplete.add(code)

    def account(self, n):
        self.decoded += n
        if self.decoded > MAX_DECODED_TOTAL:
            self.fail("R_LIMIT")
            return False
        return True

    def timed_out(self):
        if time.monotonic() > self.deadline:
            self.incomplete.add("R_TIME_BUDGET")
            return True
        return False


# ---------------------------------------------------------------------------------------------------------- format sniffing
_IMG_OTHER = ((b"GIF87a", "GIF"), (b"GIF89a", "GIF"), (b"II*\x00", "TIFF"), (b"MM\x00*", "TIFF"), (b"BM", "BMP"))
_MAGIC_ANY = (b"%PDF-", b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"PK\x03\x04", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1",
              b"GIF87a", b"GIF89a", b"Rar!", b"7z\xbc\xaf\x27\x1c", b"\x1f\x8b")


def detect_format(data, name=None):
    """The bytes decide; the file name only chooses between text kinds (R-40)."""
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
        except Exception:  # noqa: BLE001
            return "rejected:R_FORMAT_REJECTED"
        if "xl/workbook.xml" in names:
            return "rejected:R_MACRO_REJECTED" if any(x.lower().endswith("vbaproject.bin") for x in names) else "xlsx"
        return "rejected:R_ARCHIVE_REJECTED"
    if data[:2] in (b"\x1f\x8b", b"BZ") or data[:6] == b"7z\xbc\xaf\x27\x1c" or data[:4] == b"Rar!" or data[257:262] == b"ustar":
        return "rejected:R_ARCHIVE_REJECTED"
    if any(data.startswith(m) for m, _k in _IMG_OTHER) or (data[:4] == b"RIFF" and data[8:12] == b"WEBP") \
            or data.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
        return "rejected:R_FORMAT_REJECTED"                                  # images and OLE files not accepted (R-40)
    head = data[:1024]
    if b"%PDF-" in head:
        return "pdf"                                                         # a PDF may carry junk before its header
    if any(m in head[1:] for m in _MAGIC_ANY if m != b"%PDF-") or b"PK\x03\x04" in data[:65536]:
        return "rejected:R_FORMAT_REJECTED"                                  # a binary format behind a prefix (SFX, junk)
    if _binary(data):
        return "rejected:R_FORMAT_REJECTED"
    if head.lstrip()[:5] == b"{\\rtf":
        return "rejected:R_FORMAT_REJECTED"                                  # RTF hides text in escapes: not accepted
    if b"OFXHEADER" in head or b"<OFX>" in head.upper():
        return "text"
    if re.match(rb"(?i)^(received|return-path|from|message-id|mime-version|date|subject|to|delivered-to|x-[a-z-]+):", data[:2048]):
        return "eml"
    if n.endswith(".eml"):
        return "text"                                                        # named .eml but not a message: read as text
    if n.endswith(TEXT_EXT) or not n:
        return "text"
    return "rejected:R_FORMAT_REJECTED"


def _utf16_shape(b):
    s = b[:4096]
    if len(s) < 4:
        return None
    ev, od = s[0::2], s[1::2]
    if od.count(0) > 0.3 * len(od) and ev.count(0) < 0.1 * len(ev):
        return "utf-16-le"
    if ev.count(0) > 0.3 * len(ev) and od.count(0) < 0.1 * len(od):
        return "utf-16-be"
    return None


def _binary(data):
    """Text must decode: NUL bytes only in a UTF-16/32 shape."""
    s = data[:65536]
    if b"\0" not in s:
        return False
    return not (s.startswith((b"\xff\xfe", b"\xfe\xff", b"\x00\x00\xfe\xff")) or _utf16_shape(s))


# ---------------------------------------------------------------------------------------------------------- text decodings
_ENCODINGS = ("utf-8", "gb18030", "big5", "shift_jis", "cp1252")


def text_variants(b):
    """Every decoding of b that is clean (R-39), plus UTF-8 with replacement (a stray byte must not hide an accented label)."""
    out = []
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    if b.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        try:
            return [b.decode("utf-32")]
        except UnicodeDecodeError:
            return [b.decode("utf-32", errors="replace")]
    if b.startswith((b"\xff\xfe", b"\xfe\xff")):
        return [b.decode("utf-16", errors="replace")]
    sh = _utf16_shape(b)
    if sh:
        out.append(b.decode(sh, errors="replace"))
    out.append(b.decode("utf-8", errors="replace"))
    if any(x >= 0x80 for x in b[:1 << 20]):
        for enc in _ENCODINGS[1:]:
            try:
                out.append(b.decode(enc))
            except UnicodeDecodeError:
                pass
    return out


def _decode_text(b):
    return text_variants(b)[0]


def check_bytes(sc, b, loc, force_label=False):
    sc.check_variants(text_variants(b), loc, force_label=force_label)


# ---------------------------------------------------------------------------------------------------------- OCR
def ocr_available():
    return shutil.which(OCR_CMD[0]) is not None


def _pdeathsig():
    try:
        import ctypes
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)       # PR_SET_PDEATHSIG
    except Exception:  # noqa: BLE001
        pass


def _ocr_run(sc, img):
    """One tesseract pass on a PIL image; returns [(line_text, confidences)] or None after a failure."""
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    try:
        r = subprocess.run(OCR_CMD + ["stdin", "stdout", "--psm", "6", "tsv"], input=buf.getvalue(), capture_output=True,
                           timeout=max(1.0, sc.deadline - time.monotonic()), preexec_fn=_pdeathsig,
                           env={"PATH": "/usr/bin:/bin:/usr/local/bin", "OMP_THREAD_LIMIT": "1"})
    except subprocess.TimeoutExpired:
        sc.fail("R_OCR_TIMEOUT")
        return None
    except OSError:
        sc.fail("R_OCR_UNAVAILABLE")
        return None
    if r.returncode != 0:
        sc.fail("R_OCR_FAILED")
        return None
    lines = {}
    for row in r.stdout.decode("utf-8", errors="replace").splitlines()[1:]:
        f = row.split("\t")
        if len(f) < 12 or f[0] != "5" or not f[11].strip():
            continue
        lines.setdefault((int(f[2]), int(f[3]), int(f[4])), []).append((f[11], float(f[10]) / 100.0))
    out = []
    for key in sorted(lines):
        text, cf = "", []
        for word, c in lines[key]:
            if text:
                text += " "; cf.append(c)
            text += word; cf.extend([c] * len(word))
        out.append((text, cf))
    return out


def _flatten(img, background):
    from PIL import Image
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        bg = Image.new("RGBA", rgba.size, background)
        bg.alpha_composite(rgba)
        return bg.convert("RGB"), True
    return img.convert("RGB"), False


def _confident_words(lines):
    """Words of two or more characters, with a letter or digit, recognised with a mean confidence of at least 0.85."""
    n = 0
    for t, cf in lines or []:
        k = 0
        for w in t.split(" "):
            c = cf[k:k + len(w)]
            if len(w) >= 2 and any(ch.isalnum() for ch in w) and c and sum(c) / len(c) >= 0.85:
                n += 1
            k += len(w) + 1
    return n


def ocr_image(sc, img, loc, origin="ocr", require_text=False, orientations=True):
    """OCR one PIL image through tesseract stdin/stdout (TSV with word confidences). Alpha is flattened on white and on
    black, EXIF orientation is applied, and when little text is found the image is also read at 90/180/270 degrees and
    mirrored (R-38). require_text: the image is the whole document, so no recognisable text at all fails closed."""
    from PIL import ImageOps
    if not ocr_available():
        sc.fail("R_OCR_UNAVAILABLE")
        return
    try:
        img = ImageOps.exif_transpose(img)
    except Exception:  # noqa: BLE001
        pass
    bases = []
    rgb, had_alpha = _flatten(img, (255, 255, 255, 255))
    bases.append(rgb)
    if had_alpha:
        bases.append(_flatten(img, (0, 0, 0, 255))[0])
    best = 0
    for b in bases:
        lines = _ocr_run(sc, b)
        if lines is None:
            return
        best = max(best, _confident_words(lines))
        for text, cf in lines:
            sc.check(text, {**loc, "kind": "ocr"}, origin=origin, confidences=cf if origin == "ocr" else None)
    if best < 3 and orientations:
        for b in bases:
            for t in ("r90", "r180", "r270", "mirror", "skew+", "skew-"):
                if sc.timed_out():
                    return
                if t.startswith("skew") and best >= 3:
                    break                                                    # small skew only when no orientation read
                v = {"r90": lambda x: x.rotate(90, expand=True), "r180": lambda x: x.rotate(180, expand=True),
                     "r270": lambda x: x.rotate(270, expand=True), "mirror": ImageOps.mirror,
                     "skew+": lambda x: x.rotate(12, expand=True, fillcolor="white"),
                     "skew-": lambda x: x.rotate(-12, expand=True, fillcolor="white")}[t](b)
                lines = _ocr_run(sc, v)
                if lines is None:
                    return
                best = max(best, _confident_words(lines))
                for text, cf in lines:
                    sc.check(text, {**loc, "kind": "ocr", "part": loc.get("part", "image")}, origin=origin,
                             confidences=cf if origin == "ocr" else None)
    if require_text and best == 0:
        sc.fail("R_OCR_NO_TEXT")


# ---------------------------------------------------------------------------------------------------------- images
_EXIF_IFDS = (0x8769, 0x8825, 0xA005)      # Exif, GPS, Interop
_XP_TAGS = (0x9C9B, 0x9C9C, 0x9C9D, 0x9C9E, 0x9C9F)


def _meta_value(v):
    if isinstance(v, bytes):
        return text_variants(v) + [v.decode("utf-16-le", errors="replace")]
    if isinstance(v, tuple):
        return [" ".join(str(x) for x in v)]
    return [str(v)]


def _jpeg_segments(data):
    """APPn and COM payloads of a JPEG, and the bytes after the last EOI (R-37)."""
    segs, i, n = [], 2, len(data)
    while i + 4 <= n and data[i] == 0xFF:
        mk = data[i + 1]
        if mk == 0xFF:
            i += 1; continue
        if mk in (0xD8, 0x01) or 0xD0 <= mk <= 0xD7:
            i += 2; continue
        ln = struct.unpack(">H", data[i + 2:i + 4])[0]
        if 0xE0 <= mk <= 0xEF or mk == 0xFE:
            segs.append(data[i + 4:i + 2 + ln])
        if mk == 0xDA:                                                      # start of scan: entropy data follows
            break
        i += 2 + ln
    e = data.rfind(b"\xff\xd9")
    tail = data[e + 2:] if e >= 0 else b""
    return segs, tail


def _png_chunks(data):
    out, i, n, tail = [], 8, len(data), b""
    while i + 12 <= n:
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + ln]
        if typ == b"IEND":
            tail = data[i + 12 + ln:]
            break
        if typ == b"zTXt":
            k = body.find(b"\0")
            try:
                out.append(body[:k] + b" " + zlib.decompress(body[k + 2:]))
            except zlib.error:
                out.append(body)
        elif typ == b"iTXt":
            k = body.find(b"\0")
            comp = body[k + 1:k + 2] == b"\x01"
            rest = body[k + 3:]
            parts = rest.split(b"\0", 2)
            txt = parts[2] if len(parts) == 3 else rest
            if comp:
                try:
                    txt = zlib.decompress(txt)
                except zlib.error:
                    pass
            out.append(body[:k] + b" " + b" ".join(parts[:2]) + b" " + txt)
        elif typ[0:1].islower() and typ not in (b"pHYs", b"gAMA", b"cHRM", b"sRGB", b"bKGD", b"tRNS", b"sBIT", b"hIST", b"tIME", b"sPLT"):
            out.append(body)                                                # tEXt, eXIf, iCCP and private ancillary chunks
        i += 12 + ln
    return out, tail


def scan_image(sc, data, loc, depth=0, require_text=True):
    from PIL import Image, IptcImagePlugin
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            img = Image.open(io.BytesIO(data))
            img.load()
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        sc.fail("R_LIMIT")
        return
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    meta = []
    try:
        ex = img.getexif()
        for _k, v in ex.items():
            meta += _meta_value(v)
        for ifd in _EXIF_IFDS:
            try:
                for _k, v in ex.get_ifd(ifd).items():
                    meta += _meta_value(v)
            except KeyError:
                continue                                                     # that IFD is absent
            except Exception:  # noqa: BLE001
                sc.fail("R_EXTRACTION_FAILED")
        for t in _XP_TAGS:
            if t in ex and isinstance(ex[t], (bytes, tuple)):
                raw = bytes(ex[t]) if isinstance(ex[t], tuple) else ex[t]
                meta.append(raw.decode("utf-16-le", errors="replace"))
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    for k in ("xmp", "XML:com.adobe.xmp", "comment", "Description", "exif"):
        v = img.info.get(k)
        if v:
            meta += _meta_value(v)
    for k, v in getattr(img, "text", {}).items():
        meta.append(f"{k} {v}")
    try:
        for v in (IptcImagePlugin.getiptcinfo(img) or {}).values():
            meta += _meta_value(v)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    tail = b""
    if data.startswith(b"\xff\xd8"):
        segs, tail = _jpeg_segments(data)
        for s in segs:
            meta += _meta_value(s)
    elif data.startswith(b"\x89PNG"):
        chunks, tail = _png_chunks(data)
        for s in chunks:
            meta += _meta_value(s)
    sc.check_variants(meta, {**loc, "kind": "image_metadata"})
    if tail.strip(b"\0 \r\n\t"):
        _scan(sc, tail, None, depth + 1, {**loc, "kind": "trailing_data"})  # data appended after the image (R-37)
    frames = getattr(img, "n_frames", 1) or 1
    if frames > MAX_FRAMES:
        sc.fail("R_LIMIT")
        return
    for f in range(frames):                                                 # APNG, MPO, multi-page images (R-37)
        if sc.timed_out():
            return
        try:
            img.seek(f)
            fr = img.copy()
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
            return
        ocr_image(sc, fr, {**loc, **({"page": f + 1} if frames > 1 else {})}, require_text=require_text and f == 0)


# ---------------------------------------------------------------------------------------------------------- PDF objects
# A small, tolerant PDF object parser (R-24): dictionaries are parsed, never guessed from header text. Names are decoded
# (#xx), strings are kept as bytes, numbers are never scanned (coordinates are not nine-digit numbers, D-9011c-2).
class Name(str):
    pass


class Ref(tuple):
    pass


_PDF_WS = b" \t\r\n\f\0"
_PDF_DELIM = b"()<>[]{}/%"


def _skip_ws(d, i, comments=None):
    n = len(d)
    while i < n:
        c = d[i]
        if c in _PDF_WS:
            i += 1
        elif c == 0x25:
            j = d.find(b"\n", i)
            j2 = d.find(b"\r", i)
            j = min(x for x in (j, j2, n) if x >= 0)
            if comments is not None:
                comments.append(d[i + 1:j])
            i = j
        else:
            break
    return i


def _literal(d, i):
    buf, lvl, n = bytearray(), 1, len(d)
    i += 1
    while i < n and lvl:
        ch = d[i]
        if ch == 0x5C and i + 1 < n:
            e = d[i + 1]
            if 0x30 <= e <= 0x37:
                k = i + 1
                while k < n and k < i + 4 and 0x30 <= d[k] <= 0x37:
                    k += 1
                buf.append(int(d[i + 1:k], 8) & 0xFF); i = k; continue
            if e == 0x0D:
                i += 3 if d[i + 2:i + 3] == b"\n" else 2; continue
            if e == 0x0A:
                i += 2; continue
            buf += {0x6E: b"\n", 0x72: b"\r", 0x74: b"\t", 0x62: b"\b", 0x66: b"\f"}.get(e, bytes([e]))
            i += 2; continue
        if ch == 0x28:
            lvl += 1
        elif ch == 0x29:
            lvl -= 1
            if not lvl:
                return bytes(buf), i + 1
        buf.append(ch); i += 1
    return bytes(buf), i


def _hexstr(d, i):
    j = d.find(b">", i)
    if j < 0:
        return b"", len(d)
    hx = re.sub(rb"[^0-9A-Fa-f]", b"", d[i + 1:j])
    if len(hx) % 2:
        hx += b"0"
    return bytes.fromhex(hx.decode()), j + 1


_NUM = re.compile(rb"[+-]?(?:\d+\.?\d*|\.\d+)")
_REF = re.compile(rb"\s+(\d+)\s+R(?![A-Za-z0-9])")


def parse_obj(d, i, depth=0):
    """(value, next index); strings are bytes, names Name, references Ref, dictionaries dict, arrays list."""
    if depth > 64:
        raise ValueError("nesting")
    i = _skip_ws(d, i)
    n = len(d)
    if i >= n:
        raise ValueError("eof")
    c = d[i]
    if d.startswith(b"<<", i):
        out, i = {}, i + 2
        while True:
            i = _skip_ws(d, i)
            if i >= n:
                raise ValueError("eof in dict")
            if d.startswith(b">>", i):
                return out, i + 2
            k, i = parse_obj(d, i, depth + 1)
            v, i = parse_obj(d, i, depth + 1)
            out[str(k)] = v
    if c == 0x5B:
        out, i = [], i + 1
        while True:
            i = _skip_ws(d, i)
            if i >= n:
                raise ValueError("eof in array")
            if d[i] == 0x5D:
                return out, i + 1
            v, i = parse_obj(d, i, depth + 1)
            out.append(v)
    if c == 0x28:
        return _literal(d, i)
    if c == 0x3C:
        return _hexstr(d, i)
    if c == 0x2F:
        j = i + 1
        while j < n and d[j] not in _PDF_WS and d[j] not in _PDF_DELIM:
            j += 1
        raw = re.sub(rb"#([0-9A-Fa-f]{2})", lambda m: bytes([int(m.group(1), 16)]), d[i + 1:j])
        return Name("/" + raw.decode("latin-1")), j
    m = _NUM.match(d, i)
    if m:
        r = _REF.match(d, m.end())
        if r and b"." not in m.group(0):
            g = re.match(rb"\s+(\d+)", d[m.end():m.end() + 12])
            return Ref((int(m.group(0)), int(g.group(1)) if g else 0)), r.end()
        s = m.group(0)
        return (float(s) if b"." in s else int(s)), m.end()
    for kw, v in ((b"true", True), (b"false", False), (b"null", None)):
        if d.startswith(kw, i):
            return v, i + len(kw)
    j = i
    while j < n and d[j] not in _PDF_WS and d[j] not in _PDF_DELIM:
        j += 1
    return Name(d[i:j].decode("latin-1")), max(j, i + 1)                # an operator or a stray token


def _pdf_text_variants(b):
    """A PDF string as text: UTF-16BE with BOM, UTF-8 with BOM, else PDFDocEncoding (Latin-1); 2-byte codes also as
    UTF-16BE (R-25)."""
    if b[:2] == b"\xfe\xff":
        return [b[2:].decode("utf-16-be", errors="replace")]
    if b[:3] == b"\xef\xbb\xbf":
        return [b[3:].decode("utf-8", errors="replace")]
    out = [b.decode("latin-1")]
    if len(b) >= 4 and len(b) % 2 == 0 and b[0::2].count(0) > len(b) // 4:
        out.append(b.decode("utf-16-be", errors="replace"))
    return out


def _pdf_text(b):
    return _pdf_text_variants(b)[0]


def _leaf_strings(v, out, depth=0):
    if depth > 64:
        return
    if isinstance(v, bytes):
        out.append(v)
    elif isinstance(v, dict):
        for x in v.values():
            _leaf_strings(x, out, depth + 1)
    elif isinstance(v, list):
        for x in v:
            _leaf_strings(x, out, depth + 1)


def pdf_strings(data, skip_comments=True):
    """String operands of a PDF byte sequence, decoded; strings inside one array are concatenated (compatibility helper)."""
    out = []
    for texts in _content_shows(data):
        out.append("".join(texts))
    return out


# content streams: text shown per operator, rebuilt per text object (R-25)
_OPS_SHOW = {"Tj", "TJ", "'", '"'}
_OPS_ALL = {"b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI",
            "EMC", "ET", "EX", "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP", "n",
            "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf", "Tj",
            "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w", "W", "W*", "y", "'", '"'}


def _content_shows(data):
    """[[strings shown in one text object]] of a content stream; operands of other operators are dropped."""
    objs, cur, stack, i, n = [], [], [], 0, len(data)
    while i < n:
        i = _skip_ws(data, i)
        if i >= n:
            break
        if data.startswith(b"BI", i) and (i + 2 >= n or data[i + 2] in _PDF_WS):
            j = data.find(b"EI", i + 2)                                      # inline image data: skip to EI
            i = n if j < 0 else j + 2
            stack = []
            continue
        try:
            v, j = parse_obj(data, i)
        except Exception:  # noqa: BLE001
            i += 1
            continue
        i = j
        if isinstance(v, Name) and not v.startswith("/"):
            op = str(v)
            if op in _OPS_SHOW:
                strs = []
                for x in stack:
                    if isinstance(x, bytes):
                        strs.append(x)
                    elif isinstance(x, list):
                        strs += [y for y in x if isinstance(y, bytes)]
                cur.append(strs)
            elif op == "ET" or op == "BT":
                if cur:
                    objs.append(cur)
                cur = []
            stack = []
        else:
            stack.append(v)
            if len(stack) > 64:
                stack = stack[-64:]
    if cur:
        objs.append(cur)
    return [[_pdf_text(s) for show in o for s in show] for o in objs]


_GLYPH_DIGITS = {n: str(i) for i, n in enumerate(("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"))}


def _collect_differences(v, out, depth=0):
    if depth > 16:
        return
    if isinstance(v, dict):
        if isinstance(v.get("/Differences"), list):
            out.append(_differences_map(v["/Differences"]))
        for x in v.values():
            _collect_differences(x, out, depth + 1)
    elif isinstance(v, list):
        for x in v:
            _collect_differences(x, out, depth + 1)


def _differences_map(arr):
    """code -> character for the glyph names of a font /Differences array that name digits or ASCII letters."""
    out, code = {}, None
    for x in arr:
        if isinstance(x, (int, float)):
            code = int(x)
        elif isinstance(x, Name) and code is not None:
            g = str(x)[1:]
            if g in _GLYPH_DIGITS:
                out[code] = _GLYPH_DIGITS[g]
            elif len(g) == 1 and g.isascii() and g.isalnum():
                out[code] = g
            elif re.fullmatch(r"g[0-9]", g):
                out[code] = g[1]
            code += 1
    return {k: v for k, v in out.items() if chr(k) != v}


def _scan_content(sc, data, loc, diffs=()):
    """Text of a content stream: per text object joined without separator (a value split over operators), and per
    operator joined with a separator (a following digit-led string must not lengthen a value); 2-byte codes also as
    UTF-16BE (R-25)."""
    objs = []
    i, n, stack, cur = 0, len(data), [], []
    while i < n:
        i = _skip_ws(data, i)
        if i >= n:
            break
        if data.startswith(b"BI", i) and (i + 2 >= n or data[i + 2] in _PDF_WS):
            j = data.find(b"EI", i + 2)
            i = n if j < 0 else j + 2
            stack = []
            continue
        try:
            v, j = parse_obj(data, i)
        except Exception:  # noqa: BLE001
            i += 1
            continue
        i = j
        if isinstance(v, Name) and not v.startswith("/"):
            op = str(v)
            if op in _OPS_SHOW:
                show = []
                for x in stack:
                    if isinstance(x, bytes):
                        show.append(x)
                    elif isinstance(x, list):
                        show += [y for y in x if isinstance(y, bytes)]
                cur.append(show)
            elif op in ("BT", "ET"):
                if cur:
                    objs.append(cur)
                cur = []
            stack = []
        else:
            stack.append(v)
            if len(stack) > 64:
                stack = stack[-64:]
    if cur:
        objs.append(cur)
    if not objs:
        return
    decs = [lambda b: _pdf_text_variants(b)[0], lambda b: _pdf_text_variants(b)[-1]]
    for dm in diffs:                                                         # glyphs remapped by a font encoding (R-28)
        decs.append(lambda b, dm=dm: "".join(dm.get(x, chr(x)) for x in b))
    for dec in decs:
        joined = SEP.join("".join(dec(s) for show in o for s in show) for o in objs)
        per_op = SEP.join(SEP.join("".join(dec(s) for s in show) for show in o) for o in objs)
        per_str = SEP.join(dec(s) for o in objs for show in o for s in show)
        sc.check_variants([joined, per_op, per_str], loc)


_CONTENT_TOKEN = re.compile(rb"[A-Za-z'\"*]{1,3}(?=[\s\[\]()<>/]|$)")


def _is_content(body):
    """A content stream is mostly operators, numbers, names and strings; text (XFA data, notes) is words."""
    s = body[:65536].lstrip()
    if not s or s[:1] in (b"<",) and not s.startswith(b"<<") and re.match(rb"<[?!A-Za-z]", s):
        return False
    s = re.sub(rb"\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f\s]*>|/[^\s/\[\]()<>{}%]*", b" ", s)   # strings and names are operands
    words = re.findall(rb"[A-Za-z][A-Za-z0-9*'\"]*", s)
    if not words:
        return bool(re.search(rb"[()<>\[\]]", s))
    ops = sum(1 for w in words if w.decode("latin-1") in _OPS_ALL)
    return ops >= 0.6 * len(words)


_JOIN_TAGS = {"p", "r", "si", "is", "rich", "tx", "t", "title", "datasets", "data", "field", "text"}


def _xml_texts(b):
    """Text nodes (runs joined per element), attribute values and comments of an XML document (R-29, R-31)."""
    import xml.etree.ElementTree as ET
    txt = None
    for t in text_variants(b):
        txt = t
        break
    if txt is None:
        return None
    txt = re.sub(r"^\s*<\?xml[^>]*\?>", "", txt)
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True, insert_pis=True))
        parser.feed(txt)
        root = parser.close()
    except Exception:  # noqa: BLE001
        return None
    out = []

    def walk(e, depth=0):
        if depth > 200:
            return
        if callable(e.tag):                                                  # comment or processing instruction
            if e.text:
                out.append(e.text)
        else:
            for v in e.attrib.values():
                out.append(v)
            if e.tag.rsplit("}", 1)[-1] in _JOIN_TAGS:                       # runs of one paragraph or string item
                joined = "".join(e.itertext())
                if joined.strip():
                    out.append(joined)
            if e.text and e.text.strip():
                out.append(e.text)
        for c in list(e):
            walk(c, depth + 1)
            if c.tail and c.tail.strip():
                out.append(c.tail)
    walk(root)
    return out


def _check_xml(sc, b, loc):
    t = _xml_texts(b)
    if t is None:
        check_bytes(sc, b, loc)                                              # not well-formed: read it as text
        sc.check(html.unescape(re.sub(r"<[^>]+>", SEP, _decode_text(b))), loc)
        return
    sc.check(SEP.join(t), loc)


_FILTERS = {"/FlateDecode": "FlateDecode", "/Fl": "FlateDecode", "/ASCIIHexDecode": "ASCIIHexDecode", "/AHx": "ASCIIHexDecode",
            "/ASCII85Decode": "ASCII85Decode", "/A85": "ASCII85Decode", "/LZWDecode": "LZWDecode", "/LZW": "LZWDecode",
            "/RunLengthDecode": "RunLengthDecode", "/RL": "RunLengthDecode"}
_IMAGE_FILTERS = {"/DCTDecode", "/DCT", "/JPXDecode", "/CCITTFaxDecode", "/CCF", "/JBIG2Decode"}


def _as_list(v):
    return v if isinstance(v, list) else ([] if v is None else [v])


def _decode_stream(sc, dic, raw):
    """(decoded bytes, remaining image filter or None); None on a failure already recorded."""
    import pypdf.filters as PF
    from pypdf.errors import LimitReachedError
    from pypdf.generic import DictionaryObject, NameObject, NumberObject
    filters = _as_list(dic.get("/Filter"))
    parms = _as_list(dic.get("/DecodeParms") or dic.get("/DP"))
    body = raw
    for k, f in enumerate(filters):
        f = str(f)
        if f in _IMAGE_FILTERS:
            return body, f
        if f in ("/Crypt",):
            continue
        cls = _FILTERS.get(f)
        if cls is None:
            sc.fail("R_FILTER_UNSUPPORTED")
            return None, None
        p = parms[k] if k < len(parms) and isinstance(parms[k], dict) else None
        dp = DictionaryObject({NameObject(x): NumberObject(int(y)) for x, y in p.items() if isinstance(y, (int, float))}) if p else None
        if cls == "FlateDecode":
            # strict inflate first: a stream that does not inflate cleanly fails closed (pypdf would recover a prefix)
            try:
                z = zlib.decompressobj()
                out = z.decompress(body, MAX_STREAM_OUT + 1)
                if len(out) > MAX_STREAM_OUT or z.unconsumed_tail:
                    sc.fail("R_LIMIT")
                    return None, None
                if not z.eof:
                    sc.fail("R_EXTRACTION_FAILED")
                    return None, None
            except zlib.error:
                sc.fail("R_EXTRACTION_FAILED")
                return None, None
            if not dp or int(dp.get("/Predictor", 1)) < 2:
                body = out
                if not sc.account(len(body)):
                    return None, None
                continue
        try:
            body = getattr(PF, cls).decode(body, dp)
        except LimitReachedError:
            sc.fail("R_LIMIT")
            return None, None
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
            return None, None
        if len(body) > MAX_STREAM_OUT or not sc.account(len(body)):
            sc.fail("R_LIMIT")
            return None, None
    return body, None


def _is_image(dic):
    return str(dic.get("/Subtype", "")) == "/Image" or ("/Width" in dic and "/Height" in dic and "/BitsPerComponent" in dic)


def _simple_image(dic, body, imgfilter):
    """PIL image of an image stream decoded without the document (orphan or carved objects); None when it needs more."""
    from PIL import Image
    if imgfilter in ("/DCTDecode", "/DCT", "/JPXDecode"):
        return Image.open(io.BytesIO(body))
    if imgfilter is not None:
        return None
    cs, bpc = str(dic.get("/ColorSpace", "")), dic.get("/BitsPerComponent")
    w, hgt = dic.get("/Width"), dic.get("/Height")
    if not isinstance(w, int) or not isinstance(hgt, int) or w * hgt > MAX_PIXELS:
        return None
    if dic.get("/ImageMask") is True or (cs == "/DeviceGray" and bpc == 1):
        return Image.frombytes("1", (w, hgt), body[:((w + 7) // 8) * hgt])
    if bpc == 8 and cs in ("/DeviceRGB", "/DeviceGray", "/DeviceCMYK"):
        mode = {"/DeviceRGB": "RGB", "/DeviceGray": "L", "/DeviceCMYK": "CMYK"}[cs]
        return Image.frombytes(mode, (w, hgt), body[:w * hgt * len(mode)])
    return None


_OBJ = re.compile(rb"(?<![0-9])(\d{1,10})\s+(\d{1,5})\s+obj(?![A-Za-z0-9])")


def _carve_pdf(sc, data, depth, image_hashes):
    """Every object in the file, referenced or not, parsed (R-24): strings of every dictionary and array, every stream
    decoded with its filters (R-23), images OCRed unless the structural pass did (R-26), metadata and XFA parsed as XML
    (R-29), comments and bytes outside objects read (R-30)."""
    covered, objstreams, streams, diffs = [], [], [], []
    for m in _OBJ.finditer(data):
        if sc.timed_out():
            return
        if covered and m.start() < covered[-1][1]:
            continue
        try:
            val, j = parse_obj(data, m.end())
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
            continue
        k = _skip_ws(data, j)
        end = data.find(b"endobj", k)
        _collect_differences(val, diffs)
        if isinstance(val, dict) and data.startswith(b"stream", k):
            s = k + 6
            s += 2 if data[s:s + 2] == b"\r\n" else (1 if data[s:s + 1] in (b"\r", b"\n") else 0)
            ln = val.get("/Length")
            e = -1
            if isinstance(ln, int) and 0 <= ln <= len(data) - s and re.match(rb"\s*endstream", data[s + ln:s + ln + 20]):
                e = s + ln
            if e < 0:
                e = data.find(b"endstream", s)
            if e < 0:
                sc.fail("R_EXTRACTION_FAILED")
                break
            raw = data[s:e]
            if e != s + (ln if isinstance(ln, int) else -1):
                raw = raw.rstrip(b"\r\n")
            end = data.find(b"endobj", e)
            streams.append((val, raw))
        strs = []
        _leaf_strings(val, strs)
        if strs:
            sc.check_variants([SEP.join(t for b in strs for t in _pdf_text_variants(b)[:1])] +
                              [SEP.join(_pdf_text_variants(b)[-1] for b in strs)], {"part": "object", "kind": "object_strings"})
        covered.append((m.start(), (end + 6) if end >= 0 else len(data)))
    diffs = [d for d in diffs if d]
    for val, raw in streams:
        if sc.timed_out():
            return
        _scan_stream(sc, val, raw, depth, image_hashes, objstreams, diffs)
    for body in objstreams:                                                  # objects inside object streams
        _scan_objstm(sc, body)
    # bytes outside objects: comments, data between objects, data after the last %%EOF (R-30)
    gaps, pos = [], 0
    for a, b in covered:
        if a > pos:
            gaps.append(data[pos:a])
        pos = max(pos, b)
    gaps.append(data[pos:])
    trail_strs = []
    for tm in re.finditer(rb"trailer\s*(<<.*?>>)\s*startxref", data, flags=re.S):
        try:
            tv, _ = parse_obj(tm.group(1), 0)
            _leaf_strings(tv, trail_strs)
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
    if trail_strs:
        sc.check(SEP.join(_pdf_text(b) for b in trail_strs), {"part": "file", "kind": "trailer"})
    for g in gaps:
        g = re.sub(rb"xref\s+[\d\s\r\nfn]*", b" ", g)                     # cross-reference tables: offsets only
        g = re.sub(rb"trailer\s*<<.*?>>", b" ", g, flags=re.S)              # trailer dictionary: strings scanned above
        g = re.sub(rb"startxref\s*\d+\s*", b" ", g)
        g = re.sub(rb"%%EOF|%PDF-\d\.\d", b" ", g)
        g = g.replace(b"%", b" ")
        if g.strip(b" \t\r\n\f\0"):
            check_bytes(sc, g, {"part": "file", "kind": "outside_objects"})
    tail = data[data.rfind(b"%%EOF") + 5:] if b"%%EOF" in data else b""
    if tail.strip(b" \t\r\n\f\0"):
        check_bytes(sc, tail, {"part": "file", "kind": "after_eof"})


def _scan_objstm(sc, body):
    m = re.match(rb"\s*((?:\d+\s+\d+\s*)+)", body)
    if not m:
        sc.fail("R_EXTRACTION_FAILED")
        return
    strs = []
    i = m.end()
    while i < len(body):
        try:
            v, i = parse_obj(body, i)
        except Exception:  # noqa: BLE001
            break
        _leaf_strings(v, strs)
    if strs:
        sc.check_variants([SEP.join(_pdf_text_variants(b)[0] for b in strs), SEP.join(_pdf_text_variants(b)[-1] for b in strs)],
                          {"part": "object", "kind": "object_stream"})


def _scan_stream(sc, dic, raw, depth, image_hashes, objstreams, diffs=()):
    typ = str(dic.get("/Type", ""))
    if typ == "/XRef":
        return                                                               # offsets only
    body, imgf = _decode_stream(sc, dic, raw)
    if body is None:
        return
    if _is_image(dic) or imgf is not None:
        h = hashlib.sha256(raw).digest()
        if h in image_hashes:
            return
        image_hashes.add(h)
        sc.images += 1
        if sc.images > MAX_IMAGES:
            sc.fail("R_LIMIT")
            return
        try:
            img = _simple_image(dic, body, imgf)
        except Exception:  # noqa: BLE001
            img = None
        if img is None:
            sc.fail("R_IMAGE_UNDECODED")                                     # an image no reader could show: fail closed
            return
        ocr_image(sc, img, {"part": "object", "kind": "image_stream"})
        return
    if _JS.search(re.sub(rb"#([0-9A-Fa-f]{2})", lambda m: bytes([int(m.group(1), 16)]), body)) \
            or re.search(rb"(?i)<(?:[a-z0-9_]+:)?script[\s>/]", body):
        sc.fail("R_JS_REJECTED")                                             # JavaScript in a compressed stream or XFA (R-22)
    if typ == "/EmbeddedFile" or "/Params" in dic and typ in ("", "/EmbeddedFile"):
        _scan(sc, body, None, depth + 1, {"part": "attachment", "kind": "embedded_file"})
        return
    if "/Length1" in dic or "/Length2" in dic or "/Length3" in dic or str(dic.get("/Subtype", "")) in ("/Type1C", "/CIDFontType0C", "/OpenType"):
        if _is_content(body):                                                # a font key does not make a content stream a font
            _scan_content(sc, body, {"part": "object", "kind": "content"}, diffs)
        elif sum(32 <= x < 127 or x in (9, 10, 13) for x in body[:65536]) > 0.95 * min(len(body), 65536):
            check_bytes(sc, body, {"part": "object", "kind": "stream_text"})
        return                                                               # binary font programs carry no document text
    if typ == "/CMap" or body.lstrip()[:8] == b"/CIDInit":
        return                                                               # character maps (code ranges only)
    if typ == "/ObjStm":
        objstreams.append(body)
        return
    head = body.lstrip()[:64]
    if typ == "/Metadata" or head.startswith((b"<?xpacket", b"<x:xmpmeta", b"<?xml", b"<xdp:", b"<xfa:", b"\xef\xbb\xbf<")) \
            or (head[:2] in (b"\xff\xfe", b"\xfe\xff")):
        _check_xml(sc, body, {"part": "document", "kind": "metadata_xmp"})
        if re.search(rb"(?i)<(?:[a-z]+:)?script[\s>]", body):
            sc.fail("R_JS_REJECTED")
        return
    if _is_content(body):
        _scan_content(sc, body, {"part": "object", "kind": "content"}, diffs)
    else:
        check_bytes(sc, body, {"part": "object", "kind": "stream_text"})       # plain text, XFA data or anything else


# ---------------------------------------------------------------------------------------------------------- PDF structure
def _pdf_str(v):
    try:
        if hasattr(v, "get_object"):
            v = v.get_object()
        return str(v)
    except Exception:  # noqa: BLE001
        return ""


def _scan_pdf_revision(sc, data, rev, depth, final, image_hashes):
    from pypdf import PdfReader
    from pypdf.generic import StreamObject
    from pypdf.generic._image_xobject import _xobj_to_image
    try:
        rd = PdfReader(io.BytesIO(data), strict=False)
        if rd.is_encrypted:
            sc.fail("R_ENCRYPTED")
            return
        pages = list(rd.pages)
    except Exception:  # noqa: BLE001
        if final:
            sc.fail("R_EXTRACTION_FAILED")
        else:
            sc.fail("R_REVISION_UNREADABLE")                                 # an earlier revision pypdf cannot open (R-45)
        return
    base = {"revision": rev}
    for i, pg in enumerate(pages):
        if sc.timed_out():
            return
        for mode in ("plain", "layout"):                                     # stream order and visual order (R-27)
            try:
                t = pg.extract_text() if mode == "plain" else pg.extract_text(extraction_mode="layout")
                sc.check(t or "", {**base, "part": "page", "page": i + 1, "kind": "text_layer" if mode == "plain" else "text_layout"})
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
    # every image XObject in the revision, wherever it is used: pages, forms, annotation appearances, thumbnails (R-26)
    try:
        size = int(rd.trailer.get("/Size", 0) or 0)
    except Exception:  # noqa: BLE001
        size = 0
    for num in range(1, min(size, 200000)):
        if sc.timed_out():
            return
        try:
            o = rd.get_object(num)
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(o, StreamObject) or o.get("/Subtype") != "/Image":
            continue
        try:
            h = hashlib.sha256(o._data if hasattr(o, "_data") else o.get_data()).digest()
        except Exception:  # noqa: BLE001
            h = None
        if h in image_hashes:
            continue
        image_hashes.add(h)
        sc.images += 1
        if sc.images > MAX_IMAGES:
            sc.fail("R_LIMIT")
            return
        try:
            _ext, _b, img = _xobj_to_image(o)
            from PIL import Image
            if not isinstance(img, Image.Image):
                img = Image.open(io.BytesIO(_b))
        except Exception:  # noqa: BLE001
            sc.fail("R_IMAGE_UNDECODED")
            continue
        ocr_image(sc, img, {**base, "part": "object", "kind": "image_xobject"})
    try:
        for name, f in (rd.get_fields() or {}).items():
            labelled = S.key_is_label(name) or S.key_is_label(_pdf_str(f.get("/TU", "")))
            for k in ("/V", "/DV", "/TU", "/T", "/Opt"):
                if k in f:
                    sc.check(_pdf_str(f[k]), {**base, "part": "form", "kind": "form_field"}, force_label=labelled and k in ("/V", "/DV", "/Opt"))
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    try:
        for k, v in (rd.metadata or {}).items():
            sc.check(f"{k}{SEP}{_pdf_str(v)}", {**base, "part": "document", "kind": "metadata_info"})
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    if final:
        try:
            for name, blobs in (rd.attachments or {}).items():
                for b in blobs:
                    _scan(sc, b, name, depth + 1, {"part": "attachment", "kind": "embedded_file", "revision": rev})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")


def _render_pdf(sc, data):
    """The pages as a reader sees them, OCRed (R-28): catches text layers that differ from the glyphs drawn (ToUnicode or
    /Differences remapping, Type3 fonts) and annotation appearances. Judged with the native rules: this is a cross-check
    of what the page shows, not a scan of an image document (D-9011R-4)."""
    try:
        import pypdfium2 as pdfium
    except Exception:  # noqa: BLE001
        sc.fail("R_RASTER_UNAVAILABLE")
        return
    try:
        doc = pdfium.PdfDocument(data)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    try:
        n = len(doc)
        if n > MAX_PAGES_RENDER:
            sc.fail("R_LIMIT")
            return
        for i in range(n):
            if sc.timed_out():
                return
            page = doc[i]
            w, h = page.get_size()
            scale = RENDER_SCALE if w * h * RENDER_SCALE ** 2 <= MAX_PIXELS else (MAX_PIXELS / (w * h)) ** 0.5
            img = page.render(scale=scale, may_draw_forms=True).to_pil()
            # a rendered page is upright as displayed (pdfium applies /Rotate); rotated scans are read on the image path
            ocr_image(sc, img, {"part": "page", "page": i + 1, "kind": "rendered"}, origin="native", orientations=False)
            page.close()
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    finally:
        try:
            doc.close()
        except Exception:  # noqa: BLE001
            pass


_JS = re.compile(rb"/(?:JS|JavaScript|Launch)(?![A-Za-z0-9])")


def scan_pdf(sc, data, depth):
    norm = re.sub(rb"#([0-9A-Fa-f]{2})", lambda m: bytes([int(m.group(1), 16)]), data)
    if _JS.search(norm):
        sc.fail("R_JS_REJECTED")
    if re.search(rb"/Encrypt[\s/<\[]", norm):
        sc.fail("R_ENCRYPTED")
        return
    image_hashes = set()
    ends = [m.end() for m in re.finditer(rb"%%EOF", data)]
    if not ends:
        sc.fail("R_EXTRACTION_FAILED")
        ends = [len(data)]
    for rev, e in enumerate(ends):
        _scan_pdf_revision(sc, data[:e] + b"\n", rev, depth, final=(rev == len(ends) - 1), image_hashes=image_hashes)
    _carve_pdf(sc, data, depth, image_hashes)
    _render_pdf(sc, data)


# ---------------------------------------------------------------------------------------------------------- XLSX
_IMG_MAGIC = (b"\x89PNG", b"\xff\xd8\xff", b"GIF8", b"BM", b"II*\x00", b"MM\x00*")


def _render_number(v, fmt):
    """The digits a number format shows for v, for the formats that change digits: zero padding and scaling (R-33)."""
    if not isinstance(v, (int, float)) or isinstance(v, bool) or not fmt:
        return None
    f = re.sub(r'"[^"]*"|\\.|\[[^\]]*\]', "", fmt.split(";")[0])
    m = re.fullmatch(r"([0#]+)(,*)", f.replace(" ", ""))
    if not m:
        return None
    scaled = v / (1000 ** len(m.group(2)))
    s = str(int(round(scaled)))
    return s.zfill(m.group(1).count("0"))


def scan_xlsx(sc, data, depth):
    import openpyxl
    zf = zipfile.ZipFile(io.BytesIO(data))
    infos = zf.infolist()
    if len(infos) > MAX_ZIP_MEMBERS or sum(i.file_size for i in infos) > MAX_ZIP_TOTAL or any(i.flag_bits & 0x1 for i in infos):
        sc.fail("R_LIMIT")
        return
    if zf.comment:
        check_bytes(sc, zf.comment, {"part": "member", "kind": "zip_comment"})
    eocd = data.rfind(b"PK\x05\x06")
    if eocd >= 0 and len(data) > eocd + 22 + len(zf.comment):
        tail = data[eocd + 22 + len(zf.comment):]
        if tail.strip(b"\0 \r\n\t"):
            sc.fail("R_FORMAT_REJECTED")                                     # data appended after the archive (R-32)
    for i in infos:
        if sc.timed_out():
            return
        raw = zf.read(i)
        low = i.filename.lower()
        if i.is_dir():
            continue
        if low.endswith((".xml", ".rels", ".vml")):
            _check_xml(sc, raw, {"part": "member", "kind": "xlsx_part"})
        elif low.endswith(".bin"):
            sc.fail("R_EMBEDDED_UNSUPPORTED")
        elif low.endswith((".emf", ".wmf")) or raw[:4] in (b"\x01\x00\x00\x00", b"\xd7\xcd\xc6\x9a"):
            sc.fail("R_FORMAT_REJECTED")                                     # vector previews cannot be read (R-32)
        elif raw.startswith(_IMG_MAGIC):
            if raw.startswith((b"\x89PNG", b"\xff\xd8\xff")):
                scan_image(sc, raw, {"part": "member", "kind": "member_image"}, depth + 1, require_text=False)
            else:
                sc.fail("R_FORMAT_REJECTED")
        else:
            _scan(sc, raw, i.filename, depth + 1, {"part": "member", "kind": "embedded_object"})   # by format (R-32)
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=False, data_only=False)
        wbv = openpyxl.load_workbook(io.BytesIO(data), read_only=False, data_only=True)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    for si, ws in enumerate(wb.worksheets):                                  # every sheet, hidden and very hidden included
        if sc.timed_out():
            return
        wsv = wbv.worksheets[si]
        sc.check(ws.title, {"part": "sheet", "page": si + 1, "kind": "sheet_name"})
        if ws.max_row * ws.max_column > 5_000_000:
            sc.fail("R_LIMIT")
            continue
        cells, label_cells = {}, []
        for row in ws.iter_rows():
            for c in row:
                if c.value is None and c.comment is None:
                    continue
                shown = []
                v = c.value
                cached = wsv.cell(row=c.row, column=c.column).value
                if c.data_type == "f" or (isinstance(v, str) and v.startswith("=")):
                    if cached is None:
                        sc.fail("R_FORMULA_UNCACHED")                       # the displayed value is not in the file (R-33)
                    shown.append(str(v))                                     # literals inside the formula
                    if cached is not None:
                        shown.append(str(cached))
                        rn = _render_number(cached, c.number_format)
                        if rn:
                            shown.append(rn)
                elif v is not None:
                    shown.append(str(v))
                    rn = _render_number(v, c.number_format)
                    if rn:
                        shown.append(rn)
                if c.number_format and c.number_format != "General":
                    shown.append(c.number_format)
                txt = SEP.join(shown)
                cells[(c.row, c.column)] = txt
                if v is not None and isinstance(v, str) and (S.key_is_label(v) or S.label_spans(S.fold(S.normalize(v)[0]))):
                    label_cells.append((c.row, c.column))
                if c.comment is not None:
                    sc.check(c.comment.text, {"part": "sheet", "page": si + 1, "kind": "comment"})
        rows = {}
        for (r, col), t in cells.items():
            rows.setdefault(r, []).append((col, t))
        for r in sorted(rows):
            sc.check(SEP.join(t for _c, t in sorted(rows[r])), {"part": "sheet", "page": si + 1, "kind": "cell_row"})
        forced = set()
        right = set()
        for (r, col) in label_cells:                                         # every cell below and the right neighbour (R-34)
            forced |= {(rr, cc) for (rr, cc) in cells if cc == col and rr > r}
            right.add((r, col + 1))
        for k in sorted(forced | right):
            if k in cells:
                sc.check(cells[k], {"part": "sheet", "page": si + 1, "kind": "labelled_column" if k in forced else "labelled_cell"},
                         force_label=True)
        try:
            for dv in ws.data_validations.dataValidation:
                sc.check(SEP.join(str(x or "") for x in (dv.prompt, dv.promptTitle, dv.error, dv.errorTitle, dv.formula1, dv.formula2)),
                         {"part": "sheet", "page": si + 1, "kind": "data_validation"})
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
    try:
        for name, dn in wb.defined_names.items():
            sc.check(f"{name} {dn.attr_text}", {"part": "workbook", "kind": "defined_name"})
        for ws in wb.worksheets:
            for name, dn in ws.defined_names.items():
                sc.check(f"{name} {dn.attr_text}", {"part": "workbook", "kind": "defined_name"})
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    p = wb.properties
    for k in ("title", "subject", "creator", "keywords", "description", "category", "lastModifiedBy", "identifier", "contentStatus"):
        sc.check(str(getattr(p, k, "") or ""), {"part": "workbook", "kind": "property"})


# ---------------------------------------------------------------------------------------------------------- EML
_INLINE = r"a|abbr|b|bdi|bdo|big|cite|code|data|del|dfn|em|font|i|ins|kbd|mark|q|s|samp|small|span|strike|strong|sub|sup|time|tt|u|var|wbr"


def _html_variants(t):
    """HTML text with inline tags and comments removed (a value split by inline elements, R-36), and with every tag a
    separator."""
    t = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", t)
    a = re.sub(r"(?s)<!--.*?-->", "", t)
    a = re.sub(r"(?i)</?(?:%s)\b[^>]*>" % _INLINE, "", a)
    a = re.sub(r"<[^>]+>", "\n", a)
    b = re.sub(r"<[^>]+>", SEP, re.sub(r"(?s)<!--.*?-->", SEP, t))
    return [html.unescape(a), html.unescape(b)]


def scan_eml(sc, data, depth):
    try:
        msg = email.message_from_bytes(data, policy=email.policy.default)
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
        return
    for part in msg.walk():                                                   # every part and attached message (R-35)
        if sc.timed_out():
            return
        hdrs = []
        try:
            for k, v in part.raw_items():
                hdrs.append(f"{k}: {v}")
            for k in part.keys():
                for v in part.get_all(k, []):
                    hdrs.append(f"{k}: {v}")                                  # decoded: RFC 2047 encoded words, RFC 2231
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
        sc.check_variants(hdrs, {"part": "message", "kind": "eml_header"})
        for k in ("preamble", "epilogue"):
            v = getattr(part, k, None)
            if v:
                sc.check(v, {"part": "message", "kind": "eml_" + k})
        try:
            fname = part.get_filename()
        except Exception:  # noqa: BLE001
            fname = None
            sc.fail("R_EXTRACTION_FAILED")
        if fname:
            sc.check(fname, {"part": "message", "kind": "eml_filename"})
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        try:
            payload = part.get_payload(decode=True)
        except Exception:  # noqa: BLE001
            sc.fail("R_EXTRACTION_FAILED")
            continue
        if payload is None:
            continue
        if ctype.startswith("text/") and not fname:
            cs = part.get_content_charset()
            texts = []
            if cs:
                try:
                    texts.append(payload.decode(cs, errors="replace"))
                except LookupError:
                    sc.fail("R_EXTRACTION_FAILED")
            texts += text_variants(payload)                                  # undeclared or wrong charsets (R-39)
            for t in texts:
                if ctype == "text/html":
                    sc.check_variants(_html_variants(t), {"part": "message", "kind": "eml_part"})
                sc.check(t, {"part": "message", "kind": "eml_part"})
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
    outer, sc.depth = sc.depth, depth
    try:
        fmt = detect_format(data, name)
        if fmt.startswith("rejected:"):
            sc.fail(fmt.split(":", 1)[1])
        elif fmt == "pdf":
            scan_pdf(sc, data, depth)
        elif fmt in ("png", "jpeg"):
            scan_image(sc, data, loc or {"part": "image"}, depth, require_text=(depth == 0))
        elif fmt == "xlsx":
            scan_xlsx(sc, data, depth)
        elif fmt == "eml":
            scan_eml(sc, data, depth)
        else:
            check_bytes(sc, data, loc or {"part": "document", "kind": "text"})
    except MemoryError:
        sc.fail("R_MEMORY_BUDGET")
    except Exception:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    finally:
        sc.depth = outer


def _child(data, name, deadline, wfd, efd):
    """The scan, in the forked child: memory limit, no logging, stderr into a pipe the parent discards (R-18, R-19)."""
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    _pdeathsig()
    os.dup2(efd, 2)
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT, MEM_LIMIT))
    except Exception:  # noqa: BLE001
        pass
    logging.disable(logging.CRITICAL)                                        # pypdf/PIL warnings quote document objects
    warnings.simplefilter("ignore")
    sc = _Scan(deadline)
    try:
        _scan(sc, data, name, 0)
    except MemoryError:
        sc.fail("R_MEMORY_BUDGET")
    except BaseException:  # noqa: BLE001
        sc.fail("R_EXTRACTION_FAILED")
    out = json.dumps({"rules": sorted(sc.rules), "incomplete": sorted(sc.incomplete), "locators": sc.locators}).encode()
    try:
        view = memoryview(out)
        while view:
            k = os.write(wfd, view)
            view = view[k:]
    finally:
        os._exit(0)


def _run_isolated(data, name, budget_seconds):
    deadline = time.monotonic() + budget_seconds
    rr, rw = os.pipe()
    er, ew = os.pipe()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        pid = os.fork()
    if pid == 0:                                                             # pragma: no cover (child)
        os.close(rr)
        os.close(er)
        _child(data, name, deadline, rw, ew)
    os.close(rw)
    os.close(ew)
    chunks, hard = [], deadline + GRACE_SECONDS
    open_fds = {rr, er}
    killed = False
    while open_fds:
        left = hard - time.monotonic()
        if left <= 0:
            killed = True
            break
        rl, _, _ = select.select(list(open_fds), [], [], min(left, 1.0))
        for fd in rl:
            b = os.read(fd, 65536)
            if not b:
                open_fds.discard(fd)
            elif fd == rr:
                chunks.append(b)
    if killed:
        for sig_target in (lambda: os.killpg(pid, signal.SIGKILL), lambda: os.kill(pid, signal.SIGKILL)):
            try:
                sig_target()
            except OSError:
                pass
    for fd in (rr, er):
        try:
            os.close(fd)
        except OSError:
            pass
    _p, status = os.waitpid(pid, 0)
    if killed:
        return {"rules": [], "incomplete": ["R_TIME_BUDGET"], "locators": []}
    try:
        return json.loads(b"".join(chunks).decode())
    except ValueError:
        sig = os.WTERMSIG(status) if os.WIFSIGNALED(status) else None
        return {"rules": [], "incomplete": ["R_MEMORY_BUDGET" if sig == signal.SIGKILL else "R_EXTRACTION_FAILED"], "locators": []}


def validate(data, name=None, budget_seconds=BUDGET_SECONDS):
    """Transient scan of one file (Z1). Returns the verdict; never text, values or the file name."""
    data = bytes(data)                                                       # one immutable copy: hashed and scanned (R-45)
    r = _run_isolated(data, name, budget_seconds)
    rules, inc = set(r["rules"]), set(r["incomplete"])
    result = "SIN_CANDIDATE" if rules else ("SCAN_INCOMPLETE" if inc else "PASSED")
    return {"sha256": hashlib.sha256(data).hexdigest(), "sin_detector_version": S.VERSION, "scan_result": result,
            "rule_codes": sorted(rules | inc), "locators": r["locators"]}


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
    try:
        fmt = detect_format(data, name)
    except Exception:  # noqa: BLE001
        return None
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
