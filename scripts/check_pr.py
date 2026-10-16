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
- the Authorship section has no `| Author | Human: … |` or `| Author | AI: … |`
  row, that row disagrees with Provenance (human/ai, and for AI the model), it
  has no `### Findings ledger`, or a ledger row is malformed (9 columns, a
  "Found by", and a status: fixed | open | rejected — <reason>);
- the PR touches study material under certs/ and the provenance it declares
  does not match the meta.yaml of the topics it touches: for `Author: ai`, the
  declared backend and model must be the ones meta.yaml records; for
  `Author: human`, every touched meta.yaml must carry a `human_edits` entry.

- the provenance is not declared: `Author:` must be `human` or `ai` on every PR
  (not only when certs/ changes), and for `ai` the `Backend:` and `Model:` must
  say which tool and model (the AI disclosure, CONTRIBUTING.md);
- a non-merge commit of the PR has no `Signed-off-by:` trailer (Developer
  Certificate of Origin, the `DCO` file) whose email is the commit author's or
  the PR author's GitHub noreply address. PRs numbered below DCO_FIRST_PR were
  opened before the rule and are grandfathered; merged history is never checked.

One exemption, and a narrow one: the graph refresh bot
(.github/workflows/graph.yml) opens `chore(graph): ...` PRs from the branch
`bot/graph-refresh`. Such a PR cannot cite a CI run in its own description
(the run does not exist yet when the bot writes it), so when the head branch is
exactly that, the PR's author is github-actions[bot], its head repository is this
one (not a fork), and EVERY changed file is under graphify-out/, only the title
is checked. Any other file, author or branch gets the full check. The same PR is
exempt from the sign-off check, and only while every commit is authored by
github-actions[bot]. (Paths are read with core.quotePath=false: git quotes a
non-ASCII name, and a quoted "graphify-out/... fails the prefix test, which is
how #60 lost the exemption.)

It also checks scope and size (one topic, one lab, material apart from code,
<= 400 changed lines of code), waived by the scope-exception/size-exception
labels.

No model. No network either, except `--verify-runs` (CI only): that mode asks
the GitHub API, with `gh api`, whether the run cited under "Where it ran" is
a green run of verify.yml on the PR's head commit. Everything else reads the
PR body, the list of changed files and the meta.yaml files in the checkout.

    # by hand
    scripts/check_pr.py --title "docs: x" --body-file body.md --files a b c

    # CI (.github/workflows/verify.yml, job pr-format), step 1: the description
    scripts/check_pr.py --event "$GITHUB_EVENT_PATH" --labels-file labels.txt \
        --base origin/<base> --label-file site-label.txt --runs-file cited-runs.txt
    # step 2: the cited run, against the API
    scripts/check_pr.py --verify-runs cited-runs.txt --repo <owner/name> --head <sha>
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

SECTIONS = ("What and why", "Kind", "Provenance", "Evidence", "Authorship",
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


def base_texts(paths: list[str], base: str) -> dict[str, str | None]:
    """{path: its text at `base`} (None when it did not exist), in one `git cat-file --batch`."""
    if not paths:
        return {}
    query = "".join(f"{base}:{p}\n" for p in paths)
    res = subprocess.run(["git", "cat-file", "--batch"], cwd=REPO, input=query.encode("utf-8"),
                         capture_output=True, check=True)
    out, data, i = {}, res.stdout, 0
    for p in paths:
        header_end = data.index(b"\n", i)
        header = data[i:header_end].split()
        if len(header) < 3 or header[1] == b"missing":
            out[p] = None
            i = header_end + 1
            continue
        size = int(header[2])
        out[p] = data[header_end + 1:header_end + 1 + size].decode("utf-8")
        i = header_end + 1 + size + 1
    return out


# meta.yaml keys that record checks and reviews of the material, not its authorship.
NOT_AUTHORSHIP_KEYS = ("quality", "reviews")


def quality_only(files: list[str], base_text, root: Path = REPO) -> set[str]:
    """meta.yaml files that are the only change in their topic/language and differ from
    the base only in NOT_AUTHORSHIP_KEYS: the `quality:` block scripts/quality_score.py
    writes, and the `reviews:` a reviewer records (docs/REVIEWS.md).

    Neither is authorship: a PR that rescored the corpus, or recorded a review,
    would otherwise be read as editing the topic's material and asked for
    provenance matching its author. Any other change to the file still counts.
    """
    by_dir: dict[str, list[str]] = {}
    for f in (f.replace("\\", "/") for f in files):
        if MATERIAL.match(f):
            by_dir.setdefault(f.rsplit("/", 1)[0], []).append(f.rsplit("/", 1)[1])
    candidates = [f"{d}/meta.yaml" for d, names in by_dir.items() if names == ["meta.yaml"]]
    before = base_text(candidates)
    out = set()
    for path in candidates:
        if before.get(path) is None or not (root / path).exists():
            continue
        head = yaml.safe_load((root / path).read_text(encoding="utf-8")) or {}
        old = yaml.safe_load(before[path]) or {}
        for key in NOT_AUTHORSHIP_KEYS:
            head.pop(key, None)
            old.pop(key, None)
        if head == old:
            out.add(path)
    return out


def material_dirs(files: list[str]) -> list[Path]:
    dirs = {Path(*Path(f).parts[:4]) for f in files if MATERIAL.match(f.replace("\\", "/"))}
    return sorted(dirs)


GRAPH_BOT_BRANCH = "bot/graph-refresh"
GRAPH_DIR = "graphify-out/"


GRAPH_BOT_AUTHOR = "github-actions[bot]"


def is_graph_refresh(head_ref: str | None, files: list[str], author: str | None = None,
                     same_repo: bool = False) -> bool:
    """The graph bot's PR: its fixed branch, opened by the Actions bot from this
    repository (not a fork, not a collaborator who made the branch by hand), and
    nothing outside graphify-out/. A branch name alone is not an identity (#33)."""
    return (head_ref == GRAPH_BOT_BRANCH and author == GRAPH_BOT_AUTHOR and same_repo
            and bool(files)
            and all(f.replace("\\", "/").startswith(GRAPH_DIR) for f in files))


def disclosure(prov: dict[str, str]) -> list[str]:
    """The AI disclosure, on every PR: `Author: human|ai`, and for ai the tool and the model."""
    author = prov.get("author", "").strip().lower()
    if author not in ("ai", "human"):
        return ["Provenance: 'Author:' must be exactly 'ai' or 'human' (also 'ai' when an AI helped write "
                "it), then say which Backend and Model"]
    if author == "ai":
        empty = [k.capitalize() for k in ("backend", "model")
                 if prov.get(k, "").strip().lower() in ("", "none", "n/a")]
        if empty:
            return [f"Provenance: Author is ai, so name the tool and model ({' and '.join(empty)} "
                    "is empty or 'none')"]
    return []


def check(title: str, body: str, files: list[str], root: Path = REPO,
          head_ref: str | None = None, author: str | None = None,
          same_repo: bool = False) -> list[str]:
    problems: list[str] = []
    if not TITLE.match(title.strip()):
        problems.append(f"title is not a Conventional Commit ({'|'.join(TYPES)}(scope)?: summary): {title!r}")
    if is_graph_refresh(head_ref, files, author, same_repo):
        return problems  # generated by .github/workflows/graph.yml; see the module docstring
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

    if "Provenance" in found:
        problems += disclosure(declared(found["Provenance"]))

    if "Authorship" in found and "Provenance" in found:
        problems += authorship(found["Authorship"], declared(found["Provenance"]))

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
        return problems  # disclosure() already reported it
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


# --- authorship: who wrote it, who found what, who fixed it -----------------

AUTHOR_ROW = re.compile(r"^\|\s*Author\s*\|([^|]*)\|", re.M | re.I)
LEDGER_COLUMNS = 9  # # · found by · head · severity · finding · fixed by · fix · verified by · status
STATUS = re.compile(r"^(fixed|open|rejected\s*[—–:-]+\s*\S.*)$", re.I)


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def ledger_rows(authorship_text: str) -> list[list[str]] | None:
    """The data rows of '### Findings ledger' (None if the subsection is missing)."""
    match = re.search(r"^###\s+Findings ledger\s*$(.*?)(?=^###\s|\Z)", authorship_text, re.M | re.S)
    if not match:
        return None
    rows = []
    for line in match.group(1).splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = _cells(line)
        if cells[0] == "#" or all(re.fullmatch(r":?-+:?", c) for c in cells if c):
            continue  # header or separator
        rows.append(cells)
    return rows


def authorship(text: str, prov: dict[str, str]) -> list[str]:
    """Who is declared as author agrees with Provenance; the findings ledger is well formed."""
    problems = []
    row = AUTHOR_ROW.search(text)
    who = row.group(1).strip() if row else ""
    kind = re.match(r"(?i)(ai|human)\s*:", who)
    if not kind:
        problems.append("Authorship: add an Author row, '| Author | Human: <who> | …' or "
                        "'| Author | AI: <agent> · <model> | …'")
    else:
        said = prov.get("author", "").lower()
        if said in ("ai", "human") and kind.group(1).lower() != said:
            problems.append(f"Authorship: the Author row says {kind.group(1)}, Provenance says Author: {said}")
        models = [m.strip() for m in prov.get("model", "").split(",") if m.strip() and m.strip() != "none"]
        if kind.group(1).lower() == "ai" and models and not any(m in who for m in models):
            problems.append(f"Authorship: the Author row must name the model Provenance declares ({', '.join(models)})")
    rows = ledger_rows(text)
    if rows is None:
        problems.append("Authorship: add a '### Findings ledger' subsection (its table may have no rows yet)")
        return problems
    for cells in rows:
        ref = cells[0] or "?"
        if len(cells) != LEDGER_COLUMNS:
            problems.append(f"Findings ledger row {ref}: {len(cells)} columns, expected {LEDGER_COLUMNS}")
            continue
        if not cells[1]:
            problems.append(f"Findings ledger row {ref}: 'Found by' is empty")
        if not STATUS.match(cells[8]):
            problems.append(f"Findings ledger row {ref}: status must be fixed, open or "
                            f"'rejected — <reason>', not {cells[8]!r}")
        elif cells[8].lower() == "fixed" and not (cells[5] and cells[6]):
            problems.append(f"Findings ledger row {ref}: fixed, but 'Fixed by' or 'Fix' is empty")
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


def scope(files: list[str], code_lines: int | None = None, labels: set | None = None,
          all_files: list[str] | None = None) -> list[str]:
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
    # A rescored meta.yaml (left out of `files` as not authored) is still a certs/ change.
    if touched_generated and not any(f.startswith("certs/") for f in (all_files or files)):
        problems.append(f"generated file changed without any certs/ change ({', '.join(touched_generated)}): "
                        "regenerate it with `teach status`, never edit it by hand")
    if code_lines is not None and code_lines > CODE_LIMIT and SIZE_LABEL not in labels:
        problems.append(f"size: {code_lines} changed lines of code (limit {CODE_LIMIT}, generated files "
                        "excluded); split it into stacked PRs ('Depends on: #N')")
    return problems


# --- DCO: a human signs off every commit (CONTRIBUTING -> Sign your commits) --

DCO_FIRST_PR = 73   # PRs numbered below this were opened before the rule: grandfathered (#68)
BOT_EMAIL = "github-actions[bot]@users.noreply.github.com"
SIGNED_OFF = re.compile(r"^Signed-off-by:[ \t]*(.*?)[ \t]*<([^<>\s]+)>[ \t]*$", re.M | re.I)
DCO_FIX = ("fix: `git commit --amend -s` (last commit) or `git rebase --signoff origin/main` (all of "
           "them), then `git push --force-with-lease`; see CONTRIBUTING.md -> Sign your commits (DCO)")


def commits_of(base: str) -> list[dict]:
    """The non-merge commits of base..HEAD: sha, author email, message."""
    result = subprocess.run(["git", "log", "--no-merges", "--format=%H%x1f%ae%x1f%B%x1e", f"{base}..HEAD"],
                            cwd=REPO, capture_output=True, text=True, check=True)
    out = []
    for record in result.stdout.split("\x1e"):
        if record.strip():
            sha, email, message = record.strip("\n").split("\x1f", 2)
            out.append({"sha": sha.strip(), "email": email.strip(), "message": message})
    return out


def noreply(email: str, login: str | None) -> bool:
    """`<id>+<login>@users.noreply.github.com` or `<login>@users.noreply.github.com`."""
    if not login:
        return False
    return re.fullmatch(rf"(\d+\+)?{re.escape(login)}@users\.noreply\.github\.com", email, re.I) is not None


def dco(commits: list[dict], pr_author: str | None = None, number: int | None = None,
        head_ref: str | None = None, files: list[str] | None = None,
        same_repo: bool = False) -> list[str]:
    """One problem per commit without a valid Signed-off-by (empty: all signed, or exempt)."""
    if number is not None and number < DCO_FIRST_PR:
        return []  # grandfathered: opened before the rule (DCO_FIRST_PR)
    if (is_graph_refresh(head_ref, files or [], pr_author, same_repo) and commits
            and all(c["email"].lower().endswith(BOT_EMAIL) for c in commits)):
        return []  # the graph bot, see the module docstring
    problems = []
    for c in commits:
        emails = {m.group(2).lower() for m in SIGNED_OFF.finditer(c["message"])}
        if c["email"].lower() in emails or any(noreply(e, pr_author) for e in emails):
            continue
        subject = c["message"].strip().splitlines()[0] if c["message"].strip() else ""
        problems.append(f"DCO: commit {c['sha'][:7]} ({subject[:60]!r}) has no 'Signed-off-by: Name <email>' "
                        f"for its author <{c['email']}>; {DCO_FIX}")
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


def read_labels(path: Path) -> set:
    """One label per line, as `gh api .../labels --jq '.[].name'` writes them."""
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}


def changed_files(base: str) -> list[str]:
    result = subprocess.run(["git", "-c", "core.quotePath=false", "diff", "--name-only", f"{base}...HEAD"],
                            cwd=REPO, capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def code_lines_changed(base: str) -> int:
    result = subprocess.run(["git", "-c", "core.quotePath=false", "diff", "--numstat", f"{base}...HEAD"],
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
    parser.add_argument("--labels-file",
                        help="the PR's current labels, one per line (read live in CI); they replace "
                             "the event payload's, which a re-run replays as they were")
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
    head_ref = author = None
    same_repo = False
    number = None
    if args.event:
        pr = json.loads(Path(args.event).read_text(encoding="utf-8"))["pull_request"]
        title, body = pr["title"], pr.get("body") or ""
        head_ref = pr.get("head", {}).get("ref")
        number = pr.get("number")
        author = (pr.get("user") or {}).get("login")
        head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name") or ""
        base_repo = ((pr.get("base") or {}).get("repo") or {}).get("full_name") or "-"
        same_repo = head_repo.lower() == base_repo.lower()  # a fork's head repo differs
        labels = {label["name"] for label in pr.get("labels") or []}
    else:
        title = args.title or ""
        body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else ""
    if args.labels_file and Path(args.labels_file).is_file():
        labels = read_labels(Path(args.labels_file))  # live labels replace the replayed payload's
    files = args.files if args.files is not None else (changed_files(args.base) if args.base else [])
    code_lines = code_lines_changed(args.base) if args.base and args.files is None else None

    generated = quality_only(files, lambda paths: base_texts(paths, args.base)) if args.base else set()
    if generated:
        print(f"{len(generated)} meta.yaml change only their generated quality block: not counted as material")
    authored = [f for f in files if f.replace("\\", "/") not in generated]
    problems = check(title, body, authored, head_ref=head_ref, author=author,
                     same_repo=same_repo) + scope(authored, code_lines, labels, all_files=files)
    if args.base:
        problems += dco(commits_of(args.base), author, number, head_ref, files, same_repo)
    # The graph bot's PR cites no run, and an empty runs file would still make
    # the workflow's "cited run" step run and fail: write nothing for it.
    if args.runs_file and not is_graph_refresh(head_ref, files, author, same_repo):
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
