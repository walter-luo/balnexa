"""Q8 text formats, encodings, format sniffing (name/extension overrides), OFX."""
from common import *
from PIL import Image


def g(v, sep=" "):
    return sep.join((v[:3], v[3:6], v[6:]))


@case("TXT-ctl-utf8")
def TXT_ctl_utf8():
    return ("Ref " + g(plain("luhn", 501))).encode(), "x.txt"


@case("TXT-ctl-utf8-no-name")
def TXT_ctl_utf8_no_name():
    return ("Ref " + g(plain("luhn", 502))).encode(), None


@case("TXT-utf16le-no-bom-csv")
def TXT_utf16le_no_bom_csv():
    return ("ref," + g(plain("luhn", 503)) + "\n").encode("utf-16-le"), "x.csv"


@case("TXT-utf16le-with-bom-control")
def TXT_utf16le_with_bom_control():
    return ("ref," + g(plain("luhn", 504)) + "\n").encode("utf-16"), "x.csv"


@case("TXT-utf32-with-bom")
def TXT_utf32_with_bom():
    return ("ref," + g(plain("luhn", 505)) + "\n").encode("utf-32"), "x.csv"


@case("TXT-gbk-label-nonluhn")
def TXT_gbk_label_nonluhn():
    return ("社会保险号," + plain("nonluhn", 506) + "\n").encode("gbk"), "x.csv"


@case("TXT-gbk-fullwidth-digits-luhn")
def TXT_gbk_fullwidth_digits_luhn():
    v = plain("luhn", 507)
    return ("编号," + "".join(chr(0xFF10 + int(c)) for c in v) + "\n").encode("gbk"), "x.csv"


@case("TXT-big5-label-nonluhn")
def TXT_big5_label_nonluhn():
    return ("社會保險號," + plain("nonluhn", 508) + "\n").encode("big5"), "x.csv"


@case("TXT-utf8-label-nonluhn-control")
def TXT_utf8_label_nonluhn_control():
    return ("社会保险号," + plain("nonluhn", 509) + "\n").encode("utf-8"), "x.csv"


@case("TXT-utf8-label-nonluhn-one-stray-byte")
def TXT_utf8_label_nonluhn_one_stray_byte():
    return ("社会保险号," + plain("nonluhn", 510) + "\n").encode("utf-8") + b"\xff", "x.csv"


@case("TXT-utf8-french-label-accent-with-stray-byte")
def TXT_utf8_french_label_accent_with_stray_byte():
    return ("numéro d'assurance sociale: " + plain("nonluhn", 511) + "\n").encode("utf-8") + b"\xff", "x.txt"


@case("TXT-shift-jis-fullwidth-luhn")
def TXT_shift_jis_fullwidth_luhn():
    v = plain("luhn", 512)
    return ("番号," + "".join(chr(0xFF10 + int(c)) for c in v) + "\n").encode("shift_jis"), "x.csv"


@case("TXT-ebcdic-cp037")
def TXT_ebcdic_cp037():
    return ("ref," + g(plain("luhn", 513)) + "\n").encode("cp037"), "x.csv"


def _sep_case(cid, seed, sep_between, kind="luhn"):
    @case(cid)
    def sep_case_builder():
        v = plain(kind, seed)
        return ("Ref " + sep_between.join((v[:3], v[3:6], v[6:]))).encode("utf-8"), "x.txt"


for cid, seed, s in [("TXT-sep-lrm-between-groups", 514, " ‎"), ("TXT-sep-rlm-between-groups", 515, "‏ "), ("TXT-sep-invisible-separator-U2063", 516, "⁣"),
                     ("TXT-sep-cgj-U034F", 517, "͏"), ("TXT-sep-variation-selector", 518, "️"), ("TXT-sep-invisible-times-U2062", 519, "⁢"),
                     ("TXT-sep-ltr-embedding-U202A-U202C", 520, "‪ ‬"), ("TXT-sep-dot", 521, "."), ("TXT-sep-slash", 522, "/"),
                     ("TXT-sep-space-dash-space", 523, " - "), ("TXT-sep-hyphen-newline", 524, "-\n"), ("TXT-sep-underscore", 525, "_"),
                     ("TXT-sep-comma", 526, ","), ("TXT-sep-nbsp-control", 527, " "), ("TXT-sep-newline-control", 528, "\n"),
                     ("TXT-sep-two-spaces-control", 529, "  "), ("TXT-sep-mongolian-vowel-sep-U180E", 530, "᠎"), ("TXT-sep-word-joiner-control", 531, "⁠"),
                     ("TXT-sep-bidi-isolate-U2066-U2069", 532, "⁦⁩")]:
    _sep_case(cid, seed, s)


