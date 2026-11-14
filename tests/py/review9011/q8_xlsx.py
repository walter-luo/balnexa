# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Q8 XLSX hiding places."""
from common import *
import openpyxl


def wb_bytes(build):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Summary"
    ws.append(["Account", "Balance"])
    ws.append(["Chequing", "1234.56"])
    build(wb, ws)
    b = io.BytesIO()
    wb.save(b)
    return b.getvalue()


def g(v):
    return " ".join((v[:3], v[3:6], v[6:]))


def raw_part(name, xml, enc="utf-8"):
    data = F.xlsx() if False else wb_bytes(lambda wb, ws: None)
    return zip_patch(data, add={name: xml.encode(enc) if isinstance(xml, str) else xml})


@case("XLSX-ctl-visible-cell")
def XLSX_ctl_visible_cell():
    return wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 201))])), "x.xlsx"


@case("XLSX-ctl-numeric-9digit-cell")
def XLSX_ctl_numeric_9digit_cell():
    return wb_bytes(lambda wb, ws: ws.append(["Ref", int(plain("luhn", 202))])), "x.xlsx"


@case("XLSX-ctl-very-hidden-sheet")
def XLSX_ctl_very_hidden_sheet():
    return F.xlsx(very_hidden=g(plain("luhn", 203))), "x.xlsx"


@case("XLSX-ctl-comment")
def XLSX_ctl_comment():
    return F.xlsx(comment=g(plain("luhn", 204))), "x.xlsx"


@case("XLSX-ctl-property")
def XLSX_ctl_property():
    return F.xlsx(prop=g(plain("luhn", 205))), "x.xlsx"


@case("XLSX-ctl-rich-text-runs-in-cell")
def XLSX_ctl_rich_text_runs_in_cell():
    from openpyxl.cell.rich_text import CellRichText, TextBlock
    from openpyxl.cell.text import InlineFont
    v = plain("luhn", 206)
    def b(wb, ws):
        ws["A3"] = CellRichText(TextBlock(InlineFont(b=True), v[:3] + " " + v[3:6] + " "), TextBlock(InlineFont(i=True), v[6:]))
    return wb_bytes(b), "x.xlsx"


@case("XLSX-sheet-name")
def XLSX_sheet_name():
    v = plain("luhn", 207)
    return wb_bytes(lambda wb, ws: wb.create_sheet("Ref " + g(v))), "x.xlsx"


@case("XLSX-data-validation-prompt-attr")
def XLSX_data_validation_prompt_attr():
    from openpyxl.worksheet.datavalidation import DataValidation
    v = plain("luhn", 208)
    def b(wb, ws):
        dv = DataValidation(type="list", formula1='"a,b"', showInputMessage=True, promptTitle="t", prompt="Ref " + g(v))
        ws.add_data_validation(dv); dv.add("C2")
    return wb_bytes(b), "x.xlsx"


@case("XLSX-hyperlink-tooltip-attr")
def XLSX_hyperlink_tooltip_attr():
    from openpyxl.worksheet.hyperlink import Hyperlink
    v = plain("luhn", 209)
    def b(wb, ws):
        ws["C2"] = "link"
        ws["C2"].hyperlink = Hyperlink(ref="C2", location="Summary!A1", tooltip="Ref " + g(v))
    return wb_bytes(b), "x.xlsx"


@case("XLSX-numfmt-literal-text-attr")
def XLSX_numfmt_literal_text_attr():
    v = plain("luhn", 210)
    def b(wb, ws):
        ws["C2"] = 1
        ws["C2"].number_format = '"Ref ' + g(v) + '"'
    return wb_bytes(b), "x.xlsx"


@case("XLSX-numfmt-thousands-scale")
def XLSX_numfmt_thousands_scale():
    v = plain("luhn", 211)
    def b(wb, ws):
        ws["C2"] = int(v + "000")
        ws["C2"].number_format = "0,"
    return wb_bytes(b), "x.xlsx"


@case("XLSX-formula-concat-no-cached-value")
def XLSX_formula_concat_no_cached_value():
    v = plain("luhn", 212)
    def b(wb, ws):
        ws["C2"] = '="%s"&"%s"&"%s"' % (v[:3], v[3:6], v[6:])
    return wb_bytes(b), "x.xlsx"


