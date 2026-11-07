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
host, port = [kv.split("=")[1] for kv in h.SERVERS[server].split()]
print(json.dumps({"db": db, "host": host, "port": int(port)}))
