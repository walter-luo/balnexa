"""Q8 PDF hiding places (vendored from the 9011 review ZIP; widget rectangles written as decimals, 10.0 not 10, so that the
repository scan, guard C6, does not read a coordinate list next to a field named sin as a labelled value). Every builder returns (bytes, name). Values are built in memory only."""
from common import *


def std(content_obj=None, content=None, page_extra=b"", catalog_extra=b"", resources_extra=b"", extra=None, info=None,
        trailer_extra=b"", font=None):
    objs = {1: b"<< /Type /Catalog /Pages 2 0 R " + catalog_extra + b" >>",
            2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> "
               + resources_extra + b" >> " + page_extra + b" >>",
            4: content_obj if content_obj is not None else F.stream(b"", content if content is not None else F.text_ops(["Synthetic statement"])),
            5: font if font is not None else F.FONT}
    objs.update(extra or {})
    for n in range(1, max(objs) + 1):
        objs.setdefault(n, b"null")
    tr = b"/Root 1 0 R " + trailer_extra
    if info is not None:
        n = max(objs) + 1
        objs[n] = info
        tr += b" /Info %d 0 R" % n
    return F.write(objs, tr)[0]


def groups(v):
    return v[:3], v[3:6], v[6:]


def tj1(v, y=600):      # one Tj, grouped with spaces
    g = groups(v)
    return b"BT /F1 12 Tf 72 %d Td (Ref %s) Tj ET\n" % (y, " ".join(g).encode())


def tj2(v, y=600):      # value split over two Tj operators
    g = groups(v)
    return b"BT /F1 12 Tf 72 %d Td (Ref %s ) Tj (%s) Tj ET\n" % (y, " ".join(g[:2]).encode(), g[2].encode())


def tjarr_kern(v, y=600):   # a trailing digit set far away by kerning inside one TJ array
    g = groups(v)
    return b"BT /F1 12 Tf 72 %d Td [(Ref %s) -2500 (5)] TJ ET\n" % (y, " ".join(g).encode())


FREETEXT = b"<< /Type /Annot /Subtype /FreeText /Rect [10 10 210 50] /F 4 /AP << /N 7 0 R >> /DA (/F1 12 Tf 0 g) >>"
AP_DICT = b"/Type /XObject /Subtype /Form /BBox [0 0 200 40] /Resources << /Font << /F1 5 0 R >> >>"


def ap_pdf(ops, how="flate", ap_dict=AP_DICT, annot=FREETEXT, dict_after=b""):
    return std(extra={6: annot, 7: enc_stream(ap_dict, ops, how, dict_after)}, page_extra=b"/Annots [6 0 R]")


def orphan_pdf(ops, how="flate", dict_pre=b"", dict_after=b""):
    return std(extra={9: enc_stream(dict_pre + b"/Type /XObject /Subtype /Form /BBox [0 0 200 40]", ops, how, dict_after)})


FILTERS = ["flate", "ahex", "a85", "lzw", "rl", "a85+flate", "ahex+flate", "flate+ahex"]


def _reg_filters():
    for how in FILTERS:
        for place in ("page", "orphan", "ap"):
            def mk(how=how, place=place):
                v = plain("luhn", 101)
                ops = tj1(v)
                if place == "page":
                    return std(content_obj=enc_stream(b"", ops, how)), "x.pdf"
                if place == "orphan":
                    return orphan_pdf(ops, how), "x.pdf"
                return ap_pdf(ops, how), "x.pdf"
            case(f"PDF-FILT-{how}-{place}")(mk)
_reg_filters()


