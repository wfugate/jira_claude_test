#!/usr/bin/env python3
"""Detached worker: extract reasoning from a finished session.

Writes ONLY to a local file. Nothing here touches Jira - posting happens later,
on /updatejira, behind the approval gate.

A record is written for EVERY session, even when nothing is extracted. That way
"the gate found nothing" is visible and recoverable rather than silent, and the
transcript path is retained so a thin summary can be drilled into later.

Everything below the helpers sits inside main(). That matters: replay.py imports
extract_user_turns from here, and module-level work would run - and sys.exit -
on import, killing the caller.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(os.path.dirname(HERE), "ticket-notes")
# The prompt lives with the PowerShell runtime, which is what actually runs in
# production. These Python tools point at THAT file, not a copy: tuning must
# edit the same prompt the hook uses, or replay would score a prompt nobody
# runs.
PROMPT_FILE = os.path.join(os.path.dirname(HERE), "scripts", "worker_prompt.txt")

sys.path.insert(0, HERE)
import notes  # noqa: E402 - one file per session, concurrency-safe

MAX_TURN_CHARS = 4000
MAX_TURNS = 60


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def _is_source(path):
    """Keep source files out of which the diff is made; drop everything else.

    Sessions write to the memory store and to notes as a side effect, and those
    were turning up in "files touched" as though they were part of the change.
    """
    low = path.replace("\\", "/").lower()
    if "/.claude/" in low or "/memory/" in low:
        return False
    if os.path.basename(low) in ("memory.md", "claude.md"):
        return False
    return not low.endswith((".md", ".json", ".jsonl", ".log", ".txt"))


def extract_user_turns(path):
    """User turns only - ~13% of transcript volume, most of the reasoning.

    Shapes are identical between the cli and claude-desktop entrypoints; the
    record types that differ between them are all ones dropped here.
    """
    turns, files = [], set()
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                continue

            tur = o.get("toolUseResult")
            if isinstance(tur, dict):
                fp = tur.get("filePath") or tur.get("file_path")
                if fp and _is_source(str(fp)):
                    files.add(os.path.basename(str(fp)))

            if o.get("type") != "user" or o.get("isSidechain"):
                continue
            content = (o.get("message") or {}).get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = " ".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text")
            else:
                continue
            text = text.strip()
            if not text:
                continue
            # Harness noise, not anything a human typed.
            if ("<local-command-caveat>" in text
                    or text.startswith("<system-reminder>")):
                continue
            turns.append(text[:MAX_TURN_CHARS])
    return turns, sorted(files)


def run_gate(turns):
    """Ask a headless call what was decided. Returns (parsed, raw, error)."""
    prompt = (open(PROMPT_FILE, encoding="utf-8").read()
              + "\n\n---\n".join(turns[:MAX_TURNS]))

    env = dict(os.environ)
    env["UPDATEJIRA_HOOK_GUARD"] = "1"

    t0 = time.time()
    try:
        proc = subprocess.run(["claude", "-p", prompt], capture_output=True,
                              text=True, timeout=300, env=env, cwd=HERE)
    except Exception as exc:
        return None, "", repr(exc)[:300]

    log("claude -p rc=%s in %.1fs" % (proc.returncode, time.time() - t0))
    out = (proc.stdout or "").strip()

    # Strip a markdown fence if one slipped through.
    if out.startswith("```"):
        out = out.split("\n", 1)[-1]
        if out.rstrip().endswith("```"):
            out = out.rstrip()[:-3]

    try:
        return json.loads(out), out, None
    except Exception:
        return None, out, None


def record_from(parsed):
    """Flatten a gate result into the fields a record carries."""
    items = sum(len(parsed.get(k) or [])
                for k in ("decisions", "constraints", "rejected", "deferred"))
    return {
        "gate": "captured" if parsed.get("substantive") else "skip",
        "ticket_hint": (parsed.get("ticket") or "").strip(),
        "skip_reason": (parsed.get("skip_reason") or "").strip(),
        "summary": parsed.get("summary", ""),
        "decisions": parsed.get("decisions") or [],
        "constraints": parsed.get("constraints") or [],
        "rejected": parsed.get("rejected") or [],
        "deferred": parsed.get("deferred") or [],
        "item_count": items,
    }


def main():
    transcript = sys.argv[1] if len(sys.argv) > 1 else ""
    session_id = sys.argv[2] if len(sys.argv) > 2 else ""
    reason = sys.argv[3] if len(sys.argv) > 3 else ""

    base = {
        "session_id": session_id,
        "transcript_path": transcript,
        "ended": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "end_reason": reason,
        "posted": False,
    }

    if not transcript or not os.path.exists(transcript):
        log("no transcript at %r" % transcript)
        base.update({"gate": "error", "error": "transcript missing", "turns": 0})
        notes.write_record(base)
        return

    turns, files = extract_user_turns(transcript)
    log("extracted %d user turns, %d files touched" % (len(turns), len(files)))

    # A session spent running /updatejira is not a session that decided
    # anything. Recording it would feed a previous draft back into the next one.
    if any("Update ticket" in t and "captured from earlier sessions" in t
           for t in turns):
        log("this was a ticket-update session, not work - recording as empty")
        base.update({"gate": "skip", "turns": len(turns),
                     "skip_reason": "NOTHING_TO_RECORD",
                     "is_draft_session": True,
                     "summary": "Ran the ticket-update command; no development "
                                "decisions made."})
        notes.write_record(base)
        return
    base["turns"] = len(turns)
    base["files"] = files

    if not turns:
        base.update({"gate": "empty"})
        notes.write_record(base)
        return

    parsed, raw, error = run_gate(turns)
    if error:
        log("claude -p failed: %s" % error)
        base.update({"gate": "error", "error": error})
        notes.write_record(base)
        return
    if parsed is None:
        log("unparseable output, storing raw")
        base.update({"gate": "unparsed", "raw": raw[:2000]})
        notes.write_record(base)
        return

    base.update(record_from(parsed))
    notes.write_record(base)
    log("gate=%s items=%d" % (base["gate"], base["item_count"]))


if __name__ == "__main__":
    main()
