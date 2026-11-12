#!/usr/bin/env python3
"""Install one Balnexa instance database and render the Worker configuration (M0-A / M0-C-06; IL V1.2 §3; UA V1.2 §6.2).

Runs as the installer identity: a NON-superuser role with CREATEROLE and CREATEDB that owns the database (the Neon project
owner, or a local stand-in). Synthetic data only. Steps (each re-runnable):
  1. B001 and B002 (psql; PGOPTIONS createrole_self_grant=set,inherit so the installer may create bnx_definer objects);
  2. random passwords for the LOGIN roles the deployment uses (bnx_migrator, bnx_app, bnx_authn, bnx_worker);
  3. db/tools/run_migrations.py as bnx_migrator (B003 as the installer when the runner asks for it);
  4. install_household_v2 (Owner placeholder identity until the probe, runbook step 6) and install_activate_config;
  5. apps/worker/wrangler.toml from the template, and the runtime connection strings for `wrangler secret put`.
Secrets go to --secrets-dir (mode 0600, outside the repository) and are never printed.

Usage:
  install_instance.py --pg "host=127.0.0.1 port=15432 dbname=balnexa user=balnexa_owner password=… sslmode=disable"
                      --runtime-host ep-….us-east-2.aws.neon.tech --project-id synthetic-test-01 --owner-name "Owner"
                      --worker-name balnexa-test --app-origin https://balnexa-test.<sub>.workers.dev --kv-id … --google-client-id …
  install_instance.py … --bind-owner-sub SUB      (after the probe: adds the Owner's Google identity, removes the placeholder)
  install_instance.py … --plan                    (INS-2: validate every input and print the steps; touches nothing)
"""
import argparse, hashlib, json, os, re, secrets, subprocess, sys, uuid
import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROLES = ["bnx_migrator", "bnx_app", "bnx_authn", "bnx_worker"]
ISS = "https://accounts.google.com"
PLACEHOLDER_SUB = "pending-owner-probe"


