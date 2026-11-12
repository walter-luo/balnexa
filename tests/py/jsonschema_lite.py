"""JSON Schema subset used by the bnx-tools/1.0 catalog (a port of apps/worker/src/schema.js validate()), and the output
contract: every result of a tool with a curated output schema (db/catalog/bnx-tools-1.0.overrides.json, schemas.<fn>.output)
must conform, wherever a test calls it as bnx_app (2.8 part 3; D-OUT-2: the Gateway refuses a non-conforming MCP result)."""
import json, os, re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# A port of apps/worker/src/schema.js validate(): the same keywords and the same first-violation order, so a result that
# passes here passes the Worker's check (UT-MCP-OUT-01 covers the Worker side).
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
DATE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}(:?\d{2})?)?$")


def jtype(v):
    if v is None: return "null"
    if isinstance(v, bool): return "boolean"
    if isinstance(v, int): return "integer"
    if isinstance(v, float): return "integer" if v.is_integer() else "number"
    if isinstance(v, str): return "string"
    if isinstance(v, list): return "array"
    return "object"


def valid_date(s):
    import datetime as dt
    m = DATE.match(s)
    if not m: return False
    try:
        dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3))); return True
    except ValueError:
        return False


def validate(s, v, path="$"):
    if s is True or s is None: return None
    if s is False: return (path, "not allowed")
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        a = jtype(v)
        if not any(a == t or (t == "number" and a == "integer") for t in ts): return (path, f"type {a}")
    if "enum" in s and not any(e == v and type(e) is type(v) for e in s["enum"]): return (path, "enum")
    if isinstance(v, str):
        if "pattern" in s and not re.search(s["pattern"], v): return (path, "pattern")
        if s.get("format") == "uuid" and not UUID.match(v): return (path, "format uuid")
        if s.get("format") == "date" and not valid_date(v): return (path, "format date")
        if s.get("format") == "date-time" and not (DATETIME.match(v) and valid_date(v[:10])): return (path, "format date-time")
        if "minLength" in s and len(v) < s["minLength"]: return (path, "minLength")
        if "maxLength" in s and len(v) > s["maxLength"]: return (path, "maxLength")
    if isinstance(v, list):
        if "items" in s:
            for i, x in enumerate(v):
                e = validate(s["items"], x, f"{path}[{i}]")
                if e: return e
    if isinstance(v, dict):
        for r in s.get("required", []):
            if r not in v: return (f"{path}.{r}", "required")
        props = s.get("properties", {})
        for k in sorted(v):
            if k in props:
                e = validate(props[k], v[k], f"{path}.{k}")
                if e: return e
            elif s.get("additionalProperties") is False:
                return (f"{path}.{k}", "additional property")
    return None




_OUT = None


def output_schemas():
    global _OUT
    if _OUT is None:
        o = json.load(open(os.path.join(ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
        _OUT = {k: v["output"] for k, v in o.get("schemas", {}).items() if "output" in v}
    return _OUT


class OutputContractError(AssertionError):
    pass


def check_output(fn, result):
    """Raise OutputContractError when a curated tool's result does not match its output schema (path only, no value)."""
    s = output_schemas().get(fn)
    if s is None:
        return
    e = validate(s, result if isinstance(result, dict) else {"result": result})
    if e:
        raise OutputContractError(f"OUTPUT_SCHEMA_MISMATCH {fn} at {e[0]}: {e[1]}")
