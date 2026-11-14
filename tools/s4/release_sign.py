#!/usr/bin/env python3
"""INS-1 signed releases (WP matrix V1.2 phase 2.6; IL V1.2 §4): a detached Ed25519 signature over release/manifest.json.

The manifest already pins every migration by SHA-256, the Worker release and its schema range, and the SBOM, so one signature
over the manifest bytes covers the release. The signature file is release/manifest.json.sig:

    {"format": "bnx-release-signature/1.0", "manifest_sha256": "<hex>", "key_id": "<hex, first 16 of SHA-256(raw public key)>",
     "signature": "<base64 Ed25519 signature over the manifest bytes>"}

The private key is the Owner's and never enters the repository or CI (D-SIG-1). The public key is committed as
release/release-signing.pub (32 raw bytes, base64, one line) once the Owner has generated it; until then releases are unsigned
and only a synthetic instance may install them (deploy/install_instance.py --require-signed refuses them).

Usage:
  release_sign.py keygen --private PATH --public PATH     (Owner's machine; PATH for the private key must not be in the repo)
  release_sign.py sign --private PATH [--manifest M]       (writes M.sig)
  release_sign.py verify [--public PATH] [--manifest M]    (exit 0 valid, 1 invalid or missing, 2 no public key)
  release_sign.py check-files [--manifest M]               (every migration file's SHA-256 equals the manifest's)"""
import argparse, base64, hashlib, json, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MANIFEST = os.path.join(ROOT, "release", "manifest.json")
PUBLIC = os.path.join(ROOT, "release", "release-signing.pub")
FORMAT = "bnx-release-signature/1.0"


def _crypto():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
    from cryptography.hazmat.primitives import serialization
    return Ed25519PrivateKey, Ed25519PublicKey, serialization


def key_id(raw_pub):
    return hashlib.sha256(raw_pub).hexdigest()[:16]


def load_public(path):
    raw = base64.b64decode(open(path).read().strip(), validate=True)
    if len(raw) != 32:
        raise ValueError("public key must be 32 raw Ed25519 bytes")
    return raw


def keygen(private, public):
    priv_cls, _, ser = _crypto()
    if os.path.abspath(private).startswith(ROOT + os.sep):
        raise SystemExit("refused: the private key must be stored outside the repository (D-SIG-1)")
    k = priv_cls.generate()
    raw = k.private_bytes(ser.Encoding.Raw, ser.PrivateFormat.Raw, ser.NoEncryption())
    fd = os.open(private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(base64.b64encode(raw).decode() + "\n")
    pub = k.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)
    with open(public, "w") as f:
        f.write(base64.b64encode(pub).decode() + "\n")
    return key_id(pub)


def sign(private, manifest=MANIFEST):
    priv_cls, _, ser = _crypto()
    k = priv_cls.from_private_bytes(base64.b64decode(open(private).read().strip(), validate=True))
    body = open(manifest, "rb").read()
    pub = k.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)
    sig = {"format": FORMAT, "manifest_sha256": hashlib.sha256(body).hexdigest(), "key_id": key_id(pub),
           "signature": base64.b64encode(k.sign(body)).decode()}
    with open(manifest + ".sig", "w") as f:
        f.write(json.dumps(sig, indent=1, sort_keys=True) + "\n")
    return sig


def verify(public=PUBLIC, manifest=MANIFEST):
    """Returns (ok, reason). Never raises for a bad or missing signature."""
    if not os.path.exists(public):
        return None, "NO_PUBLIC_KEY"
    _, pub_cls, _ = _crypto()
    try:
        raw = load_public(public)
    except Exception:
        return False, "PUBLIC_KEY_MALFORMED"
    if not os.path.exists(manifest + ".sig"):
        return False, "UNSIGNED"
    try:
        sig = json.load(open(manifest + ".sig"))
        body = open(manifest, "rb").read()
        if sig.get("format") != FORMAT:
            return False, "SIGNATURE_FORMAT"
        if sig.get("key_id") != key_id(raw):
            return False, "KEY_MISMATCH"
        if sig.get("manifest_sha256") != hashlib.sha256(body).hexdigest():
            return False, "MANIFEST_CHANGED"
        pub_cls.from_public_bytes(raw).verify(base64.b64decode(sig["signature"], validate=True), body)
    except Exception as e:                       # InvalidSignature, bad base64, bad JSON
        return False, "SIGNATURE_INVALID" if type(e).__name__ == "InvalidSignature" else "SIGNATURE_MALFORMED"
    return True, "VALID"


def check_files(manifest=MANIFEST, mig_dir=os.path.join(ROOT, "db", "migrations")):
    """Every migration listed in the manifest exists with the listed SHA-256, and no migration file is unlisted."""
    m = json.load(open(manifest))
    listed = {x["file"]: x["sha256"] for x in m["migrations"]}
    errs = []
    on_disk = sorted(f for f in os.listdir(mig_dir) if f.endswith(".sql"))
    for f in on_disk:
        if f not in listed:
            errs.append(f"UNLISTED {f}")
        elif hashlib.sha256(open(os.path.join(mig_dir, f), "rb").read()).hexdigest() != listed[f]:
            errs.append(f"CHANGED {f}")
    for f in listed:
        if f not in on_disk:
            errs.append(f"MISSING {f}")
    return errs


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("keygen"); g.add_argument("--private", required=True); g.add_argument("--public", default=PUBLIC)
    s = sub.add_parser("sign"); s.add_argument("--private", required=True); s.add_argument("--manifest", default=MANIFEST)
    v = sub.add_parser("verify"); v.add_argument("--public", default=PUBLIC); v.add_argument("--manifest", default=MANIFEST)
    c = sub.add_parser("check-files"); c.add_argument("--manifest", default=MANIFEST)
    a = ap.parse_args()
    if a.cmd == "keygen":
        print(f"key {keygen(a.private, a.public)} written; keep the private key offline")
        return 0
    if a.cmd == "sign":
        print(f"signed {a.manifest} with key {sign(a.private, a.manifest)['key_id']}")
        return 0
    if a.cmd == "verify":
        ok, why = verify(a.public, a.manifest)
        print(why)
        return 0 if ok else (2 if ok is None else 1)
    errs = check_files(a.manifest)
    print("\n".join(errs) if errs else "migration files match the manifest")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
