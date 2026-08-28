#!/usr/bin/env python3
"""The only file that knows which version control system this repo uses.

    python vcs.py status     # what has changed in the working copy
    python vcs.py diff       # the actual changes
    python vcs.py prepare    # make new files visible to diff (no-op on some VCS)
    python vcs.py backend    # which backend is active, and why

Backend selection, in order:
  1. UPDATEJIRA_VCS=git|accurev in the environment
  2. a .git directory  -> git
  3. a .acignore file or an accurev executable on PATH -> accurev
  4. otherwise: error, rather than guessing

Everything else in this tool is VCS-agnostic. The capture half reads Claude Code
transcripts and never touches version control at all; only the draft step needs a
diff. So porting to a different VCS is this file and nothing else.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TIMEOUT = 120

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def run(args):
    """Run a command in the repo root. Returns (rc, stdout, stderr)."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, cwd=REPO,
                           timeout=TIMEOUT, encoding="utf-8", errors="replace")
        return p.returncode, (p.stdout or ""), (p.stderr or "")
    except FileNotFoundError:
        return 127, "", "command not found: %s" % args[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ds: %s" % (TIMEOUT, " ".join(args))


# --------------------------------------------------------------------------
# git  -- fully verified, used for all development and testing
# --------------------------------------------------------------------------

class Git:
    name = "git"

    def prepare(self):
        """Intent-to-add, so brand-new files appear in `diff HEAD`.

        Without this, a new source file is invisible to the diff - and new
        features are exactly where new files live. Registers paths only; stages
        no content and commits nothing.
        """
        return run(["git", "add", "-N", "."])

    def status(self):
        return run(["git", "status", "--short"])

    def diff(self):
        return run(["git", "diff", "HEAD"])


# --------------------------------------------------------------------------
# AccuRev  -- NOT VERIFIED. No command below has been run against a real
# workspace. See the notes on each one.
# --------------------------------------------------------------------------

class AccuRev:
    name = "accurev"

    def prepare(self):
        """No equivalent of git's intent-to-add.

        AccuRev tracks new files differently: a file present in the workspace but
        not in the depot has status "external" and is not part of any diff until
        it is added with `accurev add`. So new files will NOT appear in diff
        output - status() surfaces them separately instead.
        """
        return 0, "(no prepare step for accurev)\n", ""

    def status(self):
        """Modified files, plus external (new, not yet added) files.

        `stat -m` is documented as searching the workspace for modified files.
        IMPORTANT: it uses a timestamp optimisation and skips files whose
        timestamps have not changed since the last update or modified-search,
        which can silently omit a genuinely modified file. `-O` disables that
        optimisation at the cost of a slower, full search. We pass -O because a
        missing file means a ticket comment that describes an incomplete change,
        which is worse than a slow command.

        `stat -x` lists external files - present in the workspace, unknown to the
        depot. Those are new files, and without them new work is invisible.

        UNVERIFIED: the -O and -x flags, and whether combining -m -O is valid.
        """
        rc_m, out_m, err_m = run(["accurev", "stat", "-m", "-O"])
        rc_x, out_x, err_x = run(["accurev", "stat", "-x"])
        out = out_m
        if out_x.strip():
            out += "\n--- external (new, not yet added to the depot) ---\n" + out_x
        return (rc_m or rc_x), out, " | ".join(
            e.strip() for e in (err_m, err_x) if e.strip())

    def diff(self):
        """All elements, workspace against the version last kept.

        `accurev diff` with no version spec compares the workspace file against
        the active version in the workspace stream - what you last kept. That is
        the equivalent of `git diff HEAD`. `-a` widens it to all elements rather
        than named ones.

        Note: extra flags are passed through to the underlying comparison
        program, not interpreted by AccuRev. An earlier draft of this tool used
        `-a -b`, where -b is the comparison program's ignore-whitespace flag.
        Dropped: whitespace changes are real changes for our purposes.

        UNVERIFIED against a real workspace.
        """
        return run(["accurev", "diff", "-a"])

    def ticket_history(self, ticket):
        """All transactions whose comment mentions the ticket.

        Matthew's observation: with the ticket number in the transaction comment,
        AccuRev already aggregates every change for a ticket - which is the half
        of the problem this tool does NOT need to solve.

        UNVERIFIED, and the most speculative command here. `hist` is the history
        command but whether it can filter on comment text is unconfirmed; it may
        need a full dump filtered locally instead.
        """
        rc, out, err = run(["accurev", "hist", "-k", "keep", "-t", "now.100"])
        if rc == 0 and ticket:
            keep = [ln for ln in out.splitlines() if ticket.lower() in ln.lower()]
            out = "\n".join(keep) or "(no transactions mentioning %s)" % ticket
        return rc, out, err


# --------------------------------------------------------------------------

def detect():
    """Pick a backend. Returns (backend, reason)."""
    forced = (os.environ.get("UPDATEJIRA_VCS") or "").strip().lower()
    if forced == "git":
        return Git(), "UPDATEJIRA_VCS=git"
    if forced == "accurev":
        return AccuRev(), "UPDATEJIRA_VCS=accurev"
    if forced:
        raise SystemExit("UPDATEJIRA_VCS=%r is not a known backend "
                         "(git or accurev)" % forced)

    if os.path.isdir(os.path.join(REPO, ".git")):
        return Git(), "found .git"
    if os.path.exists(os.path.join(REPO, ".acignore")):
        return AccuRev(), "found .acignore"
    if shutil.which("accurev"):
        return AccuRev(), "accurev found on PATH"

    raise SystemExit(
        "Cannot tell which version control system %s uses.\n"
        "Set UPDATEJIRA_VCS=git or UPDATEJIRA_VCS=accurev." % REPO)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    action = sys.argv[1]
    backend, reason = detect()

    if action == "backend":
        print("backend: %s   (%s)" % (backend.name, reason))
        if backend.name == "accurev":
            print("WARNING: no accurev command in this file has ever been run "
                  "against a real workspace. Treat its output as unverified.")
        return

    if action == "ticket-history":
        ticket = sys.argv[2] if len(sys.argv) > 2 else ""
        if not hasattr(backend, "ticket_history"):
            print("(%s has no ticket-history support)" % backend.name)
            return
        rc, out, err = backend.ticket_history(ticket)
    elif action in ("prepare", "status", "diff"):
        rc, out, err = getattr(backend, action)()
    else:
        raise SystemExit("Unknown action %r. Use: prepare, status, diff, "
                         "ticket-history, backend" % action)

    if out.strip():
        print(out.rstrip())
    if rc != 0:
        # Loud, not silent. A diff that failed must never look like "no changes".
        print("\n!! %s %s failed (rc=%s)" % (backend.name, action, rc))
        if err.strip():
            print("!! %s" % err.strip()[:600])
        sys.exit(rc)
    elif not out.strip():
        print("(no output - nothing changed)")


if __name__ == "__main__":
    main()
