# Multi-session capture — run 2, with automatic attribution

Six working sessions: **four belong to the ticket, one clearly does not, and one
is genuinely ambiguous.** Last run every session belonged to one ticket, so
attribution was untestable and it simply asked you.

Now `/updatejira` fetches the ticket's summary and description and works out which
sessions belong, on subject matter. The ticket is deliberately vague — as real
ones are — so the question is not just whether it classifies correctly but
whether it knows when it cannot.

Run 1's records are archived under `.claude/ticket-notes-archive/run1-sessions/`
and its script as `SESSIONS-run1.md`, if you want them for tuning with
`replay.py`.

---

## Step 1 — make the ticket

Create a ticket on the test board. **Deliberately thin** — a title and two
sentences, no scope section, no acceptance criteria, no out-of-scope list. This is
what real tickets look like, and the vagueness is the point: the whole project
exists because people do not write good tickets. Testing attribution against a
beautifully specified ticket would be testing a ticket that does not exist.

**Summary:**

```
Members complaining about late fees
```

**Description:**

```
Members say they get hit with late fees without warning and have no way to see
what they owe. Desk staff can't do anything about it when they ask.
```

That is all. Resist the urge to improve it.

These instructions say `TEST-117`; substitute your key.

### What this costs, and why it is the right test

A vague ticket means attribution is genuinely harder, and for one session it
becomes genuinely *ambiguous* rather than merely hard. That is not a flaw in the
test — it is the real operating condition. Read the session 6 notes before
judging the result.

The useful question stops being "did it classify correctly" and becomes **"was it
correctly calibrated"** — did it know what it could not know, and ask?

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

# Sessions that do NOT clearly belong

## Session 5 — the obvious decoy

> unrelated to what I've been doing: the hold queue. when several members are
> waiting on a book, first in line should get it when it comes back, and a hold
> should expire if they don't collect within 5 days.

then:

> implement that

*Watch for:* straightforward exclusion. Different feature, no subject-matter
overlap.

## Session 6 — the genuinely ambiguous one

> finance is raising the late fee cap from $10 to $12 starting next month. change
> the cap constant. don't touch the ordering of the cap and the grace period
> credit, that stays as it is.

then:

> yep

*Watch for:* **this one has no single right answer, which is the point.**

It is about late fees, and the ticket is about late fees. But look closer: the
ticket is about members not being *warned* and not being able to *see* what they
owe — a visibility and recourse complaint. Raising the cap is a finance-driven
change to the *amounts*, and it makes things worse for members rather than
better. A careful reader treats it as separate work. A keyword matcher sees
"late fee" twice and includes it.

Earlier drafts of this demo used a ticket with an explicit *"out of scope: the
fee calculation itself"* line, which made exclusion straightforward. Removing
that line is what makes this realistic — and it means **exclusion is now a
judgement call, not a lookup.**

Three possible outcomes, in order of quality:

1. **Excludes it, with reasoning about visibility versus amounts.** Best case.
2. **Flags it as uncertain and asks you.** Equally acceptable — arguably better.
   With a ticket this thin, admitting the ambiguity is the correct answer.
3. **Silently includes it.** This is the failure. Not because including it is
   indefensible, but because it made a debatable call without surfacing it.

Outcome 3 is what to watch for. A tool that quietly resolves ambiguity in its own
favour cannot be trusted with a ticket.

## Session 7 — draft the ticket

Fresh session, no work in it:

> /updatejira TEST-117

It should:

1. Print the ticket summary and description it fetched
2. **Print its classification** — which records it is using, which it is
   excluding and why — before showing any draft
3. Draft from sessions 1–4 — and either exclude 6 with a reason or ask you
   about it
4. Route the rejected email approach and any deferrals to `CLAUDE.md`
   suggestions rather than the ticket body
5. Post nothing until you approve

### What to judge

- **Did it exclude 5?** That one should be easy; failing it means attribution
  is not working at all.
- **What did it do with 6?** Excluded with reasoning, or asked — both fine.
  Silently included is the failure. See the session 6 notes.
- **Did it explain its exclusions** well enough that you could have caught a
  wrong call? A classification you cannot audit is worth little, even when it
  happens to be right.
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
