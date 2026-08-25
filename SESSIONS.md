# Multi-session capture — test drive

Five sessions against one imaginary ticket, `TEST-200`. The point is to watch
reasoning get captured across sessions you never explicitly write up, then tune
the gate until it stops missing things.

**Nothing is posted to Jira by any of this.** The hook writes only to
`.claude/ticket-notes/accumulated.jsonl`, which is gitignored.

---

## How it works

A `SessionEnd` hook fires when you end a session. It spawns a detached worker
that reads your turns from the transcript, asks a headless `claude -p` to pull
out decisions/constraints/rejections/deferrals, and appends one JSON record per
session. `/updatejira` would later read those records and draft from them.

## The rules that matter

1. **You have to actually end the session** for the hook to fire. `/exit`, or
   close the window. Starting a new session without ending the old one captures
   nothing.
2. **Wait ~15 seconds** after ending before inspecting. The worker runs detached
   and takes 5–10s for its inference call.
3. **Don't let sessions bleed together.** One task per session — that is the
   workflow being tested.

## Watching it

```
python .claude/scripts/inspect.py        # what has been captured
python .claude/scripts/inspect.py -v     # plus transcript paths and raw output
```

---

## Session 1 — a constraint that exists nowhere in the code

Start Claude Code in this repo. Then:

> reference-only books can't be checked out at all right now. I want staff to be
> able to override that, but only for same-day loans. don't add an IsStaff flag
> to Member — HR owns that record and we can't modify it.

then:

> go ahead and implement it

**End the session.** Wait, then inspect.

*Watch for:* the HR constraint and the rejected `IsStaff` approach. Neither
exists anywhere in the code — a diff-reading tool could never recover either.

---

## Session 2 — the case that currently fails

Fresh session.

> the hold-count fallback in Renew treats an unknown hold count as zero and lets
> the renewal through. I know that's sketchy. leave it alone for now, it's a
> separate conversation — but I do want the max concurrent loans bumped from 5
> to 8, members have been complaining.

then:

> yep do it

**End the session.** Inspect.

*Watch for:* the hold-count deferral landing under `deferred`. In earlier
testing this exact shape — "I know it's sketchy but leave it" — got dropped
entirely. **This is the false negative you are hunting.** If `deferred` is empty
here, the gate is broken.

---

## Session 3 — should capture nothing

Fresh session.

> what's the current loan period and how many renewals are allowed?

**End the session.** Inspect.

*Watch for:* `gate=skip`, empty arrays, but **a record still written**. That is
the design — "no summary" is recorded rather than the session vanishing, so a
missed decision is visible instead of silent. Getting `skip` here is correct;
this is the true-negative check.

---

## Session 4 — a decision that reverses mid-session

Fresh session.

> suspended members should still be able to return books and pay fees, they just
> can't borrow. add a CanReturn check.

then:

> actually wait — returning a book isn't a permission at all, anyone holding a
> book can return it. drop the CanReturn idea. instead make the suspension
> message explain why they're blocked, so staff can tell them.

**End the session.** Inspect.

*Watch for:* whether it records the **final** decision or presents both as
though they stood. The reversed idea belongs under `rejected`, not
`decisions`. Getting this wrong writes a confidently misleading ticket.

---

## Session 5 — several decisions at once

Fresh session.

> the fee cap is applied before the grace period credit is subtracted, so the
> real maximum is $9.25 not $10. finance owns that ordering so don't change it.
> but I do want two things: overdue notices at 7 and 14 days, and a way to see
> the total outstanding fees for a member. one notice per threshold, don't spam
> them if the job runs twice.

then:

> implement both

**End the session.** Inspect.

*Watch for:* it should capture the finance constraint, the two features, and the
idempotency rule as **separate items**. A single-line capture would keep roughly
one of the four — this is what "capture rich, compress late" is for.

---

## Then: tune

```
python .claude/scripts/inspect.py
```

Read every session's items and ask two questions:

- **Anything missing?** A decision you made that is not in the list. This is the
  failure that matters — it is unrecoverable once the session is gone.
- **Anything junk?** Meta-observations like "user asked for a design
  discussion", or restatements of what the code does. Cheap to ignore, but they
  dilute the record.

Then edit `.claude/scripts/worker_prompt.txt` and **replay** — re-score the same
transcripts against the new prompt, no need to redo the sessions:

```
python .claude/scripts/replay.py            # re-score all, dry run
python .claude/scripts/replay.py 2          # just session 2
python .claude/scripts/replay.py --write    # save the new results
```

Replay prints `<-- CHANGED` where a verdict moved, so you can see whether an
edit fixed session 2 without breaking session 3.

That loop — edit prompt, replay, compare — is the whole point of the setup.
Sessions are expensive to produce and cheap to re-score.

---

## Troubleshooting

**Nothing captured at all.** The hook did not fire. Check
`.claude/ticket-notes/worker.log` exists; if not, confirm you actually ended the
session, and that `C:/Python314/python.exe` is still the right path in
`.claude/settings.json`.

**`gate=error`, transcript missing.** The hook got a path that does not exist.
Run `inspect.py -v` to see what it was handed.

**`gate=unparsed`.** The model replied with something other than clean JSON.
`inspect.py -v` shows the raw text. Usually means the prompt needs tightening
about output format.

**Worker seems to hang.** It has a 300s timeout and logs to
`.claude/ticket-notes/worker.log`. Tail it.