# ---- carve-pass quirks, each in the two places only the carve pass reads (orphan object, annotation appearance stream)
for place in ("orphan", "ap"):
    mkp = (lambda ops, **kw: orphan_pdf(ops, **kw)) if place == "orphan" else (lambda ops, **kw: ap_pdf(ops, **kw))

    @case(f"PDF-CARVE-control-flate-{place}")
    def PDF_CARVE_control_flate_X(mkp=mkp):
        return mkp(tj1(plain("luhn", 102))), "x.pdf"

    @case(f"PDF-CARVE-split-tj-{place}")
    def PDF_CARVE_split_tj_X(mkp=mkp):
        return mkp(tj2(plain("luhn", 103))), "x.pdf"

    @case(f"PDF-CARVE-tj-array-digit-merge-{place}")
    def PDF_CARVE_tj_array_digit_merge_X(mkp=mkp):
        return mkp(tjarr_kern(plain("luhn", 104))), "x.pdf"

    @case(f"PDF-CARVE-decodeparms-after-filter-{place}")
    def PDF_CARVE_decodeparms_after_filter_X(place=place):
        v = plain("luhn", 105)
        if place == "orphan":
            return orphan_pdf(tj1(v), dict_after=b" /DecodeParms << /Predictor 1 >>"), "x.pdf"
        return ap_pdf(tj1(v), dict_after=b" /DecodeParms << /Predictor 1 >>"), "x.pdf"

    @case(f"PDF-CARVE-long-dict-{place}")
    def PDF_CARVE_long_dict_X(place=place):
        v = plain("luhn", 106)
        pad = b"/Pad (" + b"x" * 3000 + b") "
        if place == "orphan":
            return orphan_pdf(tj1(v), dict_pre=pad), "x.pdf"
        return ap_pdf(tj1(v), ap_dict=pad + AP_DICT), "x.pdf"

    @case(f"PDF-CARVE-begincmap-word-{place}")
    def PDF_CARVE_begincmap_word_X(mkp=mkp):
        v = plain("luhn", 107)
        return mkp(b"% begincmap\n" + tj1(v)), "x.pdf"

    @case(f"PDF-CARVE-length1-key-{place}")
    def PDF_CARVE_length1_key_X(place=place):
        v = plain("luhn", 108)
        if place == "orphan":
            return orphan_pdf(tj1(v), dict_pre=b"/Length1 10 "), "x.pdf"
        return ap_pdf(tj1(v), ap_dict=AP_DICT + b" /Length1 10"), "x.pdf"

    @case(f"PDF-CARVE-procset-imageb-{place}")
    def PDF_CARVE_procset_imageb_X(place=place):
        v = plain("luhn", 109)
        d = b"/Resources << /Font << /F1 5 0 R >> /ProcSet [/PDF /Text /ImageB] >> /Type /XObject /Subtype /Form /BBox [0 0 200 40]"
        if place == "orphan":
            return std(extra={9: enc_stream(d, tj1(v))}), "x.pdf"
        return std(extra={6: FREETEXT, 7: enc_stream(d, tj1(v))}, page_extra=b"/Annots [6 0 R]"), "x.pdf"

    @case(f"PDF-CARVE-cid-hex-2byte-{place}")
    def PDF_CARVE_cid_hex_2byte_X(mkp=mkp):
        v = plain("luhn", 110)
        t = " ".join(groups(v))
        hx = b"<" + "".join("%04X" % ord(c) for c in t).encode() + b">"
        return mkp(b"BT /F1 12 Tf 72 600 Td " + hx + b" Tj ET\n"), "x.pdf"

    @case(f"PDF-CARVE-flate-25MiB-padding-{place}", heavy=True)
    def PDF_CARVE_flate_25MiB_padding_X(place=place):
        v = plain("luhn", 111)
        ops = b"BT /F1 12 Tf 72 600 Td\n" + b" " * (V.MAX_BYTES + 10) + b"\n(Ref " + " ".join(groups(v)).encode() + b") Tj ET\n"
        if place == "orphan":
            return orphan_pdf(ops), "x.pdf"
        return ap_pdf(ops), "x.pdf"


# ---- font-encoding remap: codes A..J draw the glyphs zero..nine
DIFF_FONT = (b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding "
             b"/Differences [65 /zero /one /two /three /four /five /six /seven /eight /nine] >> %s >>")
TOUNI = (b"/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def 1 begincodespacerange <00> <FF> endcodespacerange "
         b"10 beginbfchar <41> <0061> <42> <0062> <43> <0063> <44> <0064> <45> <0065> <46> <0066> <47> <0067> <48> <0068> <49> <0069> <4A> <006A> "
         b"endbfchar endcmap CMapName currentdict /CMap defineresource pop end end")


def remap(v):
    return "".join(chr(65 + int(c)) if c.isdigit() else c for c in v)


def remap_ops(v, y=600):
    g = groups(v)
    return b"BT /F1 12 Tf 72 %d Td (%s) Tj ET\n" % (y, remap(" ".join(g)).encode())


@case("PDF-FONT-remap-differences-page")
def PDF_FONT_remap_differences_page():
    v = plain("luhn", 112)
    return std(content=remap_ops(v), font=DIFF_FONT % b""), "x.pdf"


@case("PDF-FONT-remap-differences-orphan")
def PDF_FONT_remap_differences_orphan():
    v = plain("luhn", 113)
    return std(extra={9: enc_stream(b"/Type /XObject /Subtype /Form /BBox [0 0 200 40]", remap_ops(v))}, font=DIFF_FONT % b""), "x.pdf"


@case("PDF-FONT-remap-differences-ap")
def PDF_FONT_remap_differences_ap():
    v = plain("luhn", 114)
    return std(extra={6: FREETEXT, 7: enc_stream(AP_DICT, remap_ops(v))}, page_extra=b"/Annots [6 0 R]", font=DIFF_FONT % b""), "x.pdf"


@case("PDF-FONT-tounicode-lie-page", note="glyphs draw digits (Differences); ToUnicode maps the codes to letters")
def PDF_FONT_tounicode_lie_page():
    v = plain("luhn", 115)
    return std(content=remap_ops(v), font=DIFF_FONT % b"/ToUnicode 8 0 R", extra={8: F.stream(b"", TOUNI)}), "x.pdf"


# ---- page text layer order / splitting (reachable page: pypdf is the authority)
@case("PDF-PAGE-control-one-tj")
def PDF_PAGE_control_one_tj():
    return std(content=tj1(plain("luhn", 116))), "x.pdf"


