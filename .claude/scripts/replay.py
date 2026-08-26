#!/usr/bin/env python3
"""Re-run the gate over already-captured sessions with the CURRENT prompt.

The tuning loop: edit worker_prompt.txt, run this, compare. No need to redo the
sessions - the transcripts are already on disk.

    python .claude/scripts/replay.py            # re-score every session
    python .claude/scripts/replay.py 2 5        # just sessions 2 and 5
    python .claude/scripts/replay.py --write    # overwrite accumulated.jsonl

Without --write nothing is modified; results print for comparison only.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(os.path.dirname(HERE), "ticket-notes")
import notes  # noqa: E402
PROMPT_FILE = os.path.join(HERE, "worker_prompt.txt")

sys.path.insert(0, HERE)
from worker import extract_user_turns, MAX_TURNS  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("-")]
write = "--write" in sys.argv

records = notes.load_records()
if not records:
    sys.exit("Nothing to replay - no records in %s" % notes.SESSIONS)
wanted = [int(a) for a in args] if args else list(range(1, len(records) + 1))
prompt_base = open(PROMPT_FILE, encoding="utf-8").read()

env = dict(os.environ)
env["UPDATEJIRA_HOOK_GUARD"] = "1"
updated = []

for i, rec in enumerate(records, 1):
    if i not in wanted:
        updated.append(rec)
        continue
    tp = rec.get("transcript_path")
    if not tp or not os.path.exists(tp):
        print("[%d] transcript gone, skipping: %s" % (i, tp))
        updated.append(rec)
        continue

    turns, files = extract_user_turns(tp)
    if not turns:
        print("[%d] no user turns" % i)
        updated.append(rec)
        continue

    proc = subprocess.run(
        ["claude", "-p", prompt_base + "\n\n---\n".join(turns[:MAX_TURNS])],
        capture_output=True, text=True, timeout=300, env=env, cwd=HERE)
    out = (proc.stdout or "").strip()
    if out.startswith("```"):
        out = out.split("\n", 1)[-1]
        if out.rstrip().endswith("```"):
            out = out.rstrip()[:-3]
    try:
        parsed = json.loads(out)
    except Exception:
        print("[%d] UNPARSEABLE: %s" % (i, out[:200]))
        updated.append(rec)
        continue

    items = sum(len(parsed.get(k) or [])
                for k in ("decisions", "constraints", "rejected", "deferred"))
    was_gate, was_items = rec.get("gate"), rec.get("item_count", 0)
    now_gate = "captured" if parsed.get("substantive") else "skip"
    flag = "  <-- CHANGED" if (was_gate != now_gate or was_items != items) else ""
    print("\n[%d] %s  was: gate=%s items=%s   now: gate=%s items=%s%s"
          % (i, (rec.get("session_id") or "?")[:8], was_gate, was_items,
             now_gate, items, flag))
    print("    summary: %s" % parsed.get("summary", ""))
    for key in ("decisions", "constraints", "rejected", "deferred"):
        for item in parsed.get(key) or []:
            print("    %-11s %s" % (key + ":", item))

    rec = dict(rec)
    rec.update({
        "gate": now_gate, "summary": parsed.get("summary", ""),
        "decisions": parsed.get("decisions") or [],
        "constraints": parsed.get("constraints") or [],
        "rejected": parsed.get("rejected") or [],
        "deferred": parsed.get("deferred") or [],
        "item_count": items,
    })
    updated.append(rec)

if write:
    for r in updated:
        r.pop("_path", None)
        notes.write_record(r)
    print("Wrote %d record(s) to %s" % (len(updated), notes.SESSIONS))
else:
    print("\n(dry run - pass --write to save these results)")
