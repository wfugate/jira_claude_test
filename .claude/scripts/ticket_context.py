#!/usr/bin/env python3
"""Fetch a ticket's summary and description as plain text.

    python ticket_context.py TEST-117

This is the ONE place ticket prose is handed to the model, and it is a
deliberate, bounded relaxation of the rule that ticket text stays out of the
model's context. The reason: without knowing what a ticket is about, nothing can
decide which captured sessions belong to it. Attribution is impossible without
it.

What crosses the line: summary and description only. Never comments, never other
fields, never other issues. Credentials stay in the environment.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from jira_comment import _get  # noqa: E402

MAX_DESC_CHARS = 4000
BLOCK_TYPES = ("paragraph", "heading", "listItem", "blockquote", "codeBlock")


def adf_to_text(node, out=None):
    """Flatten an ADF document to plain text. Enough to match on, not fidelity."""
    if out is None:
        out = []
    if isinstance(node, str):
        out.append(node)
        return out
    if not isinstance(node, dict):
        return out

    kind = node.get("type")
    if kind == "text":
        out.append(node.get("text") or "")
    elif kind == "hardBreak":
        out.append(os.linesep)

    for child in node.get("content") or []:
        adf_to_text(child, out)

    if kind in BLOCK_TYPES:
        out.append(os.linesep)
    return out


def fetch(issue, url, user, token):
    data = _get(url, "/rest/api/3/issue/%s?fields=summary,description" % issue,
                user, token)
    fields = data.get("fields") or {}
    summary = fields.get("summary") or "(no summary)"

    desc = fields.get("description")
    if isinstance(desc, str):
        text = desc
    elif isinstance(desc, dict):
        text = "".join(adf_to_text(desc))
    else:
        text = ""

    lines = [ln.strip() for ln in text.splitlines()]
    return summary, "\n".join(ln for ln in lines if ln)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: ticket_context.py ISSUE-KEY")
    issue = sys.argv[1]

    url = os.environ.get("JIRA_URL")
    user = os.environ.get("JIRA_USER")
    token = os.environ.get("JIRA_TOKEN")
    missing = [n for n, v in (("JIRA_URL", url), ("JIRA_USER", user),
                              ("JIRA_TOKEN", token)) if not v]
    if missing:
        print("COULD NOT READ TICKET %s - not set: %s"
              % (issue, ", ".join(missing)))
        print("Attribution cannot be automatic without the ticket. Ask which "
              "sessions belong before drafting.")
        return

    try:
        summary, text = fetch(issue, url, user, token)
    except Exception as exc:
        # Degrade to asking rather than failing the whole command.
        print("COULD NOT READ TICKET %s: %r" % (issue, exc))
        print("Attribution cannot be automatic without the ticket. Ask which "
              "sessions belong before drafting.")
        return

    print("TICKET: %s" % issue)
    print("SUMMARY: %s" % summary)
    print("DESCRIPTION:")
    print(text[:MAX_DESC_CHARS] if text else "(empty)")
    if len(text) > MAX_DESC_CHARS:
        print("... (truncated at %d chars)" % MAX_DESC_CHARS)


if __name__ == "__main__":
    main()
