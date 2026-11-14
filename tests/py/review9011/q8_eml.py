# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Q8 EML hiding places."""
from common import *
import email.message, email.policy, email.utils, quopri

HDR = b"From: bank@example.invalid\r\nTo: owner@example.invalid\r\nMessage-ID: <s@example.invalid>\r\nMIME-Version: 1.0\r\n"


def g(v):
    return " ".join((v[:3], v[3:6], v[6:]))


def raw_msg(subject=b"Synthetic", extra_headers=b"", ctype=b"text/plain; charset=utf-8", body=b"Synthetic statement.\r\n", cte=None):
    h = HDR + b"Subject: " + subject + b"\r\n" + extra_headers + b"Content-Type: " + ctype + b"\r\n"
    if cte:
        h += b"Content-Transfer-Encoding: " + cte + b"\r\n"
    return h + b"\r\n" + body


def multipart(parts, sub=b"mixed", preamble=b"", epilogue=b"", bnd=b"BNDRY"):
    out = HDR + b"Subject: Synthetic\r\nContent-Type: multipart/" + sub + b'; boundary="' + bnd + b'"\r\n\r\n' + preamble
    for hdrs, body in parts:
        out += b"--" + bnd + b"\r\n" + hdrs + b"\r\n\r\n" + body + b"\r\n"
    return out + b"--" + bnd + b"--\r\n" + epilogue


def b64(b):
    return base64.encodebytes(b).replace(b"\n", b"\r\n")


def ew(text, enc="B"):
    if enc == "B":
        return b"=?utf-8?B?" + base64.b64encode(text.encode()) + b"?="
    return b"=?utf-8?Q?" + text.replace(" ", "_").encode() + b"?="


TXT = (b"Content-Type: text/plain; charset=utf-8", b"Synthetic body.")


@case("EML-ctl-subject-raw")
def EML_ctl_subject_raw():
    return raw_msg(subject=b"Ref " + g(plain("luhn", 301)).encode()), "x.eml"


@case("EML-ctl-body-plain")
def EML_ctl_body_plain():
    return raw_msg(body=b"Ref " + g(plain("luhn", 302)).encode()), "x.eml"


@case("EML-subject-encoded-word-base64")
def EML_subject_encoded_word_base64():
    return raw_msg(subject=ew("Ref " + g(plain("luhn", 303)))), "x.eml"


@case("EML-subject-encoded-word-q")
def EML_subject_encoded_word_q():
    return raw_msg(subject=ew("Ref " + g(plain("luhn", 304)), "Q")), "x.eml"


@case("EML-subject-encoded-word-split-in-two")
def EML_subject_encoded_word_split_in_two():
    v = g(plain("luhn", 305))
    return raw_msg(subject=ew("Ref " + v[:5]) + b" " + ew(v[5:])), "x.eml"


@case("EML-from-display-name-encoded-word")
def EML_from_display_name_encoded_word():
    return raw_msg(extra_headers=b"Reply-To: " + ew(g(plain("luhn", 306))) + b" <a@example.invalid>\r\n"), "x.eml"


@case("EML-body-base64-control")
def EML_body_base64_control():
    return raw_msg(body=b64(("Ref " + g(plain("luhn", 307))).encode()), cte=b"base64"), "x.eml"


@case("EML-body-qp-softbreaks-control")
def EML_body_qp_softbreaks_control():
    v = g(plain("luhn", 308))
    return raw_msg(body=("Ref " + v[:5] + "=\r\n" + v[5:] + "\r\n").encode(), cte=b"quoted-printable"), "x.eml"


@case("EML-body-utf16-charset")
def EML_body_utf16_charset():
    return raw_msg(ctype=b"text/plain; charset=utf-16", body=b64(("Ref " + g(plain("luhn", 309))).encode("utf-16")), cte=b"base64"), "x.eml"


@case("EML-body-gb2312-label-nonluhn")
def EML_body_gb2312_label_nonluhn():
    v = plain("nonluhn", 310)
    return raw_msg(ctype=b"text/plain; charset=gb2312", body=b64(("社会保险号 " + v).encode("gb2312")), cte=b"base64"), "x.eml"


@case("EML-body-8bit-gbk-undeclared-label-nonluhn")
def EML_body_8bit_gbk_undeclared_label_nonluhn():
    v = plain("nonluhn", 311)
    return raw_msg(ctype=b"text/plain", body=("社会保险号 " + v).encode("gbk"), cte=b"8bit"), "x.eml"


@case("EML-body-unknown-charset", expect="INCOMPLETE")
def EML_body_unknown_charset():
    return raw_msg(ctype=b"text/plain; charset=x-no-such-charset", body=b"Ref " + g(plain("luhn", 312)).encode()), "x.eml"


