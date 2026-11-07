#!/usr/bin/env python3
"""AUD-038 keyring simulation with the real `age` CLI and SYNTHETIC keys (development tool; no cloud, no real data).
Simulates 13 monthly backups encrypted to [Owner key, current drill key], four quarterly drill-key rotations, the
automated drill using ONLY the drill keyring, the Owner-key path, compromise options and pruning.
Also runs the withdrawn Draft-03 policy (old drill key destroyed one month after rotation) as a negative control."""
import hashlib, json, os, subprocess, tempfile, sys
W = tempfile.mkdtemp(prefix="bnx-keyring-")
def run(*a, inp=None):
    r = subprocess.run(a, input=inp, capture_output=True)
    return r.returncode, r.stdout, r.stderr
def keygen(name):
    p = os.path.join(W, name + ".key"); run("age-keygen", "-o", p)
    pub = [l for l in open(p).read().splitlines() if l.startswith("# public key: ")][0].split(": ")[1]
    return {"id": name, "file": p, "recipient": pub, "identity": [l for l in open(p).read().splitlines() if l.startswith("AGE-SECRET-KEY-")][0]}
def encrypt(data, recipients):
    args = ["age"]; [args.extend(["-r", r]) for r in recipients]
    rc, out, err = run(*args, inp=data); assert rc == 0, err; return out
def decrypt(blob, identity_lines):
    p = os.path.join(W, "ring.txt"); open(p, "w").write("\n".join(identity_lines) + "\n")
    rc, out, _ = run("age", "-d", "-i", p, inp=blob); return out if rc == 0 else None
log = []
def say(s): print(s); log.append(s)
owner = keygen("M0-SYNTHETIC-owner")
keys = [keygen("drill-k1")]; current = keys[0]
objects = []                                   # registry: objects.jsonl
DAY = 30
rotations = {3: "drill-k2", 6: "drill-k3", 9: "drill-k4", 12: "drill-k5"}
for m in range(1, 14):
    if m in rotations:
        current = keygen(rotations[m]); keys.append(current)
    plain = os.urandom(4096) + f"manifest month {m}".encode()
    blob = encrypt(plain, [owner["recipient"], current["recipient"]])
    objects.append({"name": f"backup-m{m:02d}", "day": m * DAY, "retain_until": m * DAY + 366, "drill_key": current["id"],
                    "plaintext_sha256": hashlib.sha256(plain).hexdigest(), "blob": blob})
say(f"created 13 monthly objects; drill keys {[k['id'] for k in keys]} (4 rotations at months 3, 6, 9, 12)")
now = 13 * DAY
def needed_keys(day):  # keyring policy: keep every identity still listed by a retained object, plus the current key
    ids = {o["drill_key"] for o in objects if o["retain_until"] > day} | {current["id"]}
    return [k for k in keys if k["id"] in ids]
def drill(ring, label):
    ok = fail = 0
    for o in objects:
        if o["retain_until"] <= now: continue
        out = decrypt(o["blob"], [k["identity"] for k in ring])
        if out is not None and hashlib.sha256(out).hexdigest() == o["plaintext_sha256"]: ok += 1
        else: fail += 1
    say(f"{label}: {ok} restored, {fail} failed (retained objects at day {now})"); return fail
# AT-BKP-17 keyring survival
ring = needed_keys(now)
f1 = drill(ring, "AT-BKP-17 keyring policy (drill identities only)")
m12 = [o for o in objects if o["name"] == "backup-m01"][0]
say(f"  oldest object backup-m01 needs {m12['drill_key']}; keyring holds {[k['id'] for k in ring]}")
# negative control: Draft-03 policy
draft03 = [k for k in keys if k["id"] in (current["id"], keys[-2]["id"])]
f0 = drill(draft03, "NEGATIVE CONTROL Draft-03 policy (current + previous key only)")
# AT-BKP-20 Owner key path
import random; random.seed(7)
o = random.choice(objects); out = decrypt(o["blob"], [owner["identity"]])
f2 = 0 if (out and hashlib.sha256(out).hexdigest() == o["plaintext_sha256"]) else 1
say(f"AT-BKP-20 Owner key only, random object {o['name']}: {'PASS' if not f2 else 'FAIL'}; all objects: " +
    str(sum(1 for o in objects if hashlib.sha256(decrypt(o['blob'], [owner['identity']]) or b'').hexdigest() == o['plaintext_sha256'])) + "/13")
# AT-BKP-19 compromise of drill-k3: option (a) keep for drills, option (b) remove
comp = "drill-k3"
fa = drill([k for k in ring], "AT-BKP-19 option (a) keep compromised key for drills")
fb = drill([k for k in ring if k["id"] != comp], "AT-BKP-19 option (b) remove compromised key")
nb = sum(1 for o in objects if o["drill_key"] == comp)
say(f"  option (b) failures equal the {nb} objects encrypted to {comp}; they remain decryptable by the Owner key")
# AT-BKP-18 pruning
def prune(day):
    keep = needed_keys(day); return [k["id"] for k in keys if k not in keep]
early = prune(now); late = prune(13 * DAY + 366 + 1)
say(f"AT-BKP-18 prune at day {now}: {early or 'none'} (no premature prune); at day {13*DAY+367}: {late}")
ok = f1 == 0 and f0 > 0 and f2 == 0 and fa == 0 and fb == nb and early == [] and set(late) == {"drill-k1","drill-k2","drill-k3","drill-k4"}
say("KEYRING SIMULATION PASS" if ok else "KEYRING SIMULATION FAIL")
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "last_run.txt"), "w").write("\n".join(log) + "\n")
sys.exit(0 if ok else 1)
