#!/usr/bin/env python3
"""Keep release milestones (`vX.Y.Z`, CONTRIBUTING -> Releases) in step with the work.
Run by .github/workflows/milestone.yml: `pr-merged` and `issue-closed` give work without a milestone the
open `v*` milestone due first (Release PRs skipped; a PR without "Closes/Fixes/Part of #N" gets a summary
warning); `release` moves what is still open in milestone `vX.Y.Z` to the next one and closes it.
Stdlib only: event from GITHUB_EVENT_PATH, REST API with GITHUB_TOKEN. Tests: tests/test_milestone_sync.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request

RELEASE_TITLE = re.compile(r"^v\d+(\.\d+)*$")
ISSUE_LINK = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|part\s+of)\s*:?\s+"
                        r"(?:(?:[\w.-]+/[\w.-]+)?#|https://github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/)\d+", re.I)
RELEASE_BRANCH_PREFIX = "release-please--"
RELEASE_LABELS = {"autorelease: pending", "autorelease: tagged"}


def release_milestones(milestones: list[dict], exclude: str | None = None) -> list[dict]:
    """Open `v*` milestones, earliest due date first; those without a due date go last."""
    candidates = [m for m in milestones if m.get("state", "open") == "open"
                  and RELEASE_TITLE.match(m.get("title", "")) and m.get("title") != exclude]

    def key(m: dict):
        version = tuple(int(p) for p in m["title"][1:].split("."))
        due = m.get("due_on")
        return (due is None, due or "", version)

    return sorted(candidates, key=key)


def pick_milestone(milestones: list[dict], exclude: str | None = None) -> dict | None:
    ordered = release_milestones(milestones, exclude)
    return ordered[0] if ordered else None


def is_release_pr(pr: dict) -> bool:
    head = (pr.get("head") or {}).get("ref", "")
    labels = {label.get("name", "") for label in pr.get("labels") or []}
    return head.startswith(RELEASE_BRANCH_PREFIX) or bool(labels & RELEASE_LABELS)


def links_an_issue(body: str | None) -> bool:
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.DOTALL)
    return bool(ISSUE_LINK.search(text))


def plan_pr_merged(pr: dict, milestones: list[dict]) -> dict:
    warn = None if links_an_issue(pr.get("body")) else (
        f"PR #{pr.get('number')} links no issue: add 'Closes #N', 'Fixes #N' or 'Part of #N' "
        "to the description so the issue and the milestone follow the work."
    )
    if not pr.get("merged"):
        return {"milestone": None, "reason": "not merged", "warn": None}
    if (pr.get("base") or {}).get("ref") != "main":
        return {"milestone": None, "reason": "not merged into main", "warn": warn}
    if is_release_pr(pr):
        return {"milestone": None, "reason": "release PR, skipped", "warn": None}
    if pr.get("milestone"):
        return {"milestone": None, "reason": f"already in {pr['milestone'].get('title')}", "warn": warn}
    target = pick_milestone(milestones)
    if not target:
        return {"milestone": None, "reason": "no open v* milestone", "warn": warn}
    return {"milestone": target["number"], "reason": f"set to {target['title']}", "warn": warn}


def plan_issue_closed(issue: dict, milestones: list[dict]) -> dict:
    if issue.get("pull_request"):
        return {"milestone": None, "reason": "a pull request, not an issue"}
    if issue.get("state_reason") != "completed":
        return {"milestone": None, "reason": f"closed as {issue.get('state_reason')}, not completed"}
    if issue.get("milestone"):
        return {"milestone": None, "reason": f"already in {issue['milestone'].get('title')}"}
    target = pick_milestone(milestones)
    if not target:
        return {"milestone": None, "reason": "no open v* milestone"}
    return {"milestone": target["number"], "reason": f"set to {target['title']}"}


def plan_release(tag: str, milestones: list[dict], open_items: list[dict]) -> dict:
    """Release `tag` published: {'released', 'next', 'move', 'close', 'reason'}. With open items and no
    next milestone the released one stays open: nothing is left behind silently."""
    released = next((m for m in milestones if m.get("title") == tag and m.get("state", "open") == "open"), None)
    if not released:
        return {"released": None, "next": None, "move": [], "close": False,
                "reason": f"no open milestone named {tag}"}
    nxt = pick_milestone(milestones, exclude=tag)
    move = [item["number"] for item in open_items]
    if move and not nxt:
        return {"released": released["number"], "next": None, "move": [], "close": False,
                "reason": f"{len(move)} open item(s) in {tag} and no next v* milestone: left open"}
    return {"released": released["number"], "next": nxt, "move": move, "close": True,
            "reason": f"close {tag}" + (f", move {len(move)} item(s) to {nxt['title']}" if move else "")}


class GitHub:
    def __init__(self, repo: str, token: str, api: str = "https://api.github.com"):
        self.base = f"{api}/repos/{repo}"
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            self.base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
        return json.loads(data) if data else None

    def paged(self, path: str) -> list[dict]:
        out, page = [], 1
        sep = "&" if "?" in path else "?"
        while True:
            batch = self.call("GET", f"{path}{sep}per_page=100&page={page}")
            out.extend(batch)
            if len(batch) < 100:
                return out
            page += 1

    def milestones(self) -> list[dict]:
        return self.paged("/milestones?state=open")

    def issue(self, number: int) -> dict:
        return self.call("GET", f"/issues/{number}") or {}


def summary(lines: list[str]) -> None:
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8").write(text)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["pr-merged", "issue-closed", "release"])
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args(argv)

    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
        event = json.load(fh)
    gh = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ.get("GITHUB_TOKEN", ""))
    milestones = gh.milestones()

    if args.command == "pr-merged":
        pr = {**event["pull_request"], "milestone": gh.issue(event["pull_request"]["number"]).get("milestone")}
        plan = plan_pr_merged(pr, milestones)
        lines = [f"### Milestone for PR #{pr['number']}", f"- {plan['reason']}"]
        if plan["warn"]:
            lines.append(f"- :warning: {plan['warn']}")
        if plan["milestone"] and not args.dry_run:
            gh.call("PATCH", f"/issues/{pr['number']}", {"milestone": plan["milestone"]})
        summary(lines)
    elif args.command == "issue-closed":
        issue = {**event["issue"], "milestone": gh.issue(event["issue"]["number"]).get("milestone")}
        plan = plan_issue_closed(issue, milestones)
        if plan["milestone"] and not args.dry_run:
            gh.call("PATCH", f"/issues/{issue['number']}", {"milestone": plan["milestone"]})
        summary([f"### Milestone for issue #{issue['number']}", f"- {plan['reason']}"])
    else:
        tag = event["release"]["tag_name"]
        released = next((m for m in milestones if m.get("title") == tag), None)
        items = gh.paged(f"/issues?milestone={released['number']}&state=open") if released else []
        plan = plan_release(tag, milestones, items)
        lines = [f"### Milestones after release {tag}", f"- {plan['reason']}"]
        if not args.dry_run:
            for number in plan["move"]:   # move first, then comment: a failed move never leaves a comment behind
                gh.call("PATCH", f"/issues/{number}", {"milestone": plan["next"]["number"]})
                gh.call("POST", f"/issues/{number}/comments", {"body": (
                    f"Release {tag} is out and this was still open, so it moved to milestone {plan['next']['title']} "
                    "(the next release by due date). Done automatically by `.github/workflows/milestone.yml`.")})
            if plan["close"]:
                gh.call("PATCH", f"/milestones/{plan['released']}", {"state": "closed"})
        lines += [f"- moved #{n}" for n in plan["move"]]
        summary(lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
