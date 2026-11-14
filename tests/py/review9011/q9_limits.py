# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Q9 limits and failure paths. Heavy cases are meant to be run one per process by run_heavy.py (rusage is measured there)."""
from common import *
import zipfile


def g(v):
    return " ".join((v[:3], v[3:6], v[6:]))


def std_pdf(content=None, extra=None, **kw):
    import q8_pdf as P
    return P.std(content=content, extra=extra, **kw)


# ---------------------------------------------------------------- fail-closed controls and variants
@case("Q9-pdf-encrypted-control", expect="INCOMPLETE")
def Q9_pdf_encrypted_control():
    return F.pdf_encrypted(), "x.pdf"


@case("Q9-pdf-encrypt-direct-dict-no-space", expect="INCOMPLETE")
def Q9_pdf_encrypt_direct_dict_no_space():
    import q8_pdf as P
    enc = b"<< /Filter /Standard /V 2 /R 3 /Length 128 /P -44 /O <" + b"00" * 32 + b"> /U <" + b"00" * 32 + b"> >>"
    return P.std(trailer_extra=b"/Encrypt" + enc + b" /ID [<" + b"11" * 16 + b"> <" + b"11" * 16 + b">]", content=P.tj1(plain("luhn", 601))), "x.pdf"


@case("Q9-pdf-really-encrypted-empty-user-password", expect="INCOMPLETE")
def Q9_pdf_really_encrypted_empty_user_password():
    from pypdf import PdfReader, PdfWriter
    w = PdfWriter(); w.append(PdfReader(io.BytesIO(F.pdf_visible(val("luhn", 602)))))
    w.encrypt("", owner_password="o", algorithm="RC4-128")
    b = io.BytesIO(); w.write(b)
    return b.getvalue(), "x.pdf"


@case("Q9-pdf-really-encrypted-user-password", expect="INCOMPLETE")
def Q9_pdf_really_encrypted_user_password():
    from pypdf import PdfReader, PdfWriter
    w = PdfWriter(); w.append(PdfReader(io.BytesIO(F.pdf_visible(val("luhn", 603)))))
    w.encrypt("pw", owner_password="o", algorithm="RC4-128")
    b = io.BytesIO(); w.write(b)
    return b.getvalue(), "x.pdf"


@case("Q9-pdf-damaged-garbage-after-header", expect="INCOMPLETE")
def Q9_pdf_damaged_garbage_after_header():
    return b"%PDF-1.7\n" + os.urandom(2000), "x.pdf"


@case("Q9-pdf-header-only", expect="INCOMPLETE")
def Q9_pdf_header_only():
    return b"%PDF-1.7\n", "x.pdf"


@case("Q9-pdf-broken-page-tree-visible-stream", expect="INCOMPLETE")
def Q9_pdf_broken_page_tree_visible_stream():
    import q8_pdf as P
    b = P.std(content=P.tj1(plain("luhn", 604)))
    return b.replace(b"/Kids [3 0 R]", b"/Kids [99 0 R]"), "x.pdf"


@case("Q9-pdf-kids-cycle", expect="INCOMPLETE")
def Q9_pdf_kids_cycle():
    import q8_pdf as P
    b = P.std(content=P.tj1(plain("luhn", 605)))
    return b.replace(b"/Kids [3 0 R]", b"/Kids [2 0 R]"), "x.pdf"


@case("Q9-pdf-page-count-lie-many-kids", expect="INCOMPLETE")
def Q9_pdf_page_count_lie_many_kids():
    import q8_pdf as P
    b = P.std(content=P.tj1(plain("luhn", 606)))
    return b.replace(b"/Count 1", b"/Count 1" + b"0" * 8), "x.pdf"


@case("Q9-truncated-png", expect="INCOMPLETE")
def Q9_truncated_png():
    return F.damaged_png(), "x.png"


