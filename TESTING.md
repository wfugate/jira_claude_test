# Extensive testing — how to run it and what to hand over

Written to be handed, along with the reports it produces, to whoever analyses
the results.

---

## Is this ready?

**Ready to test properly. Not ready to ship.** Specifically:

### Implemented and verified working

| | |
|---|---|
| `SessionEnd` hook, detached worker | verified — including that an inline hook gets killed, and the recursion guard |
| Structured capture | decisions / constraints / rejected / deferred, many per session |
| One record per session | atomic write, concurrency-safe, verified with simultaneous session ends |
| No-regress guard | a thinner record can never overwrite a fuller one |
| `skip_reason` | distinguishes a confident empty from a possible miss |
| Drafting-session exclusion | three layers; verified catching real cases in production |
| Ticket-context fetch | summary + description, ADF flattened |
| Attribution | inline classification against the ticket, verified excluding both a clear and an ambiguous decoy |
| Per-ticket marking | selective, refuses to act without a selection, stamps `posted_to` |
| `replay.py` | dry run and `--write`, flags preserved |
| Untracked files | `git add -N` step, so new files reach the diff |
| Encoding | UTF-8 on the Jira stdin path and the report stdout path |

### Not implemented

- **AccuRev.** `accurev stat -m`, the `diff` flags and `hist`-by-ticket are all
  still unverified, and no port exists. Everything here is git.
- **Item-level attribution.** A session mixing two tickets' work produces one
  record that cannot be split. One ticket per session for now.
- **Automatic draft capture.** The draft prints to the terminal; you paste it
  into a file for `report.py --draft`.
- **Cost accounting.** One `claude -p` per session end, unmeasured in aggregate.
- **`worker.log` rotation.** Grows without bound.

### The one unknown that still matters

**Compaction.** A long session gets compacted, and the transcript may then hold
a summary rather than what was actually said. If the reasoning is already gone
before the gate reads it, nothing downstream can recover it. **Untested** — and
long flows are exactly where it would show up, so watch for it in the runs you
are about to do. A record that is thin despite a long session is the symptom.

---

## Running a long flow

A single `claude -p` gives a session with **one** user turn no matter how much
work happens inside it, and the gate reads user turns. So a one-shot call
produces a thin record and tells you little. Long flows need many turns.

`flow.py` scripts them:

```bash
python .claude/scripts/flow.py flows/example-notices.txt
```

One turn per blank-line-separated paragraph, all in a single session via
`claude -p --continue`. `--dry` prints the turns without running them.

Write flows in `flows/`. Things worth varying across them:

- **Length.** Three turns versus fifteen. This is where compaction bites.
- **Reversals.** A decision made then reversed — the abandoned one belongs in
  `rejected`, not `decisions`.
- **Deferrals.** "I know it's sketchy, leave it" — historically the gate's
  weakest spot.
- **External constraints.** "Another team owns that" — the highest-value items,
  because they exist nowhere in the code.
- **Nothing sessions.** A bare question. Should come back
  `skip_reason=NOTHING_TO_RECORD`, not flagged as a gap.
- **Interleaved tickets.** Flows belonging to a different ticket, to test
  attribution rather than capture.

After a flow, give the last worker ~15s and check:

```bash
python .claude/scripts/inspect.py
```

## Bundling a run

Run `/updatejira TEST-115` in a fresh session, copy the draft it prints into a
file, then:

```bash
python .claude/scripts/report.py TEST-115 --draft drafts/run3.txt > reports/run3.md
```

`report.py` collects the ticket as fetched, every record with full extracted
reasoning, the diff stat, the gate prompt **in force at the time**, and the
tooling commit. That last pair matters: without them a report cannot be compared
against another run, because you will not know what changed between them.

## Tuning between runs

```bash
python .claude/scripts/replay.py            # re-score every record, dry run
python .claude/scripts/replay.py 4          # just record 4
python .claude/scripts/replay.py --write    # save the new results
```

Edit `.claude/scripts/worker_prompt.txt`, replay, compare. `<-- CHANGED` marks
any record whose verdict or item count moved, so you can check that a fix for one
case did not break another.

The point of this loop: **sessions are expensive to produce and cheap to
re-score.** Build a library of flows once, then iterate the prompt against them
as many times as you like.

Two cautions:

- Replay re-scores **posted** records too. Harmless for tuning, but afterwards
  those records no longer match what was actually posted to the ticket.
- Replay uses the **current** prompt. Note the tooling commit in each report or
  you will not be able to tell which prompt produced which result.

---

## What to hand an analyst

For each run: the `reports/runN.md` file, plus your own assessment. Yours is the
part that cannot be automated — **only you know what you actually decided**, so
only you can identify what is missing.

The five questions `report.py` appends, in priority order:

1. **Is anything missing?** A decision you made that no record contains. This is
   the failure that matters: unrecoverable once the session is over, and
   invisible unless someone who was there checks.
2. **Is anything junk?** Meta-observations ("user asked for a design
   discussion"), or restatements of what the code already shows.
3. **Was attribution right**, and were exclusions explained well enough to catch
   a wrong call?
4. **Could the `Why` have been written from the diff alone?** If yes, the capture
   is not earning its keep — that is the whole premise.
5. **Where the record was incomplete, did the draft say so?**

Question 1 is the one to spend time on. Everything else is visible in the output;
that one is not.

## Known behaviours, so nobody reports them as new

- The gate sometimes records meta-items like "user asked for approach only, no
  code." Junk, harmless, a tuning candidate.
- It has recorded a constraint as `DEFERRED` ("don't touch the ordering" is
  really a fence, not a postponement).
- `worker.log` interleaves under concurrency. The records are unaffected.
- Draft-session records are kept on disk with `is_draft_session: true` and
  excluded from the draft feed. They are audit trail, not noise.
