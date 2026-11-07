#!/usr/bin/env python3
"""AUD-047 capacity model: second-copy (Drive) backlog under the Cloud Run egress admission meter.
Inputs from the Draft-04 Cost Model (P-02 Cloud Run outbound: 1 GiB/month free NA, pause at 0.8 GiB; other egress
~50 MB/month, ~0.6 GB in a drill month) and Architecture C2.8. egress_factor = Cloud Run outbound bytes per evidence
byte: 2.0 (Draft-04 assumption: upload + verification download), 1.0 (upload only; verification re-hash downloads are
ingress), 0.0 (alternative ARC-ALT-1: the PWA writes the Drive copy at acquisition and the executor only re-hashes it).
Which factor applies on the real account is M0-B-08 / M0-F (PROVIDER_DOC_VERIFIED is NOT claimed here).
Result: months until the last object is dual_verified, and the worst single-copy exposure, when onboarding starts on
day 20 of a billing month (crossing the month boundary)."""
import json, math, os, sys

GIB = 1024 ** 3
PAUSE = 0.8 * GIB
OTHER = {"normal_month": 50e6, "drill_month": 0.6e9}


def model(load_bytes, factor, other, start_day=20, days_in_month=30, objects=None):
    budget_first = PAUSE * (days_in_month - start_day) / days_in_month - other * (days_in_month - start_day) / days_in_month
    per_month = PAUSE - other
    need = load_bytes * factor
    if need == 0:
        return {"days_to_all_dual_verified": "bounded by executor latency (no egress)", "worst_single_copy_days": "<1 (M0-B-08)"}
    if per_month <= 0:
        return {"days_to_all_dual_verified": math.inf}
    if need <= budget_first:
        days = need / budget_first * (days_in_month - start_day)
    else:
        rest = need - budget_first
        days = (days_in_month - start_day) + rest / per_month * days_in_month
    return {"egress_needed_gib": round(need / GIB, 2), "admitted_per_month_gib": round(per_month / GIB, 2),
            "days_to_all_dual_verified": round(days, 1), "worst_single_copy_days": round(days, 1),
            "meets_24h_target": days <= 1.0}


out = {"pause_threshold_gib": 0.8, "assumptions": __doc__.split("\n")[1:7], "cases": {}}
for load in (1e9, 4e9):
    for factor in (2.0, 1.0, 0.0):
        for k, other in OTHER.items():
            out["cases"][f"load_{int(load/1e9)}GB_factor_{factor}_{k}"] = model(load, factor, other)
out["conclusion"] = ("Under the egress meter (0.75 GiB/month admitted in a normal month, 0.24 GiB in a drill month) a 1 GB onboarding "
                     "needs 37-74 days and a 4 GB onboarding 148-297 days (egress factor 1-2, normal months) until every object is "
                     "dual_verified; drill months stretch this further. The 24 h target is NOT met for onboarding volumes. Meanwhile "
                     "objects are single_copy/archive_pending (visible, INV-48) and NOT independently recoverable if R2 is lost. "
                     "Options: (1) accept and disclose (default), (2) require_dual_copy_before_approval (implemented in 0109; delays "
                     "approval by the same period), (3) ARC-ALT-1 (factor 0; engineering change pending reviewer and M0-B-08), "
                     "(4) paid egress (Owner decision CAP-UP; not authorized).")
json.dump(out, sys.stdout, indent=1)
print()
