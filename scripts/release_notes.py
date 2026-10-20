#!/usr/bin/env python3
"""The human half of the GitHub Release notes (CONTRIBUTING -> Releases).
Run by release-please.yml when it creates a release: `publish --tag vX.Y.Z` puts NEXT.md (as of the tag) plus a
generated Thanks (`@user (#N)`: authors of the PRs merged since the previous tag who are not in CODEOWNERS or bots)
above release-please's changelog, then opens a PR that removes the published lines from NEXT.md on main.
Stdlib only; token from GITHUB_TOKEN; runs no PR code; idempotent. Tests: tests/test_release_notes.py.
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import sys
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from milestone_sync import GitHub, summary  # noqa: E402

NEXT_PATH = "docs/release-notes/NEXT.md"
CODEOWNERS_PATH = ".github/CODEOWNERS"
MARKER = "<!-- release-notes:v1 -->"
SECTIONS = ("Highlights", "Upgrade notes", "Thanks")
RESET_BRANCH = "release-notes-reset--{tag}"
COMMENT = re.compile(r"<!--.*?-->", re.S)
HEADING = re.compile(r"^##[ \t]+(.+?)[ \t]*$", re.M)
PR_REF = re.compile(r"\(#(\d+)\)\s*$")
SEMVER_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
MENTION = re.compile(r"@([A-Za-z0-9][A-Za-z0-9-]*)")


def parse_sections(text: str) -> dict[str, list[str]]:
    """{heading: [content lines]} for the sections with at least one line outside comments."""
    parts = HEADING.split(COMMENT.sub("", text))   # [preamble, h1, body1, h2, body2, ...]
    out: dict[str, list[str]] = {}
    for name, body in zip(parts[1::2], parts[2::2]):
        lines = [ln.rstrip() for ln in body.splitlines() if ln.strip()]
        if lines:
            out[name.strip()] = lines
    return out


def maintainers(codeowners: str) -> set[str]:
    """Every @login in CODEOWNERS, lowercase, without the '@'. Teams (@org/team) are not logins."""
    logins = set()
    for line in codeowners.splitlines():
        for m in re.finditer(r"(?<![\w/])@([A-Za-z0-9][A-Za-z0-9-]*)(?![\w/-])", line.split("#", 1)[0]):
            logins.add(m.group(1).lower())
    return logins


def pr_numbers(subjects: list[str]) -> list[int]:
    """PR numbers from squash-merge subjects `type(scope): title (#N)`, in order, once each."""
    seen: list[int] = []
    for s in subjects:
        m = PR_REF.search(s.splitlines()[0] if s else "")
        if m and int(m.group(1)) not in seen:
            seen.append(int(m.group(1)))
    return seen


def thanks_lines(prs: list[dict], excluded: set[str], already: frozenset[str] | set[str] = frozenset()) -> list[str]:
    """`- @user (#N, #M)` per merged PR author who is not a maintainer, a bot or thanked by hand already."""
    by_user: dict[str, tuple[str, list[int]]] = {}
    for pr in sorted(prs, key=lambda p: p["number"]):
        user = pr.get("user") or {}
        login = user.get("login", "")
        if not pr.get("merged_at") or not login or user.get("type") == "Bot" or login.endswith("[bot]"):
            continue
        if login.lower() in excluded or login.lower() in already:
            continue
        by_user.setdefault(login.lower(), (login, []))[1].append(pr["number"])
    return [f"- @{login} ({', '.join(f'#{n}' for n in nums)})"
            for login, nums in sorted(by_user.values(), key=lambda t: t[0].lower())]


def compose(next_text: str, generated: list[str]) -> str:
    """The block that goes on top of the release body; "" when there is nothing to say."""
    sections = parse_sections(next_text)
    hand = sections.get("Thanks", [])
    merged = hand + [ln for ln in generated if ln not in hand]
    if merged:
        sections["Thanks"] = merged
    blocks = [f"## {name}\n\n" + "\n".join(sections[name]) for name in SECTIONS if name in sections]
    return (MARKER + "\n" + "\n\n".join(blocks) + "\n") if blocks else ""


def merge_body(block: str, body: str | None) -> str:
    """The block, a `---`, then release-please's changelog. Applied twice: unchanged."""
    body = body or ""
    if not block or MARKER in body:
        return body
    return f"{block}\n---\n\n{body}"


def remove_published(current: str, published: str) -> str:
    """NEXT.md on main minus the lines that were published; lines added since the tag stay."""
    gone = {ln.strip() for lines in parse_sections(published).values() for ln in lines}
    kept = [ln for ln in current.splitlines() if ln.strip() not in gone]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(kept)).rstrip("\n") + "\n"


