#!/usr/bin/env python3
"""Are the docs consistent with the repository they describe?

Deterministic, offline, no model. It reads the tracked Markdown (README,
root docs, docs/, .github/, deploy/ — never the generated study corpus in
certs/ or graphify-out/) and fails when:

- a relative link points to a file that does not exist, or to an anchor
  (`#heading` or `<a id>`) that the target file does not have;
- an inline-code path (`scripts/x.py`, `docs/X.md`, `teach/...`) names a
  file or directory that does not exist;
- a `make <target>` mentioned in the docs is not a Makefile target, or a
  `teach <command>` is not a command of teach/cli.py;
- a generated file is stale: the same `--check` the generators already have
  (gen_api_docs.py, gen_readme_table.py).

A reference that is meant to point at something that does not exist (a
placeholder, a file a reader creates, a historical name) goes in
ALLOWED below with the reason, never silently.

    scripts/check_docs.py              # everything
    scripts/check_docs.py --no-generated   # skip the generator --check calls
"""
from __future__ import annotations

import argparse
import posixpath
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

# Markdown that is documentation. The corpus (certs/), generated graph pages,
# third-party trees and test fixtures are not.
SKIP_DIRS = ("certs/", "graphify-out/", "media/", "node_modules/", "tests/fixtures/", ".claude/")

# References that intentionally name something absent from the tree, with why.
ALLOWED: dict[str, str] = {
    "deploy/helm/values-local.yaml": "created by the reader from values-study.example.yaml; gitignored",
    ".env": "created by the reader from .env.example; gitignored",
    "usage.jsonl": "local spend log; gitignored",
}

# Files that describe proposals or history: their links are checked, the
# commands they mention are not (a `teach pipeline` in BACKLOG is an idea, a
# `teach cert diff` in PLAN is the original design, not the current CLI).
COMMANDS_NOT_CHECKED = {
    "docs/BACKLOG.md": "proposals",
    "docs/ORIGINAL_DESIGN.md": "the original design, kept as history",
    "CHANGELOG.md": "history",
    "docs/HISTORY.md": "history",
}

FENCE = re.compile(r"^(\s*)(```|~~~)")
LINK = re.compile(r"!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_SPAN = re.compile(r"`([^`\n]+)`")
PATH_LIKE = re.compile(r"^(?:\./)?((?:teach|scripts|docs|tests|deploy|\.github|\.githooks|openwiki)/[\w./-]*[\w/])$")
# A command is what a reader would type: a code span or a code-block line that
# starts with it (optionally after `$ ` or `.venv/bin/`), not the word in prose.
MAKE_CMD = re.compile(r"^(?:\$\s+)?make\s+([a-z][\w-]*)")
TEACH_CMD = re.compile(r"^(?:\$\s+)?(?:\.venv/bin/)?teach\s+([a-z][\w-]*)(?:\s+([a-z][\w-]*))?")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
EXPLICIT_ANCHOR = re.compile(r"<a\s+(?:id|name)=[\"']([^\"']+)[\"']", re.I)


REPO_URL = re.compile(r"https://github\.com/villadalmine/study-cybercirujas/(?:blob|tree)/main/([^\s)#>\"'`]+)")


def personal_names() -> list[str]:
    """docs/personal-names.yaml: words that identify a person; decisions are written by role."""
    f = REPO / "docs" / "personal-names.yaml"
    return list((yaml.safe_load(f.read_text(encoding="utf-8")) or {}).get("personal_names") or []) if f.is_file() else []


def personal_name_problems(rel: str, text: str, names: list[str]) -> list[str]:
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        for name in names:
            if re.search(rf"\b{re.escape(name)}\b", line):
                out.append(f"{rel}:{n}: names a person ({name}); refer to the role instead (the maintainer, a contributor), see docs/personal-names.yaml")
    return out


