#!/usr/bin/env python3
"""Labels are code: every label the repo names must exist in .github/labels.yml.

    scripts/check_labels.py            # exit 1 on any problem; `make labels-check`

Two checks, both offline and deterministic:

1. `.github/labels.yml` is well formed: unique names, a 6-digit hex colour, a description of
   1-100 characters (GitHub's limit), aliases that are not themselves labels.
2. Nothing names a label that is not in it. Read from: the `labels:` of every issue form
   (`.github/ISSUE_TEMPLATE/*.yml`), the keys of `.github/labeler.yml`, the label-ish inputs of
   every workflow step (`*-label`, `*-labels`), `gh ... --add-label/--remove-label/label create`
   in workflow scripts, any `prefix:value` token with one of our prefixes (`type:` `area:` ...)
   in the workflows and in scripts/check_pr.py, and the `*_LABEL` constants of check_pr.py.

It exists because the issue forms named four labels that did not exist (issue #75): GitHub
silently drops an unknown label from a form, so nothing ever failed.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
LABELS_FILE = Path(".github/labels.yml")
PREFIXES = ("type", "area", "priority", "severity", "scope", "site", "lang", "triage", "status", "lifecycle")
# `site:{impact}` and friends are templates, not labels: the value must start with a letter.
PREFIXED = re.compile(r"(?<![\w/.-])((?:%s):[a-z][a-z0-9-]*)(?![\w:/-])" % "|".join(PREFIXES))
SHELL_LABEL = re.compile(r"""(?:--(?:add|remove)-label[ =]+|gh\s+label\s+create\s+)["']?([^"'\s$\\]+)""")
HEX = re.compile(r"^[0-9a-fA-F]{6}$")
DESC_MAX = 100
CHECK_PR = Path("scripts/check_pr.py")


def load_labels(root: Path) -> tuple[dict[str, dict], list[str]]:
    problems: list[str] = []
    path = root / LABELS_FILE
    if not path.is_file():
        return {}, [f"{LABELS_FILE}: missing"]
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        return {}, [f"{LABELS_FILE}: must be a list of labels"]
    labels: dict[str, dict] = {}
    for i, item in enumerate(data):
        name = item.get("name") if isinstance(item, dict) else None
        if not isinstance(name, str) or not name.strip():
            problems.append(f"{LABELS_FILE}: entry {i} has no name")
            continue
        if name in labels:
            problems.append(f"{LABELS_FILE}: duplicate label '{name}'")
        labels[name] = item
        if not HEX.match(str(item.get("color", ""))):
            problems.append(f"{LABELS_FILE}: '{name}' needs a 6-digit hex color")
        desc = str(item.get("description") or "").strip()
        if not desc:
            problems.append(f"{LABELS_FILE}: '{name}' has no description")
        elif len(desc) > DESC_MAX:
            problems.append(f"{LABELS_FILE}: '{name}' description is {len(desc)} chars (max {DESC_MAX})")
    for name, item in labels.items():
        for alias in item.get("aliases") or []:
            if alias in labels:
                problems.append(f"{LABELS_FILE}: alias '{alias}' of '{name}' is also a label")
    return labels, problems


def _split(value) -> list[str]:
    if isinstance(value, list):
        return [str(v).strip() for v in value]
    return [p.strip() for p in str(value).replace("\n", ",").split(",")]


def _walk_label_inputs(node, out: list[str]) -> None:
    """Workflow inputs named like `stale-issue-label` or `exempt-issue-labels`."""
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str) and re.search(r"labels?$", key) and key != "sync-labels" and isinstance(value, str):
                out += [v for v in _split(value) if v]
            else:
                _walk_label_inputs(value, out)
    elif isinstance(node, list):
        for value in node:
            _walk_label_inputs(value, out)


def references(root: Path) -> list[tuple[str, str]]:
    """(where, label) for every label the repo names outside labels.yml."""
    refs: list[tuple[str, str]] = []
    for form in sorted((root / ".github/ISSUE_TEMPLATE").glob("*.yml")):
        if form.name == "config.yml":
            continue
        data = yaml.safe_load(form.read_text(encoding="utf-8")) or {}
        refs += [(str(form.relative_to(root)), v) for v in _split(data.get("labels") or []) if v]
    labeler = root / ".github/labeler.yml"
    if labeler.is_file():
        refs += [(".github/labeler.yml", k) for k in (yaml.safe_load(labeler.read_text(encoding="utf-8")) or {})]
    for wf in sorted((root / ".github/workflows").glob("*.y*ml")):
        text = wf.read_text(encoding="utf-8")
        rel = str(wf.relative_to(root))
        found: list[str] = []
        # `with:` inputs of the steps (actions/labeler, actions/stale, ...). The `labels:` of
        # docker/metadata-action are OCI image labels, not issue labels.
        for job in ((yaml.safe_load(text) or {}).get("jobs") or {}).values():
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).startswith("docker/"):
                    continue
                _walk_label_inputs(step.get("with") or {}, found)
        found += [m.group(1) for m in SHELL_LABEL.finditer(text)]
        found += PREFIXED.findall(text)
        refs += [(rel, v) for v in found if "$" not in v]
    cp = root / CHECK_PR
    if cp.is_file():
        src = cp.read_text(encoding="utf-8")
        for node in ast.walk(ast.parse(src)):
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                if any(isinstance(t, ast.Name) and t.id.endswith("_LABEL") for t in node.targets):
                    refs.append((str(CHECK_PR), node.value.value))
        refs += [(str(CHECK_PR), v) for v in PREFIXED.findall(src)]
    return refs


def check(root: Path = REPO) -> tuple[list[str], int, int]:
    labels, problems = load_labels(root)
    known = set(labels)
    refs = references(root)
    seen: set[tuple[str, str]] = set()
    for where, name in refs:
        if name not in known and (where, name) not in seen:
            seen.add((where, name))
            problems.append(f"{where}: label '{name}' is not in {LABELS_FILE} (add it there, or fix the name)")
    return problems, len(labels), len(refs)


def main() -> int:
    problems, n_labels, n_refs = check()
    if problems:
        print("labels: FAIL")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"labels: OK ({n_labels} labels, {n_refs} references checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