@case("Q9-truncated-jpeg", expect="INCOMPLETE")
def Q9_truncated_jpeg():
    import q8_img as I
    d = I.jpeg(I.render(["Synthetic", I.vline("luhn", 607)]))
    return d[:len(d) // 2], "x.jpg"


@case("Q9-png-header-only-valid-ihdr-no-idat", expect="INCOMPLETE")
def Q9_png_header_only_valid_ihdr_no_idat():
    import q8_img as I
    d = I.png(I.render(["Synthetic"]))
    i = d.find(b"IDAT") - 4
    return d[:i] + I.chunk(b"IEND", b""), "x.png"


@case("Q9-xlsx-password-protected-ole", expect="INCOMPLETE")
def Q9_xlsx_password_protected_ole():
    return b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\0" * 600 + "EncryptedPackage".encode("utf-16-le"), "x.xlsx"


@case("Q9-xlsx-corrupt-sheet-xml", expect="INCOMPLETE")
def Q9_xlsx_corrupt_sheet_xml():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 608))]))
    return zip_patch(d, replace={"xl/worksheets/sheet1.xml": lambda b: b[:len(b) // 2]}), "x.xlsx"


@case("Q9-xlsx-corrupt-sharedstrings-but-value-in-cell-xml", expect="DETECT")
def Q9_xlsx_corrupt_sharedstrings_but_value_in_cell_xml():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 609))]))
    return zip_patch(d, replace={"xl/styles.xml": lambda b: b"<broken"}), "x.xlsx"


@case("Q9-eml-deep-multipart-20000", expect="INCOMPLETE")
def Q9_eml_deep_multipart_20000():
    m = b"x"
    for _ in range(20000):
        m = b"Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\n" + m + b"\r\n--B--\r\n"
    return b"From: a@example.invalid\r\nMIME-Version: 1.0\r\n" + m, "x.eml"


@case("Q9-nested-xlsx-4-levels-value-innermost", expect="INCOMPLETE")
def Q9_nested_xlsx_4_levels_value_innermost():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 610))]))
    for _ in range(4):
        d = zip_patch(X.wb_bytes(lambda wb, ws: None), add={"xl/embeddings/e.xlsx": d})
    return d, "x.xlsx"


@case("Q9-nested-zip-in-xlsx-embeddings", expect="INCOMPLETE")
def Q9_nested_zip_in_xlsx_embeddings():
    import q8_xlsx as X
    return zip_patch(X.wb_bytes(lambda wb, ws: None), add={"xl/embeddings/a.zip": F.zip_archive(val("luhn", 611))}), "x.xlsx"


@case("Q9-gzip-tar-7z-rar-magic", expect="INCOMPLETE")
def Q9_gzip_tar_7z_rar_magic():
    import gzip
    return gzip.compress(b"Ref " + g(plain("luhn", 612)).encode()), "x.csv"


@case("Q9-tar-ustar-named-csv", expect="INCOMPLETE")
def Q9_tar_ustar_named_csv():
    import tarfile
    o = io.BytesIO()
    with tarfile.open(fileobj=o, mode="w") as t:
        ti = tarfile.TarInfo("a.txt"); body = ("Ref " + g(plain("luhn", 613))).encode(); ti.size = len(body); t.addfile(ti, io.BytesIO(body))
    return o.getvalue(), "x.csv"


@case("Q9-zip-without-lfh-magic-empty-eocd", expect="INCOMPLETE")
def Q9_zip_without_lfh_magic_empty_eocd():
    return b"PK\x05\x06" + b"\0" * 18, "x.xlsx"


@case("Q9-zip-prefixed-sfx-style-named-csv", expect="INCOMPLETE")
def Q9_zip_prefixed_sfx_style_named_csv():
    o = io.BytesIO()
    with zipfile.ZipFile(o, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("inner.txt", "ref " + val("luhn", 614) + " " * 50)
    return b"MZ" + b"\0" * 100 + o.getvalue(), "x.csv"


@case("Q9-zip-with-xl-workbook-but-bad-central-dir-offsets", expect="INCOMPLETE")
def Q9_zip_with_xl_workbook_but_bad_central_dir_offsets():
    import q8_xlsx as X
    d = bytearray(X.wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 615))])))
    i = d.find(b"PK\x01\x02")
    d[i + 42:i + 46] = struct.pack("<I", 7)       # bogus local header offset of the first member
    return bytes(d), "x.xlsx"


