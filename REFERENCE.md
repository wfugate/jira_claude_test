# /updatejira — reference

What it does, how every part works, and why. Current as of 2026-09-01.

---

## 1. The problem

Developers do not fill in tickets. Vague titles, no record of what was done or
why. The comparison is not "a human does this better" — it is "nothing gets
written."

A diff shows **what** changed and can never show **why**. The why exists only in
the conversation where the choice was made.

Two consequences shape everything below:

- **The reason must come from what the developer said, never inferred from
  code.** If nothing supports a reason, the correct output says the reason is
  missing. An update that admits a gap beats one that guesses convincingly.
- **A ticket's work spans many sessions.** Context hygiene means people start
  fresh sessions per task, so reading only the current one loses the rest.

---

## 2. How it works

```
during the work
  → Claude notices this looks like ticket work and asks which ticket
  → you answer "TEST-122"          <- the whole attribution mechanism

later, when you want the ticket updated
  → /updatejira TEST-122
  → read the diff
  → read the ticket, and when this tool last commented on it
  → find past sessions in this repo where YOU said "TEST-122",
    after that timestamp
  → read your own turns from those sessions
  → draft a comment: what changed from the diff, why from your words
  → stop and wait for approval
  → post the comment, and update the description only if the work
    showed the description no longer states the problem properly
```

There is no background process, nothing is captured at session end, and nothing
is stored on disk. The transcripts Claude Code already writes are the record.

### Why not a session-end hook

The previous design used one. `SessionEnd` does not fire when the desktop app is
closed with X, or when you switch chats — which is how people actually leave a
chat. Capture was silently missing most sessions, and a silent miss is the worst
failure this tool can have.

Transcripts, by contrast, are written continuously. Verified: they survive
compaction, an interrupted response, and force-quit.

---

## 3. Every file

### The runtime — six files, all in version control

| File | What it is for |
|---|---|
| `CLAUDE.md` | Tells Claude to ask which ticket you are working on. Loads on every session in the repo. |
| `.claude/commands/updatejira.md` | The command. Prose, not code — this is the main quality lever. |
| `.claude/scripts/sessions.ps1` | Finds sessions by ticket key, extracts your turns, or lists sessions for manual picking. |
| `.claude/scripts/vcs.ps1` | The only file that knows whether this repo is git or AccuRev. |
| `.claude/scripts/jira_lib.ps1` | Shared Jira plumbing: auth, ADF conversion, the HTTP call, the watermark lookup. |
| `.claude/scripts/jira_comment.ps1` | The only file that writes to Jira. |
| `.claude/scripts/ticket_context.ps1` | Fetches the ticket's summary, description, and last-posted timestamp. |

### Removed

The `SessionEnd` hook, the background worker, the gate prompt and the local
record store are gone — `hook.ps1`, `worker.ps1`, `worker_prompt.txt`,
`notes.ps1`, `inspect.ps1`, `settings.json` and the Python tuning tools. They
belonged to the previous design and nothing reads them.

**There is no `settings.json`, so no hook is registered and nothing runs in the
background.** If you find one in a clone, it is stale.

## 4. The parts that carry the weight

### `CLAUDE.md` — the ask

```
When it looks like I am starting work that belongs to a ticket — a bug fix, a
feature, a change with a stated reason — ask me for the ticket key before
getting far in. Once, briefly.
```

This is the whole attribution mechanism, and it is why the tool can be simple.
A key you stated is worth more than any amount of inference afterwards.

**It must live in the repo, not in personal settings.** In personal config it
works for whoever set it up and silently does not for anyone else — and the
failure is invisible, because the lookup just comes back empty.

**Observed hit rate:** fired on 2 of 3 test sessions. It missed a session whose
entire content was "here's an issue, actually ignore it" — which does not look
like starting work. Judged acceptable: in real use that sentence is said
mid-session, where the key is already stated.

### `sessions.ps1` — finding and reading sessions

```
sessions.ps1 -Key TEST-122 [-Since <timestamp>] [-ExcludeSession <id>]
sessions.ps1 -Extract "abc12345,def67890"
sessions.ps1 -List [-Limit 20]
```

**Finding this repo's transcripts.** They live under
`~/.claude/projects/<mangled-cwd>/`. The mangling is undocumented, so it is used
only as a fast glob and never trusted — each candidate is confirmed against the
`cwd` field inside its own records. The glob has a trailing wildcard because a
session started in a subdirectory gets its own project directory.

**Matching the key.** Only where a *human* said it, never a raw file match.
This matters more than it sounds: on this repo, a raw grep for `TEST-117`
returned nine sessions and **not one** of them had a human say it — every hit
was inside a `tool_result`. A literal string, not a pattern: a generic
`[A-Z]+-[0-9]+` also matches `UTF-8`, `UTF-16` and `Z0-9`.

**Extracting turns.** Only the user's, ported from the old `worker.ps1` with its
filters intact. User turns are ~13% of transcript volume and hold most of the
reasoning; assistant turns are ~44% and narrate what was done, which the diff
already shows. Including them would invent rationales you never endorsed.

