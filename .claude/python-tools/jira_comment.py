#!/usr/bin/env python3
"""
jira_comment.py — post a plain-text comment to a Jira Cloud issue.

Exists so nothing else has to build Atlassian Document Format by hand.
Plain text in, correct JSON out, posted.

Standard library only. Nothing to install.

    export JIRA_URL=https://datamaxx.atlassian.net
    export JIRA_USER=you@datamaxx.com
    export JIRA_TOKEN=...                     # never commit this

    # See what would be sent
    echo "hello" | python3 jira_comment.py TEST-1 --dry-run

    # Actually send it
    echo "hello" | python3 jira_comment.py TEST-1

    # Prove auth works before anything else exists
    python3 jira_comment.py TEST-1 --selftest

    # Append one line to the issue description's change log
    python3 jira_comment.py TEST-1 --append-description "Added fee waiver."

Note on --append-description: this is a read-modify-write on a field, unlike
posting a comment. The script reads the current description, appends one line
under a "Change log" heading, and writes it back. Existing content above that
heading is never touched. The description text is handled entirely inside this
script - it is not passed to the model.
"""

import argparse
import base64
import json
import os
import sys
from datetime import datetime
import urllib.error
import urllib.request


def to_adf(text):
    """Jira Cloud v3 wants a document object, not a string.

    Blank-line-separated blocks become paragraphs. Single newlines inside a
    block become hard breaks, so indented lists survive intact.
    """
    content = []
    for block in text.replace("\r\n", "\n").split("\n\n"):
        block = block.strip("\n")
        if not block.strip():
            continue
        nodes = []
        for i, line in enumerate(block.split("\n")):
            if i:
                nodes.append({"type": "hardBreak"})
            if line:
                nodes.append({"type": "text", "text": line})
        if nodes:
            content.append({"type": "paragraph", "content": nodes})

    if not content:
        content = [{"type": "paragraph", "content": [{"type": "text", "text": "(empty)"}]}]
    return {"type": "doc", "version": 1, "content": content}


def post(issue, text, url, user, token, visibility_role=None, timeout=30):
    endpoint = "%s/rest/api/3/issue/%s/comment" % (url.rstrip("/"), issue)
    payload = {"body": to_adf(text)}
    if visibility_role:
        payload["visibility"] = {"type": "role", "value": visibility_role}

    cred = base64.b64encode(("%s:%s" % (user, token)).encode()).decode()
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Basic %s" % cred,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:800]
        hint = {
            401: "Auth rejected. Check JIRA_USER is your full email and the token is current.",
            403: "Authenticated but not permitted. Can your account comment on this project?",
            404: "Issue not found, or your account cannot see it. Check the key.",
        }.get(exc.code, "")
        raise SystemExit("Jira returned %s.\n%s\n%s" % (exc.code, hint, body))
    except urllib.error.URLError as exc:
        raise SystemExit("Could not reach %s: %s" % (url, exc.reason))


CHANGELOG_HEADING = "Change log"


def _get(url, path, user, token, timeout=30):
    endpoint = "%s%s" % (url.rstrip("/"), path)
    cred = base64.b64encode(("%s:%s" % (user, token)).encode()).decode()
    request = urllib.request.Request(
        endpoint,
        headers={"Accept": "application/json", "Authorization": "Basic %s" % cred},
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _put(url, path, payload, user, token, timeout=30):
    endpoint = "%s%s" % (url.rstrip("/"), path)
    cred = base64.b64encode(("%s:%s" % (user, token)).encode()).decode()
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Basic %s" % cred,
        },
        method="PUT",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status


def _has_changelog(doc):
    for node in doc.get("content", []):
        if node.get("type") != "heading":
            continue
        text = "".join(c.get("text", "") for c in node.get("content", []))
        if text.strip().lower() == CHANGELOG_HEADING.lower():
            return True
    return False