@case("EML-html-only-control")
def EML_html_only_control():
    return raw_msg(ctype=b"text/html; charset=utf-8", body=("<html><body><p>Ref " + g(plain("luhn", 313)) + "</p></body></html>").encode()), "x.eml"


@case("EML-html-inline-spans-split-digits")
def EML_html_inline_spans_split_digits():
    v = plain("luhn", 314)
    return raw_msg(ctype=b"text/html; charset=utf-8", body=("<p>Ref <span>%s</span><span>%s</span><span>%s</span></p>" % (v[:3], v[3:6], v[6:])).encode()), "x.eml"


@case("EML-html-spans-with-space-between-groups")
def EML_html_spans_with_space_between_groups():
    v = plain("luhn", 315)
    return raw_msg(ctype=b"text/html; charset=utf-8", body=("<p>Ref <b>%s</b> <b>%s</b> <b>%s</b></p>" % (v[:3], v[3:6], v[6:])).encode()), "x.eml"


@case("EML-html-comment-inside-digits")
def EML_html_comment_inside_digits():
    v = plain("luhn", 316)
    return raw_msg(ctype=b"text/html; charset=utf-8", body=("<p>Ref %s<!-- x -->%s<!-- y -->%s</p>" % (v[:3], v[3:6], v[6:])).encode()), "x.eml"


@case("EML-html-attribute-alt-title")
def EML_html_attribute_alt_title():
    return raw_msg(ctype=b"text/html; charset=utf-8", body=('<p><img alt="Ref %s" src="x"></p>' % g(plain("luhn", 317))).encode()), "x.eml"


@case("EML-html-display-none-and-css-content")
def EML_html_display_none_and_css_content():
    v = plain("luhn", 318)
    return raw_msg(ctype=b"text/html; charset=utf-8", body=('<style>p::before{content:"%s"}</style><p>x</p>' % g(v)).encode()), "x.eml"


@case("EML-attachment-filename-plain")
def EML_attachment_filename_plain():
    v = g(plain("luhn", 319))
    return multipart([TXT, (b'Content-Type: application/octet-stream; name="' + v.encode() + b'.csv"\r\nContent-Disposition: attachment; filename="' + v.encode() + b'.csv"\r\nContent-Transfer-Encoding: base64', b64(b"a,b\n1,2\n"))]), "x.eml"


@case("EML-attachment-filename-rfc2231")
def EML_attachment_filename_rfc2231():
    v = plain("luhn", 320)
    return multipart([TXT, (b"Content-Type: text/csv\r\nContent-Disposition: attachment; filename*=utf-8''Ref%20" + v.encode() + b".csv\r\nContent-Transfer-Encoding: base64", b64(b"a,b\n1,2\n"))]), "x.eml"


@case("EML-attachment-filename-encoded-word")
def EML_attachment_filename_encoded_word():
    v = g(plain("luhn", 321))
    return multipart([TXT, (b'Content-Type: text/csv\r\nContent-Disposition: attachment; filename="' + ew("Ref " + v + ".csv") + b'"\r\nContent-Transfer-Encoding: base64', b64(b"a,b\n1,2\n"))]), "x.eml"


@case("EML-part-header-content-description")
def EML_part_header_content_description():
    v = g(plain("luhn", 322))
    return multipart([(b"Content-Type: text/plain; charset=utf-8\r\nContent-Description: Ref " + v.encode(), b"Synthetic body.")]), "x.eml"


@case("EML-preamble")
def EML_preamble():
    return multipart([TXT], preamble=b"Ref " + g(plain("luhn", 323)).encode() + b"\r\n"), "x.eml"


@case("EML-epilogue")
def EML_epilogue():
    return multipart([TXT], epilogue=b"Ref " + g(plain("luhn", 324)).encode() + b"\r\n"), "x.eml"


@case("EML-nested-rfc822-inner-subject-header")
def EML_nested_rfc822_inner_subject_header():
    inner = raw_msg(subject=b"Ref " + g(plain("luhn", 325)).encode(), body=b"inner clean\r\n")
    return multipart([(b"Content-Type: message/rfc822", inner)]), "x.eml"


@case("EML-nested-rfc822-inner-body-control")
def EML_nested_rfc822_inner_body_control():
    inner = raw_msg(body=b"Ref " + g(plain("luhn", 326)).encode() + b"\r\n")
    return multipart([(b"Content-Type: message/rfc822", inner)]), "x.eml"


@case("EML-nested-rfc822-attached-with-filename-body")
def EML_nested_rfc822_attached_with_filename_body():
    inner = raw_msg(body=b"Ref " + g(plain("luhn", 327)).encode() + b"\r\n")
    return multipart([TXT, (b'Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename="fwd.eml"', inner)]), "x.eml"


def nest(depth, leaf):
    m = leaf
    for _ in range(depth):
        m = multipart([TXT, (b"Content-Type: message/rfc822", m)])
    return m