def absolute_url_problems(rel: str, n: int, line: str, tracked: set[str]) -> list[str]:
    """An absolute GitHub URL to a file of this repo is never checked by the link check, so it can point at nothing and stay green."""
    return [f"{rel}:{n}: absolute GitHub URL to {m.group(1)!r}, which does not exist on this branch; write a relative link"
            for m in REPO_URL.finditer(line) if m.group(1).rstrip("/") not in tracked and m.group(1).rstrip("/") not in ALLOWED]


def tracked_paths() -> set[str]:
    """Every tracked file and every directory that holds one, exactly as git spells them.

    Existence is asked of git, not of the working tree: on a case-insensitive
    file system (Windows, macOS) `scripts/Check_Docs.py` "exists", and an
    untracked local file exists only on one machine — both pass locally and
    fail in CI. Membership in this set is case-exact and the same everywhere.
    """
    out = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, capture_output=True, text=True,
                         encoding="utf-8", check=True)
    paths: set[str] = set()
    for f in out.stdout.split(chr(0)):
        if not f:
            continue
        paths.add(f)
        parts = f.split("/")
        for i in range(1, len(parts)):
            paths.add("/".join(parts[:i]))
    return paths


def tracked_markdown() -> list[str]:
    # -z: without it git quotes non-ASCII names (an em dash in a graphify wiki page name).
    out = subprocess.run(["git", "ls-files", "-z", "*.md"], cwd=REPO, capture_output=True, text=True,
                         encoding="utf-8", check=True)
    return sorted(f for f in out.stdout.split(chr(0)) if f and not f.startswith(SKIP_DIRS))


def prose_lines(text: str):
    """(line number, line, in_code_block) for every line."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if m:
            fence = None if fence and line.strip().startswith(fence) else (fence or m.group(2))
            yield n, line, True
            continue
        yield n, line, fence is not None


def slug(heading: str) -> str:
    """GitHub's heading anchor: markup stripped, lower-cased, punctuation dropped, spaces to '-'."""
    text = re.sub(r"<[^>]+>", "", heading)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)   # links -> their text
    text = text.replace("`", "").replace("*", "").replace("~", "")
    text = re.sub(r"(?<!\w)_|_(?!\w)", "", text)               # emphasis underscores, not snake_case
    out = []
    for ch in text.lower():
        if ch in " -":
            out.append("-" if ch == " " else ch)
        elif ch == "_" or unicodedata.category(ch)[0] in "LN":
            out.append(ch)
    return "".join(out)


def anchors(path: Path, cache: dict) -> set[str]:
    if path not in cache:
        found: set[str] = set()
        seen: dict[str, int] = {}
        text = path.read_text(encoding="utf-8")
        for _, line, code in prose_lines(text):
            if code:
                continue
            found.update(a.lower() for a in EXPLICIT_ANCHOR.findall(line))
            h = HEADING.match(line)
            if h:
                base = slug(h.group(2))
                k = seen.get(base, 0)
                found.add(base if k == 0 else f"{base}-{k}")
                seen[base] = k + 1
        cache[path] = found
    return cache[path]


def make_targets() -> set[str]:
    text = (REPO / "Makefile").read_text(encoding="utf-8")
    return set(re.findall(r"^([A-Za-z][\w.-]*)\s*:(?!=)", text, re.M))


def teach_commands() -> tuple[set[str], dict[str, set[str]]]:
    """Top-level commands and {group: subcommands}, read statically from teach/cli.py."""
    text = (REPO / "teach" / "cli.py").read_text(encoding="utf-8")
    groups = {var: name for var, name in re.findall(r'app\.add_typer\((\w+),\s*name="([\w-]+)"', text)}
    subs: dict[str, set[str]] = {name: set() for name in groups.values()}
    top: set[str] = set(subs)
    for var, explicit, func in re.findall(r'@(\w+)\.command\((?:"([\w-]+)")?[^)]*\)\s*\ndef (\w+)', text):
        name = explicit or func.replace("_", "-")
        if var == "app":
            top.add(name)
        elif var in groups:
            subs[groups[var]].add(name)
    return top, subs


