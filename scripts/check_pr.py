#!/usr/bin/env python3
"""Check a pull request's description: sections, title, and declared provenance.

The PR format is the same whoever wrote the change, a person or a model
(.github/PULL_REQUEST_TEMPLATE/, CONTRIBUTING.md). This makes the format a
check instead of a request. It fails when:

- a required section is missing or empty (HTML comments do not count);
- the title is not a Conventional Commit;
- the "Site:" line in the Kind section is missing or disagrees with the
  computed site impact: `image-rebuild` when the PR touches anything the
  public image is built from (the `paths` of .github/workflows/docker.yml,
  the single source), `none` otherwise;
- the PR touches study material under certs/ and the provenance it declares
  does not match the meta.yaml of the topics it touches: for `Author: ai`, the
  declared backend and model must be the ones meta.yaml records; for
  `Author: human`, every touched meta.yaml must carry a `human_edits` entry.

No network, no model: it reads the PR body, the list of changed files and the
meta.yaml files in the checkout.

    scripts/check_pr.py --title "docs: x" --body-file body.md --files a b c
    scripts/check_pr.py --event "$GITHUB_EVENT_PATH" --base origin/main   # CI
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

SECTIONS = ("What and why", "Kind", "Provenance", "Evidence",
            "How to test it from a clean clone", "Risk and rollback", "Depends on")
TYPES = ("feat", "fix", "docs", "test", "ci", "chore", "refactor", "perf", "build",
         "style", "revert", "i18n", "content", "lab", "video")
TITLE = re.compile(rf"^({'|'.join(TYPES)})(\([\w./,-]+\))?!?: \S.*$")
# certs/<cert>/<topic>/<lang>/<file> — the material that carries a meta.yaml.
MATERIAL = re.compile(r"^certs/([^/]+)/([^/]+)/([a-z]{2})/[^/]+$")


def sections(body: str) -> dict[str, str]:
    """`## Heading` → its text, with HTML comments removed."""
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    found: dict[str, str] = {}
    current = None
    for line in body.splitlines():
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            current = heading.group(1)
            found[current] = ""
        elif current is not None:
            found[current] += line + "\n"
    return {k: v.strip() for k, v in found.items()}


def declared(provenance: str) -> dict[str, str]:
    """`- Key: value` lines of the Provenance section, lower-cased keys."""
    out = {}
    for line in provenance.splitlines():
        match = re.match(r"^\s*[-*]\s*([A-Za-z ]+):\s*(.*?)\s*$", line)
        if match:
            out[match.group(1).strip().lower()] = match.group(2)
    return out


def image_paths() -> list[str]:
    """What triggers an image rebuild: docker.yml's push paths, read, not copied."""
    workflow = yaml.safe_load((REPO / ".github" / "workflows" / "docker.yml").read_text(encoding="utf-8"))
    triggers = workflow.get("on", workflow.get(True))  # YAML 1.1 reads `on:` as True
    return list(triggers["push"]["paths"])


def _glob(pattern: str) -> re.Pattern:
    """GitHub path filter semantics: `**` crosses directories, `*` does not."""
    out = ""
    for part in re.split(r"(\*\*|\*)", pattern):
        out += ".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
    return re.compile(out + "$")


def site_impact(files: list[str]) -> str:
    patterns = [_glob(p) for p in image_paths()]
    hit = any(p.match(f.replace("\\", "/")) for f in files for p in patterns)
    return "image-rebuild" if hit else "none"


def material_dirs(files: list[str]) -> list[Path]:
    dirs = {Path(*Path(f).parts[:4]) for f in files if MATERIAL.match(f.replace("\\", "/"))}
    return sorted(dirs)


def check(title: str, body: str, files: list[str], root: Path = REPO) -> list[str]:
    problems: list[str] = []
    if not TITLE.match(title.strip()):
        problems.append(f"title is not a Conventional Commit ({'|'.join(TYPES)}(scope)?: summary): {title!r}")
    found = sections(body)
    for name in SECTIONS:
        if name not in found:
            problems.append(f"missing section: ## {name}")
        elif not found[name]:
            problems.append(f"empty section: ## {name}")

    if "Evidence" in found and not cited_runs(body):
        problems.append("Evidence: add a '### Where it ran' subsection linking the CI run on this "
                        "PR's head commit (github.com/<owner>/<repo>/actions/runs/<id>); the "
                        "'where-it-ran' comment CI posts has the line ready to paste")

    impact = site_impact(files)
    site = re.search(r"^\s*[-*]?\s*Site:\s*(\S+)", found.get("Kind", ""), re.M)
    if not site:
        problems.append(f"Kind: add a 'Site: {impact}' line (computed from the changed files)")
    elif site.group(1).strip("`") != impact:
        problems.append(f"Kind: says Site: {site.group(1)}, but the changed files make it "
                        f"'{impact}' (image paths: .github/workflows/docker.yml)")

    dirs = material_dirs(files)
    if not dirs or "Provenance" not in found:
        return problems
    prov = declared(found["Provenance"])
    author = prov.get("author", "").lower()
    if author not in ("ai", "human"):
        problems.append("Provenance: 'Author:' must be 'ai' or 'human' when certs/ material changes")
        return problems
    for directory in dirs:
        if not (root / directory).is_dir():
            # The PR removed (or renamed away) this topic/language: there is
            # nothing left whose provenance could be checked. A directory that
            # still exists without meta.yaml is still an error, below.
            continue
        meta_file = root / directory / "meta.yaml"
        if not meta_file.exists():
            problems.append(f"{directory}: no meta.yaml — material without provenance")
            continue
        meta = yaml.safe_load(meta_file.read_text(encoding="utf-8")) or {}
        if author == "ai":
            for key in ("backend", "model"):
                want = str(meta.get(key, ""))
                said = [v.strip() for v in prov.get(key, "").split(",") if v.strip()]
                if want not in said:
                    problems.append(f"{directory}: Provenance says {key} {prov.get(key)!r}, "
                                    f"meta.yaml says {want!r}")
        elif not meta.get("human_edits"):
            problems.append(f"{directory}: Author is human but meta.yaml has no human_edits "
                            "entry (CONTRIBUTING.md → Provenance is mandatory)")
    return problems


