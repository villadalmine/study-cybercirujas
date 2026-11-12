#!/usr/bin/env python3
"""Put ONE generated topic on its own branch, ready for its PR. No model, no hand edits.

`make batch` authors topics in the checkout it runs in, two at a time, and `teach cert translate`
adds their translations there. A PR carries one topic (CONTRIBUTING -> one topic per PR), so each
topic has to leave that checkout on its own, with the bookkeeping the gates check:

    scripts/topic_pr.py nca-aiio 1.5 --agent claude-code      # worktree ../<repo>-<cert>-<topic>
    scripts/topic_pr.py nca-aiio 1.5 --agent claude-code --dry-run

1. a git worktree off `--base` (origin/main) on branch `feat/<issue>-<cert>-<topic>` (`--issue`, default none);
2. `certs/<cert>/<topic>/` copied from this checkout, every language it has plus `lab/`;
3. the topic's syllabus status set to what this checkout says (`teach.core.certs.set_topic_status`);
4. `quality_score.py` over the tree (a newly catalogued source domain moves other certs' scores too:
   those meta.yaml files are committed with it), `status_matrix.py --keep-spend`,
   `model_comparison.py --write`;
5. one commit per language (the authoring language first, with the lab and the syllabus line), one for
   quality blocks of other topics if any moved, one for the generated docs. Trailers `Agent:` (the
   `--agent` that drives the PR) and `Model:` (what the topic's meta.yaml says wrote it), DCO sign-off.

It refuses, before touching git, when a language directory has no meta.yaml or when the topic is identical
to the base; it refuses to commit when the worktree exists or when docs/STATUS.md's spend footer is not the
base's. Only the languages (and lab) that differ from the base are committed. It never pushes.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent


def run(cmd: list[str], cwd: Path, env: dict | None = None, check: bool = True) -> str:
    done = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SystemExit(f"{' '.join(cmd)} failed in {cwd}:\n{done.stdout}{done.stderr}")
    return done.stdout


def topic_langs(topic_dir: Path) -> list[str]:
    """Languages of a topic directory, authoring language (no `translated_from`) first."""
    langs = sorted(p.parent.name for p in topic_dir.glob("*/meta.yaml"))
    meta = {lang: yaml.safe_load((topic_dir / lang / "meta.yaml").read_text(encoding="utf-8")) or {} for lang in langs}
    return sorted(langs, key=lambda lang: (bool(meta[lang].get("translated_from")), lang))


def translated_from(topic_dir: Path, lang: str) -> str | None:
    meta = yaml.safe_load((topic_dir / lang / "meta.yaml").read_text(encoding="utf-8")) or {}
    return meta.get("translated_from")


def subject(cert: str, topic: str, lang: str, model: str, source: str | None) -> str:
    """What the commit says happened: a translation only when meta.yaml records one."""
    how = f"translated from {source}" if source else model
    return f"feat({cert}): {topic} in {lang}, {how}"


def model_of(topic_dir: Path, lang: str) -> str:
    meta = yaml.safe_load((topic_dir / lang / "meta.yaml").read_text(encoding="utf-8")) or {}
    model = meta.get("model")
    if not model:
        raise SystemExit(f"{topic_dir / lang / 'meta.yaml'} has no model: provenance first")
    return str(model)


def plan(cert: str, topic: str, source: Path, issue: str | None) -> dict:
    """What would be done, as data: branch, worktree, languages and their models."""
    topic_dir = source / "certs" / cert / topic
    if not topic_dir.is_dir():
        raise SystemExit(f"{topic_dir} does not exist: generate it first (make batch)")
    langs = topic_langs(topic_dir)
    if not langs:
        raise SystemExit(f"{topic_dir} has no <lang>/meta.yaml")
    unmetered = sorted(d.name for d in topic_dir.iterdir() if d.is_dir() and d.name != "lab" and d.name not in langs)
    if unmetered:
        raise SystemExit(f"{topic_dir}: {', '.join(unmetered)} without meta.yaml: provenance first")
    slug = f"{cert}-{topic}"
    return {"cert": cert, "topic": topic, "langs": langs,
            "models": {lang: model_of(topic_dir, lang) for lang in langs},
            "translated_from": {lang: translated_from(topic_dir, lang) for lang in langs},
            "lab": (topic_dir / "lab").is_dir(),
            "branch": f"feat/{issue}-{slug}" if issue else f"feat/{slug}",
            "worktree": str(source.parent / f"{source.name}-{slug}")}


def trailers(agent: str, model: str, issue: str | None, extra: tuple[str, ...] = ()) -> list[str]:
    msg = ["-m", f"Part of #{issue}"] if issue else []
    return msg + ["-m", "\n".join([f"Agent: {agent}", f"Model: {model}", *extra])]


def differs(source: Path, base: str, path: str) -> bool:
    """Whether `path` (a directory in the source checkout) differs from what `base` has there."""
    def blobs(listing: str) -> dict[str, str]:
        return {line.split("\t", 1)[1]: line.split()[2] for line in listing.splitlines() if "\t" in line}

    at_base = blobs(run(["git", "ls-tree", "-r", base, "--", path], source))
    here = {}
    for f in sorted((source / path).rglob("*")):
        if f.is_file():
            here[f.relative_to(source).as_posix()] = run(["git", "hash-object", str(f)], source).strip()
    return here != at_base


def footer_kept(wt: Path, base: str) -> bool:
    """docs/STATUS.md from the spend marker on is byte-identical to the base's (#298)."""
    marker = "## Spend (measured)"
    before = run(["git", "show", f"{base}:docs/STATUS.md"], wt)
    after = (wt / "docs" / "STATUS.md").read_text(encoding="utf-8")
    return before.partition(marker)[1:] == after.partition(marker)[1:]


