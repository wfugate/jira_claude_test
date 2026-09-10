# Resume here

Handoff into a Claude Code session on the machine with AccuRev access. Written
2026-09-10 from a session on the other machine, which has no AccuRev.

**Read `REFERENCE.md` first** — sections 5 and 6 especially, which split what is
verified from what is not. Do not re-derive any of it.

---

## What this is, in one paragraph

`/updatejira TICKET-123` drafts a Jira ticket update from the sessions that did
the work. While you work, `CLAUDE.md` makes Claude ask which ticket you are on;
stating that key is the whole attribution mechanism. Later the command finds
every past session in the repo where the developer said that key, reads their
own turns back, and drafts a comment: **what** changed from the diff, **why**
from their words, never inferred from code. Nothing posts without approval.

## Where things are

| What | Where |
|---|---|
| The tool + docs | this repo, `github.com/wfugate/jira_claude_test` |
| AccuRev workspace | backed by `X_Test_William_Dev` (chain: `X_Tett_William` snapshot → `X_Test_William_Test` → `X_Test_William_Dev`) |
| Workspace content | Alchemi tree plus a `Test_DELETEME` folder |
| Jira | `datamaxx.atlassian.net`, test tickets in the `TEST` project |

`git pull` before you start. Head should be at or after `4e45ac9`.

## What is already true — do not redo

- **The three AccuRev commands are verified against a real workspace.**
  `stat --outgoing -O`, `diff -a`, `hist -a -c` all work. `--outgoing` genuinely
  covers modified, external and missing. Every flag written from documentation
  turned out correct. `ACCUREV-TEST.md` is the record of that exercise.
- **A promote deny rule is in place and verified** on that machine — a promote
  attempt is refused, not merely discouraged.
- **`vcs.ps1` was rewritten off the back of those findings** in `4e45ac9`:
  seven fixes, listed in the commit message. All of them are verified **on git
  only**. That is the gap you are closing.
- **The git path works end to end** — session lookup, drafting, posting, the
  watermark, the description update. Verified across two machines.

## Hard rules

1. **Never run `accurev promote`.** The deny rule should stop you; do not work
   around it. `keep` and `add` are workspace-local and merely untidy, but do not
   run them unless asked.
2. **Never create or modify a workspace or stream.** No `mkws`, `mkstream`,
   `chstream`, `reparent`. The workspace was made by hand and is correct.
3. **Report before fixing.** If a task below fails, say what happened and what
   you think the cause is, and let the human decide. The one exception is a
   fault whose fix is unambiguous and which you can prove by re-running — say
   so explicitly when you do that.
4. **Do not touch the git half of `vcs.ps1`.** It is the regression test for the
   shared capture layer. Twice already a change to that layer was caught only
   because git still had to work.
5. **Nothing reaches Jira without the human approving the exact text.**
   `jira_comment.ps1` is deliberately absent from the command's `allowed-tools`,
   so the harness prompts. Being asked is the gate working.

---

## Task 1 — confirm the seven fixes actually work on AccuRev

`4e45ac9` was written from a report, tested on git, and has never run against
AccuRev. Everything below is unverified until you do this.

Copy the six runtime files into the workspace root, set
`UPDATEJIRA_VCS=accurev`, restart the app if you change it, then:

**1a. The capture fix.** This is the whole point of the commit.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 diff
```

Modify a tracked file under `Test_DELETEME` first, without keeping it. Expect a
**complete unified diff** — `---`/`+++` headers and `@@` hunks. Previously this
returned a header and nothing else while reporting success. If you still get a
truncated body, `Invoke-Vcs` is still wrong and that is the finding.

**1b. New-file contents.** Create a scratch file with a few distinctive lines,
do not add it, and run `diff` again. Expect a trailing section:

```
=== NEW FILES (1) - (external), so absent from accurev diff; read from disk ===
```

with the file's lines prefixed `+`. This closes what used to be documented as a
permanent gap, so it matters that it works.

**1c. Exit code.** `accurev diff` exits 1 when differences exist. Confirm
`vcs.ps1 diff` does **not** print a `!!` failure line when there are changes.
Getting this wrong turns a silent wrong answer into a loud false alarm.

**1d. The `hist` whole-key filter.**

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 ticket-history QRM-124
```

