#!/usr/bin/env python3
"""Run a scripted multi-turn session, so long flows can be tested repeatably.

    python .claude/scripts/flow.py flows/notices.txt

The file holds one turn per paragraph, blank-line separated:

    members get no warning before late fees pile up. send a notice at 7 and 14
    days past due, one per threshold.

    implement it

    actually make the thresholds configurable, ops will want to tune them

Each paragraph becomes one user turn in ONE session, via `claude -p --continue`.
That matters: the gate reads user turns, so a single -p call gives a one-turn
session and a thin record no matter how much work happened inside it. Long flows
need many turns, which is what this produces.

The SessionEnd hook fires after every turn, each time for the same session id, so
the record is rewritten with a fuller transcript as the flow proceeds. Only the
last one matters; notes.write_record refuses to regress to a thinner record.

    --dry    print the turns without running anything
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TURN_TIMEOUT = 900


def load_turns(path):
    text = open(path, encoding="utf-8").read()
    return [blk.strip() for blk in text.split("\n\n") if blk.strip()]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit("Usage: flow.py <flow-file> [--dry]")
    path = args[0]
    if not os.path.exists(path):
        raise SystemExit("No such flow file: %s" % path)

    turns = load_turns(path)
    if not turns:
        raise SystemExit("Flow file has no turns (blank-line separated).")

    print("Flow: %s  (%d turns)" % (path, len(turns)))
    for i, t in enumerate(turns, 1):
        print("  [%d] %s%s" % (i, t[:88].replace("\n", " "),
                               "..." if len(t) > 88 else ""))
    if "--dry" in sys.argv:
        print("\n(dry run, nothing executed)")
        return

    print()
    for i, turn in enumerate(turns, 1):
        cmd = ["claude", "-p"]
        if i > 1:
            cmd.append("--continue")   # same session, turns accumulate
        cmd.append(turn)

        t0 = time.time()
        print("[%d/%d] running..." % (i, len(turns)), end="", flush=True)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=TURN_TIMEOUT, cwd=REPO)
        except subprocess.TimeoutExpired:
            print(" TIMED OUT after %ds - flow aborted" % TURN_TIMEOUT)
            return
        print(" done in %.0fs (rc=%s)" % (time.time() - t0, proc.returncode))
        if proc.returncode != 0:
            print("     stderr: %s" % (proc.stderr or "").strip()[:300])
            print("     aborting flow - later turns depend on this one")
            return

    print()
    print("Flow complete. The hook fired after each turn; give the last worker")
    print("~15s, then:")
    print("    python .claude/scripts/inspect.py")


if __name__ == "__main__":
    main()
