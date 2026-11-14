# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""age encryption through the ``age`` binary that ships in the Executor image (UA §9.3 step 8; §9.4 K2).

Only public recipients (``age1…``) are passed on the command line. The drill identity is a file whose path comes from the
job's secret mount; its content is never read into a log, a payload or a header. The key registry holds SHA-256
fingerprints of the recipients (SEC-K).
"""
import hashlib
import os
import re
import subprocess

AGE = os.environ.get("BNX_AGE", "age")
AGE_KEYGEN = os.environ.get("BNX_AGE_KEYGEN", "age-keygen")
RECIPIENT = re.compile(r"^age1[0-9a-z]{58}$")


class AgeError(Exception):
    pass


def recipient_fingerprint(recipient):
    """the value stored in bnx.backup_key_registry.recipient_fingerprint"""
    r = recipient.strip()
    if not RECIPIENT.match(r):
        raise AgeError("not an age X25519 recipient")
    return hashlib.sha256(r.encode()).hexdigest()


def version():
    r = subprocess.run([AGE, "--version"], capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()


def encrypt(src, dst, recipients, run=subprocess.run):
    if not recipients:
        raise AgeError("no recipients")
    args = [AGE, "--encrypt"]
    for r in recipients:
        recipient_fingerprint(r)
        args += ["-r", r.strip()]
    p = run(args + ["-o", dst, src], capture_output=True, text=True)
    if p.returncode:
        raise AgeError("age encrypt failed")


def decrypt(src, dst, identity_path, run=subprocess.run):
    p = run([AGE, "--decrypt", "-i", identity_path, "-o", dst, src], capture_output=True, text=True)
    if p.returncode:
        raise AgeError("age decrypt failed")      # stderr is not propagated: it can name the identity file


def identity_recipient(identity_path):
    """public recipient of an identity file (to check it against the registry fingerprint before decrypting)"""
    p = subprocess.run([AGE_KEYGEN, "-y", identity_path], capture_output=True, text=True)
    if p.returncode:
        raise AgeError("age-keygen -y failed")
    return p.stdout.strip().splitlines()[0]