**Filtering harness content.** The harness writes its own text into the `user`
slot — expanded slash commands, caveat wrappers — and flags those records
`isMeta`. That flag is the discriminator, sitting alongside the `isSidechain`
flag used for subagent turns. Content matching remains only as a fallback for
transcripts written before the flag existed.

Why this matters: without it, a previous `/updatejira` run gets read back as
your reasoning, so each draft recycles the last one. It is also
injection-shaped — that text is full of instructions addressed to the model.

**Reporting what it did not match.** The one thing this design lost against the
record store: a session where the key was never stated simply does not exist to
the lookup. So it prints the shape of the window — *"2 mention TEST-122, 7 other
sessions do not"* — and lists the unmatched ones when there are few enough to
eyeball.

### The watermark — how it knows what is already published

`Get-LastPostDate` returns **the timestamp of the most recent comment on the
ticket by your own account**, to the millisecond, straight from Jira.

That is the whole of the tool's state, and it is not stored anywhere. Nothing is
written to the ticket in order to be read back later.

An earlier version used a dated line in the description. It was day-granular, so
a second run on the same day re-read sessions the first run had already
published — the ordinary case, since people post an update and keep working.

**Known edge:** if you hand-comment on the ticket after a post, the watermark
advances to that, and sessions in between are skipped. Rare, and it fails toward
saying too little rather than republishing.

### `jira_comment.ps1` — the only writer

Posts a comment from stdin, or replaces the description from stdin.

**The description is now updated, not appended to.** A description states the
problem; it is not a log of fixes. The command only proposes a change when the
work showed the description no longer states the problem properly — most often
because the work uncovered another part of the problem the ticket never
mentioned.

This is the one destructive operation in the tool, and it replaced one that
could not be. Three things stand in for the old append-only guarantee:

1. You approve the full replacement text in the conversation before the script
   runs.
2. A shrink guard refuses outright if more than half the description would go.
3. The diff is printed on every run, so what changed is on the record.

**Known cost:** the round trip through plain text flattens structure. Headings
and bullets come back as paragraphs and hard breaks. Fine for short prose
descriptions; the diff will show it if it is not.

### `updatejira.md` — the command

Prose the model follows. The rules that carry the weight:

1. **Never infer the reason from code** — including in the notes underneath the
   draft, not only in the comment. Do not assert a standing decision exists
   unless it is in the sessions, this conversation, or `CLAUDE.md`. If you
   half-remember one, say where you got it.
2. **Flag what nothing accounts for** — including changes the model made
   unprompted. A choice the model made is not a decision you made.
3. **Do not re-judge attribution.** A match means you stated the key. In
   particular, do not compare files-touched against the diff — unrelated work
   routinely touches the same files, and a session where you ruled something out
   may touch nothing at all.
4. Short enough for one screen. Plain text, never in a code fence.

Deferrals and rejected approaches are routed to suggested `CLAUDE.md` lines
rather than the ticket — a rejected change nobody proposed reads strangely six
months later. But **cause stays in the comment**: "X was off the table, so we
did Y" is the record of this change.

---

## 5. Verified

All on Windows, Claude Code 2.1.251, 2026-09-01.

| | |
|---|---|
| Transcripts survive compaction | **Yes** — a session that compacted at line 460 kept all 69 pre-boundary user records |
| Desktop-app sessions write transcripts | **Yes** — 5,646 `claude-desktop` records against 1,813 `cli` |
| An interrupted response loses nothing | **Yes** — the turn is written at submit, before the reply; the interruption is itself recorded |
| `SessionEnd` fires on desktop close / chat switch | **No.** This is why the design changed |
| Human-turn key matching | Nine false positives to zero on `TEST-117` |
| `isMeta` marks harness content | Yes — all 9 such records were harness content, no human turn carried it |
| Posting a comment | Real Jira, TEST-122 |
| Description update | Dry run against real Jira; diff correct |
| Watermark from comment timestamp | Correctly excluded two already-published sessions |
| The ask firing | 2 of 3 sessions; the miss is understood |

## 6. Not verified

- **AccuRev.** Written from documentation, never executed. This is the real
  deployment target.
- **A second machine.** Everything above is one machine.
- **The full loop end to end** — post, then new work, then post again finding
  only the new session. The halves are proven; the whole is not.
- **A ticket spanning more than ~30 days.** Transcripts are pruned at the
  default `cleanupPeriodDays`. Mitigation is to post incrementally: once a
  comment is on the ticket, the ticket is the durable record.

## 7. Known-imperfect, deliberately

- A session where the key was never stated is invisible to the lookup. The
  unmatched-count line makes the gap visible; it does not close it.
- Multi-developer tickets do not work. Transcripts are local to a machine, so
  you can only ever find your own sessions.
- The description round trip flattens rich formatting.

- `CLAUDE.md` suggestions repeat across tickets.

---

## 8. The question that decides this

Still the whole project in one line: **would an engineer be glad to find one of
these comments on a ticket six months later?**

The first clean-room test is the closest thing to an answer so far. Given a diff
containing a planted, undiscussed change, the draft wrote:

> Also in this diff: GracePeriodDays changed from 3 to 5. Nothing in either
> session or this conversation accounts for it.

It refused to invent a reason. That is the behaviour that costs the most and is
worth the most.
