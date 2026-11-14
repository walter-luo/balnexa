# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""PostgreSQL client tools shipped in the Executor image (UA V1.2 §3: pg_dump 16/17 and pg_restore of the same major).

The binary directory of each major comes from ``BNX_PG_BINDIR_<major>`` or defaults to the Debian layout
``/usr/lib/postgresql/<major>/bin``.
"""
import os
import re
import subprocess

MAJORS = (16, 17, 18)


def bindir(major):
    return os.environ.get(f"BNX_PG_BINDIR_{major}", f"/usr/lib/postgresql/{major}/bin")


def tool(name, major):
    p = os.path.join(bindir(major), name)
    return p if os.access(p, os.X_OK) else None


def version(path):
    r = subprocess.run([path, "--version"], capture_output=True, text=True)
    m = re.search(r"(\d+)\.(\d+)", r.stdout)
    return f"{m.group(1)}.{m.group(2)}" if m else None


def version_text(server_version):
    """'16.15 (Debian 16.15-1.pgdg)' -> '16.15'"""
    m = re.match(r"^(\d+)\.(\d+)", str(server_version or ""))
    return f"{m.group(1)}.{m.group(2)}" if m else None


def major_of(v):
    m = re.match(r"^(\d+)", str(v or ""))
    return int(m.group(1)) if m else None


def select_dump(server_major):
    """the lowest available major >= the server's that has both pg_dump and pg_restore (§9.3 step 7)"""
    for mj in MAJORS:
        if mj >= server_major and tool("pg_dump", mj) and tool("pg_restore", mj):
            return mj
    return None


def select_restore(dump_major):
    """pg_restore of the dump's major (or newer)"""
    for mj in MAJORS:
        if mj >= dump_major and tool("pg_restore", mj):
            return mj
    return None


def psql():
    for mj in reversed(MAJORS):
        p = tool("psql", mj)
        if p:
            return p
    return "psql"
