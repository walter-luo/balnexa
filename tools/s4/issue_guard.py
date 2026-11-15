#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Issue guard for the public tracker (docs/s4/Issue_and_Release_Process.md §4).

Run by .github/workflows/issue-guard.yml on every new or edited issue and issue comment. Neither a SIN (Owner decision
2026-11-07) nor a full payment-card number (OD-PAN-1) may stay in a public issue. When the title or body holds a candidate,
the guard:
  1. replaces each candidate in place: a SIN with the detector's mask, a card number with all digits except the last 4 masked;
  2. adds the label privacy:redacted;
  3. posts one comment that names the kind of value removed, never the value.
GitHub keeps the edit history of an issue, and e-mail notifications have already gone out. The comment asks the maintainer
to delete the original revision in the edit history.

The guard reads only the event file; it never runs code from the issue. --self-test checks the redaction on synthetic values
built at run time (no network). Exit codes: 0 done (or nothing to do), 1 self-test failure, 2 the guard could not run.
"""
import json, os, random, string, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "apps", "executor"))
from bnx_exec import pan_detector as PAN, sin_detector as SIN  # noqa: E402

LABEL = "privacy:redacted"
NOTE = ("**Privacy guard:** this {what} contained {kinds}. The value was replaced in place and is not repeated here. "
        "Never post a SIN, a full card number, account numbers or real statements; describe the pattern instead "
        "(for example \"a 16-digit number grouped 4-4-4-4\"). Maintainer: delete the original revision from the edit history.")


def redact(text):
    """(new text, kinds found). The SIN pass runs first; the card pass then masks all but the last 4 digits."""
    if not text:
        return text, []
    kinds = []
    s = SIN.scrub(text)
    if s != text:
        kinds.append("a SIN-like number")
    p = PAN.mask(s)
    if p != s:
        kinds.append("a payment-card number")
    return p, kinds


def plan(event_name, ev):
    """[(api path, field values)] edits, the kinds found, the issue number, and what was edited. No network."""
    if event_name == "issues":
        it = ev["issue"]
        t, kt = redact(it.get("title") or "")
        b, kb = redact(it.get("body") or "")
        kinds = sorted(set(kt + kb))
        patch = {}
        if t != (it.get("title") or ""):
            patch["title"] = t
        if b != (it.get("body") or ""):
            patch["body"] = b
        return ([(f"issues/{it['number']}", patch)] if patch else []), kinds, it["number"], "issue"
    if event_name == "issue_comment":
        c = ev["comment"]
        b, kinds = redact(c.get("body") or "")
        edits = [(f"issues/comments/{c['id']}", {"body": b})] if b != (c.get("body") or "") else []
        return edits, sorted(set(kinds)), ev["issue"]["number"], "comment"
    return [], [], None, None


def api(method, path, data=None):
    repo, token = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"]
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}", method=method,
                                 data=None if data is None else json.dumps(data).encode(),
                                 headers={"authorization": f"Bearer {token}", "accept": "application/vnd.github+json",
                                          "content-type": "application/json", "x-github-api-version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def run():
    ev = json.load(open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8"))
    name = os.environ["GITHUB_EVENT_NAME"]
    if name == "issue_comment" and (ev.get("comment", {}).get("user", {}).get("type") == "Bot"):
        return 0                                                  # never re-check the guard's own comment
    edits, kinds, number, what = plan(name, ev)
    if not edits:
        print("issue_guard: nothing to redact")
        return 0
    for path, fields in edits:
        api("PATCH", path, fields)
    api("POST", f"issues/{number}/labels", {"labels": [LABEL]})
    api("POST", f"issues/{number}/comments", {"body": NOTE.format(what=what, kinds=" and ".join(kinds))})
    print(f"issue_guard: redacted the {what} of #{number} ({', '.join(kinds)})")
    return 0


def self_test():
    r = random.Random(20261115)

    def pan(prefix, n):
        d = prefix + "".join(r.choice(string.digits) for _ in range(n - len(prefix) - 1))
        return next(d + c for c in string.digits if PAN.luhn(d + c))

    def threes(d):                     # the value printed in groups of three, as on a slip
        return " ".join(d[i:i + 3] for i in range(0, len(d), 3))

    label = "SIN"

    def sin():
        while True:
            d = r.choice(string.digits[1:]) + "".join(r.choice(string.digits) for _ in range(8))
            if SIN.luhn(d) and SIN.candidate(label + " " + threes(d)):
                return d
    card, debit, s = pan("4", 16), pan("9", 16), sin()
    grouped = " ".join(card[i:i + 4] for i in range(0, 16, 4))
    ev = {"issue": {"number": 7, "title": "Import refused card " + grouped,
                    "body": "My " + label + " is " + threes(s) + " and debit " + debit + ". Release 0.9.8-p2, 2026-11-15, amount 1234.56."}}
    edits, kinds, number, what = plan("issues", ev)
    out = json.dumps(edits)
    fails = []
    if number != 7 or what != "issue" or len(edits) != 1:
        fails.append("plan shape")
    if kinds != ["a SIN-like number", "a payment-card number"]:
        fails.append(f"kinds {kinds}")
    for v in (card, debit, s, card[:12], debit[:12], s[:6]):
        if v in out.replace(" ", ""):
            fails.append("a value survived")
    if card[-4:] not in out or debit[-4:] not in out:
        fails.append("last 4 digits not kept")
    if "0.9.8-p2" not in out or "2026-11-15" not in out or "1234.56" not in out:
        fails.append("ordinary text changed")
    fixed = {"issue": {"number": 7, "title": edits[0][1]["title"], "body": edits[0][1]["body"]}}
    if plan("issues", fixed)[0]:
        fails.append("redacted text triggers again")
    if plan("issues", {"issue": {"number": 8, "title": "Typo on the Reports screen", "body": "ref 2026111412345678901234"}})[0]:
        fails.append("clean issue edited")
    c = plan("issue_comment", {"issue": {"number": 7}, "comment": {"id": 99, "body": f"card {card}"}})
    if not c[0] or c[0][0][0] != "issues/comments/99" or card in json.dumps(c[0]):
        fails.append("comment")
    if any(x in NOTE for x in (card, s)):
        fails.append("note")
    print("issue_guard self-test:", "OK" if not fails else "FAIL " + "; ".join(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    try:
        sys.exit(self_test() if "--self-test" in sys.argv else run())
    except (KeyError, OSError, ValueError) as e:
        print(f"issue_guard: ERROR, the guard did not run: {type(e).__name__}", file=sys.stderr)
        sys.exit(2)
