# AccuRev verification — handoff

## For the human, before you start

Two things to do yourself, then hand the rest to Claude:

1. **Switch out of auto mode.** In auto mode, whether a write gets run is a
   judgement rather than a hard stop. For this work you want writes to prompt.
2. **Add a deny rule** so `accurev promote` cannot run even by accident.

   The file is `.claude/settings.local.json` in **whichever folder you open as
   the project** — for this exercise, the AccuRev workspace, not the git clone.
   It will not exist yet: Claude Code creates it when you make permission
   decisions, and it is gitignored so it never arrives with a clone. Create it:

   ```
   New-Item -ItemType Directory -Force .claude | Out-Null
   '{ "permissions": { "deny": ["Bash(accurev promote:*)"] } }' | Set-Content .claude\settings.local.json -Encoding utf8
   ```

   Restart the app so it is picked up. Then verify it fires — this matches the
   rule but does nothing:
   `accurev promote --help`. If that is refused, the rule works. If it runs,
   managed settings are ignoring project rules; tell Claude, and rely on the
   prompts instead.

Then open a chat in the AccuRev workspace folder and say: *"Read
ACCUREV-TEST.md and work through it."*

---

## Claude: your instructions start here

### What you are doing and why

There is a Claude Code slash command, `/updatejira`, that drafts Jira ticket
updates. One file — `.claude/scripts/vcs.ps1` — is the only part that knows
which version control system a repo uses. Its git half is verified and in daily
use. **Its AccuRev half was written from the AccuRev CLI documentation and has
never been executed against a real workspace.**

Your job is to find out which of those commands actually work, and how their
real output differs from what was assumed. You are gathering evidence, not
fixing code.

### Hard rules

1. **Never run `accurev promote`.** It pushes changes up to a shared stream.
   Nothing being tested needs it.
2. **Never run `accurev keep` or `accurev add`** unless the human explicitly
   asks in this conversation. They are workspace-local so they are untidy
   rather than dangerous, but they change what the later tests measure. There is
   one legitimate exception, called out in step 2.
3. **Do not edit `vcs.ps1` or any other script in this exercise.** Report what
   you found. The changes get made deliberately afterwards, with the outputs in
   hand.
4. **Do not assume the commands below are correct.** They are documented
   guesses. If one is rejected, read `accurev help <subcommand>` and report what
   the right form appears to be — but do not silently substitute it and carry on
   as though it worked.
5. **Report failures verbatim.** An error message is more useful than a summary
   of it. Do not tidy them up.

### The four commands under test

These are what `vcs.ps1` runs today, exactly:

| Action | Command | What is uncertain |
|---|---|---|
| status | `accurev stat --outgoing -O` | Whether `-O` is accepted alongside `--outgoing`. `--outgoing` should cover modified, external and missing files. `-O` should disable a timestamp optimisation that can skip a genuinely modified file. |
| diff | `accurev diff -a` | Whether `-a` shows changes made but **not yet kept**, or only kept ones. |
| new files | — | A new file is `(external)` and not in the depot, so there is nothing to diff it against. Expected: it appears in status by name and its **contents appear nowhere**. |
| ticket history | `accurev hist -a -c "KEY"` | Whether `-a -c` filters depot transactions by comment text as documented. |

There is also a `prepare` action, which on AccuRev is a deliberate no-op — git
uses `git add -N` there and AccuRev has no equivalent that does not create a
version.

---

## Step 1 — orient

```
accurev info
```

Report the workspace name, backing stream, and depot. Confirm `accurev` is
runnable at all; if it is not found, stop and say so — most likely it was
installed after the desktop app launched, so the app's inherited PATH predates
it and the app needs restarting.

Then list the workspace folder and report whether it contains any files.

## Step 2 — make sure there is something to test with

Both of the next two steps need a **tracked** file to modify.

If the workspace has files, pick a small one and use it.

**If the workspace is empty**, say so and ask the human whether to create one
file and `accurev add` + `accurev keep` it as setup. That is the single
exception to rule 2 — do not do it without them saying yes in this
conversation.