@case("PDF-PAGE-split-two-tj")
def PDF_PAGE_split_two_tj():
    return std(content=tj2(plain("luhn", 117))), "x.pdf"


@case("PDF-PAGE-reverse-stream-order")
def PDF_PAGE_reverse_stream_order():
    g = groups(plain("luhn", 118))
    ops = b"BT /F1 12 Tf 1 0 0 1 128 600 Tm (%s) Tj ET\nBT /F1 12 Tf 1 0 0 1 100 600 Tm (%s) Tj ET\nBT /F1 12 Tf 1 0 0 1 72 600 Tm (%s) Tj ET\n" % (g[2].encode(), g[1].encode(), g[0].encode())
    return std(content=ops), "x.pdf"


@case("PDF-PAGE-char-by-char-tm")
def PDF_PAGE_char_by_char_tm():
    d = plain("luhn", 119)
    ops = b"".join(b"BT /F1 12 Tf 1 0 0 1 %d 600 Tm (%s) Tj ET\n" % (72 + 6.67 * k if False else 72 + int(6.67 * k), c.encode()) for k, c in enumerate(d))
    return std(content=ops), "x.pdf"


@case("PDF-PAGE-tj-kern-groups")
def PDF_PAGE_tj_kern_groups():
    g = groups(plain("luhn", 120))
    return std(content=b"BT /F1 12 Tf 72 600 Td [(%s) -300 (%s) -300 (%s)] TJ ET\n" % tuple(x.encode() for x in g)), "x.pdf"


@case("PDF-PAGE-form-xobject-do")
def PDF_PAGE_form_xobject_do():
    v = plain("luhn", 121)
    form = enc_stream(b"/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources << /Font << /F1 5 0 R >> >>", tj1(v, 20))
    return std(content=b"q /Fm1 Do Q\n", extra={6: form}, resources_extra=b"/XObject << /Fm1 6 0 R >>"), "x.pdf"


@case("PDF-PAGE-pattern-text")
def PDF_PAGE_pattern_text():
    v = plain("luhn", 122)
    pat = enc_stream(b"/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 200 40] /XStep 200 /YStep 40 /Resources << /Font << /F1 5 0 R >> >>", tj1(v, 10))
    return std(content=b"/Pattern cs /P1 scn 0 0 200 40 re f\n", extra={6: pat}, resources_extra=b"/Pattern << /P1 6 0 R >>"), "x.pdf"


@case("PDF-PAGE-type3-no-unicode", expect="DETECT", note="digit glyphs drawn as Type3 procedures named g0..g9; codes have no Unicode mapping")
def PDF_PAGE_type3_no_unicode():
    v = plain("luhn", 123)
    procs = {k: F.stream(b"", b"600 0 0 0 500 700 d1 0 0 500 700 re f") for k in range(10)}
    cp = b" ".join(b"/g%d %d 0 R" % (k, 20 + k) for k in range(10))
    diff = b" ".join(b"/g%d" % k for k in range(10))
    font = (b"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 800] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << " + cp +
            b" >> /Encoding << /Type /Encoding /Differences [65 " + diff + b"] >> /FirstChar 65 /LastChar 74 /Widths [600 600 600 600 600 600 600 600 600 600] >>")
    ex = {20 + k: procs[k] for k in range(10)}
    ops = b"BT /F1 12 Tf 72 600 Td (%s) Tj ET\n" % remap(v).encode()
    return std(content=ops, font=font, extra=ex), "x.pdf"


# ---- annotations and forms
@case("PDF-ANNOT-freetext-contents")
def PDF_ANNOT_freetext_contents():
    v = plain("luhn", 124)
    return std(extra={6: b"<< /Type /Annot /Subtype /FreeText /Rect [10 10 210 50] /Contents " + F.hexstr("Note " + " ".join(groups(v))) + b" >>"},
               page_extra=b"/Annots [6 0 R]"), "x.pdf"


@case("PDF-ANNOT-rc-stream")
def PDF_ANNOT_rc_stream():
    v = plain("luhn", 125)
    xh = ("<?xml version='1.0'?><body xmlns='http://www.w3.org/1999/xhtml'><p>Note " + " ".join(groups(v)) + "</p></body>").encode()
    return std(extra={6: b"<< /Type /Annot /Subtype /FreeText /Rect [10 10 210 50] /RC 7 0 R >>", 7: F.stream(b"", xh)}, page_extra=b"/Annots [6 0 R]"), "x.pdf"


@case("PDF-ANNOT-popup-contents")
def PDF_ANNOT_popup_contents():
    v = plain("luhn", 126)
    return std(extra={6: b"<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Popup 7 0 R >>",
                      7: b"<< /Type /Annot /Subtype /Popup /Rect [40 40 240 140] /Parent 6 0 R /Contents " + F.hexstr("n " + " ".join(groups(v))) + b" >>"},
               page_extra=b"/Annots [6 0 R 7 0 R]"), "x.pdf"


