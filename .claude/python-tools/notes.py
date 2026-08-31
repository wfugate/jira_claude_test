#!/usr/bin/env python3
"""Session record store, draft feed, and the watermark.

One file per session under ticket-notes/sessions/. Sessions run CONCURRENTLY, so
several detached workers can finish in the same instant. A shared append-file can
interleave writes and corrupt a line, and a corrupted line is a session's
reasoning lost silently. One file per session means no contention at all.

    python notes.py --for-draft                    # unposted records, numbered
    python notes.py --mark-posted 1,3,5 TEST-115   # consume ONLY those records

Selection is mandatory when marking. Several tickets can be worked in one repo,
so "everything unposted" is not a safe default - it would attribute one ticket's
reasoning to another and consume records that belonged elsewhere. Pass --all
explicitly if every unposted record really does belong to this ticket.

Nothing here is destructive in the end: each record keeps its transcript_path, so
a record consumed by the wrong ticket can be recovered with replay.py.
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
    """Write one session record atomically: temp file, then rename.

    A session can end more than once - `claude -p --continue` fires the hook
    after every call, each time for the same session id. Later firings see more
    turns, so overwriting is usually right. But workers run detached and can
    finish out of order, so an earlier, thinner record must never clobber a
    fuller one: compare turn counts before replacing.
    """
    os.makedirs(SESSIONS, exist_ok=True)
    name = rec.get("session_id") or ("nosid-%d-%d" % (time.time(), os.getpid()))
    final = os.path.join(SESSIONS, "%s.json" % name)

    if os.path.exists(final):
        try:
            with open(final, encoding="utf-8") as fh:
                existing = json.load(fh)
        except Exception:
            existing = {}
        if existing.get("posted"):
            return final          # already consumed by a ticket; leave it alone
        if (existing.get("turns") or 0) > (rec.get("turns") or 0):
            return final          # existing record is fuller; do not regress

    tmp = final + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
    os.replace(tmp, final)
    return final


def load_records():
    """Every record, oldest first. Bad files are reported, never hidden."""
    out = []
    for path in sorted(glob.glob(os.path.join(SESSIONS, "*.json")),
                       key=os.path.getmtime):
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            rec["_path"] = path
            out.append(rec)
        except Exception as exc:
            out.append({"_path": path, "gate": "corrupt",
                        "error": "unreadable record: %r" % exc})
    return out


def unposted(include_draft_sessions=False):
    """Records not yet consumed by a ticket.

    Sessions that were themselves /updatejira runs are kept on disk as an audit
    trail but excluded here - they are not work, and listing them would put
    permanent noise in front of every future draft.
    """
    out = [r for r in load_records() if not r.get("posted")]
    if not include_draft_sessions:
        out = [r for r in out if not r.get("is_draft_session")]
    return out


def _save(rec):
    path = rec.pop("_path")
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
    os.replace(tmp, path)


def mark_posted(indices, ticket):
    """Mark only the selected 1-based indices into the unposted list."""
    recs = unposted()
    bad = [i for i in indices if i < 1 or i > len(recs)]
    if bad:
        raise SystemExit("No such session(s): %s (there are %d unposted)"
                         % (", ".join(str(b) for b in bad), len(recs)))
    done = []
    for i in indices:
        rec = recs[i - 1]
        if rec.get("gate") == "corrupt":
            continue
        rec["posted"] = True
        rec["posted_to"] = ticket
        rec["posted_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        _save(rec)
        done.append(i)
    return done, len(recs)


def main():
    argv = sys.argv[1:]

    if "--mark-posted" in argv:
        rest = argv[argv.index("--mark-posted") + 1:]
        recs = unposted()
        if "--all" in rest:
            indices = list(range(1, len(recs) + 1))
            ticket = next((a for a in rest if a != "--all"), "")
        else:
            sel = next((a for a in rest if not a.startswith("-")
                        and any(c.isdigit() for c in a)), None)
            if not sel:
                raise SystemExit(
                    "Refusing to mark anything without a selection.\n"
                    "There are %d unposted session(s). Pass the ones belonging "
                    "to this ticket:\n"
                    "    python notes.py --mark-posted 1,3,5 TICKET-KEY\n"
                    "or --all if every one of them really does belong to it."
                    % len(recs))
            indices = [int(x) for x in sel.replace(",", " ").split()]
            ticket = next((a for a in rest
                           if a != sel and not a.startswith("-")), "")
        done, total = mark_posted(indices, ticket)
        print("Marked %d of %d unposted session(s) as posted%s: %s"
              % (len(done), total, (" to " + ticket) if ticket else "",
                 ", ".join(str(d) for d in done)))
        left = len(unposted())
        if left:
            print("%d session(s) still unposted - they stay available for "
                  "another ticket." % left)
        return

    recs = unposted()
    if not recs:
        print("(no unposted sessions captured)")
        return

    print("%d unposted session(s). Numbers are for selection at post time."
          % len(recs))
    print()
    blank = 0
    hints = set()
    for i, r in enumerate(recs, 1):
        hint = r.get("ticket_hint") or ""
        if hint:
            hints.add(hint)
        print("[%d] ended %s, %s user turns%s"
              % (i, r.get("ended"), r.get("turns"),
                 ("   ticket named in session: %s" % hint) if hint else ""))
        if r.get("summary"):
            print("    summary: %s" % r["summary"])
        for key, label in (("decisions", "DECISION"),
                           ("constraints", "CONSTRAINT"),
                           ("rejected", "REJECTED"),
                           ("deferred", "DEFERRED")):
            for item in r.get(key) or []:
                print("    %s: %s" % (label, item))
        if r.get("gate") in ("skip", "empty", "error", "unparsed", "corrupt"):
            reason = r.get("skip_reason") or ""
            if reason == "NOTHING_TO_RECORD":
                print("    (nothing to record - the gate read this and found"
                      " no decision. Not a gap.)")
            else:
                blank += 1
                print("    NOTE: nothing extracted, and the gate was NOT"
                      " confident it was empty (gate=%s%s)."
                      % (r.get("gate"), ", " + reason if reason else ""))
                if r.get("transcript_path"):
                    print("          transcript available: %s"
                          % r["transcript_path"])
        if r.get("files"):
            print("    files touched: %s" % ", ".join(r["files"][:10]))
        print()

    if len(hints) > 1:
        print("CAUTION: these sessions name more than one ticket (%s)."
              % ", ".join(sorted(hints)))
        print("They do NOT all belong to the same update. Select carefully.")
        print()
    if blank:
        print("WARNING: %d of %d sessions produced nothing AND the gate was not"
              % (blank, len(recs)))
        print("confident they were empty. Those may be missing real decisions,")
        print("so any draft is possibly INCOMPLETE - say so.")
        print("(Sessions the gate confidently found empty are not counted.)")


if __name__ == "__main__":
    main()
