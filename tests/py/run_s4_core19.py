#!/usr/bin/env python3
"""S4 phase 2 tests: 2.8 part 3 curated MCP output schemas (migration 9032) and INS-1 signed releases
(tools/s4/release_sign.py; deploy/install_instance.py --require-signed). Synthetic data only.
Usage: run_s4_core19.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time, traceback, types
import importlib.util
import harness as h
from fixture import new_key
import run_s4_core1 as C1
import run_s4_core2 as C2
import run_s4_core4 as C4
import run_s4_core14 as C14

sys.path.insert(0, os.path.join(h.ROOT, "tools", "s4"))
import release_sign as RS   # noqa: E402
import catalog_build as CB  # noqa: E402

RESULTS, TESTS = [], []
check = C1.check


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


# ---------------------------------------------------------------------------------------------- JSON Schema (output side)
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


# ---------------------------------------------------------------------------------------------- 2.8 part 3 output schemas
def catalog_entry(H, fn):
    with C1.migrator(H.server, H.db) as cx:
        return json.loads(cx.execute("select obj_description(%s::regprocedure, 'pg_proc')", (f"bnx.{fn}(jsonb, jsonb)",)).fetchone()[0])


@test("AT-OUT-01", "2.8 part 3; MCP tools outputSchema; 9032 (every tool with a curated output schema returns conforming results "
                   "for an Owner in the PWA and for an AI connection: draft tools incl. replay, transfer, revise, validate, withdraw; "
                   "balances; whoami; report families F1-F7, R09, R30, R31; FX rate, snapshots, registry search, handoff status)")
def t_output_schemas(server, ev):
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    curated = sorted(k for k, v in ovr["schemas"].items() if "output" in v)
    H = C4.v2_full(server, "bnx_c19out")
    cad = H.cad["account_currency_id"]
    sav = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Savings", currencies=["CAD"])["account_currencies"][0]
    H.cmd(H.owner, "set_opening", account_currency_id=sav["account_currency_id"], anchor_date="2026-01-01", amount="50.00")
    B = C4.bearer(H, ["finance.read", "finance.draft", "reports.read", "handoff.read"], acs=[cad, sav["account_currency_id"]])
    entries = {fn: catalog_entry(H, fn) for fn in curated}
    calls = []                                       # (who, function, result)

    def run(who, cred, fn, key=None, **body):
        if fn.startswith("cmd_"):
            body["idempotency_key"] = key or new_key()
        r = H.app.call(fn, cred, body)
        calls.append((who, fn, r))
        return r

    j = H.expense(H.owner, "25.00", date="2026-02-10")["journal_id"]
    for who, cred in (("owner/pwa", H.owner), ("ai/mcp", B)):
        # the report families (common envelope of bnx.rpt_envelope plus their own keys)
        run(who, cred, "q_f1_balances", as_of="2026-12-31")
        run(who, cred, "q_f1_balances", as_of="2026-12-31", reporting_currency="USD")      # a missing rate: null total
        run(who, cred, "q_f2_transactions", account_currency_id=cad, date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_f3_income_expense", date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_f4_investments", as_of="2026-12-31")
        run(who, cred, "q_f5_networth", as_of="2026-12-31")
        run(who, cred, "q_f6_cards", as_of="2026-12-31")
        run(who, cred, "q_f7_reconciliation", account_currency_id=cad)
        run(who, cred, "q_cashflow_statement", date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_r30_review_queue")
        run(who, cred, "q_evidence_trace", journal_id=j)
        # 2.8 part 4 (9033): FX, snapshots, registry search, handoff status
        run(who, cred, "q_fx_rate", base="CAD", quote="USD", date="2026-03-01")                # no rate: MISSING, rate null
        run(who, cred, "q_fx_rate", base="CAD", quote="CAD", date="2026-03-01")                # IDENTITY
        snap = H.app.call("cmd_create_report_snapshot", cred, {"report_code": "R-BAL", "as_of": "2026-12-31", "idempotency_key": new_key()})
        run(who, cred, "q_snapshot_list")
        run(who, cred, "q_snapshot_status", snapshot_id=snap["snapshot_id"])
        run(who, cred, "q_institutions_search", text="CIBC")
        run(who, cred, "q_handoff_status")
        run(who, cred, "q_whoami")
        run(who, cred, "q_balances", as_of="2026-12-31")
        k = new_key()
        tx = dict(account_currency_id=cad, transaction_date="2026-03-02", economic_type="consumption_expense", amount="-12.00",
                  description="synthetic draft")
        tx.update(counter_ledger_account_id=H.groceries) if who == "owner/pwa" else tx.update(lines=[
            {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-12.00"},
            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "12.00"}])
        d = run(who, cred, "cmd_draft_create_transaction", key=k, **tx)
        run(who, cred, "cmd_draft_create_transaction", key=k, **tx)                      # replay
        run(who, cred, "q_draft_get_for_confirmation", plan_id=d["plan_id"])
        run(who, cred, "cmd_draft_validate", key=new_key(), plan_id=d["plan_id"])
        t = run(who, cred, "cmd_draft_create_transfer", key=new_key(), from_account_currency_id=cad,
                to_account_currency_id=sav["account_currency_id"], amount="5.00", transaction_date="2026-03-04")
        run(who, cred, "q_draft_get_for_confirmation", plan_id=t["plan_id"])
        run(who, cred, "cmd_draft_withdraw", key=new_key(), plan_id=t["plan_id"])
        run(who, cred, "q_draft_get_for_confirmation", plan_id=t["plan_id"])            # a withdrawn draft
    # a member draft revised by its author (draft_revise is the member path)
    md = run("member/pwa", H.member, "cmd_draft_create_transaction", key=new_key(), account_currency_id=cad, transaction_date="2026-03-05",
             economic_type="consumption_expense", amount="-3.00", counter_ledger_account_id=H.groceries, description="member draft")
    run("member/pwa", H.member, "cmd_draft_revise", key=new_key(), plan_id=md["plan_id"],
        item={"transaction_date": "2026-03-06", "economic_type": "consumption_expense", "amount": "-4.00",
              "counter_ledger_account_id": H.groceries, "description": "member draft revised"})
    run("member/pwa", H.member, "q_balances", as_of="2026-12-31")
    H.close()
    bad = [(who, fn, validate(entries[fn]["output_schema"], r)) for who, fn, r in calls
           if validate(entries[fn]["output_schema"], r if isinstance(r, dict) else {"result": r})]
    covered = sorted({fn for _, fn, _ in calls})
    replays = [r["replayed"] for _, fn, r in calls if fn == "cmd_draft_create_transaction"]
    kinds = sorted({r["kind"] for _, fn, r in calls if fn == "cmd_draft_create_transaction"})
    check(bad == [] and covered == curated, f"{bad} {covered} {curated}")
    check(all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] and entries[fn]["provenance"] == "curated" for fn in curated),
          "catalog output schemas differ from the overrides")
    check(replays.count(True) == 2 and kinds == ["ai_draft", "member_draft"], f"{replays} {kinds}")
    # the generator refuses an output schema the Gateway could not enforce
    probs = CB.schema_problems({"type": "object", "required": ["x"], "properties": {"y": {"oneOf": []}}})
    check(probs == ["$.y: unsupported keyword oneOf", "$: required x has no property"], probs)
    json.dump([{"who": w, "fn": f} for w, f, _ in calls], open(os.path.join(ev, "AT-OUT-01_calls.json"), "w"), indent=1)
    return (f"{len(calls)} calls by the Owner (PWA), an AI connection (MCP) and a member over {len(curated)} tools with curated output "
            f"schemas ({', '.join(curated)}): every result conforms (incl. replays, ai_draft and member_draft, a withdrawn draft); "
            f"the catalog carries the overrides' schemas; the generator refuses unsupported keywords and dangling required keys")


# ---------------------------------------------------------------------------------------------- INS-1 signed releases
@test("AT-SIG-01", "INS-1 signed releases (Ed25519 detached signature over release/manifest.json; installer --require-signed)")
def t_signed_release(server, ev):    # noqa: ARG001 - no database needed
    tmp = tempfile.mkdtemp(prefix="bnx-sig-")
    try:
        man = os.path.join(tmp, "manifest.json")
        shutil.copyfile(RS.MANIFEST, man)
        priv, pub = os.path.join(tmp, "k.key"), os.path.join(tmp, "k.pub")
        kid = RS.keygen(priv, pub)
        mode = oct(os.stat(priv).st_mode & 0o777)
        inside = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools", "s4", "release_sign.py"), "keygen", "--private",
                                 os.path.join(h.ROOT, "release", "x.key"), "--public", os.path.join(tmp, "y.pub")], capture_output=True, text=True)
        unsigned = RS.verify(pub, man)
        RS.sign(priv, man)
        good = RS.verify(pub, man)
        sig = json.load(open(man + ".sig"))
        # the manifest changes after signing
        body = open(man).read()
        open(man, "w").write(body.replace('"format"', '"format" ', 1))
        changed = RS.verify(pub, man)
        # a signature whose digest was edited to match, but whose signature bytes are for the old body
        import hashlib
        json.dump({**sig, "manifest_sha256": hashlib.sha256(open(man, "rb").read()).hexdigest()}, open(man + ".sig", "w"))
        forged = RS.verify(pub, man)
        open(man, "w").write(body); RS.sign(priv, man)
        priv2, pub2 = os.path.join(tmp, "o.key"), os.path.join(tmp, "o.pub")
        RS.keygen(priv2, pub2)
        other = RS.verify(pub2, man)
        nokey = RS.verify(os.path.join(tmp, "absent.pub"), man)
        # migration files against the manifest
        mig = os.path.join(tmp, "mig")
        shutil.copytree(os.path.join(h.ROOT, "db", "migrations"), mig)
        clean = RS.check_files(man, mig)
        last = sorted(f for f in os.listdir(mig) if f.endswith(".sql"))[-1]
        open(os.path.join(mig, last), "a").write("\n-- edited\n")
        open(os.path.join(mig, "9999_s4_unlisted.sql"), "w").write("select 1;\n")
        dirty = RS.check_files(man, mig)
        # the installer: the repository release (unsigned) passes by default; --require-signed refuses it
        spec = importlib.util.spec_from_file_location("install_instance", os.path.join(h.ROOT, "deploy", "install_instance.py"))
        I = importlib.util.module_from_spec(spec); spec.loader.exec_module(I)
        base = dict(pg="host=127.0.0.1 dbname=balnexa user=balnexa_owner", runtime_host="ep-synthetic.c-8.us-east-2.aws.neon.tech",
                    project_id="synthetic-test-01", modules='{"Canada":"YES","International":"YES","CRA":"NO"}', worker_name="balnexa-test",
                    app_origin="https://balnexa-test.synthetic.workers.dev", kv_id="0" * 32,
                    google_client_id="1000000000001-abcdefghijklmnop.apps.googleusercontent.com", bind_owner_sub=None, secrets_dir="/nonexistent")
        dflt = I.validate(types.SimpleNamespace(**base))
        req = I.validate(types.SimpleNamespace(**base, require_signed=True))
        req_pub = I.validate(types.SimpleNamespace(**base, require_signed=True, release_pub=pub))
        plan = subprocess.run([sys.executable, os.path.join(h.ROOT, "deploy", "install_instance.py"), "--pg", base["pg"], "--runtime-host",
                               base["runtime_host"], "--project-id", base["project_id"], "--app-origin", base["app_origin"], "--kv-id",
                               base["kv_id"], "--google-client-id", base["google_client_id"], "--secrets-dir", "/nonexistent-dir", "--plan"],
                              capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check(mode == "0o600" and inside.returncode != 0 and "outside the repository" in (inside.stdout + inside.stderr)
          and not os.path.exists(os.path.join(h.ROOT, "release", "x.key")), f"{mode} {inside}")
    check(unsigned == (False, "UNSIGNED") and good == (True, "VALID") and sig["key_id"] == kid and len(base64_len(sig["signature"])) == 64
          and changed == (False, "MANIFEST_CHANGED") and forged == (False, "SIGNATURE_INVALID") and other == (False, "KEY_MISMATCH")
          and nokey == (None, "NO_PUBLIC_KEY"), f"{unsigned} {good} {changed} {forged} {other} {nokey}")
    check(clean == [] and sorted(dirty) == sorted([f"CHANGED {last}", "UNLISTED 9999_s4_unlisted.sql"]), f"{clean} {dirty}")
    check(dflt == [] and req == ["--require-signed: the release signature is NO_PUBLIC_KEY"]
          and req_pub == ["--require-signed: the release signature is UNSIGNED"] and plan.returncode == 0
          and "0. release: signature NO_PUBLIC_KEY; migration files match" in plan.stdout, f"{dflt} {req} {req_pub} {plan.stdout} {plan.stderr}")
    return (f"key {kid}: private key 0600 and refused inside the repository; unsigned -> UNSIGNED, signed -> VALID, edited manifest -> "
            f"MANIFEST_CHANGED, edited digest -> SIGNATURE_INVALID, other key -> KEY_MISMATCH, no key -> NO_PUBLIC_KEY; an edited and an "
            f"unlisted migration are reported; the installer passes the unsigned repository release by default, refuses it with "
            f"--require-signed (no key / unsigned), and --plan reports the release state")


def base64_len(s):
    import base64
    return base64.b64decode(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core19", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "PASS"
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    summary = {"server": a.server, "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core19_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