@case("PDF-ANNOT-stamp-image-ap", note="image XObject only in a stamp appearance stream")
def PDF_ANNOT_stamp_image_ap():
    img, (w, h) = F.image(["Synthetic stamp", "Ref " + val("luhn", 127)])
    from PIL import Image
    raw = Image.open(io.BytesIO(img)).convert("RGB").tobytes()
    imo = enc_stream(b"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8" % (w, h), raw)
    ap = enc_stream(b"/Type /XObject /Subtype /Form /BBox [0 0 %d %d] /Resources << /XObject << /Im1 8 0 R >> >>" % (w, h), b"q %d 0 0 %d 0 0 cm /Im1 Do Q" % (w, h))
    return std(extra={6: b"<< /Type /Annot /Subtype /Stamp /Rect [10 10 410 110] /F 4 /AP << /N 7 0 R >> >>", 7: ap, 8: imo}, page_extra=b"/Annots [6 0 R]"), "x.pdf"


def _rawimg(lines, **kw):
    img, (w, h) = F.image(lines, **kw)
    from PIL import Image
    return Image.open(io.BytesIO(img)).convert("RGB").tobytes(), w, h


@case("PDF-IMG-control-page-image")
def PDF_IMG_control_page_image():
    raw, w, h = _rawimg(["Synthetic scan", "Ref " + val("luhn", 128)])
    imo = enc_stream(b"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8" % (w, h), raw)
    return std(content=b"q 400 0 0 %d 10 10 cm /Im1 Do Q" % int(400 * h / w), extra={6: imo}, resources_extra=b"/XObject << /Im1 6 0 R >>"), "x.pdf"


@case("PDF-IMG-in-form-xobject")
def PDF_IMG_in_form_xobject():
    raw, w, h = _rawimg(["Synthetic scan", "Ref " + val("luhn", 129)])
    imo = enc_stream(b"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8" % (w, h), raw)
    fm = enc_stream(b"/Type /XObject /Subtype /Form /BBox [0 0 400 300] /Resources << /XObject << /Im1 6 0 R >> >>", b"q 400 0 0 %d 0 0 cm /Im1 Do Q" % int(400 * h / w))
    return std(content=b"q /Fm1 Do Q", extra={6: imo, 7: fm}, resources_extra=b"/XObject << /Fm1 7 0 R >>"), "x.pdf"


@case("PDF-IMG-page-thumbnail-only", note="stale /Thumb image of the page")
def PDF_IMG_page_thumbnail_only():
    raw, w, h = _rawimg(["Synthetic scan", "Ref " + val("luhn", 130)])
    th = enc_stream(b"/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8" % (w, h), raw)
    return std(extra={6: th}, page_extra=b"/Thumb 6 0 R"), "x.pdf"


@case("PDF-IMG-inline-image")
def PDF_IMG_inline_image():
    # inline image of text: 1-bit, built from a rendered line
    from PIL import Image
    img, (w, h) = F.image(["Ref " + val("luhn", 131)])
    im = Image.open(io.BytesIO(img)).convert("L")
    raw = im.tobytes()
    ops = b"q 400 0 0 %d 10 10 cm\nBI /W %d /H %d /CS /G /BPC 8 /F /Fl ID\n" % (int(400 * h / w), w, h) + zlib.compress(raw) + b"\nEI Q\n"
    return std(content=ops), "x.pdf"


@case("PDF-FORM-widget-in-acroform-V")
def PDF_FORM_widget_in_acroform_V():
    v = plain("luhn", 132)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (holder_ref) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /V " + F.hexstr(" ".join(groups(v))) + b" >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-widget-not-in-fields")
def PDF_FORM_widget_not_in_fields():
    v = plain("luhn", 133)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (holder_ref) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /V " + F.hexstr(" ".join(groups(v))) + b" >>"},
               page_extra=b"/Annots [6 0 R]"), "x.pdf"


@case("PDF-FORM-choice-opt-array")
def PDF_FORM_choice_opt_array():
    v = plain("luhn", 134)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (pick) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /Opt [(" + " ".join(groups(v)).encode() + b") (0)] >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-widget-ap-only")
def PDF_FORM_widget_ap_only():
    v = plain("luhn", 135)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (holder) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /AP << /N 7 0 R >> >>",
                      7: enc_stream(AP_DICT, tj2(v))}, page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-labelled-nonluhn-name-sin")
def PDF_FORM_labelled_nonluhn_name_sin():
    v = plain("nonluhn", 136)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (sin) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /V (" + v.encode() + b") >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-labelled-parent-name")
def PDF_FORM_labelled_parent_name():
    v = plain("nonluhn", 137)   # field name sin only on the parent; kid is anonymous: fully qualified name is sin.field
    return std(extra={6: b"<< /T (sin) /Kids [7 0 R] /FT /Tx >>",
                      7: b"<< /Type /Annot /Subtype /Widget /Parent 6 0 R /T (a) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /V (" + v.encode() + b") >>"},
               page_extra=b"/Annots [7 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-labelled-caption-mk")
def PDF_FORM_labelled_caption_mk():
    v = plain("nonluhn", 138)   # the label is the visible caption (/MK /CA) of the field
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (f1) /MK << /CA (Social insurance number) >> /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /V (" + v.encode() + b") >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


