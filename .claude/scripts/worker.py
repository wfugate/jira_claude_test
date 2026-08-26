#!/usr/bin/env python3
"""Detached worker: extract reasoning from a finished session.

Writes ONLY to a local file. Nothing here touches Jira - posting happens later,
on /updatejira, behind the approval gate.

A record is written for EVERY session, even when nothing is extracted. That way
"the gate found nothing" is visible and recoverable rather than silent, and the
transcript path is retained so a thin summary can be drilled into later.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(os.path.dirname(HERE), "ticket-notes")
sys.path.insert(0, HERE)
import notes  # noqa: E402 - one file per session, concurrency-safe
PROMPT_FILE = os.path.join(HERE, "worker_prompt.txt")

transcript = sys.argv[1] if len(sys.argv) > 1 else ""
session_id = sys.argv[2] if len(sys.argv) > 2 else ""
reason = sys.argv[3] if len(sys.argv) > 3 else ""

MAX_TURN_CHARS = 4000
MAX_TURNS = 60


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


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
                if fp:
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
            if "<local-command-caveat>" in text or text.startswith("<system-reminder>"):
                continue
            turns.append(text[:MAX_TURN_CHARS])
    return turns, sorted(files)


def write(record):
    notes.write_record(record)


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
    write(base)
    sys.exit(0)

turns, files = extract_user_turns(transcript)
log("extracted %d user turns, %d files touched" % (len(turns), len(files)))
base["turns"] = len(turns)
base["files"] = files

if not turns:
    base.update({"gate": "empty"})
    write(base)
    sys.exit(0)

prompt = open(PROMPT_FILE, encoding="utf-8").read() + "\n\n---\n".join(turns[:MAX_TURNS])

env = dict(os.environ)
env["UPDATEJIRA_HOOK_GUARD"] = "1"

t0 = time.time()
try:
    proc = subprocess.run(["claude", "-p", prompt], capture_output=True,
                          text=True, timeout=300, env=env, cwd=HERE)
except Exception as exc:
    log("claude -p failed: %r" % exc)
    base.update({"gate": "error", "error": repr(exc)[:300]})
    write(base)
    sys.exit(0)

log("claude -p rc=%s in %.1fs" % (proc.returncode, time.time() - t0))
out = (proc.stdout or "").strip()

# Strip a markdown fence if one slipped through.
if out.startswith("```"):
    out = out.split("\n", 1)[-1]
    if out.rstrip().endswith("```"):
        out = out.rstrip()[:-3]

try:
    parsed = json.loads(out)
except Exception:
    log("unparseable output, storing raw")
    base.update({"gate": "unparsed", "raw": out[:2000]})
    write(base)
    sys.exit(0)

items = sum(len(parsed.get(k) or [])
            for k in ("decisions", "constraints", "rejected", "deferred"))
base.update({
    "gate": "captured" if parsed.get("substantive") else "skip",
    "summary": parsed.get("summary", ""),
    "decisions": parsed.get("decisions") or [],
    "constraints": parsed.get("constraints") or [],
    "rejected": parsed.get("rejected") or [],
    "deferred": parsed.get("deferred") or [],
    "item_count": items,
})
write(base)
log("gate=%s items=%d" % (base["gate"], items))