def psql_file(pg, path):
    env = {**os.environ, "PGOPTIONS": "-c createrole_self_grant=set,inherit"}
    r = subprocess.run(["psql", pg, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", path], capture_output=True, text=True, env=env)
    if r.returncode:
        sys.exit(f"{os.path.basename(path)} failed:\n{r.stderr[-2000:]}")
    print(f"ok {os.path.basename(path)}" + (f" ({r.stdout.strip()})" if r.stdout.strip() else ""))


def as_role(pg, user, password):
    d = conninfo_to_dict(pg); d.update(user=user, password=password)
    return make_conninfo(**d)


def load(path):
    return json.load(open(path)) if os.path.exists(path) else {}


def save(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)


MODULES = {"Canada", "International", "CRA"}


def validate(a):
    """INS-2 validator: every input is checked before anything is touched (IL V1.2 §3). Returns a list of problems."""
    p = []
    try:
        d = conninfo_to_dict(a.pg)
        if not d.get("dbname") or not d.get("user"):
            p.append("--pg needs dbname and user")
        elif d["user"].startswith("bnx_"):
            p.append("--pg user must not be a bnx_* role: the privilege audit treats those as system roles (runbook note)")
    except Exception:  # noqa: BLE001
        p.append("--pg is not a libpq conninfo")
    if a.bind_owner_sub is not None:                     # binding touches only the identity table: the other inputs are unused
        if not re.fullmatch(r"[0-9]{6,30}", a.bind_owner_sub):
            p.append("--bind-owner-sub must be the numeric Google subject shown by the install probe")
        return p
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{3,253}", a.runtime_host or ""):
        p.append("--runtime-host must be a host name")
    if not re.fullmatch(r"[a-z][a-z0-9-]{2,40}", a.project_id or ""):
        p.append("--project-id: lower-case letters, digits and '-', 3-41 characters")
    try:
        mods = json.loads(a.modules)
        if set(mods) != MODULES or any(v not in ("YES", "NO") for v in mods.values()):
            p.append("--modules must set exactly Canada, International and CRA to YES or NO")
        elif mods.get("CRA") == "YES":
            p.append("--modules CRA=YES needs the Owner gate G-CRA-1 (closed)")
    except ValueError:
        p.append("--modules is not JSON")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", a.worker_name or ""):
        p.append("--worker-name: a Cloudflare Worker name")
    if not re.fullmatch(r"https://[a-z0-9.-]+(:[0-9]{2,5})?", (a.app_origin or "").rstrip("/")):
        p.append("--app-origin must be an https origin without a path")
    if not re.fullmatch(r"[0-9a-f]{32}", a.kv_id or ""):
        p.append("--kv-id must be a 32-hex Cloudflare KV namespace id")
    if not re.fullmatch(r"[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com", a.google_client_id or ""):
        p.append("--google-client-id must be a Google OAuth web client id")
    return p


def plan(a):
    steps = ["1. B001/B002 as the installer (skipped when applied)", "2. passwords for bnx_migrator, bnx_app, bnx_authn, bnx_worker",
             "3. migrations as bnx_migrator (B003 on request)", f"4. install_household_v2 for project {a.project_id} (data_class synthetic), "
             "install_activate_config", f"5. render apps/worker/wrangler.toml for {a.worker_name} at {a.app_origin}; runtime secrets to "
             f"{a.secrets_dir} (0600)"]
    if a.bind_owner_sub:
        steps = ["bind the Owner's Google subject and remove the placeholder (then set BNX_INSTALL_PROBE=0 and redeploy)"]
    return "install plan (nothing done):\n  " + "\n  ".join(steps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pg", required=True, help="libpq conninfo of the installer identity")
    ap.add_argument("--runtime-host", required=True, help="database host the Worker uses (Neon endpoint host)")
    ap.add_argument("--project-id", required=True)
    ap.add_argument("--owner-name", default="Owner")
    ap.add_argument("--modules", default='{"Canada":"YES","International":"YES","CRA":"NO"}')
    ap.add_argument("--worker-name", default="balnexa-test")
    ap.add_argument("--app-origin", required=True)
    ap.add_argument("--kv-id", required=True)
    ap.add_argument("--google-client-id", required=True)
    ap.add_argument("--install-probe", default="1", choices=["0", "1"])
    ap.add_argument("--secrets-dir", default=os.path.expanduser("~/.balnexa"))
    ap.add_argument("--bind-owner-sub")
    ap.add_argument("--plan", action="store_true", help="validate the inputs and print the steps; touch nothing (INS-2)")
    a = ap.parse_args()
    problems = validate(a)
    if problems:
        sys.exit("invalid installer input:\n  " + "\n  ".join(problems))
    if a.plan:
        print(plan(a))
        return
    os.makedirs(a.secrets_dir, mode=0o700, exist_ok=True)
    spath = os.path.join(a.secrets_dir, f"{a.project_id}.secrets.json")
    st = load(spath)
    dbname = conninfo_to_dict(a.pg)["dbname"]

    if a.bind_owner_sub:
        mig = as_role(a.pg, "bnx_migrator", st["passwords"]["bnx_migrator"])
        with psycopg.connect(mig) as cx:
            cx.execute("set role bnx_definer")
            owner = cx.execute("select member_id from bnx.member_identity where iss = %s and sub = %s", (ISS, PLACEHOLDER_SUB)).fetchone()
            if not owner:
                sys.exit("no placeholder identity: the Owner is already bound")
            cx.execute("insert into bnx.member_identity values (%s, %s, %s)", (ISS, a.bind_owner_sub, owner[0]))
            cx.execute("delete from bnx.member_identity where iss = %s and sub = %s", (ISS, PLACEHOLDER_SUB))
            cx.commit()
        print("ok owner identity bound; set BNX_INSTALL_PROBE=0 and redeploy (runbook step 7)")
        return

    # 1. bootstrap
    with psycopg.connect(a.pg, autocommit=True) as cx:
        su = cx.execute("select rolsuper from pg_roles where rolname = current_user").fetchone()[0]
        if su:
            print("note: installer is a superuser (local run); Neon uses a non-superuser CREATEROLE owner")
        have = cx.execute("select to_regclass('bnx.schema_bootstrap') is not null").fetchone()[0]
        done = {r[0] for r in cx.execute("select version from bnx.schema_bootstrap")} if have else set()
    for b in ("B001", "B002"):
        if b in done:
            print(f"skip {b} (applied)")
        else:
            psql_file(a.pg, os.path.join(ROOT, "db", "bootstrap", {"B001": "B001_bootstrap.sql", "B002": "B002_bootstrap_s4.sql"}[b]))

    # 2. passwords (kept across re-runs)
    pw = st.setdefault("passwords", {})
    with psycopg.connect(a.pg, autocommit=True) as cx:
        for r in ROLES:
            pw.setdefault(r, secrets.token_urlsafe(32))
            cx.execute(f'alter role "{r}" password %s'.replace("%s", "'" + pw[r].replace("'", "''") + "'"))
    save(spath, st)
    print("ok passwords for " + ", ".join(ROLES))

    # 3. migrations
    mig = as_role(a.pg, "bnx_migrator", pw["bnx_migrator"])
    cmd = [sys.executable, os.path.join(ROOT, "db", "tools", "run_migrations.py"), "--dsn", mig]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 6 and "BOOTSTRAP_MISSING: B003" in r.stdout:
        psql_file(a.pg, os.path.join(ROOT, "db", "bootstrap", "B003_audit_owner.sql"))
        r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout[-1500:])
    if r.returncode:
        sys.exit(f"migrations failed ({r.returncode}):\n{r.stderr[-2000:]}")

    # 4. install + activate
    mods = json.loads(a.modules)
    head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    digest = hashlib.sha256(f"{head}\n{a.project_id}\n{json.dumps(mods, sort_keys=True)}".encode()).hexdigest()
    with psycopg.connect(mig) as cx:
        cx.execute("set role bnx_definer")
        idt = cx.execute("select instance_uid from bnx.instance_identity").fetchone()
        if idt:
            uid = str(idt[0]); print("skip install (installed)")
            # re-render: keep the digest the database activated (binding B2), not one recomputed from the current HEAD
            act = cx.execute("select coalesce(deployed_digest, config_sha256) from bnx.config_version_anchor "
                             "where state = 'ACTIVE' order by config_version desc limit 1").fetchone()
            if act and act[0]:
                digest = act[0]
        else:
            uid = str(uuid.uuid4())
            owner = cx.execute("select bnx.install_household_v2(%s, %s, %s, %s, %s, %s::jsonb, %s::jsonb)",
                               (a.owner_name, ISS, PLACEHOLDER_SUB, a.project_id, uid, json.dumps(mods),
                                json.dumps({"reporting_currency": "CAD", "declared_by": "installer"}))).fetchone()[0]
            # data class of this instance: synthetic (O-8 closed); written once by the installer
            cx.execute("insert into bnx.household_setting(key, value, set_by) values ('data_class', '\"synthetic\"'::jsonb, %s) "
                       "on conflict (key) do update set value = excluded.value", (owner,))
            print("ok install_household_v2 (data_class synthetic)")
        pend = cx.execute("select config_version from bnx.config_version_anchor where state = 'PENDING_DEPLOY' order by config_version").fetchall()
        cx.commit()
        for (cv,) in pend:
            cx.execute("set role bnx_definer")
            cx.execute("select bnx.install_activate_config(%s, %s, %s::jsonb)",
                       (cv, digest, json.dumps({"project_id": a.project_id, "instance_uid": uid, "modules": mods})))
            cx.commit()
            print(f"ok install_activate_config v{cv}")

    # 5. Worker configuration and runtime secrets
    t = open(os.path.join(ROOT, "apps", "worker", "wrangler.template.toml")).read()
    for k, v in {"WORKER_NAME": a.worker_name, "KV_ID": a.kv_id, "APP_ORIGIN": a.app_origin.rstrip("/"), "GOOGLE_CLIENT_ID": a.google_client_id,
                 "PROJECT_ID": a.project_id, "INSTANCE_UID": uid, "CONFIG_DIGEST": digest, "INSTALL_PROBE": a.install_probe,
                 "MOD_CANADA": mods["Canada"], "MOD_INTERNATIONAL": mods["International"], "MOD_CRA": mods["CRA"]}.items():
        t = t.replace(f"@@{k}@@", v)
    open(os.path.join(ROOT, "apps", "worker", "wrangler.toml"), "w").write(t)
    st["runtime"] = {f"DB_URL_{r.upper()}": f"postgresql://{r}:{pw[r]}@{a.runtime_host}/{dbname}?sslmode=require"
                     for r in ("bnx_app", "bnx_authn", "bnx_worker")}
    st["instance"] = {"project_id": a.project_id, "instance_uid": uid, "config_digest": digest, "modules": mods}
    save(spath, st)
    print(f"ok apps/worker/wrangler.toml rendered; runtime secrets in {spath} (DB_URL_BNX_APP, DB_URL_BNX_AUTHN, DB_URL_BNX_WORKER)")


if __name__ == "__main__":
    main()