# --- scope: one concern per PR (CONTRIBUTING → Size and scope) ---------------

CODE_LIMIT = 400                     # changed lines of code, generated files excluded
GENERATED = ("STATUS.md", "MODELS.md")
LAB = re.compile(r"^certs/([^/]+)/([^/]+)/lab/")
CODE = re.compile(r"^(teach/|scripts/|tests/(?!fixtures/)|deploy/|\.github/|Makefile$|pyproject\.toml$)")
SCOPE_LABEL = "scope-exception"      # set by a maintainer, never by the check
SIZE_LABEL = "size-exception"


def kinds(files: list[str]) -> dict[str, set]:
    """What a PR touches, by kind: material (topic/lang dirs), labs, code, docs."""
    out: dict[str, set] = {"material": set(), "lab": set(), "code": set(), "docs": set()}
    for f in (f.replace("\\", "/") for f in files):
        if MATERIAL.match(f):
            out["material"].add("/".join(f.split("/")[1:4]))
        elif LAB.match(f):
            out["lab"].add("/".join(f.split("/")[1:3]))
        elif CODE.match(f):
            out["code"].add(f)
        else:
            out["docs"].add(f)
    return out


def scope(files: list[str], code_lines: int | None = None, labels: set | None = None) -> list[str]:
    """Problems with the shape of a PR, independent of its description."""
    labels = labels or set()
    k = kinds(files)
    problems = []
    if SCOPE_LABEL not in labels:
        if len(k["material"]) > 1:
            problems.append(f"scope: material in {len(k['material'])} topic/language directories "
                            f"({', '.join(sorted(k['material'])[:4])}…); one per PR — stack the rest "
                            "with 'Depends on'")
        if len(k["lab"]) > 1:
            problems.append(f"scope: {len(k['lab'])} labs changed; one lab per PR")
        if (k["material"] or k["lab"]) and k["code"]:
            problems.append("scope: study material and code in the same PR; split them "
                            f"(code: {', '.join(sorted(k['code'])[:3])}…)")
    touched_generated = [f for f in files if f in GENERATED]
    if touched_generated and not any(f.startswith("certs/") for f in files):
        problems.append(f"generated file changed without any certs/ change ({', '.join(touched_generated)}): "
                        "regenerate it with `teach status`, never edit it by hand")
    if code_lines is not None and code_lines > CODE_LIMIT and SIZE_LABEL not in labels:
        problems.append(f"size: {code_lines} changed lines of code (limit {CODE_LIMIT}, generated files "
                        "excluded); split it into stacked PRs ('Depends on: #N')")
    return problems


RUN_LINK = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/actions/runs/(\d+)")


def cited_runs(body: str) -> list[tuple[str, str]]:
    """(repo, run id) linked under '### Where it ran' inside Evidence."""
    evidence = sections(body).get("Evidence", "")
    match = re.search(r"^###\s+Where it ran.*?$(.*?)(?=^###\s|\Z)", evidence, re.M | re.S)
    return RUN_LINK.findall(match.group(1)) if match else []


# --- the cited run, checked against the API (the only networked part) --------

VERIFY_WORKFLOW = ".github/workflows/verify.yml"
PROOF_JOBS = ("verify", "e2e")


def judge_run(run: dict, jobs: dict, head_sha: str) -> str | None:
    """Why a cited run does not prove this head, or None if it does.

    Jobs named verify/e2e are not enough: any workflow (one the PR itself adds)
    can name its jobs that way, so the run must come from verify.yml and from a
    pull_request event. The jobs, not the run's conclusion: the run that proves
    the code also contains pr-format, which was red until the link was pasted.
    """
    if run.get("head_sha") != head_sha:
        return f"is on head {str(run.get('head_sha'))[:7]}, not the PR head {head_sha[:7]}"
    if run.get("path") != VERIFY_WORKFLOW:
        return f"comes from {run.get('path')}, not {VERIFY_WORKFLOW}"
    if run.get("event") != "pull_request":
        return f"was triggered by {run.get('event')}, not pull_request"
    states = {j.get("name"): j.get("conclusion") for j in jobs.get("jobs") or [] if j.get("name") in PROOF_JOBS}
    if states != {name: "success" for name in PROOF_JOBS}:
        return "has " + (", ".join(f"{k}={v}" for k, v in sorted(states.items())) or "no verify/e2e jobs")
    return None