@case("XLSX-formula-char-codes-no-cached-value")
def XLSX_formula_char_codes_no_cached_value():
    v = plain("luhn", 213)
    def b(wb, ws):
        ws["C2"] = "=" + "&".join("CHAR(%d)" % (48 + int(c)) for c in v)
    return wb_bytes(b), "x.xlsx"


@case("XLSX-formula-literal-with-value")
def XLSX_formula_literal_with_value():
    v = plain("luhn", 214)
    return wb_bytes(lambda wb, ws: ws.__setitem__("C2", '="Ref ' + g(v) + '"')), "x.xlsx"


@case("XLSX-label-in-row4-value-below-nonluhn")
def XLSX_label_in_row4_value_below_nonluhn():
    v = plain("nonluhn", 215)
    def b(wb, ws):
        ws["A4"] = "SIN"; ws["A5"] = v
    return wb_bytes(b), "x.xlsx"


@case("XLSX-label-in-row2-header-values-below-nonluhn")
def XLSX_label_in_row2_header_values_below_nonluhn():
    v = plain("nonluhn", 216)
    def b(wb, ws):
        ws.insert_rows(1)
        ws["C1"] = "Employee list"
        ws["C2"] = "Social insurance number"
        ws["C3"] = v
    return wb_bytes(b), "x.xlsx"


@case("XLSX-label-in-row4-value-below-far-from-label")
def XLSX_label_in_row4_value_below_far_from_label():
    v = plain("nonluhn", 245)
    def b(wb, ws):
        ws["A4"] = "SIN"
        for k in range(2, 14):
            ws.cell(row=4, column=k, value="filler text number %d" % k)
        ws["A5"] = v
    return wb_bytes(b), "x.xlsx"


@case("XLSX-label-right-of-label-cell-nonluhn")
def XLSX_label_right_of_label_cell_nonluhn():
    v = plain("nonluhn", 217)
    def b(wb, ws):
        ws["A4"] = "SIN"; ws["B4"] = v
    return wb_bytes(b), "x.xlsx"


@case("XLSX-label-far-column-header-row1")
def XLSX_label_far_column_header_row1():
    v = plain("nonluhn", 218)
    def b(wb, ws):
        ws["F1"] = "SIN"; ws["F3"] = v
    return wb_bytes(b), "x.xlsx"


@case("XLSX-split-across-three-cells", note="by design D-9011c-7")
def XLSX_split_across_three_cells():
    v = plain("luhn", 219)
    return wb_bytes(lambda wb, ws: ws.append([v[:3], v[3:6], v[6:]])), "x.xlsx"


# ---- raw parts
DML = 'xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'


@case("XLSX-part-drawing-alt-text-attr")
def XLSX_part_drawing_alt_text_attr():
    v = plain("luhn", 220)
    return raw_part("xl/drawings/drawing1.xml", f'<xdr:wsDr {DML}><xdr:oneCellAnchor><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="2" name="Picture 1" descr="Ref {g(v)}"/></xdr:nvPicPr></xdr:pic></xdr:oneCellAnchor></xdr:wsDr>'), "x.xlsx"


@case("XLSX-part-drawing-textbox-one-run-control")
def XLSX_part_drawing_textbox_one_run_control():
    v = plain("luhn", 221)
    return raw_part("xl/drawings/drawing1.xml", f'<xdr:wsDr {DML}><xdr:sp><xdr:txBody><a:p><a:r><a:t>Ref {g(v)}</a:t></a:r></a:p></xdr:txBody></xdr:sp></xdr:wsDr>'), "x.xlsx"


@case("XLSX-part-drawing-textbox-split-runs")
def XLSX_part_drawing_textbox_split_runs():
    v = plain("luhn", 222)
    return raw_part("xl/drawings/drawing1.xml", f'<xdr:wsDr {DML}><xdr:sp><xdr:txBody><a:p><a:r><a:t>Ref {v[:3]} {v[3:6]} </a:t></a:r><a:r><a:t>{v[6:]}</a:t></a:r></a:p></xdr:txBody></xdr:sp></xdr:wsDr>'), "x.xlsx"


@case("XLSX-part-chart-title-split-runs")
def XLSX_part_chart_title_split_runs():
    v = plain("luhn", 223)
    return raw_part("xl/charts/chart1.xml", f'<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>{v[:3]} {v[3:6]}</a:t></a:r><a:r><a:t> {v[6:]}</a:t></a:r></a:p></c:rich></c:tx></c:title></c:chart></c:chartSpace>'), "x.xlsx"