def _xfa(xml, how="flate"):
    return std(catalog_extra=b"/AcroForm << /Fields [] /XFA [(datasets) 8 0 R] >>", extra={8: enc_stream(b"", xml, how)})


@case("PDF-XFA-datasets-ascii")
def PDF_XFA_datasets_ascii():
    v = plain("luhn", 139)
    return _xfa(("<xfa:datasets xmlns:xfa='http://www.xfa.org/schema/xfa-data/1.0/'><xfa:data><f><ref>" + " ".join(groups(v)) + "</ref></f></xfa:data></xfa:datasets>").encode()), "x.pdf"


@case("PDF-XFA-datasets-cjk-heavy")
def PDF_XFA_datasets_cjk_heavy():
    v = plain("luhn", 140)
    pad = "纳税人信息表单数据集合" * 12
    return _xfa(("<xfa:datasets><xfa:data><f><n>" + pad + "</n><ref>" + " ".join(groups(v)) + "</ref></f></xfa:data></xfa:datasets>").encode("utf-8")), "x.pdf"


@case("PDF-XFA-datasets-utf16")
def PDF_XFA_datasets_utf16():
    v = plain("luhn", 141)
    return _xfa(("﻿<xfa:datasets><xfa:data><f><ref>" + " ".join(groups(v)) + "</ref></f></xfa:data></xfa:datasets>").encode("utf-16-le")), "x.pdf"


@case("PDF-XFA-datasets-word-re")
def PDF_XFA_datasets_word_re():
    v = plain("luhn", 142)
    return _xfa(("<xfa:datasets><xfa:data><f><note>the re value</note><ref>" + " ".join(groups(v)) + "</ref></f></xfa:data></xfa:datasets>").encode()), "x.pdf"


@case("PDF-XFA-datasets-ahex")
def PDF_XFA_datasets_ahex():
    v = plain("luhn", 143)
    return _xfa(("<xfa:datasets><f><ref>" + " ".join(groups(v)) + "</ref></f></xfa:datasets>").encode(), "ahex"), "x.pdf"


# ---- metadata
@case("PDF-META-info-custom-key-number")
def PDF_META_info_custom_key_number():
    v = plain("luhn", 144)
    return std(info=b"<< /Title (x) /Custom " + v.encode() + b" >>"), "x.pdf"


@case("PDF-META-info-custom-key-name-object")
def PDF_META_info_custom_key_name_object():
    v = plain("luhn", 145)
    return std(info=b"<< /Title (x) /Custom /Ref" + v.encode() + b" >>"), "x.pdf"


@case("PDF-META-catalog-integer-value", note="9-digit integer object in a dictionary; D-9011c-2 treats numbers as graphics operands")
def PDF_META_catalog_integer_value():
    v = plain("luhn", 146)
    return std(catalog_extra=b"/MyRef " + v.encode()), "x.pdf"


@case("PDF-META-name-object-with-digits")
def PDF_META_name_object_with_digits():
    v = plain("luhn", 147)
    return std(catalog_extra=b"/Ref" + v.encode() + b" true"), "x.pdf"


XMP_ELEM = ('<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:description>Ref %s</dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>')
XMP_ATTR = ('<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="Ref %s"/></rdf:RDF></x:xmpmeta><?xpacket end="w"?>')


def xmp_pdf(x, how):
    return std(catalog_extra=b"/Metadata 6 0 R", extra={6: enc_stream(b"/Type /Metadata /Subtype /XML", x.encode(), how)})


@case("PDF-XMP-element-flate")
def PDF_XMP_element_flate():
    return xmp_pdf(XMP_ELEM % " ".join(groups(plain("luhn", 148))), "flate"), "x.pdf"


@case("PDF-XMP-element-uncompressed")
def PDF_XMP_element_uncompressed():
    return xmp_pdf(XMP_ELEM % " ".join(groups(plain("luhn", 149))), "none"), "x.pdf"


@case("PDF-XMP-attribute-form-flate")
def PDF_XMP_attribute_form_flate():
    return xmp_pdf(XMP_ATTR % " ".join(groups(plain("luhn", 150))), "flate"), "x.pdf"


@case("PDF-XMP-attribute-form-uncompressed")
def PDF_XMP_attribute_form_uncompressed():
    return xmp_pdf(XMP_ATTR % " ".join(groups(plain("luhn", 151))), "none"), "x.pdf"


@case("PDF-XMP-ahex", expect="INCOMPLETE")
def PDF_XMP_ahex():
    return xmp_pdf(XMP_ELEM % " ".join(groups(plain("luhn", 152))), "ahex"), "x.pdf"


@case("PDF-XMP-on-page-object-flate")
def PDF_XMP_on_page_object_flate():
    x = XMP_ELEM % " ".join(groups(plain("luhn", 153)))
    return std(page_extra=b"/Metadata 6 0 R", extra={6: enc_stream(b"/Type /Metadata /Subtype /XML", x.encode(), "flate")}), "x.pdf"


