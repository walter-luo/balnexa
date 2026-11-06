#!/usr/bin/env python3
"""Fresh database for the black-box suite: B001 + migrations (bnx_migrator) + installer steps only.
Prints {"db":..., "host":..., "port":...}. Usage: prepare_db.py pg16|pg17"""
import json, os, sys, uuid
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "py"))
import harness as h
server = sys.argv[1] if len(sys.argv) > 1 else "pg16"
db = "bnx_bb_" + uuid.uuid4().hex[:6]
h.bootstrap(server, db)
h.migrate(server, db)
h.as_definer_via_migrator(server, db, "select bnx.install_household('Owner A', 'https://accounts.google.com', 'g-owner')")
h.as_definer_via_migrator(server, db, "insert into bnx.oauth_client values ('chatgpt-test', 'Synthetic AI host', array['https://host.example/cb']) returning 1")
# S4 phase-2 preparation (installer steps only): adopt + activate (all modules YES) and one verified registry
# institution, when the chain has 9003/9006/9007. At R1 head nothing extra is done and accounts use free text.
out = {}
caps = h.as_definer_via_migrator(server, db, "select to_regprocedure('bnx.adopt_existing_household(text,uuid,jsonb,jsonb)') is not null, "
    "exists (select 1 from information_schema.columns where table_schema = 'bnx' and table_name = 'institution' and column_name = 'status')")[0]
if caps[0]:
    uid = str(uuid.uuid4()); mods = {"Canada": "YES", "International": "YES", "CRA": "YES"}
    cv = h.as_definer_via_migrator(server, db, "select bnx.adopt_existing_household('bb-household', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(mods)))[0][0]
    h.as_definer_via_migrator(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                              (cv, "e" * 64, json.dumps({"project_id": "bb-household", "instance_uid": uid, "modules": mods})))
if caps[1]:
    out["institution_id"] = str(h.as_definer_via_migrator(server, db,
        "insert into bnx.institution(id, name_en, country, code, kind, jurisdiction, status, verification_provenance) "
        "values (gen_random_uuid(), 'Synthetic Bank', 'CA', 'SYNTHETIC_BANK', 'bank', 'CA', 'VERIFIED_ACTIVE', "
        "'{\"method\":\"installer fixture (synthetic)\"}') returning id")[0][0])
host, port = [kv.split("=")[1] for kv in h.SERVERS[server].split()]
print(json.dumps({"db": db, "host": host, "port": int(port), **out}))