@case("TXT-keycap-digits")
def TXT_keycap_digits():
    v = plain("luhn", 533)
    return ("Ref " + "".join(c + "️⃣" for c in v)).encode(), "x.txt"


@case("TXT-dingbat-negative-circled-digits")
def TXT_dingbat_negative_circled_digits():
    v = plain("luhn", 534)
    m = {str(k): chr(0x2776 + k - 1) if k else "⓿" for k in range(10)}
    return ("Ref " + "".join(m[c] for c in v)).encode(), "x.txt"


@case("TXT-superscript-and-circled-control")
def TXT_superscript_and_circled_control():
    v = plain("luhn", 535)
    sup = {"0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"}
    return ("Ref " + "".join(sup[c] for c in v)).encode(), "x.txt"


@case("TXT-combining-mark-after-each-digit")
def TXT_combining_mark_after_each_digit():
    v = plain("luhn", 536)
    return ("Ref " + "".join(c + "́" for c in v)).encode(), "x.txt"


@case("TXT-label-then-70-blank-lines-nonluhn")
def TXT_label_then_70_blank_lines_nonluhn():
    return ("Social Insurance Number\n" + "\n" * 70 + plain("nonluhn", 537) + "\n").encode(), "x.txt"


@case("TXT-label-then-long-line-then-value-next-line-nonluhn")
def TXT_label_then_long_line_then_value_next_line_nonluhn():
    return ("SIN " + "x" * 80 + "\n" + plain("nonluhn", 538) + "\n").encode(), "x.txt"


@case("TXT-label-same-line-100-chars-after-nonluhn")
def TXT_label_same_line_100_chars_after_nonluhn():
    return ("SIN" + " " * 100 + plain("nonluhn", 539)).encode(), "x.txt"


@case("TXT-csv-header-label-value-row-below-far-right-nonluhn")
def TXT_csv_header_label_value_row_below_far_right_nonluhn():
    cols = ["col%d" % k for k in range(30)]
    return (",".join(["SIN"] + cols) + "\n" + ",".join([plain("nonluhn", 540)] + ["x"] * 30) + "\n").encode(), "x.csv"


@case("TXT-csv-value-column-then-header-label-in-last-col-nonluhn")
def TXT_csv_value_column_then_header_label_in_last_col_nonluhn():
    return ("a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,SIN\n" + ",".join(["x"] * 26) + "," + plain("nonluhn", 541) + "\n").encode(), "x.csv"


@case("TXT-md-and-ofx-control")
def TXT_md_and_ofx_control():
    return F.ofx(plain("luhn", 542)), "x.ofx"


@case("TXT-ofx-no-name-sniffed")
def TXT_ofx_no_name_sniffed():
    return F.ofx(plain("luhn", 543)), None


@case("TXT-qfx-nonluhn-labelled-by-tag-name")
def TXT_qfx_nonluhn_labelled_by_tag_name():
    return F.ofx(plain("nonluhn", 544)).replace(b"ACCTID", b"SIN"), "x.qfx"


@case("TXT-ofx-latin1-charset-header")
def TXT_ofx_latin1_charset_header():
    return ("OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\nENCODING:USASCII\nCHARSET:1252\n\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><MEMO>caf\xe9 Ref " + g(plain("luhn", 545)) + "</MEMO></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>").encode("cp1252"), "x.ofx"


# ---- format sniffing: the name decides when no magic matches, and TEXT_EXT forces the text path for any bytes
def img_fmt(fmt, lines):
    im = Image.new("RGB", (1400, 120 + 90 * len(lines)), "white")
    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(im); f = ImageFont.load_default(size=44)
    for i, ln in enumerate(lines):
        d.text((60, 60 + 90 * i), ln, fill="black", font=f)
    b = io.BytesIO(); im.save(b, fmt); return b.getvalue()