@case("PDF-STRUCT-outline-title")
def PDF_STRUCT_outline_title():
    v = plain("luhn", 154)
    return std(catalog_extra=b"/Outlines 6 0 R", extra={6: b"<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>",
                                                           7: b"<< /Title (Ref " + " ".join(groups(v)).encode() + b") /Parent 6 0 R /Dest [3 0 R /Fit] >>"}), "x.pdf"


@case("PDF-STRUCT-pagelabels")
def PDF_STRUCT_pagelabels():
    v = plain("luhn", 155)
    return std(catalog_extra=b"/PageLabels << /Nums [0 << /P (" + " ".join(groups(v)).encode() + b") >>] >>"), "x.pdf"


@case("PDF-STRUCT-comment-line")
def PDF_STRUCT_comment_line():
    v = plain("luhn", 156)
    b = std()
    return b.replace(b"%\xe2\xe3\xcf\xd3\n", b"%\xe2\xe3\xcf\xd3\n% Ref " + " ".join(groups(v)).encode() + b"\n", 1), "x.pdf"


@case("PDF-STRUCT-trailing-data-after-eof")
def PDF_STRUCT_trailing_data_after_eof():
    v = plain("luhn", 157)
    return std() + b"\nRef " + " ".join(groups(v)).encode() + b"\n", "x.pdf"


@case("PDF-STRUCT-text-between-objects")
def PDF_STRUCT_text_between_objects():
    v = plain("luhn", 158)
    b = std()
    return b.replace(b"endobj\n", b"endobj\nRef " + " ".join(groups(v)).encode() + b"\n", 1), "x.pdf"


@case("PDF-STRUCT-ocg-hidden-layer-control")
def PDF_STRUCT_ocg_hidden_layer_control():
    return F.pdf_ocg(val("luhn", 159)), "x.pdf"


@case("PDF-STRUCT-nonfinal-revision-unparseable", note="rev0 trailer has no /Root so pypdf cannot read the rev0 prefix; text uses Differences remap")
def PDF_STRUCT_nonfinal_revision_unparseable():
    v = plain("luhn", 160)
    base_objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                 3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                 4: F.stream(b"", remap_ops(v)), 5: DIFF_FONT % b""}
    base, x = F.write(base_objs, b"")
    out, _ = F.write({4: F.stream(b"", F.text_ops(["Synthetic slip", "Recipient number [redacted]"]))}, b"/Root 1 0 R", base=base, prev=x)
    return out, "x.pdf"


@case("PDF-STRUCT-nonfinal-revision-control", note="same, rev0 trailer has /Root: the old text must be found")
def PDF_STRUCT_nonfinal_revision_control():
    v = plain("luhn", 161)
    base_objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                 3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                 4: F.stream(b"", remap_ops(v)), 5: DIFF_FONT % b""}
    base, x = F.write(base_objs, b"/Root 1 0 R")
    out, _ = F.write({4: F.stream(b"", F.text_ops(["Synthetic slip", "Recipient number [redacted]"]))}, b"/Root 1 0 R", base=base, prev=x)
    return out, "x.pdf"


@case("PDF-STRUCT-no-eof-marker", expect="INCOMPLETE")
def PDF_STRUCT_no_eof_marker():
    return std(content=tj1(plain("luhn", 162))).replace(b"%%EOF", b""), "x.pdf"


# ---- JavaScript rejection (DOC-SIN-02 g)
def xref_stream_pdf(objstm_objs, plain_objs, catalog_open=b""):
    """Classic objects 1..5 plain, objects in objstm_objs {num: body} packed in an ObjStm, plus an XRef stream."""
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offs = {}
    for n in sorted(plain_objs):
        offs[n] = len(out)
        out += b"%d 0 obj\n" % n + plain_objs[n] + b"\nendobj\n"
    nums = sorted(objstm_objs)
    head, body, o = b"", b"", 0
    for n in nums:
        head += b"%d %d " % (n, len(body))
        body += objstm_objs[n] + b"\n"
    objstm_num = max(list(plain_objs) + nums) + 1
    xref_num = objstm_num + 1
    data = head + body
    offs[objstm_num] = len(out)
    out += b"%d 0 obj\n" % objstm_num + F.stream(b"/Type /ObjStm /N %d /First %d" % (len(nums), len(head)), data) + b"\nendobj\n"
    xoff = len(out)
    size = xref_num + 1
    rows = b""
    for n in range(size):
        if n == 0:
            rows += b"\x00\x00\x00\x00\x00\x00\x00"[:7] if False else struct.pack(">BIH", 0, 0, 65535)
        elif n in nums:
            rows += struct.pack(">BIH", 2, objstm_num, nums.index(n))
        elif n == xref_num:
            rows += struct.pack(">BIH", 1, xoff, 0)
        elif n in offs:
            rows += struct.pack(">BIH", 1, offs[n], 0)
        else:
            rows += struct.pack(">BIH", 0, 0, 0)
    out += b"%d 0 obj\n" % xref_num + F.stream(b"/Type /XRef /Size %d /W [1 4 2] /Root 1 0 R" % size, rows) + b"\nendobj\nstartxref\n%d\n%%%%EOF\n" % xoff
    return bytes(out)


