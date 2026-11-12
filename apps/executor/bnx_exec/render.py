"""REPORT_RENDER: a snapshot's projection rows rendered as one self-contained HTML document (UA V1.2 §5.8.2).

The renderer receives the rows exactly as the database digested them (``rows_text`` of the 9018 work order) and refuses to
render unless their SHA-256 equals the snapshot's ``projection_sha256``: an artifact always shows the figures its snapshot
attests. The output is a pure function of the work order (no clock, no host, no random value), so a re-render produces the
same bytes and the same content-addressed object name.
"""
import hashlib
import html
import json
from decimal import Decimal

RENDERER_VERSION = "bnx-render-1.0"


class RenderError(Exception):
    pass


def _rows(order):
    rt = order.get("rows_text")
    if not isinstance(rt, str) or hashlib.sha256(rt.encode()).hexdigest() != order.get("projection_sha256"):
        raise RenderError("PROJECTION_DIGEST")
    rows = json.loads(rt)
    if not isinstance(rows, list):
        raise RenderError("ROWS")
    return rows


def render(order):
    """-> (bytes, facts) where facts = coverage and warnings for the staged result"""
    if order.get("kind") != "REPORT_RENDER" or order.get("report_code") != "R-BAL":
        raise RenderError("REPORT_NOT_SUPPORTED")
    rows = _rows(order)
    labels = {a["account_currency_id"]: a for a in order.get("accounts", [])}
    e = html.escape
    totals, statuses = {}, {}
    body = []
    for r in rows:
        acid = r["account_currency_id"]
        st = r.get("status") or ""
        statuses[st] = statuses.get(st, 0) + 1
        amt = r.get("amount")
        if st == "ok" and amt is not None:
            totals[r["currency"]] = totals.get(r["currency"], Decimal(0)) + Decimal(amt)
        body.append(f"<tr><td>{e(labels.get(acid, {}).get('label', ''))}</td><td>{e(r['currency'])}</td>"
                    f"<td class=n>{e('' if amt is None else str(amt))}</td><td>{e(st)}</td></tr>")
    tot = "".join(f"<tr class=t><td>Total</td><td>{e(c)}</td><td class=n>{e(str(v))}</td><td></td></tr>"
                  for c, v in sorted(totals.items()))
    doc = ("<!doctype html><html lang=en><head><meta charset=utf-8><title>Balances " + e(order["as_of"]) + "</title>"
           "<style>body{font:14px system-ui,sans-serif;margin:24px;color:#111}table{border-collapse:collapse}"
           "td,th{border-bottom:1px solid #ddd;padding:4px 10px;text-align:left}.n{text-align:right;font-variant-numeric:tabular-nums}"
           ".t td{font-weight:600}footer{margin-top:16px;color:#555;font-size:12px}</style></head><body>"
           f"<h1>Balances as of {e(order['as_of'])}</h1>"
           "<table><thead><tr><th>Account</th><th>Currency</th><th class=n>Balance</th><th>Status</th></tr></thead><tbody>"
           + "".join(body) + tot + "</tbody></table>"
           f"<footer>Snapshot {e(order['snapshot_id'])} &middot; ledger version {e(str(order['ledger_version']))} &middot; "
           f"definition {e(order['definition_version'])} &middot; projection SHA-256 {e(order['projection_sha256'])} &middot; "
           f"{e(RENDERER_VERSION)}</footer></body></html>\n")
    warnings = sorted(f"STATUS_{s}" for s in statuses if s != "ok")
    coverage = {"rows": len(rows), "statuses": dict(sorted(statuses.items()))}
    return doc.encode(), {"coverage": coverage, "warnings": warnings}