`QRM-1240` transactions should now be **absent**, with a line reporting how many
substring matches were dropped. Unfiltered, this attributed other people's work
to a ticket.

**1e. Stderr on success.** If any command writes to stderr while exiting 0, the
output now says so explicitly. You may not be able to trigger this deliberately;
just note whether such a line appears anywhere it should not.

## Task 2 — a full `/updatejira` run from the AccuRev workspace

**This is the real remaining test.** Three working commands is not a working
tool. Nothing in the session-lookup, drafting or posting path has ever run from
an AccuRev workspace.

1. Make a Jira test ticket with a thin, problem-shaped description.
2. In a chat **with the workspace as the project**, do a small piece of real
   work on a file under `Test_DELETEME` — and say *why*, out loud, including
   something that could not be inferred from the code. Answer the ticket
   question when Claude asks.
3. In **that same chat**, run `/updatejira <KEY>`. Running it in the chat that
   did the work is the normal case.
4. Judge four things:
   - Did `sessions.ps1` find the session? It derives the transcript directory
     from the repo path, and that has never been exercised from an AccuRev
     workspace path.
   - Is the `Why` drawn from what was said rather than from the code?
   - Does it flag anything in the diff it cannot account for?
   - Does it leave the description alone, or change it for a stated reason?
5. Approve and post. Then run `/updatejira <KEY>` again with no new work — it
   should find nothing to add. That is the watermark working, and it has never
   been tested on AccuRev.

## Task 3 — the demo

`DEMO.md` is written and runs **on git**, in this repo. Two chats, with
`/updatejira` run inside the second one. It has never been rehearsed.

Do not convert it to AccuRev. The point of the demo is the reasoning capture,
which is VCS-independent, and git is the path with full verification behind it.

---

## Decisions still open

**Adapter or direct AccuRev?** Matthew's position is that Claude already knows
AccuRev and a wrapper is unnecessary — he has been driving it directly since day
one. The verification argued against dropping the adapter, but not for the
reason expected: every flag in the script was right, and it was the wrapper's
process plumbing that failed. What keeps the script is that all three commands
need post-processing — XML parsing for `(external)`, exit-code handling and
new-file synthesis for the diff, whole-key filtering for `hist`. Those are
correctness rules that have to hold every run. **If Task 1 shows the rewritten
adapter is still fragile, reopen this.**

**Remove the git half of `vcs.ps1`?** Not yet. It is the only end-to-end
verified path, the demo runs on it, and it is the regression test for shared
code. Revisit once Task 2 passes and the demo has been given.

**Bounding `hist -c` in time.** It searches all history — a `QRM-124` match
reached back to 2015. Bounding needs `-t`, whose flags are unverified. Worth
doing, needs another verification round.

## Do not redo

- **The design.** The session-end hook was removed because `SessionEnd` does not
  fire when the desktop app is closed with X or when chats are switched.
  Transcripts are read at draft time instead. `REFERENCE.md` §2.
- **The AccuRev flag verification.** Done, recorded in `ACCUREV-TEST.md`.
- **The encoding work.** Every hop decodes UTF-8 explicitly. Multiple silent
  wrong-data bugs came from this.
- **Human-turn-only key matching.** A raw file grep for a ticket key returned
  nine sessions, none of which had a human say it — every hit was in tool
  output.
- **The `isMeta` filter.** The harness flags its own content in the user slot;
  without that filter a previous draft gets read back as the developer's
  reasoning.

## The question that decides whether this ships

**Would an engineer be glad to find one of these comments on a ticket six months
later?** Nobody outside the author has answered it. The closest evidence: given
a diff containing a change nobody had discussed, a draft wrote *"Also in this
diff: GracePeriodDays changed from 3 to 5. Nothing in either session or this
conversation accounts for it"* — it refused to invent a reason. That restraint
is the most expensive choice in the tool and the one worth the most.