## Step 3 — does `-O` work?

Run both, and report both outputs in full:

```
accurev stat --outgoing
```

```
accurev stat --outgoing -O
```

**Expected:** both succeed with similar output.

**If the second errors:** report the exact message. It means `-O` is invalid
there, the fallback in `vcs.ps1` is doing real work, and a modified file could
be silently skipped by the timestamp optimisation — which would make a ticket
comment describe less work than was actually done.

## Step 4 — does the diff see unkept changes?

Add a comment line to the tracked file from step 2. **Do not keep it.** Then:

```
accurev stat --outgoing -O
```

```
accurev diff -a
```

**Expected:** the file listed as `(modified)`, and your added line visible in
the diff output.

**This is the single most important result in the exercise.** If the diff is
empty, `-a` compares only against the last kept version, so everything done
since the last keep is invisible to the tool. Report the exact output either
way, including whether the diff has a recognisable unified-diff shape or some
other format.

## Step 5 — the new-file gap

Create a scratch file with three or four distinctive lines. Do **not** add it.

```
accurev stat --outgoing -O
```

```
accurev diff -a
```

**Expected:** listed as `(external)` in status; entirely absent from the diff.

Report the exact status line, including the parentheses and any other columns —
`vcs.ps1` does not currently parse this, but a planned fix will need to identify
`(external)` entries reliably, so the precise format matters.

## Step 6 — ticket history

Look for a transaction in this depot whose comment contains something
ticket-shaped (letters, hyphen, digits). The AccuRev GUI history view is the
easiest place to look; ask the human if you cannot see one.

If you find one, first:

```
accurev help hist
```

Report what it says about `-a` and `-c`, then run:

```
accurev hist -a -c "THE-KEY-YOU-FOUND"
```

If no transaction in this sandbox has a ticket key in its comment, skip this and
say so — it can be tested against a real depot later, read-only.

## Step 7 — the adapter, for comparison

Only after steps 3–5 are done and reported.

Copy these six files into the workspace root, preserving the folder structure,
from the `jira_claude_test` clone:

```
CLAUDE.md
.claude/commands/updatejira.md
.claude/scripts/sessions.ps1
.claude/scripts/vcs.ps1
.claude/scripts/jira_lib.ps1
.claude/scripts/jira_comment.ps1
.claude/scripts/ticket_context.ps1
```

Then, in the workspace:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 backend
```

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 status
```

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 diff
```

`backend` should report accurev, and warn that the backend is unverified. If it
reports git instead, the workspace has a `.git` directory in it, or
`UPDATEJIRA_VCS` is set to git — say which.

**Compare `status` and `diff` against what you ran by hand in steps 3–5.** Any
difference is a bug in `vcs.ps1` — most likely argument quoting, or the output
redirection it uses to avoid PowerShell re-encoding native output through the
console codepage. Report the difference precisely; do not fix it.

---

## What to report at the end

Write a summary in this shape, so it can be taken back to the design
conversation:

```
1. -O accepted alongside --outgoing?        yes / no / error: <verbatim>
2. diff -a shows unkept changes?            yes / no
3. diff output format:                      unified diff / other: <describe>
4. new file in status as?                   <verbatim status line>
5. new file contents in diff?               yes / no
6. hist -a -c works?                        yes / no / not tested: <why>
7. vcs.ps1 status matches by-hand status?   yes / no: <difference>
8. vcs.ps1 diff matches by-hand diff?       yes / no: <difference>
9. Anything surprising:                     <free text>
```

Then state plainly which of the four commands you would call verified, and which
you would not. **Do not describe a command as working if you only read its help
text.**

## One open design question, for context

A separate approach is being considered: drop the AccuRev half of `vcs.ps1`
entirely and let Claude run `accurev` directly, choosing commands as needed.
The argument for it is that a model that can read `accurev help` and adapt beats
a script full of documented guesses — and that a new file's contents, invisible
to `accurev diff`, can simply be read off disk.

Your results decide that. So if you notice that driving AccuRev directly would
have been obviously easier or more reliable than what the script does, say so —
that is a useful finding, not a digression.
