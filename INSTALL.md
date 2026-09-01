# Installing

Written for the **Claude Code desktop app**, which is what most people use. CLI
differences are noted where they matter.

Work top to bottom. Each step isolates one failure class, so out of order means
debugging auth tangled up with everything else.

**Install against a git repo first, not AccuRev.** A clone of this repo is
ideal. The AccuRev backend has never been executed and this has never been
installed on a second machine — turn both unknowns on at once and a failure has
two possible causes.

---

## Where to run the commands below

Two options, both fine:

- **The integrated terminal** in the desktop app. It runs PowerShell.
- **Just ask Claude in a chat** — "run `.claude/scripts/vcs.ps1 backend`". You
  will get a permission prompt the first time; that is normal.

**One trap, and it has cost real time:** a variable you set in the integrated
terminal exists only in that terminal. It does **not** reach the subprocesses
Claude runs. That is why step 3 sets them at user level and restarts the app.

---

## What actually gets installed

Six files, all in version control. Nothing else.

```
<repo root>/
├── CLAUDE.md                          the ticket-ask
└── .claude/
    ├── commands/updatejira.md
    └── scripts/
        ├── sessions.ps1
        ├── vcs.ps1
        ├── jira_lib.ps1
        ├── jira_comment.ps1
        └── ticket_context.ps1
```

Plus three environment variables per machine. **No hook, no `settings.json`, no
background process, no local state, no Python.** Nothing needs an admin.

---

## 1. Prerequisites

### Claude Code

If the desktop app opens and you can start a chat, it is installed and signed
in. There is nothing to version-check.

*CLI users:* `claude --version`.

### Git

```
git --version
```

### PowerShell is not locked down

```
$ExecutionContext.SessionState.LanguageMode
```

Must print `FullLanguage`. Under `ConstrainedLanguage` — a common posture on
managed corporate machines — the .NET calls this runtime depends on are blocked
and nothing will work. That is an AppLocker/WDAC question for IT, not something
to work around.

```
$PSVersionTable.PSVersion
```

5.1 is expected.

## 2. Open the repo

Clone it, then **open that folder as a project in the desktop app** — File →
Open Folder, or whatever your version calls it. The six files above should be
present.

This matters: `/updatejira` and the `CLAUDE.md` ask only exist inside this
project. Open a different folder and neither appears.

*CLI users:* `cd` into the repo and start `claude` from there.

## 3. Set the three variables, then restart the app

```
[Environment]::SetEnvironmentVariable('JIRA_URL', 'https://datamaxx.atlassian.net', 'User')
```

```
[Environment]::SetEnvironmentVariable('JIRA_USER', 'your.email@datamaxx.com', 'User')
```

Full email address, not a username — the commonest cause of a 401.

**Token:** set `JIRA_TOKEN` through the GUI so it stays out of shell history —
press Win, type "environment variables", → Environment Variables → User
variables → New.

**Then quit the desktop app completely and reopen it.** Not just the chat — the
app. It reads the environment at launch, so anything set afterwards is invisible
to it. Skipping this looks exactly like an expired token.

## 4. Verify, in this order

### 4a. Auth, before anything else

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\ticket_context.ps1 -Issue <a-real-key>
```

Expect `TICKET:` / `SUMMARY:` / `LAST_UPDATE:` / `DESCRIPTION:`.

**A 404 here usually means the token, not the key.** Jira returns 404 rather
than 401 on issue reads so it does not reveal whether an issue exists to a
caller it has not authenticated. An expired token looks exactly like a typo. To
tell them apart, a call that only needs auth:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". .\.claude\scripts\jira_lib.ps1; (Invoke-Jira -Method GET -Path '/rest/api/3/myself').displayName"
```

401 there means the token or the app restart. Your name means the key.

### 4b. Backend

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\vcs.ps1 backend
```

Expect `backend: git   (found .git)`.

### 4c. The transcript lookup — the real portability test

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\sessions.ps1 -List
```

Should list recent sessions for this repo. **This is the step most likely to
break on a new machine.** If it finds nothing, the project-directory derivation
did not work here — check that `~/.claude/projects/` exists and contains a
directory matching this repo's path with separators replaced by hyphens.

Note you need at least one prior session in this project for anything to show,
so have a short chat here first if you have only just cloned.

### 4d. The ask

Start a chat and say something that looks like ticket work — *"the late fee is
wrong for accounts overdue past 40 days, fix it"*. Claude should ask which
ticket. Answer with a real key.

Then confirm the key landed:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\scripts\sessions.ps1 -Key <your-key>
```

That session should be listed. If not, either the ask did not fire or the key
was never stated — and the whole tool depends on this step.

### 4e. The draft

**In the same chat that did the work.** That is the normal way to use it, and
the current conversation is a first-class source. A separate chat works too but
exercises less.

```
/updatejira <your-key>
```

A **permission prompt before each Jira write is the approval gate working**, not
an error.

The diff step has three sources and says which one it used: bounded by the
watermark (preferred, spans committed and uncommitted work), `git diff HEAD`
when the ticket has never been written up, or branch-against-base. If it prints
nothing at all with work clearly present, that is a bug worth reporting.

### 4f. The loop

Post, then run `/updatejira <your-key>` again with no new work. It should find
nothing to add. Then do a small piece of new work with the key stated and run
again: it should find exactly that one session.

---

## If Claude refuses to run the scripts

Managed settings. `allowManagedPermissionRulesOnly` means project-level rules —
including `allowed-tools` in the command file — are ignored. Add at
`claude.ai/admin-settings`:

```
Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude/scripts/vcs.ps1:*)
Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude/scripts/sessions.ps1:*)
Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude/scripts/ticket_context.ps1:*)
Bash(echo $CLAUDE_CODE_SESSION_ID:*)
```

`jira_comment.ps1` is deliberately absent — that omission is what forces the
approval prompt.

---

## Later: AccuRev

Only once everything above passes on git.

```
[Environment]::SetEnvironmentVariable('UPDATEJIRA_VCS', 'accurev', 'User')
```

Then run each by hand in a scratch workspace before trusting a draft — none has
ever been executed:

- `accurev stat --outgoing -O` — does `-O` combine with `--outgoing`?
- `accurev diff -a` — does it show what you expect, including unkept changes?
- `accurev hist -a -c "KEY"`

Two gaps no verification removes: new-file **contents** are absent from an
AccuRev diff (they show in status as `(external)` and nowhere else), and the
timestamp optimisation may hide new files with no documented override.

Note that **finding sessions is unaffected by the VCS** — transcripts have
nothing to do with version control. Only the diff step touches it.