def append_to_description(existing, line, stamp):
    """Return a new ADF doc with one line appended under the Change log heading.

    Content above the heading is copied unchanged. Nothing is ever rewritten.
    """
    if not existing:
        doc = {"type": "doc", "version": 1, "content": []}
    elif isinstance(existing, str):
        # Someone wrote the description through the v2 API. Preserve it as text.
        doc = to_adf(existing)
    else:
        doc = json.loads(json.dumps(existing))  # deep copy, never mutate the input

    doc.setdefault("content", [])

    if not _has_changelog(doc):
        doc["content"].append({
            "type": "heading",
            "attrs": {"level": 3},
            "content": [{"type": "text", "text": CHANGELOG_HEADING}],
        })

    doc["content"].append({
        "type": "paragraph",
        "content": [{"type": "text", "text": "%s - %s" % (stamp, line.strip())}],
    })
    return doc


def do_append_description(issue, line, url, user, token, dry_run=False):
    stamp = datetime.now().strftime("%Y-%m-%d")

    if dry_run:
        preview = append_to_description(None, line, stamp)
        print("Would append to %s description:" % issue)
        print("  %s - %s" % (stamp, line.strip()))
        print()
        print(json.dumps(preview, indent=2))
        return

    try:
        data = _get(url, "/rest/api/3/issue/%s?fields=description" % issue, user, token)
    except urllib.error.HTTPError as exc:
        raise SystemExit("Could not read %s (HTTP %s). Cannot append without "
                         "reading the current description first." % (issue, exc.code))

    current = (data.get("fields") or {}).get("description")
    updated = append_to_description(current, line, stamp)

    try:
        _put(url, "/rest/api/3/issue/%s" % issue,
             {"fields": {"description": updated}}, user, token)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:600]
        raise SystemExit("Jira rejected the description update (HTTP %s).\n%s"
                         % (exc.code, body))

    print("Appended one line to %s description." % issue)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("issue", help="Issue key, e.g. TEST-1")
    parser.add_argument("--dry-run", action="store_true", help="Print the payload, send nothing")
    parser.add_argument("--selftest", action="store_true", help="Post a fixed test comment")
    parser.add_argument("--append-description", metavar="LINE",
                        help="Append one line to the issue description's change log")
    parser.add_argument("--visibility-role", help="Restrict comment to a Jira role")
    args = parser.parse_args()

    url = os.environ.get("JIRA_URL")
    user = os.environ.get("JIRA_USER")
    token = os.environ.get("JIRA_TOKEN")

    if args.append_description:
        if not args.dry_run:
            missing = [n for n, v in (("JIRA_URL", url), ("JIRA_USER", user),
                                      ("JIRA_TOKEN", token)) if not v]
            if missing:
                raise SystemExit("Not set: %s" % ", ".join(missing))
        do_append_description(args.issue, args.append_description,
                              url, user, token, dry_run=args.dry_run)
        return

    if args.selftest:
        text = "Test comment from jira_comment.py. Auth and formatting are working."
    else:
        # Decode stdin as UTF-8 explicitly. On Windows sys.stdin defaults to
        # the locale encoding (cp1252), which turns an em dash into mojibake
        # by the time it reaches the ticket.
        text = sys.stdin.buffer.read().decode("utf-8", "replace")

    if not text.strip():
        raise SystemExit("Nothing on stdin. Pipe the comment text in.")

    if args.dry_run:
        print("POST %s/rest/api/3/issue/%s/comment" % ((url or "<JIRA_URL unset>").rstrip("/"), args.issue))
        print(json.dumps({"body": to_adf(text)}, indent=2))
        return

    missing = [n for n, v in (("JIRA_URL", url), ("JIRA_USER", user), ("JIRA_TOKEN", token)) if not v]
    if missing:
        raise SystemExit("Not set: %s" % ", ".join(missing))

    result = post(issue=args.issue, text=text, url=url, user=user, token=token,
                  visibility_role=args.visibility_role)
    print("Posted comment %s to %s" % (result.get("id", "?"), args.issue))


if __name__ == "__main__":
    main()