# ---------------------------------------------------------------- resource limits (heavy: run one per process)
@case("Q9-HEAVY-xlsx-single-cell-XFD1048576", heavy=True)
def Q9_HEAVY_xlsx_single_cell_XFD1048576():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: None)
    sheet = b'<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1048576"><c r="XFD1048576" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>'
    return zip_patch(d, replace={"xl/worksheets/sheet1.xml": lambda b: sheet}), "x.xlsx"


@case("Q9-HEAVY-xlsx-single-cell-A1048576", heavy=True)
def Q9_HEAVY_xlsx_single_cell_A1048576():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: None)
    sheet = b'<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1048576"><c r="A1048576" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>'
    return zip_patch(d, replace={"xl/worksheets/sheet1.xml": lambda b: sheet}), "x.xlsx"


@case("Q9-HEAVY-xlsx-single-cell-Z60000-120s-budget-note", heavy=True)
def Q9_HEAVY_xlsx_single_cell_Z60000_120s_budget_note():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: None)
    sheet = b'<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="60000"><c r="Z60000" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>'
    return zip_patch(d, replace={"xl/worksheets/sheet1.xml": lambda b: sheet}), "x.xlsx"


@case("Q9-HEAVY-xlsx-xml-part-90MiB-compressible", heavy=True)
def Q9_HEAVY_xlsx_xml_part_90MiB_compressible():
    import q8_xlsx as X
    d = X.wb_bytes(lambda wb, ws: None)
    return zip_patch(d, add={"customXml/item1.xml": b"<r>" + b"<n>a</n>" * (90 * 1024 * 1024 // 8) + b"</r>"}), "x.xlsx"


@case("Q9-HEAVY-text-25MiB-plain", heavy=True)
def Q9_HEAVY_text_25MiB_plain():
    return (b"ab cd 12 " * (25 * 1024 * 1024 // 9)), "x.txt"


@case("Q9-HEAVY-text-25MiB-with-value-at-end", heavy=True)
def Q9_HEAVY_text_25MiB_with_value_at_end():
    return (b"ab cd 12 " * (25 * 1024 * 1024 // 9 - 10)) + b"Ref " + g(plain("luhn", 616)).encode(), "x.txt"


@case("Q9-HEAVY-pdf-30-streams-25MiB-each-budget-5s", heavy=True)
def Q9_HEAVY_pdf_30_streams_25MiB_each_budget_5s():
    import q8_pdf as P
    z = zlib.compress(b" " * (V.MAX_BYTES - 100), 9)
    ex = {9 + k: F.stream(b"/Type /XObject /Subtype /Form /BBox [0 0 1 1]", b"") if False else b"<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Filter /FlateDecode /Length %d >>\nstream\n" % len(z) + z + b"\nendstream" for k in range(30)}
    data = P.std(extra=ex)
    return V.validate(data, "x.pdf", budget_seconds=5) | {"_data_len": len(data)}


@case("Q9-HEAVY-pdf-content-80MB-whitespace-then-value-page", heavy=True)
def Q9_HEAVY_pdf_content_80MB_whitespace_then_value_page():
    import q8_pdf as P
    ops = b"BT /F1 12 Tf 72 600 Td\n" + b" " * (80 * 1024 * 1024) + b"\n(Ref " + g(plain("luhn", 617)).encode() + b") Tj ET\n"
    return P.std(content=ops), "x.pdf"


@case("Q9-HEAVY-pdf-content-300MB-whitespace-then-value-page", heavy=True)
def Q9_HEAVY_pdf_content_300MB_whitespace_then_value_page():
    import q8_pdf as P
    ops = b"BT /F1 12 Tf 72 600 Td\n" + b" " * (300 * 1024 * 1024) + b"\n(Ref " + g(plain("luhn", 618)).encode() + b") Tj ET\n"
    return P.std(content=ops), "x.pdf"


@case("Q9-HEAVY-pdf-5000-pages", heavy=True)
def Q9_HEAVY_pdf_5000_pages():
    n = 5000
    objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 2: b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % (10 + k) for k in range(n)) + b"] /Count %d >>" % n,
            4: F.stream(b"", F.text_ops(["x"])), 5: F.FONT}
    for k in range(n):
        objs[10 + k] = b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    for k in range(3, 10):
        objs.setdefault(k, b"null")
    return F.write(objs, b"/Root 1 0 R")[0], "x.pdf"


@case("Q9-HEAVY-pdf-150k-objects", heavy=True)
def Q9_HEAVY_pdf_150k_objects():
    import q8_pdf as P
    ex = {10 + k: b"<< /K %d >>" % k for k in range(150000)}
    return P.std(extra=ex), "x.pdf"


@case("Q9-HEAVY-pdf-nested-arrays-300k-in-orphan-object", heavy=True)
def Q9_HEAVY_pdf_nested_arrays_300k_in_orphan_object():
    import q8_pdf as P
    return P.std(extra={9: b"<< /A " + b"[" * 300000 + b"] >>"}), "x.pdf"


@case("Q9-HEAVY-pdf-nested-dicts-30k-in-catalog", heavy=True)
def Q9_HEAVY_pdf_nested_dicts_30k_in_catalog():
    import q8_pdf as P
    return P.std(catalog_extra=b"/D " + b"<< /A " * 30000 + b">> " * 30000), "x.pdf"


@case("Q9-HEAVY-png-12000x12000-L-144Mpx", heavy=True)
def Q9_HEAVY_png_12000x12000_L_144Mpx():
    from PIL import Image
    im = Image.new("L", (12000, 12000), 255); b = io.BytesIO(); im.save(b, "PNG", compress_level=1)
    return b.getvalue(), "x.png"


@case("Q9-HEAVY-png-20000x20000-L-400Mpx", heavy=True)
def Q9_HEAVY_png_20000x20000_L_400Mpx():
    from PIL import Image
    im = Image.new("1", (20000, 20000), 1); b = io.BytesIO(); im.save(b, "PNG", compress_level=1)
    return b.getvalue(), "x.png"


@case("Q9-HEAVY-pdf-image-30000x30000-gray-flate", heavy=True)
def Q9_HEAVY_pdf_image_30000x30000_gray_flate():
    import q8_pdf as P
    z = zlib.compress(b"\xff" * (30000 * 3000), 1) if False else None
    w = h = 30000
    c = zlib.compressobj(1); parts = []
    row = b"\xff" * w
    for _ in range(h):
        parts.append(c.compress(row))
    parts.append(c.flush())
    z = b"".join(parts)
    imo = b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n" % (w, h, len(z)) + z + b"\nendstream"
    return P.std(content=b"q 100 0 0 100 10 10 cm /Im1 Do Q", extra={6: imo}, resources_extra=b"/XObject << /Im1 6 0 R >>"), "x.pdf"


@case("Q9-HEAVY-xlsx-many-sheets-2000", heavy=True)
def Q9_HEAVY_xlsx_many_sheets_2000():
    import openpyxl
    wb = openpyxl.Workbook()
    for k in range(1999):
        wb.create_sheet("s%d" % k)
    b = io.BytesIO(); wb.save(b)
    return b.getvalue(), "x.xlsx"


@case("Q9-HEAVY-eml-deep-multipart-40000", heavy=True)
def Q9_HEAVY_eml_deep_multipart_40000():
    m = b"x"
    for _ in range(40000):
        m = b"Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\n" + m + b"\r\n--B--\r\n"
    return b"From: a@example.invalid\r\nMIME-Version: 1.0\r\n" + m, "x.eml"


@case("Q9-zip-central-directory-extract-version-99", expect="INCOMPLETE")
def Q9_zip_central_directory_extract_version_99():
    import q8_xlsx as X
    d = bytearray(X.wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 619))])))
    i = d.find(b"PK\x01\x02")
    d[i + 6:i + 8] = struct.pack("<H", 99)       # "version needed to extract" 9.9 > 6.3
    return bytes(d), "x.xlsx"