def previous_tag(tags: list[str], tag: str) -> str | None:
    """The highest vX.Y.Z below `tag`."""
    def key(t: str):
        return tuple(int(p) for p in SEMVER_TAG.match(t).groups())
    versions = {t for t in tags if SEMVER_TAG.match(t)} | {tag}
    below = [t for t in versions if key(t) < key(tag)]
    return max(below, key=key) if below else None


# ---- the GitHub side -------------------------------------------------------------------------

def file_at(gh: GitHub, path: str, ref: str) -> tuple[str | None, str | None]:
    """(text, blob sha) of a file at a ref, or (None, None) when it is not there."""
    try:
        data = gh.call("GET", f"/contents/{path}?ref={ref}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, None
        raise
    return base64.b64decode(data["content"]).decode("utf-8"), data["sha"]


def commit_subjects(gh: GitHub, prev: str, tag: str) -> list[str]:
    out, page = [], 1
    while True:
        batch = gh.call("GET", f"/compare/{prev}...{tag}?per_page=100&page={page}").get("commits", [])
        out += [c["commit"]["message"] for c in batch]
        if len(batch) < 100:
            return out
        page += 1


def merged_prs(gh: GitHub, numbers: list[int]) -> list[dict]:
    prs = []
    for n in numbers:
        try:
            prs.append(gh.call("GET", f"/pulls/{n}"))
        except urllib.error.HTTPError as e:
            if e.code != 404:   # "(#N)" can name an issue; any other error must not be hidden
                raise
    return prs


def open_reset_pr(gh: GitHub, tag: str, published: str) -> str:
    current, sha = file_at(gh, NEXT_PATH, "main")
    if current is None:
        return "NEXT.md is not on main: nothing to reset"
    new = remove_published(current, published)
    if new == current:
        return "NEXT.md on main has no published line: no reset PR"
    branch = RESET_BRANCH.format(tag=tag)
    try:
        gh.call("GET", f"/git/ref/heads/{branch}")
        return f"branch {branch} already exists: no second reset PR"
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    head = gh.call("GET", "/git/ref/heads/main")["object"]["sha"]
    gh.call("POST", "/git/refs", {"ref": f"refs/heads/{branch}", "sha": head})
    title = f"chore(release-notes): reset NEXT.md after {tag}"
    gh.call("PUT", f"/contents/{NEXT_PATH}", {
        "message": title, "branch": branch, "sha": sha,
        "content": base64.b64encode(new.encode("utf-8")).decode("ascii")})
    pr = gh.call("POST", "/pulls", {
        "title": title, "head": branch, "base": "main",
        "body": f"Release {tag} published the lines of `{NEXT_PATH}` in its notes; this removes them so the next "
                "release starts empty. Lines added since the tag are kept. Opened by "
                "`scripts/release_notes.py` from `.github/workflows/release-please.yml`."})
    return f"opened reset PR #{pr['number']}"


def publish(gh: GitHub, tag: str) -> list[str]:
    log = [f"### Release notes for {tag}"]
    release = gh.call("GET", f"/releases/tags/{tag}")
    published = file_at(gh, NEXT_PATH, tag)[0] or ""
    excluded = maintainers(file_at(gh, CODEOWNERS_PATH, tag)[0] or "")
    prev = previous_tag([r["tag_name"] for r in gh.paged("/releases")], tag)
    prs = merged_prs(gh, pr_numbers(commit_subjects(gh, prev, tag))) if prev else []   # first release: no range, no thanks
    by_hand = {m.group(1).lower() for ln in parse_sections(published).get("Thanks", []) for m in MENTION.finditer(ln)}
    generated = thanks_lines(prs, excluded, by_hand)
    log.append(f"- range {prev or '(start)'}..{tag}: {len(prs)} merged PR(s), {len(generated)} thanked")
    old = release.get("body") or ""
    body = merge_body(compose(published, generated), old)
    if body == old:
        log.append("- release body: unchanged (no notes, or already published)")
    else:
        gh.call("PATCH", f"/releases/{release['id']}", {"body": body})
        log.append("- release body: notes added above the changelog")
    if published:
        log.append(f"- reset PR: {open_reset_pr(gh, tag, published)}")
    return log


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["publish"])
    ap.add_argument("--tag", required=True, help="the release tag, vX.Y.Z")
    args = ap.parse_args(argv)
    gh = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ.get("GITHUB_TOKEN", ""))
    summary(publish(gh, args.tag))
    return 0


if __name__ == "__main__":
    sys.exit(main())