def objstm_std(compressed, catalog_extra=b"", page_extra=b""):
    plain_objs = {1: b"<< /Type /Catalog /Pages 2 0 R " + catalog_extra + b" >>", 2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                  3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> " + page_extra + b" >>",
                  4: F.stream(b"", F.text_ops(["Synthetic statement"])), 5: F.FONT}
    return xref_stream_pdf(compressed, plain_objs)


@case("PDF-JS-plain-control", expect="INCOMPLETE")
def PDF_JS_plain_control():
    return F.pdf_javascript(), "x.pdf"


@case("PDF-JS-inside-objstm", expect="INCOMPLETE")
def PDF_JS_inside_objstm():
    return objstm_std({6: b"<< /S /JavaScript /JS (app.alert\\(1\\)) >>"}, catalog_extra=b"/OpenAction 6 0 R"), "x.pdf"


@case("PDF-JS-name-hex-escape", expect="INCOMPLETE")
def PDF_JS_name_hex_escape():
    return std(extra={6: b"<< /S /#4AavaScript /JS (app.alert\\(1\\)) >>"}, catalog_extra=b"/OpenAction 6 0 R"), "x.pdf"


@case("PDF-JS-newline-after-JS-key", expect="INCOMPLETE")
def PDF_JS_newline_after_JS_key():
    return std(extra={6: b"<< /S /JavaScript\n/JS\n(app.alert\\(1\\)) >>"}, catalog_extra=b"/OpenAction 6 0 R").replace(b"/JavaScript", b"/#4AavaScript"), "x.pdf"


@case("PDF-JS-in-xfa-script", expect="INCOMPLETE", note="XFA script element (not a /JS key)")
def PDF_JS_in_xfa_script():
    return _xfa(b"<template><script contentType='application/x-javascript'>app.alert(1)</script></template>"), "x.pdf"


@case("PDF-OBJSTM-annot-contents-compressed")
def PDF_OBJSTM_annot_contents_compressed():
    v = plain("luhn", 163)
    return objstm_std({6: b"<< /Type /Annot /Subtype /FreeText /Rect [10 10 210 50] /Contents (Note " + " ".join(groups(v)).encode() + b") >>"}, page_extra=b"/Annots [6 0 R]"), "x.pdf"


@case("PDF-OBJSTM-orphan-object-compressed")
def PDF_OBJSTM_orphan_object_compressed():
    v = plain("luhn", 164)
    return objstm_std({9: b"<< /Foo (Note " + " ".join(groups(v)).encode() + b") >>"}), "x.pdf"


# ---- embedded files
def emb_pdf(data, how="flate", placement="names", params_first=False, name="a.csv"):
    d = b"/Type /EmbeddedFile" + (b" /Params << /Size 20 >>" if params_first else b"")
    fs = b"<< /Type /Filespec /F (%s) /UF (%s) /EF << /F 6 0 R >> /AFRelationship /Data >>" % (name.encode(), name.encode())
    cat = {"names": b"/Names << /EmbeddedFiles << /Names [(%s) 7 0 R] >> >>" % name.encode(), "af": b"/AF [7 0 R]"}.get(placement, b"")
    ex = {6: enc_stream(d, data, how), 7: fs}
    page_extra = b""
    if placement == "annot":
        ex[8] = b"<< /Type /Annot /Subtype /FileAttachment /Rect [10 10 30 30] /FS 7 0 R /Name /PushPin >>"
        page_extra = b"/Annots [8 0 R]"
    return std(extra=ex, catalog_extra=cat, page_extra=page_extra)


for pl in ("names", "af", "annot", "orphan"):
    @case(f"PDF-EMB-csv-flate-{pl}")
    def PDF_EMB_csv_flate_X(pl=pl):
        return emb_pdf(("ref," + " ".join(groups(plain("luhn", 165))) + "\n").encode(), "flate", pl), "x.pdf"

    @case(f"PDF-EMB-nestedpdf-params-first-{pl}")
    def PDF_EMB_nestedpdf_params_first_X(pl=pl):
        return emb_pdf(F.pdf_visible(val("luhn", 166)), "flate", pl, params_first=True, name="a.pdf"), "x.pdf"

    @case(f"PDF-EMB-csv-flate+ahex-chain-{pl}")
    def PDF_EMB_csv_flate_ahex_chain_X(pl=pl):
        return emb_pdf(("ref," + " ".join(groups(plain("luhn", 167))) + "\n").encode(), "flate+ahex", pl), "x.pdf"

    @case(f"PDF-EMB-csv-ahex-{pl}", expect="INCOMPLETE")
    def PDF_EMB_csv_ahex_X(pl=pl):
        return emb_pdf(("ref," + " ".join(groups(plain("luhn", 168))) + "\n").encode(), "ahex", pl), "x.pdf"

    @case(f"PDF-EMB-csv-lzw-{pl}", expect="INCOMPLETE")
    def PDF_EMB_csv_lzw_X(pl=pl):
        return emb_pdf(("ref," + " ".join(groups(plain("luhn", 169))) + "\n").encode(), "lzw", pl), "x.pdf"

    @case(f"PDF-EMB-zip-{pl}", expect="INCOMPLETE")
    def PDF_EMB_zip_X(pl=pl):
        return emb_pdf(F.zip_archive(val("luhn", 170)), "flate", pl, name="a.zip"), "x.pdf"