def check_file(rel: str, targets: set[str], top: set[str], subs: dict, cache: dict,
               tracked: set[str] | None = None) -> list[str]:
    path = REPO / rel
    if tracked is None:
        tracked = cache.setdefault("__tracked__", tracked_paths())
    text = path.read_text(encoding="utf-8")
    problems = personal_name_problems(rel, text, personal_names())
    check_commands = rel not in COMMANDS_NOT_CHECKED
    for n, line, code in prose_lines(text):
        where = f"{rel}:{n}"
        commands = [line.strip()] if code else CODE_SPAN.findall(line)
        for cmd_text in commands if check_commands else []:
            m = MAKE_CMD.match(cmd_text.strip())
            if m and m.group(1) not in targets:
                problems.append(f"{where}: `make {m.group(1)}` is not a Makefile target")
            m = TEACH_CMD.match(cmd_text.strip())
            if m:
                cmd, sub = m.group(1), m.group(2)
                if cmd not in top:
                    problems.append(f"{where}: `teach {cmd}` is not a command of teach/cli.py")
                elif cmd in subs and sub and sub not in subs[cmd]:
                    problems.append(f"{where}: `teach {cmd} {sub}` is not a command of teach/cli.py")
        if code:
            continue
        problems += absolute_url_problems(rel, n, line, tracked)
        for target in LINK.findall(line):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):   # http:, mailto:, …
                continue
            file_part, _, frag = target.partition("#")
            # Normalised as written (no resolve(): on Windows it would fix the case for us).
            dest_rel = posixpath.normpath(posixpath.join(posixpath.dirname(rel), file_part)) if file_part else rel
            if dest_rel == ".." or dest_rel.startswith("../"):
                problems.append(f"{where}: link {target!r} leaves the repository")
                continue
            dest = REPO / dest_rel
            if file_part and dest_rel.rstrip("/") not in tracked:
                if dest_rel not in ALLOWED:
                    problems.append(f"{where}: link to {dest_rel!r}, which does not exist")
                continue
            if frag and dest.suffix == ".md" and dest_rel in tracked and frag.lower() not in anchors(dest, cache):
                problems.append(f"{where}: link to {dest_rel}#{frag}, which has no such heading or anchor")
        for span in CODE_SPAN.findall(line):
            m = PATH_LIKE.match(span.strip())
            if not m:
                continue
            ref = m.group(1).rstrip("/")
            if ref in ALLOWED or ref in tracked:
                continue
            problems.append(f"{where}: `{span}` names a path that does not exist")
    return problems


def generated_checks() -> list[str]:
    problems = []
    for script in ("gen_api_docs.py", "gen_readme_table.py"):
        res = subprocess.run([sys.executable, str(REPO / "scripts" / script), "--check"],
                             cwd=REPO, capture_output=True, text=True)
        if res.returncode != 0:
            problems.append(f"generated file stale: scripts/{script} --check failed: "
                            f"{(res.stdout + res.stderr).strip().splitlines()[-1:]}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-generated", action="store_true", help="skip the generators' --check")
    parser.add_argument("files", nargs="*", help="only these Markdown files (default: every tracked doc)")
    args = parser.parse_args(argv)
    targets = make_targets()
    top, subs = teach_commands()
    cache: dict = {}
    files = args.files or tracked_markdown()
    problems = [p for f in files for p in check_file(f, targets, top, subs, cache)]
    if not args.no_generated:
        problems += generated_checks()
    for problem in problems:
        print(f"docs: {problem}")
    if problems:
        print(f"\n{len(problems)} problem(s) in {len(files)} doc(s).")
        return 1
    print(f"docs: OK — {len(files)} doc(s): links, anchors, paths, make targets, teach commands, generated files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
