# /updatejira — current documentation

A Claude Code slash command that drafts a Jira ticket update from the sessions
that did the work, and posts it after approval.

| Doc | Read it for |
|---|---|
| `REFERENCE.md` | What it does, how, every file, and why each decision was made. Start here. |
| `INSTALL.md` | Getting it onto a machine. |
| `DEMO.md` | A 15-minute demo for colleagues, with the prompts. |

The `*.cs` files are a throwaway lending fixture. They exist only to produce a
diff and are not meant to compile.

## The one-paragraph version

Developers do not fill in tickets. A diff shows **what** changed and can never
show **why** — that only exists in the conversation where the choice was made,
and dies with it. So: when it looks like you are starting ticket work, Claude
asks which ticket. That key, stated in your own words, is what lets
`/updatejira TICKET-123` later find every session that worked on it, read what
you actually said, and draft a ticket comment from it. Nothing posts without
your approval.

## Status

Works end to end on **git**. Capture, attribution, drafting, posting, the
description update and the no-double-posting watermark are all verified — see
`REFERENCE.md` §5.

**AccuRev is the one unverified part.** Those commands are written from the
official CLI documentation and have never been executed. `REFERENCE.md` §6 lists
what is not proven.
