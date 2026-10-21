#!/usr/bin/env python3
"""Keep release milestones (`vX.Y.Z`, CONTRIBUTING -> Releases) in step with the work.
Run by .github/workflows/milestone.yml: `pr-merged` and `issue-closed` give work without a milestone the
open `v*` milestone due first (Release PRs skipped; a PR without "Closes/Fixes/Part of #N" gets a summary
warning). `release` (a published release, or workflow_dispatch with input `tag`) settles milestone `vX.Y.Z` from
what actually shipped: it creates it when missing (due = release date), moves into it every PR merged and every
issue closed as completed between the previous release tag and this one (found from git and the API, whatever
milestone they were in; non-`v*` milestones such as exam upgrades are never touched), moves what is still open in
it to the next `v*` milestone, and closes it. release-please picks the version only at release time, so the
milestone cannot be known when the work is planned. Safe to re-run.
Stdlib only: event from GITHUB_EVENT_PATH, REST API with GITHUB_TOKEN, git. Tests: tests/test_milestone_sync.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
import urllib.request

RELEASE_TITLE = re.compile(r"^v\d+(\.\d+)*$")
RELEASE_TAG = re.compile(r"^v\d+\.\d+\.\d+$")
PR_IN_SUBJECT = re.compile(r"\(#(\d+)\)\s*$|^Merge pull request #(\d+)")
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


def previous_tag(tag: str, tags: list[str]) -> str | None:
    """The release tag just below `tag` by version (`vX.Y.Z` tags only), or None for the first release."""
    def key(t: str):
        return tuple(int(p) for p in t[1:].split("."))
    lower = [t for t in tags if RELEASE_TAG.match(t) and key(t) < key(tag)]
    return max(lower, key=key) if lower else None


def pr_numbers(subjects: list[str]) -> list[int]:
    """PR numbers from the subjects of the commits a release shipped (squash `(#N)` or merge commits)."""
    found = []
    for subject in subjects:
        m = PR_IN_SUBJECT.search(subject.strip())
        if m:
            found.append(int(m.group(1) or m.group(2)))
    return sorted(set(found))


def closing_issue_numbers(body: str | None, repo: str) -> list[int]:
    """Issues a PR description closes (Closes/Fixes/Resolves; "Part of" closes nothing)."""
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.DOTALL)
    pattern = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+"
                         r"(?:#|https://github\.com/" + re.escape(repo) + r"/issues/)(\d+)", re.I)
    return sorted({int(n) for n in pattern.findall(text)})


def wants_release_milestone(item: dict, tag: str) -> bool:
    """A shipped PR/issue goes into `tag` unless it is already there or sits in a non-release milestone
    (an exam-version upgrade); no milestone, or another `v*` one, is overridden."""
    current = (item.get("milestone") or {}).get("title")
    return current is None or (current != tag and bool(RELEASE_TITLE.match(current)))


def plan_release(tag: str, milestones: list[dict], open_items: list[dict], shipped: list[dict] = (),
                 due_on: str | None = None) -> dict:
    """Release `tag` published. `milestones` holds every milestone (open and closed), `open_items` what is still
    open in `tag`'s milestone, `shipped` the PRs and issues that went out in it. Returns
    {'create', 'due_on', 'released', 'retag', 'next', 'move', 'close', 'reason'}. With open items and no next
    milestone the released one stays open: nothing is left behind silently."""
    existing = next((m for m in milestones if m.get("title") == tag), None)
    retag = [item["number"] for item in shipped if wants_release_milestone(item, tag)]
    nxt = pick_milestone(milestones, exclude=tag)
    move = [item["number"] for item in open_items] if existing else []
    base = {"create": existing is None, "due_on": due_on, "released": existing["number"] if existing else None,
            "retag": retag, "next": nxt, "move": move, "close": True}
    notes = [] if existing else [f"create {tag}"]
    if retag:
        notes.append(f"put {len(retag)} shipped item(s) in {tag}")
    if move and not nxt:
        return {**base, "move": [], "close": False,
                "reason": "; ".join(notes + [f"{len(move)} open item(s) in {tag} and no next v* milestone: left open"])}
    if move:
        notes.append(f"move {len(move)} open item(s) to {nxt['title']}")
    if existing and existing.get("state") == "closed":
        base["close"] = False
        notes.append(f"{tag} already closed")
    else:
        notes.append(f"close {tag}")
    return {**base, "reason": "; ".join(notes)}


def git_lines(*args: str) -> list[str]:
    out = subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def shipped_items(gh: "GitHub", repo: str, tag: str) -> list[dict]:
    """PRs merged and issues closed as completed between the previous release tag and `tag`."""
    git_lines("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    prev = previous_tag(tag, git_lines("tag", "--list", "v*"))
    rev = f"refs/tags/{prev}..refs/tags/{tag}" if prev else f"refs/tags/{tag}"
    items, seen = [], set()
    for number in pr_numbers(git_lines("log", "--format=%s", rev)):
        pr = gh.call("GET", f"/pulls/{number}") or {}
        if not pr.get("merged_at") or is_release_pr(pr):
            continue
        items.append(gh.issue(number))
        seen.add(number)
        for n in closing_issue_numbers(pr.get("body"), repo):
            if n in seen:
                continue
            issue = gh.issue(n)
            if (issue.get("state") == "closed" and issue.get("state_reason") == "completed"
                    and not issue.get("pull_request")):
                items.append(issue)
                seen.add(n)
    return [{"number": it["number"], "milestone": it.get("milestone")} for it in items]


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

    def milestones(self, state: str = "open") -> list[dict]:
        return self.paged(f"/milestones?state={state}")

    def issue(self, number: int) -> dict:
        return self.call("GET", f"/issues/{number}") or {}


def summary(lines: list[str]) -> None:
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(text)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["pr-merged", "issue-closed", "release"])
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args(argv)

    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
        event = json.load(fh)
    gh = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ.get("GITHUB_TOKEN", ""))
    milestones = gh.milestones() if args.command != "release" else []

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
        tag = (event.get("release") or {}).get("tag_name") or (event.get("inputs") or {}).get("tag") or ""
        if not RELEASE_TAG.match(tag):
            print(f"not a release tag (vX.Y.Z): {tag!r}", file=sys.stderr)
            return 1
        milestones = gh.milestones("all")
        released = next((m for m in milestones if m.get("title") == tag), None)
        items = gh.paged(f"/issues?milestone={released['number']}&state=open") if released else []
        shipped = shipped_items(gh, os.environ["GITHUB_REPOSITORY"], tag)
        published = (gh.call("GET", f"/releases/tags/{tag}") or {}).get("published_at")
        due_on = published or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        plan = plan_release(tag, milestones, items, shipped, due_on)
        lines = [f"### Milestones after release {tag}", f"- {plan['reason']}"]
        if not args.dry_run:
            number = plan["released"]
            if plan["create"]:
                number = gh.call("POST", "/milestones", {"title": tag, "due_on": due_on})["number"]
            for n in plan["retag"]:
                gh.call("PATCH", f"/issues/{n}", {"milestone": number})
            for n in plan["move"]:   # move first, then comment: a failed move never leaves a comment behind
                gh.call("PATCH", f"/issues/{n}", {"milestone": plan["next"]["number"]})
                gh.call("POST", f"/issues/{n}/comments", {"body": (
                    f"Release {tag} is out and this was still open, so it moved to milestone {plan['next']['title']} "
                    "(the next release by due date). Done automatically by `.github/workflows/milestone.yml`.")})
            if plan["close"]:
                gh.call("PATCH", f"/milestones/{number}", {"state": "closed"})
        lines += [f"- shipped #{n} -> {tag}" for n in plan["retag"]]
        lines += [f"- moved #{n}" for n in plan["move"]]
        summary(lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
