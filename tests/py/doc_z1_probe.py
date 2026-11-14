# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""AT-SIN-31 probe: one transient Z1 validation in a fresh process, traced by the test (strace) for file creation.

Usage: doc_z1_probe.py <root> <mode>   mode: success | quarantine | timeout | crash
Prints the verdict without locators. The generated value never reaches stdout or stderr unless the validator leaks it,
which is what the test checks.
"""
import json
import os
import sys
import threading

root, mode = sys.argv[1], sys.argv[2]
sys.path[:0] = [os.path.join(root, "apps", "executor"), os.path.join(root, "tests", "py")]
from bnx_exec import doc_validator as V  # noqa: E402
import doc_fixtures as F  # noqa: E402

val = F.v("luhn", 31)
budget = 120
if mode == "success":
    data = F.pdf_redacted_t4()
elif mode == "quarantine":
    data = F.pdf_visible(val)
else:
    data, _ = F.image(["Synthetic slip", "SIN " + val])
    V.OCR_CMD = [sys.executable, "-c", "import time; time.sleep(3)"]
    budget = 1
    if mode == "crash":
        threading.Timer(0.5, lambda: os.kill(os.getpid(), 9)).start()
        budget = 30
r = V.validate(data, budget_seconds=budget)
print(json.dumps({"scan_result": r["scan_result"], "rule_codes": r["rule_codes"], "locators": len(r["locators"])}))
