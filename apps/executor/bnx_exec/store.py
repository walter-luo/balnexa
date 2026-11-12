"""Object stores of the Executor.

``LocalStore`` keeps objects in a directory tree (local runs and tests; the Worker's node adapter serves the same tree as its
R2 binding). Each object has a sidecar ``<name>.bnxmeta`` with its generation, size and digests. Objects are write-once:
writing an existing name with different content is refused (content-addressed artifacts are re-written idempotently).

Cloud stores (GCS vault bucket ``bnx-<project_id>-vault``, R2 artifact bucket) are not implemented here: they need cloud
identities and buckets that the M0 gates authorize (L-CORE8-2).
"""
import json
import os
import shutil
import time

from .hashing import file_digests


class ObjectExists(Exception):
    pass


class ObjectMissing(Exception):
    pass


def _safe(name):
    if not name or name.startswith("/") or ".." in name.split("/") or "\\" in name or name.endswith(".bnxmeta"):
        raise ValueError("object name")
    return name


class LocalStore:
    def __init__(self, root):
        self.root = os.path.abspath(root)

    def _path(self, name):
        return os.path.join(self.root, _safe(name))

    def put_file(self, name, src):
        p = self._path(name)
        d = file_digests(src)
        if os.path.exists(p):
            meta = self.stat(name)
            if meta["sha256"] == d["sha256"]:
                return meta
            raise ObjectExists(name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".part"
        shutil.copyfile(src, tmp)
        meta = {"generation": str(time.time_ns() // 1000), "size": d["size"], "sha256": d["sha256"], "md5": d["md5"]}
        with open(p + ".bnxmeta", "w") as f:
            json.dump(meta, f)
        os.replace(tmp, p)
        return meta

    def stat(self, name):
        p = self._path(name)
        if not os.path.exists(p):
            raise ObjectMissing(name)
        with open(p + ".bnxmeta") as f:
            return json.load(f)

    def get_file(self, name, dst):
        p = self._path(name)
        if not os.path.exists(p):
            raise ObjectMissing(name)
        shutil.copyfile(p, dst)
        return self.stat(name)

    def exists(self, name):
        return os.path.exists(self._path(name))
