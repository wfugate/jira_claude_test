#!/usr/bin/env python3
"""SessionEnd hook: hand off to a detached worker, return immediately.

Two things this must get right, both learned the hard way:

1. Never block. A SessionEnd hook is killed when the session tears down, so
   anything slow (an inference call) has to run in a process that outlives it.
2. Never recurse. The worker's own `claude -p` call is itself a session, whose
   end fires this same hook. The env guard below is what stops that looping
   forever.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOTES = os.path.join(os.path.dirname(HERE), "ticket-notes")
GUARD = "UPDATEJIRA_HOOK_GUARD"

raw = sys.stdin.read()

# Guard: present only inside the process tree we spawned ourselves.
if os.environ.get(GUARD):
    sys.exit(0)

try:
    payload = json.loads(raw)
except Exception:
    payload = {}

os.makedirs(NOTES, exist_ok=True)

env = dict(os.environ)
env[GUARD] = "1"

flags = 0
if os.name == "nt":
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP

log = open(os.path.join(NOTES, "worker.log"), "a", encoding="utf-8")
subprocess.Popen(
    [sys.executable, os.path.join(HERE, "worker.py"),
     payload.get("transcript_path") or "",
     payload.get("session_id") or "",
     payload.get("reason") or ""],
    cwd=HERE, env=env, creationflags=flags, close_fds=True,
    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
)