@case("PDF-EMB-depth3-value-in-innermost")
def PDF_EMB_depth3_value_in_innermost():
    v = val("luhn", 171)
    p = F.pdf_visible(v)
    for _ in range(3):
        p = emb_pdf(p, "flate", "names", name="a.pdf")
    return p, "x.pdf"


@case("PDF-EMB-depth4-value-in-innermost", expect="INCOMPLETE")
def PDF_EMB_depth4_value_in_innermost():
    v = val("luhn", 172)
    p = F.pdf_visible(v)
    for _ in range(4):
        p = emb_pdf(p, "flate", "names", name="a.pdf")
    return p, "x.pdf"


@case("PDF-EMB-filespec-name-has-value")
def PDF_EMB_filespec_name_has_value():
    v = plain("luhn", 173)
    return emb_pdf(b"hello\n", "flate", "names", name=" ".join(groups(v)) + ".txt"), "x.pdf"


@case("PDF-STRUCT-white-text-on-white-control")
def PDF_STRUCT_white_text_on_white_control():
    v = plain("luhn", 174)
    return std(content=b"1 1 1 rg\n" + tj1(v)), "x.pdf"


@case("PDF-STRUCT-names-tree-dests-string")
def PDF_STRUCT_names_tree_dests_string():
    v = plain("luhn", 175)
    return std(catalog_extra=b"/Names << /Dests << /Names [(Ref " + " ".join(groups(v)).encode() + b") [3 0 R /Fit]] >> >>"), "x.pdf"


@case("PDF-FORM-DV-default-value")
def PDF_FORM_DV_default_value():
    v = plain("luhn", 176)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (holder) /Rect [10.0 10.0 210.0 30.0] /P 3 0 R /DV (" + " ".join(groups(v)).encode() + b") >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-FORM-TU-tooltip")
def PDF_FORM_TU_tooltip():
    v = plain("luhn", 177)
    return std(extra={6: b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (holder) /TU (Ref " + " ".join(groups(v)).encode() + b") /Rect [10.0 10.0 210.0 30.0] /P 3 0 R >>"},
               page_extra=b"/Annots [6 0 R]", catalog_extra=b"/AcroForm << /Fields [6 0 R] >>"), "x.pdf"


@case("PDF-EMB-collection-portfolio-names")
def PDF_EMB_collection_portfolio_names():
    b = emb_pdf(("ref," + " ".join(groups(plain("luhn", 178))) + "\n").encode(), "flate", "names")
    return b.replace(b"/Type /Catalog", b"/Type /Catalog /Collection << /Type /Collection /View /D >>", 1), "x.pdf"


for flt in ("JBIG2Decode", "CCITTFaxDecode", "JPXDecode", "DCTDecode"):
    @case(f"PDF-IMG-unsupported-or-garbage-filter-{flt}", expect="INCOMPLETE")
    def PDF_IMG_unsupported_or_garbage_filter_X(flt=flt):
        body = os.urandom(200)
        imo = b"<< /Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /%s /Length %d >>\nstream\n" % (flt.encode(), len(body)) + body + b"\nendstream"
        return std(content=b"q 100 0 0 100 10 10 cm /Im1 Do Q", extra={6: imo}, resources_extra=b"/XObject << /Im1 6 0 R >>"), "x.pdf"


def _ccitt_pdf(v_line, black_is_1=False):
    from PIL import Image
    im = Image.open(io.BytesIO(F.image(["Synthetic scan", v_line])[0])).convert("1")
    b = io.BytesIO(); im.save(b, "TIFF", compression="group4")
    t = Image.open(io.BytesIO(b.getvalue()))
    off, cnt = t.tag_v2[273], t.tag_v2[279]
    off = off[0] if isinstance(off, tuple) else off; cnt = cnt[0] if isinstance(cnt, tuple) else cnt
    data = b.getvalue()[off:off + cnt]
    w, h = im.size
    imo = (b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode "
           b"/DecodeParms << /K -1 /Columns %d /Rows %d /BlackIs1 %s >> /Length %d >>\nstream\n" % (w, h, w, h, b"true" if black_is_1 else b"false", len(data))) + data + b"\nendstream"
    return std(content=b"q 400 0 0 %d 10 10 cm /Im1 Do Q" % int(400 * h / w), extra={6: imo}, resources_extra=b"/XObject << /Im1 6 0 R >>")


@case("PDF-IMG-ccitt-g4-real-scan-blackis1-false")
def PDF_IMG_ccitt_g4_real_scan_blackis1_false():
    return _ccitt_pdf("Ref " + val("luhn", 179), False), "x.pdf"


@case("PDF-IMG-ccitt-g4-real-scan-blackis1-true")
def PDF_IMG_ccitt_g4_real_scan_blackis1_true():
    return _ccitt_pdf("Ref " + val("luhn", 180), True), "x.pdf"
