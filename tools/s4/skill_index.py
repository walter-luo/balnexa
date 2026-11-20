#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Skill index (AI-first design §5; OD-AI-3, Q2).

`skills/INDEX.csv` lists every skill under `skills/<name>/SKILL.md` with its version, status, size and SHA-256.
The household's data folder keeps a byte-identical copy of each skill and an index with the same SHA-256, so an AI host
that loads a skill from the data folder can check it against this repository.

  --check   the index matches the files, and every skill is well formed and generic (default)
  --self-test  each rule refuses a crafted skill in a temporary tree
  --write   recompute size and SHA-256 for every row; new skills are added as version 0.1.0, status candidate

A skill is well formed when:
  - the file is UTF-8, has no byte-order mark, uses LF line endings and ends with a newline;
  - its front matter has `name` equal to the folder name (lowercase letters, digits, hyphens; at most 64 characters)
    and a one-line `description` of at most 1024 characters with no angle brackets;
  - it holds no instance details: no workers.dev host, no Drive link and no Drive-style file id.
"""
import argparse
import contextlib
import csv
import hashlib
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKILLS = os.path.join(ROOT, "skills")
INDEX = os.path.join(SKILLS, "INDEX.csv")
COLUMNS = ["name", "version", "status", "path", "size_bytes", "sha256"]
STATUSES = {"candidate", "active", "retired"}
NAME_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
VERSION_RE = re.compile(r"\d+\.\d+\.\d+")
INSTANCE_PATTERNS = [
    (re.compile(r"[a-z0-9-]+\.workers\.dev", re.I), "a workers.dev host"),
    (re.compile(r"(?:drive|docs)\.google\.com/", re.I), "a Drive link"),
    (re.compile(r"(?<![A-Za-z0-9_-])1[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])"), "a Drive-style file id"),
]


def skill_dirs():
    return sorted(d for d in os.listdir(SKILLS)
                  if os.path.isfile(os.path.join(SKILLS, d, "SKILL.md")))


def front_matter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    fm = {}
    for line in text[4:end].split("\n"):
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm


def lint(name, raw):
    problems = []
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("byte-order mark")
    if b"\r" in raw:
        problems.append("CR characters (LF line endings only)")
    if not raw.endswith(b"\n"):
        problems.append("no final newline")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return problems + ["not UTF-8"]
    fm = front_matter(text)
    if fm is None:
        return problems + ["no front matter"]
    if not NAME_RE.fullmatch(name) or len(name) > 64:
        problems.append(f"folder name {name!r} is not a valid skill name")
    if fm.get("name") != name:
        problems.append(f"front matter name {fm.get('name')!r} differs from the folder name")
    desc = fm.get("description", "")
    if not desc:
        problems.append("no description")
    elif len(desc) > 1024 or "<" in desc or ">" in desc:
        problems.append("description longer than 1024 characters or with angle brackets")
    for rx, what in INSTANCE_PATTERNS:
        m = rx.search(text)
        if m:
            problems.append(f"instance detail ({what}) at offset {m.start()}")
    return problems


def file_row(name):
    rel = f"skills/{name}/SKILL.md"
    raw = open(os.path.join(ROOT, rel), "rb").read()
    return rel, raw, str(len(raw)), hashlib.sha256(raw).hexdigest()


def read_index():
    if not os.path.exists(INDEX):
        return []
    with open(INDEX, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return rows


def render(rows):
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=COLUMNS, lineterminator="\n")
    w.writeheader()
    for r in sorted(rows, key=lambda r: r["name"]):
        w.writerow({k: r[k] for k in COLUMNS})
    return out.getvalue()


def check():
    problems = []
    rows = read_index()
    if rows and list(rows[0].keys()) != COLUMNS:
        problems.append(f"INDEX.csv columns must be {COLUMNS}")
        return problems
    by_name = {r["name"]: r for r in rows}
    if len(by_name) != len(rows):
        problems.append("INDEX.csv has a duplicate name")
    names = skill_dirs()
    for n in names:
        rel, raw, size, sha = file_row(n)
        problems += [f"{rel}: {p}" for p in lint(n, raw)]
        r = by_name.get(n)
        if r is None:
            problems.append(f"{rel}: no row in skills/INDEX.csv (run --write)")
            continue
        if r["path"] != rel:
            problems.append(f"{n}: path {r['path']!r} should be {rel!r}")
        if r["size_bytes"] != size or r["sha256"] != sha:
            problems.append(f"{n}: size or sha256 differs from the file (run --write and bump the version)")
        if not VERSION_RE.fullmatch(r["version"]):
            problems.append(f"{n}: version {r['version']!r} is not N.N.N")
        if r["status"] not in STATUSES:
            problems.append(f"{n}: status {r['status']!r} is not one of {sorted(STATUSES)}")
    for n in by_name:
        if n not in names:
            problems.append(f"{n}: row in INDEX.csv but no skills/{n}/SKILL.md")
    if rows and open(INDEX, encoding="utf-8").read() != render(rows):
        problems.append("INDEX.csv is not in canonical form (sorted, LF, no quoting changes; run --write)")
    return problems


def write():
    by_name = {r["name"]: r for r in read_index()}
    rows = []
    for n in skill_dirs():
        rel, _raw, size, sha = file_row(n)
        r = by_name.get(n, {"name": n, "version": "0.1.0", "status": "candidate"})
        r.update({"path": rel, "size_bytes": size, "sha256": sha})
        rows.append(r)
    with open(INDEX, "w", encoding="utf-8", newline="") as f:
        f.write(render(rows))
    print(f"wrote {os.path.relpath(INDEX, ROOT)}: {len(rows)} skills")


def self_test():
    """Each rule refuses a crafted skill in a temporary tree (UT-SKL-01); the clean case passes."""
    import shutil
    import tempfile
    global ROOT, SKILLS, INDEX
    saved = (ROOT, SKILLS, INDEX)
    good = (b"---\nname: demo-skill\ndescription: A demo skill for the self-test.\n---\n\n# Demo\n\nSteps.\n")
    cases = [
        ("clean", good, None),
        ("bom", b"\xef\xbb\xbf" + good, "byte-order mark"),
        ("crlf", good.replace(b"\n", b"\r\n"), "CR characters"),
        ("no final newline", good.rstrip(b"\n"), "no final newline"),
        ("name mismatch", good.replace(b"name: demo-skill", b"name: other"), "differs from the folder name"),
        ("angle brackets", good.replace(b"self-test.", b"<self-test>."), "angle brackets"),
        ("instance host", good + b"Use https://demo-1.example.workers.dev/mcp\n", "workers.dev host"),
        ("drive id", good + b"Folder 1AbCdEfGhIjKlMnOpQrStUvWxYz012345\n", "Drive-style file id"),
    ]
    failures = []
    try:
        for label, body, expect in cases:
            tmp = tempfile.mkdtemp(prefix="bnx-skl-")
            try:
                ROOT, SKILLS = tmp, os.path.join(tmp, "skills")
                INDEX = os.path.join(SKILLS, "INDEX.csv")
                os.makedirs(os.path.join(SKILLS, "demo-skill"))
                with open(os.path.join(SKILLS, "demo-skill", "SKILL.md"), "wb") as f:
                    f.write(body)
                with contextlib.redirect_stdout(io.StringIO()):
                    write()
                got = check()
                if expect is None and got:
                    failures.append(f"{label}: expected clean, got {got}")
                if expect is not None and not any(expect in p for p in got):
                    failures.append(f"{label}: expected {expect!r}, got {got}")
                if expect is None:      # a changed file without --write is refused
                    with open(os.path.join(SKILLS, "demo-skill", "SKILL.md"), "ab") as f:
                        f.write(b"More.\n")
                    if not any("differs from the file" in p for p in check()):
                        failures.append("stale index: not refused")
            finally:
                shutil.rmtree(tmp)
    finally:
        ROOT, SKILLS, INDEX = saved
    if failures:
        print("skill index self-test: FAIL\n  " + "\n  ".join(failures))
        sys.exit(1)
    print(f"skill index self-test: OK, {len(cases)} cases and the stale-index case")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true")
    g.add_argument("--write", action="store_true")
    g.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return
    if a.write:
        write()
    problems = check()
    if problems:
        print("skill index: FAIL\n  " + "\n  ".join(problems))
        sys.exit(1)
    rows = read_index()
    print(f"skill index: OK, {len(rows)} skills: " + ", ".join(f"{r['name']} {r['version']} {r['status']} {r['sha256'][:12]}" for r in rows))


if __name__ == "__main__":
    main()
