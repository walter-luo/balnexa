"""Shared harness for the agentB review cases (vendored from Balnexa_9011_review_SAME_FAMILY_2026-11-11.zip, cases/validator/;
only the REPO path is changed, so that the cases run against this checkout). Synthetic data only: values come from sin_corpus.value() at run time and are
never printed or written. Case functions return (bytes, name) or a dict for special cases. Only ids, verdicts and rule codes
are printed."""
import json, os, sys, time, traceback, signal, io, zlib, base64, struct

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OUT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for p in (os.path.join(REPO, "apps", "executor"), os.path.join(REPO, "tests", "py")):
    if p not in sys.path:
        sys.path.insert(0, p)
from bnx_exec import doc_validator as V   # noqa: E402
from bnx_exec import sin_detector as S    # noqa: E402
import doc_fixtures as F                   # noqa: E402
import sin_corpus as SC                    # noqa: E402

REGISTRY = []   # (id, expect, fn, tags)


def case(cid, expect="DETECT", heavy=False, note=""):
    """expect: DETECT (SIN_CANDIDATE), INCOMPLETE (SCAN_INCOMPLETE or SIN_CANDIDATE is acceptable as safe), CLEAN (PASSED)."""
    def deco(fn):
        REGISTRY.append((cid, expect, fn, {"heavy": heavy, "note": note}))
        return fn
    return deco


def val(kind="luhn", seed=1, group="space"):
    return F.v(kind, seed, group)


def plain(kind="luhn", seed=1):
    return SC.value(kind, seed)


# ---------------------------------------------------------------------------------------------- PDF helpers
def content_page(content, **kw):
    return F.simple_pdf(content, **kw)


def lines_content(lines, **kw):
    return F.text_ops(lines, **kw)


def a85(data):
    return base64.a85encode(data) + b"~>"


def ahex(data):
    return data.hex().encode() + b">"


def runlength(data):
    out = b""
    for i in range(0, len(data), 128):
        ch = data[i:i + 128]
        out += bytes([len(ch) - 1]) + ch
    return out + b"\x80"


def lzw(data):
    assert len(data) < 200
    codes = [256] + [b for b in data] + [257]      # literal codes only (valid LZW stream: no table entries used)
    # Every literal is emitted as its own code; the decoder adds table entries but widths stay at 9 bits for < 254 codes
    bits = "".join(format(c, "09b") for c in codes)
    bits += "0" * (-len(bits) % 8)
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


ENC = {   # name -> (filter name array text, encoder)
    "flate": (b"/FlateDecode", zlib.compress),
    "ahex": (b"/ASCIIHexDecode", ahex),
    "a85": (b"/ASCII85Decode", a85),
    "lzw": (b"/LZWDecode", lzw),
    "rl": (b"/RunLengthDecode", runlength),
    "a85+flate": (b"[/ASCII85Decode /FlateDecode]", lambda d: a85(zlib.compress(d))),
    "ahex+flate": (b"[/ASCIIHexDecode /FlateDecode]", lambda d: ahex(zlib.compress(d))),
    "flate+ahex": (b"[/ASCIIHexDecode /FlateDecode]", None),   # placeholder, built below
    "none": (None, lambda d: d),
}


def enc_stream(dict_body, data, how="flate", dict_after=b""):
    """A stream object body with the named filter(s). dict_body: dictionary entries (without << >>)."""
    f, e = ENC[how]
    if how == "flate+ahex":                      # Filter [/FlateDecode /ASCIIHexDecode] : decode flate first, then hex
        f, body = b"[/FlateDecode /ASCIIHexDecode]", ahex(zlib.compress(data))
    else:
        body = e(data)
    fl = b"" if f is None else b" /Filter " + f
    return b"<< " + dict_body + fl + dict_after + b" /Length " + str(len(body)).encode() + b" >>\nstream\n" + body + b"\nendstream"


def pdf_with(extra, content=None, **kw):
    content = content if content is not None else F.text_ops(["Synthetic statement"])
    return F.simple_pdf(content, extra_objs=extra, **kw)


# ---------------------------------------------------------------------------------------------- zip helpers
def zip_patch(data, add=None, replace=None, remove=(), comment=None):
    import zipfile
    src = zipfile.ZipFile(io.BytesIO(data))
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for i in src.infolist():
            if i.filename in remove:
                continue
            b = src.read(i)
            if replace and i.filename in replace:
                b = replace[i.filename](b)
            z.writestr(i.filename, b)
        for k, b in (add or {}).items():
            z.writestr(k, b)
        if comment is not None:
            z.comment = comment
    return out.getvalue()


# ---------------------------------------------------------------------------------------------- runner
class Timeout(Exception):
    pass


def _alarm(*_):
    raise Timeout()


def run_one(cid, expect, fn, tags, budget=120):
    t0 = time.time()
    rec = {"id": cid, "expect": expect}
    try:
        signal.signal(signal.SIGALRM, _alarm)
        signal.alarm(int(budget) + 60)
        built = fn()
        if isinstance(built, dict):      # special: builder already produced a verdict-like dict
            r = built
        else:
            data, name = built if isinstance(built, tuple) else (built, None)
            r = V.validate(data, name, budget_seconds=budget)
        signal.alarm(0)
        res, rules = r["scan_result"], r["rule_codes"]
        rec.update(result=res, rules=rules)
        if expect == "DETECT":
            rec["verdict"] = "DETECTED" if res == "SIN_CANDIDATE" else ("SCAN_INCOMPLETE" if res == "SCAN_INCOMPLETE" else "MISSED")
        elif expect == "INCOMPLETE":
            rec["verdict"] = "FAIL_CLOSED" if res in ("SCAN_INCOMPLETE", "SIN_CANDIDATE") else "NOT_FAIL_CLOSED"
        else:
            rec["verdict"] = "CLEAN_OK" if res == "PASSED" else "FALSE_POSITIVE"
    except Timeout:
        rec.update(result="TIMEOUT", rules=[], verdict="HANG")
    except BaseException as e:   # noqa: BLE001 - print type only, never the message (could carry content)
        signal.alarm(0)
        rec.update(result="EXCEPTION", rules=[], verdict="EXC_ESCAPED", exc=type(e).__name__)
    rec["secs"] = round(time.time() - t0, 2)
    return rec


def main(modname):
    import importlib, resource
    resource.setrlimit(resource.RLIMIT_AS, (8 << 30, 8 << 30))
    importlib.import_module(modname)
    only = sys.argv[2:]
    out = []
    for cid, expect, fn, tags in list(REGISTRY):
        if not only and fn.__module__ != modname:
            continue
        if only and cid not in only:
            continue
        if not only and tags["heavy"] and not os.environ.get("RUN_HEAVY"):
            continue                          # heavy cases run one per process through run_heavy.py
        rec = run_one(cid, expect, fn, tags)
        out.append(rec)
        print(json.dumps({k: rec[k] for k in ("id", "expect", "verdict", "result", "rules", "secs") + (("exc",) if "exc" in rec else ())}), flush=True)
    if only:
        return                                  # single-case runs (run_heavy.py) do not overwrite the module's record
    os.makedirs(os.path.join(OUT, "runs"), exist_ok=True)
    with open(os.path.join(OUT, "runs", modname + ".jsonl"), "w") as f:
        for r in out:
            f.write(json.dumps(r) + "\n")