def gh_api(path: str) -> dict:
    """`gh api <path>` as JSON; its error goes to the log instead of being swallowed."""
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"gh api {path}: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


def verify_runs(cited: list[tuple[str, str]], repo: str, head_sha: str, fetch=gh_api) -> bool:
    """True if at least one cited run proves this head; prints why each one does or does not."""
    ok = False
    for cited_repo, run in cited:
        if cited_repo.lower() != repo.lower():  # GitHub owner/repo names ignore case
            print(f"run {run} belongs to {cited_repo}, not {repo}")
            continue
        try:
            reason = judge_run(fetch(f"repos/{repo}/actions/runs/{run}"),  # canonical name, not the pasted one
                               fetch(f"repos/{repo}/actions/runs/{run}/jobs"), head_sha)
        except (RuntimeError, ValueError) as exc:
            reason = f"could not be read: {exc}"
        print(f"run {run}: " + (reason or f"{VERIFY_WORKFLOW}, verify and e2e green on {head_sha[:7]}"))
        ok = ok or reason is None
    return ok


def changed_files(base: str) -> list[str]:
    result = subprocess.run(["git", "diff", "--name-only", f"{base}...HEAD"],
                            cwd=REPO, capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def code_lines_changed(base: str) -> int:
    result = subprocess.run(["git", "diff", "--numstat", f"{base}...HEAD"],
                            cwd=REPO, capture_output=True, text=True, check=True)
    total = 0
    for line in result.stdout.splitlines():
        added, removed, path = line.split("\t", 2)
        if added != "-" and CODE.match(path) and path not in GENERATED:
            total += int(added) + int(removed)
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--event", help="GitHub event JSON (pull_request)")
    parser.add_argument("--title")
    parser.add_argument("--body-file")
    parser.add_argument("--base", help="git ref to diff against, e.g. origin/main")
    parser.add_argument("--files", nargs="*", default=None)
    parser.add_argument("--label-file", help="write the site label here (for the labelling step)")
    parser.add_argument("--runs-file",
                        help="write the CI runs cited under 'Where it ran' here, one 'repo id' per "
                             "line, for the job step that checks them against the API")
    parser.add_argument("--verify-runs", metavar="RUNS_FILE",
                        help="networked mode, for CI only: check the runs listed in RUNS_FILE "
                             "(from --runs-file) with `gh api`; needs --repo and --head")
    parser.add_argument("--repo", help="owner/name of this repository (with --verify-runs)")
    parser.add_argument("--head", help="the PR's head commit SHA (with --verify-runs)")
    args = parser.parse_args()

    if args.verify_runs:
        cited = [tuple(line.split()) for line in Path(args.verify_runs).read_text(encoding="utf-8").splitlines()
                 if len(line.split()) == 2]
        if verify_runs(cited, args.repo, args.head):
            return 0
        print(f"::error::'Where it ran' must link a green run of {VERIFY_WORKFLOW} in {args.repo} on the "
              f"head commit {args.head}. Copy the line from the where-it-ran comment and edit the description.")
        return 1

    labels: set = set()
    if args.event:
        pr = json.loads(Path(args.event).read_text(encoding="utf-8"))["pull_request"]
        title, body = pr["title"], pr.get("body") or ""
        labels = {label["name"] for label in pr.get("labels") or []}
    else:
        title = args.title or ""
        body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else ""
    files = args.files if args.files is not None else (changed_files(args.base) if args.base else [])
    code_lines = code_lines_changed(args.base) if args.base and args.files is None else None

    problems = check(title, body, files) + scope(files, code_lines, labels)
    if args.runs_file:
        Path(args.runs_file).write_text("".join(f"{repo} {run}\n" for repo, run in cited_runs(body)),
                                        encoding="utf-8")
    impact = site_impact(files)
    print(f"site: {impact}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Site impact: `site:{impact}`\n\n")
            handle.write("Touches what the public image is built from: GHCR rebuilds on merge; "
                         "production is a separate release by the maintainer.\n"
                         if impact != "none" else
                         "Nothing the image is built from: merge when CI is green.\n")
    if args.label_file:
        Path(args.label_file).write_text(f"site:{impact}\n", encoding="utf-8")
    for problem in problems:
        print(f"PR: {problem}")
    if problems:
        print(f"\n{len(problems)} problem(s). Templates: .github/PULL_REQUEST_TEMPLATE/")
        return 1
    print(f"PR description OK ({len(files)} changed file(s), "
          f"{len(material_dirs(files))} topic(s) of material).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