@case("EML-nested-depth-3-leaf-value")
def EML_nested_depth_3_leaf_value():
    return nest(3, raw_msg(body=b"Ref " + g(plain("luhn", 328)).encode() + b"\r\n")), "x.eml"


@case("EML-nested-depth-6-leaf-value", expect="INCOMPLETE")
def EML_nested_depth_6_leaf_value():
    return nest(6, raw_msg(body=b"Ref " + g(plain("luhn", 329)).encode() + b"\r\n")), "x.eml"


@case("EML-attached-pdf-control")
def EML_attached_pdf_control():
    return multipart([TXT, (b'Content-Type: application/pdf; name="a.pdf"\r\nContent-Disposition: attachment; filename="a.pdf"\r\nContent-Transfer-Encoding: base64', b64(F.pdf_visible(val("luhn", 330))))]), "x.eml"


@case("EML-attached-png-ocr-control")
def EML_attached_png_ocr_control():
    img, _ = F.image(["Synthetic", "Ref " + val("luhn", 331)])
    return multipart([TXT, (b'Content-Type: image/png; name="a.png"\r\nContent-Disposition: inline; filename="a.png"\r\nContent-Transfer-Encoding: base64', b64(img))]), "x.eml"


@case("EML-attached-tnef-winmail", expect="INCOMPLETE")
def EML_attached_tnef_winmail():
    return multipart([TXT, (b'Content-Type: application/ms-tnef; name="winmail.dat"\r\nContent-Transfer-Encoding: base64', b64(b"\x78\x9f\x3e\x22" + b"Ref " + g(plain("luhn", 332)).encode("utf-16-le")))]), "x.eml"


@case("EML-attached-zip", expect="INCOMPLETE")
def EML_attached_zip():
    return multipart([TXT, (b'Content-Type: application/zip; name="a.zip"\r\nContent-Disposition: attachment; filename="a.zip"\r\nContent-Transfer-Encoding: base64', b64(F.zip_archive(val("luhn", 333))))]), "x.eml"


@case("EML-attachment-no-name-text-plain-octet", expect="INCOMPLETE")
def EML_attachment_no_name_text_plain_octet():
    return multipart([TXT, (b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64", b64(b"Ref " + g(plain("luhn", 334)).encode()))]), "x.eml"


@case("EML-text-calendar-part")
def EML_text_calendar_part():
    return multipart([TXT, (b"Content-Type: text/calendar; charset=utf-8", b"BEGIN:VCALENDAR\r\nDESCRIPTION:Ref " + g(plain("luhn", 335)).encode() + b"\r\nEND:VCALENDAR")]), "x.eml"


@case("EML-text-part-with-filename-txt")
def EML_text_part_with_filename_txt():
    return multipart([TXT, (b'Content-Type: text/plain; name="n.txt"\r\nContent-Disposition: attachment; filename="n.txt"', b"Ref " + g(plain("luhn", 336)).encode())]), "x.eml"


@case("EML-text-part-with-filename-no-ext", expect="INCOMPLETE")
def EML_text_part_with_filename_no_ext():
    return multipart([TXT, (b'Content-Type: text/plain; name="notes"\r\nContent-Disposition: attachment; filename="notes"', b"Ref " + g(plain("luhn", 337)).encode())]), "x.eml"


@case("EML-body-uuencode")
def EML_body_uuencode():
    import binascii
    t = ("Ref " + g(plain("luhn", 338))).encode()
    return raw_msg(ctype=b"text/plain", body=b"begin 644 f.txt\r\n" + binascii.b2a_uu(t) + b"end\r\n", cte=b"x-uuencode"), "x.eml"


@case("EML-pgp-armored-body-unreadable")
def EML_pgp_armored_body_unreadable():
    return raw_msg(body=b"-----BEGIN PGP MESSAGE-----\r\n\r\n" + b64(os.urandom(300)) + b"-----END PGP MESSAGE-----\r\n"), "x.eml"


@case("EML-smime-encrypted-p7m", expect="INCOMPLETE")
def EML_smime_encrypted_p7m():
    return multipart([TXT, (b'Content-Type: application/pkcs7-mime; smime-type=enveloped-data; name="smime.p7m"\r\nContent-Transfer-Encoding: base64', b64(os.urandom(300)))]), "x.eml"


@case("EML-eml-sniffed-no-name-from-header")
def EML_eml_sniffed_no_name_from_header():
    return raw_msg(subject=ew("Ref " + g(plain("luhn", 339)))), None


@case("EML-huge-header-count-and-depth-multipart", expect="INCOMPLETE")
def EML_huge_header_count_and_depth_multipart():
    m = b"Ref " + g(plain("luhn", 340)).encode()
    for _ in range(1500):
        m = b"Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\nx\r\n--B\r\n" + m + b"\r\n--B--\r\n"
    return HDR + m, "x.eml"
