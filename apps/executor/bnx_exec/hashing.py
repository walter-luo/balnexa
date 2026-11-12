"""Streaming digests (UA §5.9 / OR-I-05: SHA-256 is computed by the Executor; MD5 only to compare with an R2/S3 ETag)."""
import hashlib

CHUNK = 1 << 20


def file_digests(path):
    s, m, n = hashlib.sha256(), hashlib.md5(usedforsecurity=False), 0
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            s.update(b); m.update(b); n += len(b)
    return {"sha256": s.hexdigest(), "md5": m.hexdigest(), "size": n}


def sha256_file(path):
    return file_digests(path)["sha256"]


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def kib(n):
    """sizes travel in KiB, rounded up (result contract D-9016-5: never a bare byte count)"""
    return -(-int(n) // 1024)
