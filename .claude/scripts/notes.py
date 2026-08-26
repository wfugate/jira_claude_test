#!/usr/bin/env python3
"""Session record store, and the draft feed.

One file per session under ticket-notes/sessions/. This matters: sessions run
CONCURRENTLY, so several detached workers can finish at the same moment. A single
shared append-file can interleave writes and corrupt a line, and a corrupted line
is a session's reasoning lost silently. One file per session means no contention
at all.

    python notes.py --for-draft     # unposted sessions, as text for /updatejira
    python notes.py --mark-posted   # set the watermark
"""
import glob
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(os.path.dirname(HERE), "ticket-notes")
SESSIONS = os.path.join(NOTES, "sessions")


def write_record(rec):
    """Write one session record atomically: temp file, then rename."""
    os.makedirs(SESSIONS, exist_ok=True)
    name = rec.get("session_id") or ("nosid-%d-%d" % (time.time(), os.getpid()))
    final = os.path.join(SESSIONS, "%s.json" % name)
    tmp = final + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
    os.replace(tmp, final)   # atomic on Windows and POSIX
    return final


def load_records():
    """Every session record, oldest first. Bad files are reported, not hidden."""
    out = []
    for path in sorted(glob.glob(os.path.join(SESSIONS, "*.json")),
                       key=lambda p: os.path.getmtime(p)):
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            rec["_path"] = path
            out.append(rec)
        except Exception as exc:
            out.append({"_path": path, "gate": "corrupt",
                        "error": "unreadable record: %r" % exc})
    return out


def mark_posted():
    n = 0
    for rec in load_records():
        if rec.get("posted") or rec.get("gate") == "corrupt":
            continue
        path = rec.pop("_path")
        rec["posted"] = True
        tmp = path + ".tmp%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, indent=2)
        os.replace(tmp, path)
        n += 1
    return n


def main():
    if "--mark-posted" in sys.argv:
        print("Marked %d session(s) as posted." % mark_posted())
        return

    recs = [r for r in load_records() if not r.get("posted")]
    if not recs:
        print("(no unposted sessions captured)")
        return

    print("%d session(s) since the last post:" % len(recs))
    print()
    blank = 0
    for i, r in enumerate(recs, 1):
        print("Session %d  (ended %s, %s user turns)"
              % (i, r.get("ended"), r.get("turns")))
        if r.get("summary"):
            print("  summary: %s" % r["summary"])
        for key, label in (("decisions", "DECISION"),
                           ("constraints", "CONSTRAINT"),
                           ("rejected", "REJECTED"),
                           ("deferred", "DEFERRED")):
            for item in r.get(key) or []:
                print("  %s: %s" % (label, item))
        if r.get("gate") in ("skip", "empty", "error", "unparsed", "corrupt"):
            blank += 1
            print("  NOTE: nothing was extracted from this session (gate=%s)."
                  % r.get("gate"))
            if r.get("transcript_path"):
                print("        transcript still available: %s"
                      % r["transcript_path"])
        if r.get("files"):
            print("  files touched: %s" % ", ".join(r["files"][:10]))
        print()

    if blank:
        print("WARNING: %d of %d sessions produced no reasoning. If real"
              % (blank, len(recs)))
        print("decisions were made in those, this draft is INCOMPLETE - say so")
        print("rather than writing as though the record is whole.")


if __name__ == "__main__":
    main()
