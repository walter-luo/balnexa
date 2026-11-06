#!/usr/bin/env python3
"""Generates the seed block of migration 9006 from institution_registry_seed_V1.0.json (Amendment 02 seed).
Usage: gen_registry_seed_sql.py <seed.json>  -> SQL on stdout (pasted into 9006; the migration file is the artifact)."""
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
q = lambda s: "null" if s is None else "'" + str(s).replace("'", "''") + "'"
seed_set = lambda i, x: "CN_TRADITIONAL_FIVE" if i < 5 else "CN_JOINT_STOCK_TWELVE" if i < 17 else "OWNER_ADDITIONAL"
rows = []
for i, x in enumerate(d["institutions"]):
    rows.append((x["code"], x["kind"], x["jurisdiction"], x["classification"], seed_set(i, x), x["display"]["en"], x["display"]["zh-CN"],
                 x["legal_name"].get("en"), x["legal_name"].get("zh-CN"), x.get("legal_name_verification", "AUTHOR_CANDIDATE_SOURCE_REQUIRED")))
for x in d["payment_providers"]:
    rows.append((x["code"], x["kind"], None, None, "OWNER_ADDITIONAL", x["display"].get("en"), x["display"].get("zh-CN"), None, None, None))
print("insert into seed_inst(code, kind, jurisdiction, classification, seed_set, display_en, display_zh, legal_en, legal_zh, legal_verification) values")
print(",\n".join("  (" + ", ".join(q(v) for v in r) + ")" for r in rows) + ";")
print("insert into seed_brand(brand_code, brand_kind, display_en, display_zh, issuer_code, effective_from, effective_to, successor_brand) values")
print(",\n".join("  (" + ", ".join(q(v) for v in (b["brand_code"], b["brand_kind"], b["display"]["en"], b["display"]["zh-CN"], b["issuer_code"],
      b.get("effective_from"), b.get("effective_to"), b.get("successor_brand"))) + ")" for b in d["brands"]) + ";")
rel = [(b["issuer_code"], r["parent_code"], r["kind"], r["effective_from"], b["brand_code"]) for b in d["brands"] for r in b.get("owner_relationship", [])]
print("insert into seed_rel(institution_code, related_code, kind, effective_from, via_brand) values")
print(",\n".join("  (" + ", ".join(q(v) for v in r) + ")" for r in rel) + ";")
print(f"-- known_not_seeded: {[x['code_reserved'] for x in d['known_not_seeded']]} (PSBC reserved; never seeded, never joint-stock)")
