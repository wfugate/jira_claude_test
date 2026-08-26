# Multi-session capture — run 2, with automatic attribution

Six working sessions. **Four belong to the ticket, two do not.** That is the
point of this run: last time every session belonged to one ticket, so attribution
was untestable and it simply asked you.

Now `/updatejira` fetches the ticket's summary and description and works out which
sessions belong, on subject matter. If it gets that wrong, you will see it.

Run 1's records are archived under `.claude/ticket-notes-archive/run1-sessions/`
and its script as `SESSIONS-run1.md`, if you want them for tuning with
`replay.py`.

---

## Step 1 — make the ticket

Create a ticket on the test board. **Title and description matter now** — they
are what attribution matches against. Use this:

**Summary:**

```
Overdue handling: warn members and make late fees explainable
```

**Description:**

```
Members are surprised by late fees. Nothing warns them that a book has gone
overdue, there is no way to see what they owe before they arrive at the desk,
and desk staff have no way to explain or forgive a fee when the library was at
fault - closure days, system outages, a book returned to the wrong branch.

Scope:
- Warn members as fees begin to accrue, not after they have built up
- Let members and desk staff see what a member currently owes
- Let staff waive a fee, recording who waived it and why

Out of scope: the fee calculation itself. Finance owns the daily rate, the cap
and the grace period. This ticket is about visibility and recourse, not amounts.
```

That last paragraph is load-bearing — session 6 is designed to be excluded by it.

These instructions say `TEST-117`; substitute your key.

## Step 2 — set credentials

Attribution reads the ticket, so the Jira variables must be set in the terminal
you launch from:

```bash
export JIRA_URL=https://datamaxx.atlassian.net
export JIRA_USER=your.email@datamaxx.com
export JIRA_TOKEN=paste-your-token-here
```

Without them, `ticket_context.py` says so plainly and the command falls back to
asking you. That is correct behaviour but it is not what you are testing.

## Step 3 — check it can read the ticket

```bash
python .claude/scripts/ticket_context.py TEST-117
```

You should see the summary and description as plain text. Do this before the
sessions — a credentials problem is far easier to spot now than at the end.

---

## The rules that matter

1. **End each session** (`/exit`) or the hook never fires.
2. **Wait ~15 seconds** before inspecting; the worker runs detached.
3. **One task per session.**
4. **Do not mention the ticket key in any session.** Attribution should work from
   subject matter alone. Naming the key would short-circuit exactly what is being
   tested, via `ticket_hint`.
5. **Run them concurrently if you like** — each session writes its own record
   file, so simultaneous endings are safe.

Watch the records with:

```bash
python .claude/scripts/inspect.py
```

---

# Sessions that BELONG to the ticket

## Session 1 — overdue notices

> members get no warning before late fees pile up. send an overdue notice at 7
> days and again at 14 days past due. one notice per threshold — if the job runs
> twice in a day nobody gets a second copy.

then:

> implement it

## Session 2 — what a member owes

> desk staff need to see what a member owes before the member asks. add a way to
> get the total outstanding for a member, and include fees on books they still
> have out, not just returned ones.

then:

> go ahead

## Session 3 — staff waivers

> when the library is at fault — closure days, a book returned to the wrong
> branch — staff need to forgive a fee. add a waive that records who waived it
> and why. don't let the same fee be waived twice, and don't allow a blank
> reason.

then:

> build it

*Watch for:* a decision about whether a waiver is all-or-nothing or partial.
Whichever you land on, it should appear in the record.

## Session 4 — how notices get delivered, and a rejection

> for the overdue notices — I don't want to send email. we'd be signing up for a
> mail provider, bounce handling, and a suppression list, and none of that is
> ours to own. put the notices on the existing desk queue so staff mention it
> when the member next comes in.

then:

> do that

*Watch for:* the rejected email approach **and the reason**. This is the highest
value item in the run — it exists nowhere in the code, and a diff-reading tool
could never recover it.

---

# Sessions that DO NOT belong

## Session 5 — the obvious decoy

> unrelated to what I've been doing: the hold queue. when several members are
> waiting on a book, first in line should get it when it comes back, and a hold
> should expire if they don't collect within 5 days.

then:

> implement that

*Watch for:* straightforward exclusion. Different feature, no subject-matter
overlap.

## Session 6 — the hard decoy

> finance is raising the late fee cap from $10 to $12 starting next month. change
> the cap constant. don't touch the ordering of the cap and the grace period
> credit, that stays as it is.

then:

> yep

*Watch for:* **this is the real test.** It is about fees, it mentions finance, and
it touches the same file as sessions 1–3, so on keywords or file overlap it looks
like it belongs. But the description says *"Out of scope: the fee calculation
itself. Finance owns the daily rate, the cap and the grace period."* Excluding it
requires actually reading the scope line instead of pattern-matching on "fee".

If it includes session 6, that is the failure worth studying.

---

## Session 7 — draft the ticket

Fresh session, no work in it:

> /updatejira TEST-117

It should:

1. Print the ticket summary and description it fetched
2. **Print its classification** — which records it is using, which it is
   excluding and why — before showing any draft
3. Draft from sessions 1–4 only
4. Route the rejected email approach and any deferrals to `CLAUDE.md`
   suggestions rather than the ticket body
5. Post nothing until you approve

### What to judge

- **Did it exclude 5 and 6?** Six is the one that matters.
- **Did it explain its exclusions** well enough that you could have caught a
  wrong call?
- **Is the `Why` assembled from four sessions this conversation never saw?** The
  email rejection is the tell. If that reasoning is present and correct, the
  premise is working.
- **How does it handle `Also in this diff`?** Sessions 5 and 6 changed files too,
  so their changes are in the diff while their reasoning is deliberately
  excluded. It should notice code it cannot account for. This is genuinely
  awkward and worth watching — arguably the flag should distinguish "no reason
  recorded anywhere" from "reason recorded but belongs to another ticket."

On approval it posts, then marks **only** the sessions it used. Sessions 5 and 6
should still be unposted afterwards:

```bash
python .claude/scripts/notes.py --for-draft
```

Two records should remain, waiting for their own tickets.

---

## Then: tune

```bash
python .claude/scripts/replay.py            # re-score, dry run
python .claude/scripts/replay.py 4          # just session 4
python .claude/scripts/replay.py --write    # save
```

Edit `.claude/scripts/worker_prompt.txt`, replay, compare. `<-- CHANGED` marks
verdicts that moved. Sessions are expensive to produce and cheap to re-score,
which is what makes the loop worth having.

Two things to look for in the records:

- **Anything missing** — a decision you made that is not there. Unrecoverable
  once the session is over, so this is the failure that matters.
- **Anything junk** — meta-observations like "user asked for a design
  discussion", or restatements of what the code already shows.

New this run: **`skip_reason`.** A session the gate is confident held nothing is
marked `NOTHING_TO_RECORD` and no longer counts as a gap. Only `UNCERTAIN` skips
raise the incompleteness warning. That fixes the false alarm from run 1, where a
bare question was reported as possibly missing decisions.

---

## Troubleshooting

**Nothing captured.** The hook did not fire. Check
`.claude/ticket-notes/worker.log` exists, confirm you ended the session, and
check the python path in `.claude/settings.json`.

**`COULD NOT READ TICKET`.** Credentials missing or wrong key. Run
`ticket_context.py` directly to see the error.

**`gate=unparsed`.** The model returned something other than clean JSON.
`inspect.py -v` shows the raw text.

**`worker.log` looks garbled.** Concurrent workers share it; the records are
unaffected.
