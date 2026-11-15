#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Bring the repository's issue labels in line with .github/labels.json (docs/s4/Issue_and_Release_Process.md §3).

Default: show what would change (no write). --apply creates missing labels and updates colour or description of listed ones,
through the GitHub CLI (`gh api`). Labels not in the file are left alone; nothing is deleted. Exit 0 in sync or applied,
1 differences found (without --apply), 2 the tool could not run."""
import json, os, subprocess, sys, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def gh(*args, data=None):
    r = subprocess.run(["gh", "api", *args] + (["--input", "-"] if data is not None else []), capture_output=True, text=True,
                       input=None if data is None else json.dumps(data), check=True)
    return json.loads(r.stdout or "null")


def main():
    repo = os.environ.get("BNX_REPO", "walter-luo/balnexa")
    want = json.load(open(os.path.join(ROOT, ".github", "labels.json"), encoding="utf-8"))["labels"]
    have = {x["name"]: x for x in gh("--paginate", f"repos/{repo}/labels?per_page=100")}
    todo = []
    for w in want:
        h = have.get(w["name"])
        if h is None:
            todo.append(("create", w))
        elif h["color"].lower() != w["color"].lower() or (h.get("description") or "") != w["description"]:
            todo.append(("update", w))
    for op, w in todo:
        print(f"{op:6} {w['name']}")
    if "--apply" in sys.argv:
        for op, w in todo:
            if op == "create":
                gh("-X", "POST", f"repos/{repo}/labels", data=w)
            else:
                gh("-X", "PATCH", f"repos/{repo}/labels/{urllib.parse.quote(w['name'], safe='')}", data={"color": w["color"], "description": w["description"]})
        print(f"sync_labels: {len(todo)} change(s) applied")
        return 0
    print(f"sync_labels: {len(todo)} change(s) needed" + (" (run with --apply)" if todo else ", in sync"))
    return 1 if todo else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError, ValueError) as e:
        print(f"sync_labels: ERROR, could not run: {e}", file=sys.stderr)
        sys.exit(2)
