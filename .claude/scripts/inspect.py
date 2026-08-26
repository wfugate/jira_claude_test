#!/usr/bin/env python3
"""Show what the session hook has captured so far. Read-only."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import notes  # noqa: E402

records = notes.load_records()
if not records:
    print("Nothing captured yet - no records in %s" % notes.SESSIONS)
    print("Have you ended a session in this repo since the hook was installed?")
    sys.exit(0)

verbose = "-v" in sys.argv
print("=" * 72)
print("%d session(s) captured" % len(records))
print("=" * 72)

tally = {}
for i, r in enumerate(records, 1):
    g = r.get("gate", "?")
    tally[g] = tally.get(g, 0) + 1
    print("\n[%d] %s   gate=%s   turns=%s   ended=%s"
          % (i, (r.get("session_id") or "?")[:8], g, r.get("turns"), r.get("ended")))
    if r.get("summary"):
        print("    summary: %s" % r["summary"])
    for key, label in (("decisions", "decision"), ("constraints", "constraint"),
                       ("rejected", "rejected"), ("deferred", "DEFERRED")):
        for item in r.get(key) or []:
            print("    %-10s %s" % (label + ":", item))
    if r.get("files"):
        print("    files:     %s" % ", ".join(r["files"][:8]))
    if r.get("error"):
        print("    ERROR:     %s" % r["error"])
    if r.get("raw") and verbose:
        print("    raw:       %s" % r["raw"][:400])
    if verbose and r.get("transcript_path"):
        print("    transcript: %s" % r["transcript_path"])

print("\n" + "=" * 72)
print("gate tally: %s" % tally)
total = sum(len(r.get(k) or []) for r in records
            for k in ("decisions", "constraints", "rejected", "deferred"))
print("total captured items: %d" % total)
skipped = [r for r in records if r.get("gate") == "skip"]
if skipped:
    print("\n%d session(s) produced NO summary. If any of those held a real"
          % len(skipped))
    print("decision, that is a false negative - tune worker_prompt.txt.")
    for r in skipped:
        print("   %s  turns=%s  %s" % ((r.get("session_id") or "?")[:8],
                                       r.get("turns"), r.get("transcript_path")))