def build(p: dict, source: Path, base: str, agent: str, issue: str | None, extra: tuple[str, ...] = ()) -> list[str]:
    cert, topic, wt = p["cert"], p["topic"], Path(p["worktree"])
    if wt.exists():
        raise SystemExit(f"{wt} exists: finish or remove it first (git worktree remove)")
    run(["git", "fetch", "-q", "origin"], source)
    root = f"certs/{cert}/{topic}"
    # Only what differs from the base goes in the PR: a translation PR for a topic whose English
    # is already on main carries the translation alone (CONTRIBUTING -> one topic in one language).
    langs = [lang for lang in p["langs"] if differs(source, base, f"{root}/{lang}")]
    lab = p["lab"] and differs(source, base, f"{root}/lab")
    if not langs and not lab:
        raise SystemExit(f"{root} is identical to {base}: nothing to put on a branch")
    run(["git", "worktree", "add", "-q", str(wt), "-b", p["branch"], base], source)
    venv = source / ".venv"
    if venv.exists() and not (wt / ".venv").exists():
        os.symlink(venv, wt / ".venv")
    shutil.copytree(source / root, wt / root, dirs_exist_ok=True)

    env = dict(os.environ, TEACH_ROOT=str(wt))
    py = str(wt / ".venv" / "bin" / "python3") if (wt / ".venv").exists() else sys.executable
    status = run([py, "-c", f"from teach.core import certs; print(certs.get_topic({cert!r}, {topic!r})['status'])"],
                 source, dict(os.environ, TEACH_ROOT=str(source))).strip()
    run([py, "-c", f"from teach.core import certs; certs.set_topic_status({cert!r}, {topic!r}, {status!r})"], wt, env)
    run([py, "scripts/quality_score.py"], wt, env)
    run([py, "scripts/status_matrix.py", "--keep-spend"], wt, env)
    run([py, "scripts/model_comparison.py", "--write"], wt, env)
    run(["git", "restore", "graphify-out"], wt, check=False)
    if not footer_kept(wt, base):
        raise SystemExit(f"{wt}: docs/STATUS.md spend footer differs from {base}'s; the base's "
                         "status_matrix.py may predate --keep-spend. Nothing committed.")

    lead = (langs or p["langs"])[0]
    first = [f"{root}/{lead}"] if langs else []
    first += [f"certs/{cert}.md"] + ([f"{root}/lab"] if lab else [])
    run(["git", "add", *first], wt)
    title = (subject(cert, topic, lead, p["models"][lead], p["translated_from"][lead]) if langs
             else f"feat({cert}): {topic} lab")
    run(["git", "commit", "-sq", "-m", title, *trailers(agent, p["models"][lead], issue, extra)], wt)
    for lang in langs[1:]:
        run(["git", "add", f"{root}/{lang}"], wt)
        run(["git", "commit", "-sq", "-m", subject(cert, topic, lang, p["models"][lang], p["translated_from"][lang]),
             *trailers(agent, p["models"][lang], issue, extra)], wt)
    if run(["git", "status", "--porcelain", "--", "certs"], wt).strip():
        run(["git", "add", "certs"], wt)
        run(["git", "commit", "-sq", "-m", f"chore(quality): quality blocks re-scored after {cert} {topic}",
             "-m", "scripts/quality_score.py over the tree.", *trailers(agent, p["models"][lead], issue, extra)], wt)
    run(["git", "add", "docs/STATUS.md", "docs/MODELS.md"], wt)
    if run(["git", "diff", "--cached", "--name-only"], wt).strip():
        run(["git", "commit", "-sq", "-m", f"docs(status): STATUS and MODELS after {cert} {topic}",
             "-m", "status_matrix.py --keep-spend and model_comparison.py --write.",
             *trailers(agent, p["models"][lead], issue, extra)], wt)
    run(["git", "restore", "graphify-out"], wt, check=False)
    left = [line for line in run(["git", "status", "--porcelain"], wt).splitlines() if not line.endswith(".venv")]
    if left:
        raise SystemExit("left uncommitted in the worktree:\n" + "\n".join(left))
    return run(["git", "log", "--oneline", f"{base}..HEAD"], wt).splitlines()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cert")
    ap.add_argument("topic")
    ap.add_argument("--agent", required=True, help="the agent that drives the PR (commit trailer Agent:)")
    ap.add_argument("--issue", help="issue number: branch feat/<issue>-<cert>-<topic> and 'Part of #<issue>'")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--source", type=Path, default=REPO, help="the checkout the topic was generated in (default: this one)")
    ap.add_argument("--trailer", action="append", default=[], help="one more commit trailer line (repeatable)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args(argv)
    source = args.source.resolve()
    p = plan(args.cert, args.topic, source, args.issue)
    if args.dry_run:
        print(yaml.safe_dump(p, sort_keys=False), end="")
        return 0
    for line in build(p, source, args.base, args.agent, args.issue, tuple(args.trailer)):
        print(line)
    print(f"ready: {p['worktree']} on {p['branch']} (not pushed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