for fmt in ("GIF", "TIFF", "BMP", "WEBP"):
    for nm in ("scan.txt", "scan.csv", "scan.md", "scan.eml", "scan.png", "scan"):
        if fmt != "GIF" and nm not in ("scan.txt", "scan"):
            continue
        @case(f"SNIFF-{fmt.lower()}-image-with-value-named-{nm.replace('.', '_')}", expect="DETECT")
        def SNIFF_X_image_with_value_named_X(fmt=fmt, nm=nm):
            return img_fmt(fmt, ["Synthetic", "Ref " + val("luhn", 546)]), nm


@case("SNIFF-pdf-with-leading-junk-named-txt")
def SNIFF_pdf_with_leading_junk_named_txt():
    return b"\r\n\r\n" + F.pdf_visible(val("luhn", 547)), "x.txt"


@case("SNIFF-pdf-with-leading-junk-named-pdf", expect="INCOMPLETE")
def SNIFF_pdf_with_leading_junk_named_pdf():
    return b"\r\n\r\n" + F.pdf_visible(val("luhn", 548)), "x.pdf"


@case("SNIFF-pdf-with-leading-junk-no-name")
def SNIFF_pdf_with_leading_junk_no_name():
    return b"\r\n\r\n" + F.pdf_visible(val("luhn", 549)), None


@case("SNIFF-png-with-leading-junk-named-csv")
def SNIFF_png_with_leading_junk_named_csv():
    img, _ = F.image(["Synthetic", "Ref " + val("luhn", 550)])
    return b"x" + img, "x.csv"


@case("SNIFF-ole-legacy-xls-named-csv")
def SNIFF_ole_legacy_xls_named_csv():
    return b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 24 + ("Ref " + g(plain("luhn", 551))).encode("utf-16-le"), "x.csv"


@case("SNIFF-ole-legacy-xls-named-xls", expect="INCOMPLETE")
def SNIFF_ole_legacy_xls_named_xls():
    return b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 24 + ("Ref " + g(plain("luhn", 552))).encode("utf-16-le"), "x.xls"


@case("SNIFF-rtf-hex-escaped-digits-named-txt")
def SNIFF_rtf_hex_escaped_digits_named_txt():
    v = plain("luhn", 553)
    return ("{\\rtf1\\ansi Ref " + "".join("\\'%02x" % (48 + int(c)) for c in v) + "}").encode(), "x.txt"


@case("SNIFF-rtf-named-rtf", expect="INCOMPLETE")
def SNIFF_rtf_named_rtf():
    v = plain("luhn", 554)
    return ("{\\rtf1\\ansi Ref " + "".join("\\'%02x" % (48 + int(c)) for c in v) + "}").encode(), "x.rtf"


@case("SNIFF-docx-in-zip", expect="INCOMPLETE")
def SNIFF_docx_in_zip():
    import zipfile
    o = io.BytesIO()
    with zipfile.ZipFile(o, "w") as z:
        z.writestr("word/document.xml", "<w:t>Ref " + g(plain("luhn", 555)) + "</w:t>")
    return o.getvalue(), "x.docx"


@case("SNIFF-svg-text-named-svg", expect="INCOMPLETE")
def SNIFF_svg_text_named_svg():
    return ("<svg xmlns='http://www.w3.org/2000/svg'><text>Ref " + g(plain("luhn", 556)) + "</text></svg>").encode(), "x.svg"


@case("SNIFF-html-named-html-no-ext-match", expect="INCOMPLETE")
def SNIFF_html_named_html_no_ext_match():
    return ("<html><p>Ref " + g(plain("luhn", 557)) + "</p></html>").encode(), "x.html"


@case("SNIFF-xlsx-bytes-named-txt")
def SNIFF_xlsx_bytes_named_txt():
    import openpyxl
    wb = openpyxl.Workbook(); wb.active.append(["Ref", g(plain("luhn", 558))]); b = io.BytesIO(); wb.save(b)
    return b.getvalue(), "x.txt"


@case("SNIFF-pdf-bytes-with-OFX-token-in-first-2k-and-leading-byte")
def SNIFF_pdf_bytes_with_OFX_token_in_first_2k_and_leading_byte():
    return b"\n" + b"<OFX>" + F.pdf_visible(val("luhn", 559)), "x.dat"


@case("TXT-arabic-indic-and-fullwidth-digits-control")
def TXT_arabic_indic_and_fullwidth_digits_control():
    v = plain("luhn", 560)
    return ("Ref " + "".join(chr(0x0660 + int(c)) for c in v[:5]) + "".join(chr(0xFF10 + int(c)) for c in v[5:])).encode("utf-8"), "x.txt"
