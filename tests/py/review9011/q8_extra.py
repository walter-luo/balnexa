# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Extra Q8 cases found during the ITN sweep."""
from common import *
import q8_pdf as P, q8_xlsx as X


def g(v):
    return " ".join((v[:3], v[3:6], v[6:]))


for kind in ("luhn", "itn_nonluhn", "itn_luhn", "nonluhn"):
    for seed in range(1, 7):
        @case(f"PDF-PAGE-reverse-stream-order-{kind}-seed{seed}", expect="DETECT" if kind != "nonluhn" else "CLEAN")
        def PDF_PAGE_reverse_stream_order_X_seedX(kind=kind, seed=seed):
            gg = P.groups(plain(kind, 900 + seed))
            ops = b"BT /F1 12 Tf 1 0 0 1 128 600 Tm (%s) Tj ET\nBT /F1 12 Tf 1 0 0 1 100 600 Tm (%s) Tj ET\nBT /F1 12 Tf 1 0 0 1 72 600 Tm (%s) Tj ET\n" % (gg[2].encode(), gg[1].encode(), gg[0].encode())
            return P.std(content=ops), "x.pdf"


@case("XLSX-itn-numeric-cell-leading-zero-lost-numfmt-zero-pad")
def XLSX_itn_numeric_cell_leading_zero_lost_numfmt_zero_pad():
    v = plain("itn_nonluhn", 950)
    assert v[0] == "0"
    def b(wb, ws):
        ws["C2"] = int(v); ws["C2"].number_format = "0" * 9
    return X.wb_bytes(b), "x.xlsx"


@case("XLSX-itn-numeric-cell-leading-zero-lost-label-SIN-header")
def XLSX_itn_numeric_cell_leading_zero_lost_label_SIN_header():
    v = plain("itn_nonluhn", 951)
    def b(wb, ws):
        ws["D1"] = "SIN"; ws["D2"] = int(v); ws["D2"].number_format = "0" * 9
    return X.wb_bytes(b), "x.xlsx"


@case("XLSX-numeric-cell-itn-as-text-control")
def XLSX_numeric_cell_itn_as_text_control():
    v = plain("itn_nonluhn", 952)
    return X.wb_bytes(lambda wb, ws: ws.__setitem__("C2", v)), "x.xlsx"


# Reading order != content-stream order. pypdf.extract_text() returns stream order (checked in q8_extra_order_probe), so a value whose groups
# are shown in another order than they are laid out is extracted as a permutation. Mod 10 is invariant under swapping the first and last
# group (shift of 6 positions), so that permutation still hits R_MOD10; the middle-group permutation breaks Mod 10 half of the time.
PERMS = {"swap-first-last": (2, 1, 0), "middle-first": (1, 0, 2), "middle-last": (0, 2, 1)}
XPOS = (72, 100, 128)
for pname, order in PERMS.items():
    for kind in ("luhn", "itn_nonluhn"):
        for seed in range(1, 7):
            @case(f"PDF-PAGE-order-{pname}-{kind}-seed{seed}")
            def PDF_PAGE_order_X_X_seedX(order=order, kind=kind, seed=seed):
                gg = P.groups(plain(kind, 960 + seed))
                ops = b"".join(b"BT /F1 12 Tf 1 0 0 1 %d 600 Tm (%s) Tj ET\n" % (XPOS[k], gg[k].encode()) for k in order)   # shown in `order`, laid out left to right as g0 g1 g2
                return P.std(content=ops), "x.pdf"