@case("XLSX-part-customxml-cdata")
def XLSX_part_customxml_cdata():
    v = plain("luhn", 224)
    return raw_part("customXml/item1.xml", f'<root><n><![CDATA[Ref {g(v)}]]></n></root>'), "x.xlsx"


@case("XLSX-part-customxml-element-control")
def XLSX_part_customxml_element_control():
    v = plain("luhn", 225)
    return raw_part("customXml/item1.xml", f'<root><n>Ref {g(v)}</n></root>'), "x.xlsx"


@case("XLSX-part-xml-comment")
def XLSX_part_xml_comment():
    v = plain("luhn", 226)
    return raw_part("xl/drawings/drawing1.xml", f'<root><!-- Ref {g(v)} --></root>'), "x.xlsx"


@case("XLSX-part-utf16-xml")
def XLSX_part_utf16_xml():
    v = plain("luhn", 227)
    return raw_part("customXml/item1.xml", ('<?xml version="1.0" encoding="UTF-16"?><root><n>Ref ' + g(v) + '</n></root>').encode("utf-16"), ), "x.xlsx"


@case("XLSX-part-pivotcache-attr")
def XLSX_part_pivotcache_attr():
    v = plain("luhn", 228)
    return raw_part("xl/pivotCache/pivotCacheRecords1.xml", f'<pivotCacheRecords xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1"><r><s v="Ref {g(v)}"/></r></pivotCacheRecords>'), "x.xlsx"


@case("XLSX-part-custom-doc-prop-value-control")
def XLSX_part_custom_doc_prop_value_control():
    v = plain("luhn", 229)
    return raw_part("docProps/custom.xml", f'<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{{D5CDD505-2E9C-101B-9397-08002B2CF9AE}}" pid="2" name="x"><vt:lpwstr>Ref {g(v)}</vt:lpwstr></property></Properties>'), "x.xlsx"


@case("XLSX-part-custom-doc-prop-name-attr")
def XLSX_part_custom_doc_prop_name_attr():
    v = plain("luhn", 230)
    return raw_part("docProps/custom.xml", f'<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{{D5CDD505-2E9C-101B-9397-08002B2CF9AE}}" pid="2" name="Ref {g(v)}"><vt:lpwstr>x</vt:lpwstr></property></Properties>'), "x.xlsx"


@case("XLSX-part-threaded-comment-control")
def XLSX_part_threaded_comment_control():
    v = plain("luhn", 231)
    return raw_part("xl/threadedComments/threadedComment1.xml", f'<ThreadedComments xmlns="http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments"><threadedComment ref="A1" id="{{1}}"><text>Ref {g(v)}</text></threadedComment></ThreadedComments>'), "x.xlsx"


@case("XLSX-part-unlisted-extension-txt")
def XLSX_part_unlisted_extension_txt():
    v = plain("luhn", 232)
    return raw_part("xl/notes.txt", "Ref " + g(v)), "x.xlsx"


@case("XLSX-part-unlisted-extension-json")
def XLSX_part_unlisted_extension_json():
    v = plain("luhn", 233)
    return raw_part("xl/notes.json", '{"ref":"' + g(v) + '"}'), "x.xlsx"


@case("XLSX-part-docprops-thumbnail-jpeg")
def XLSX_part_docprops_thumbnail_jpeg():
    img, _ = F.image(["Synthetic", "Ref " + val("luhn", 234)], fmt="JPEG")
    return raw_part("docProps/thumbnail.jpeg", img), "x.xlsx"


@case("XLSX-part-media-png-control")
def XLSX_part_media_png_control():
    img, _ = F.image(["Synthetic", "Ref " + val("luhn", 235)])
    return raw_part("xl/media/image1.png", img), "x.xlsx"


@case("XLSX-part-drawings-dir-png")
def XLSX_part_drawings_dir_png():
    img, _ = F.image(["Synthetic", "Ref " + val("luhn", 236)])
    return raw_part("xl/drawings/image1.png", img), "x.xlsx"


@case("XLSX-part-media-gif", expect="INCOMPLETE")
def XLSX_part_media_gif():
    from PIL import Image
    im = Image.new("RGB", (40, 20), "white"); b = io.BytesIO(); im.save(b, "GIF")
    return raw_part("xl/media/image1.gif", b.getvalue()), "x.xlsx"


