# Demo — 15 minutes

**The one thing the room has to understand:** the reasoning on the ticket could
not have come from the code.

Library book lending is the domain because nobody needs it explained. Don't talk
about the repo or the scripts — if someone asks how it works, answer afterwards.

---

## Setup, before anyone is watching

**1. Create a thin ticket.** Thin on purpose — this is what real tickets look
like, and it matters later.

> **Summary:** Members surprised by renewal refusals
>
> **Description:** Members say they try to renew a book and it just fails, with
> no explanation. Desk staff can't tell them why either.

**2. Start clean:** `git checkout . && git status` — nothing uncommitted.

**3. Run Chat 1 below.** Leave the work uncommitted.

**4. Plant one change by hand** — in an editor, no conversation about it. In
`LendingService.cs`, change `MaxRenewals` from `2` to `3`.

**5. Rehearse the whole thing once.** Output varies between runs. Then
`git checkout .` and redo steps 3–4.

---

## Chat 1 — the reasoning that isn't in the code

New chat. Paste:

> Members with a book on hold for someone else can't renew, but they only find
> out when it fails at the desk. Add a way to check up front so staff can tell
> them before they try.
>
> Don't change the rules inside Renew — those were signed off by the library
> board, and changing them needs a policy review that isn't happening this
> quarter.

**Claude will ask which ticket this is for.** Answer with your key. Nobody ran a
command; it asked.

Then close the chat. **Don't run anything else here.**

---

## Chat 2 — more work, then the write-up in the same chat

New chat. Paste:

> Staff get asked "so when can I renew?" straight after being told no, so the
> refusal needs to answer both. Don't invent a date for the holds case — that
> depends on when the person ahead brings it back, and a wrong date at the desk
> is worse than saying we don't know.
>
> One more thing I've realised: when a member rings the next day to complain,
> nobody can find out why their renewal was refused, because we never record it.
> Store the reason on the loan.

Answer the ticket question again with the same key.

Then, **in this same chat**, run:

```
/updatejira <YOUR-KEY>
```

That is the normal way to use it — you finish the work and write it up without
moving. It uses this conversation directly and goes looking for the others.

---

## What to point at

**1. Nobody ran anything during the work.** Two chats, no commands, no
discipline required. The only thing anyone did was answer "which ticket?"

**2. It found Chat 1 and read it.** That reasoning is from a conversation that
is over. Say the room's own version out loud: *nobody would have written this
down.*

**3. The `Why` could not have come from the diff.** Read the board-review
sentence aloud, then ask: where would a tool reading only the diff get that? A
future maintainer sees duplicated rules and "tidies" them. This is what stops
them.

**4. It says which reasoning came from where.** Chat 2's decisions are marked as
from this conversation; the board constraint is marked as from an earlier
session. You can tell what it witnessed from what it reconstructed.

**5. It admits what it doesn't know.** Slow down here:

> *Also in this diff: MaxRenewals changed from 2 to 3. Nothing in any session
> accounts for it.*

Nobody told it about that change. It found something in the diff with no reason
behind it and **said so instead of inventing one.** Inventing something
plausible would have been easy and would have looked better.

**6. It updated the description — and only because the problem changed.** The
ticket said the problem was *no explanation at the desk*. Chat 2 uncovered a
second half: nothing is recorded for the next-day call. So the description gains
a paragraph. Show the diff it printed: everything already there is kept.

Say the distinction out loud: **the description states the problem, the comment
records the work.** It won't touch the description just because something was
done.

**7. Nothing posted without approval.** A permission prompt appeared before each
write, showing the exact command and ticket key. It is a mechanism, not a
promise in a prompt.

---

## The closer — run it again

With no new work:

```
/updatejira <YOUR-KEY>
```

It finds nothing to add and says so. It knows what it already published, and
nothing is stored on your machine to make that work — the timestamp of its own
last comment is the only state there is.

---

## Say these before anyone asks

**"It only knows what happened in a Claude Code session."** Work done in Visual
Studio gets the diff but no reasoning. A real limit, not a bug.

**"It only ever finds your own sessions."** Transcripts are local to a machine,
so a ticket worked by two people gets each person's half separately.

**"AccuRev isn't verified yet."** Everything here is git. The AccuRev commands
are written but have never been run.

---

## Questions you should expect

**"What if I forget to give the ticket number?"** That session isn't found. The
tool reports how many sessions it *didn't* match, so the gap is visible, and you
can pick sessions by hand.

**"Does it read all my conversations?"** Only ones in that repo, only ones where
you named that ticket, and only since the last time the ticket was updated.

**"Can it wreck what I wrote on the ticket?"** Comments are only added. The
description can be updated, but only with text you approved, and it refuses if
more than half would disappear.

**"How much setup?"** Six files that arrive with the repo, and three environment
variables. No install, no background process, nothing running when you aren't
asking for something.

---

## Don't

- Show the scripts. Nobody cares and it looks complicated.
- Run Chat 1 or Chat 2 live — a few seconds of silence kills the room.
- Skip the planted change. It is the most convincing part, and the only one that
  shows restraint rather than capability.
