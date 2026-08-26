#!/usr/bin/env python3
"""Read the session accumulator for the draft step, and set the watermark.

    python .claude/scripts/notes.py --for-draft     # unposted sessions, as text
    python .claude/scripts/notes.py --mark-posted   # mark them posted

--for-draft is what /updatejira consumes. Only the extracted reasoning is
emitted, never raw transcript content.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ACC = os.path.join(os.path.dirname(HERE), "ticket-notes", "accumulated.jsonl")


def load():
    out = []
    if os.path.exists(ACC):
        with open(ACC, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln:
                    try:
                        out.append(json.loads(ln))
                    except Exception:
                        pass
    return out


def save(records):
    with open(ACC, "w", encoding="utf-8") as fh:
        for r in records:
            print(json.dumps(r), file=fh)


if "--mark-posted" in sys.argv:
    recs = load()
    n = 0
    for r in recs:
        if not r.get("posted"):
            r["posted"] = True
            n += 1
    save(recs)
    print("Marked %d session(s) as posted." % n)
    sys.exit(0)

recs = [r for r in load() if not r.get("posted")]
if not recs:
    print("(no unposted sessions captured)")
    sys.exit(0)

print("%d session(s) since the last post:" % len(recs))
print()
blank = 0
for i, r in enumerate(recs, 1):
    print("Session %d  (ended %s, %s user turns)"
          % (i, r.get("ended"), r.get("turns")))
    if r.get("summary"):
        print("  summary: %s" % r["summary"])
    for key, label in (("decisions", "DECISION"), ("constraints", "CONSTRAINT"),
                       ("rejected", "REJECTED"), ("deferred", "DEFERRED")):
        for item in r.get(key) or []:
            print("  %s: %s" % (label, item))
    if r.get("gate") in ("skip", "empty", "error", "unparsed"):
        blank += 1
        print("  NOTE: nothing was extracted from this session (gate=%s)."
              % r.get("gate"))
        print("        transcript still available: %s" % r.get("transcript_path"))
    if r.get("files"):
        print("  files touched: %s" % ", ".join(r["files"][:10]))
    print()

if blank:
    print("WARNING: %d of %d sessions produced no reasoning. If real decisions"
          % (blank, len(recs)))
    print("were made in those, this draft is incomplete - say so rather than")
    print("writing as though the record is whole.")