@case("XLSX-part-emf-in-drawings")
def XLSX_part_emf_in_drawings():
    return raw_part("xl/drawings/image1.emf", b"\x01\x00\x00\x00" + b"Ref " + g(plain("luhn", 237)).encode("utf-16-le")), "x.xlsx"


@case("XLSX-part-embedded-xlsx-nested")
def XLSX_part_embedded_xlsx_nested():
    inner = wb_bytes(lambda wb, ws: ws.append(["Ref", g(plain("luhn", 238))]))
    return raw_part("xl/embeddings/Microsoft_Excel_Sheet1.xlsx", inner), "x.xlsx"


@case("XLSX-part-embedded-ole-bin", expect="INCOMPLETE")
def XLSX_part_embedded_ole_bin():
    return raw_part("xl/embeddings/oleObject1.bin", b"\xd0\xcf\x11\xe0" + b"\0" * 60), "x.xlsx"


@case("XLSX-part-printersettings-bin", expect="INCOMPLETE")
def XLSX_part_printersettings_bin():
    return raw_part("xl/printerSettings/printerSettings1.bin", b"\0" * 20), "x.xlsx"


@case("XLSX-zip-comment")
def XLSX_zip_comment():
    v = plain("luhn", 239)
    return zip_patch(wb_bytes(lambda wb, ws: None), comment=("Ref " + g(v)).encode()), "x.xlsx"


@case("XLSX-zip-extra-field-and-trailing-data")
def XLSX_zip_extra_field_and_trailing_data():
    v = plain("luhn", 240)
    return wb_bytes(lambda wb, ws: None) + b"\nRef " + g(v).encode(), "x.xlsx"


@case("XLSX-zip-duplicate-member-name")
def XLSX_zip_duplicate_member_name():
    import zipfile, warnings
    v = plain("luhn", 241)
    out = io.BytesIO()
    src = zipfile.ZipFile(io.BytesIO(wb_bytes(lambda wb, ws: None)))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("customXml/item1.xml", "<r><n>Ref " + g(v) + "</n></r>")
            for i in src.infolist():
                z.writestr(i.filename, src.read(i))
            z.writestr("customXml/item1.xml", "<r><n>clean</n></r>")
    return out.getvalue(), "x.xlsx"


@case("XLSX-encrypted-ole-container", expect="INCOMPLETE")
def XLSX_encrypted_ole_container():
    return b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\0" * 500 + "EncryptedPackage".encode("utf-16-le"), "x.xlsx"


@case("XLSX-macro-workbook", expect="INCOMPLETE")
def XLSX_macro_workbook():
    return F.xlsx(macro=True), "x.xlsx"


@case("XLSX-truncated-zip", expect="INCOMPLETE")
def XLSX_truncated_zip():
    d = wb_bytes(lambda wb, ws: None)
    return d[:len(d) // 2], "x.xlsx"


@case("XLSX-member-encrypted-flag", expect="INCOMPLETE")
def XLSX_member_encrypted_flag():
    d = bytearray(wb_bytes(lambda wb, ws: None))
    i = d.find(b"PK\x01\x02")
    d[i + 8] |= 1
    return bytes(d), "x.xlsx"


@case("XLSX-hidden-rows-and-columns-control")
def XLSX_hidden_rows_and_columns_control():
    v = plain("luhn", 242)
    def b(wb, ws):
        ws.append(["Ref", g(v)]); ws.row_dimensions[4].hidden = True; ws.column_dimensions["B"].hidden = True
    return wb_bytes(b), "x.xlsx"


@case("XLSX-defined-name-sheet-scoped-name-attr")
def XLSX_defined_name_sheet_scoped_name_attr():
    v = plain("luhn", 243)
    from openpyxl.workbook.defined_name import DefinedName
    def b(wb, ws):
        ws.defined_names.add(DefinedName("Ref" + v, attr_text="Summary!$A$1")) if hasattr(ws.defined_names, "add") else ws.defined_names.__setitem__("Ref" + v, DefinedName("Ref" + v, attr_text="Summary!$A$1"))
    return wb_bytes(b), "x.xlsx"


@case("XLSX-table-column-name-attr")
def XLSX_table_column_name_attr():
    from openpyxl.worksheet.table import Table
    v = plain("luhn", 244)
    def b(wb, ws):
        ws["D1"] = "Ref " + g(v); ws["D2"] = 1
        ws.add_table(Table(displayName="T1", ref="D1:D2"))
    return wb_bytes(b), "x.xlsx"
