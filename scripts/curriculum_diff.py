#!/usr/bin/env python3
"""Curriculum upgrades (#63): freeze an official syllabus, diff two versions, plan what each topic must do.

A curriculum version change re-evaluates the whole cert. Every step here is a
function of its inputs, never a judgment call: the same PDFs and the same frozen
syllabus give the same bytes, run after run, on any machine with the same
`pdftotext`. No model, no network.

Each subcommand's rules are written in the comment block that opens its section
below; `--help` lists the subcommands and `<subcommand> --help` their flags.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

# name -> (help, add_arguments(parser), run(args) -> exit code); each section registers its own.
COMMANDS: dict[str, tuple] = {}


def dump_yaml(data: dict) -> str:
    return yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=1000)


def dump_json(data) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write(text: str, out: str | None, check: bool) -> int:
    """Write `text` to `out` (stdout if none), or with `check` fail when `out` holds something else."""
    if check:
        current = Path(out).read_text(encoding="utf-8") if out and Path(out).is_file() else None
        if current != text:
            print(f"STALE: {out} is not what the inputs produce; regenerate it", file=sys.stderr)
            return 1
        print(f"OK: {out} is current")
        return 0
    if out:
        Path(out).write_text(text, encoding="utf-8", newline="\n")
    else:
        sys.stdout.write(text)
    return 0


# ==== text ====

def normalize(text: str) -> str:
    """The comparison key of an objective or domain name: NFKC, case-folded, single spaces, no trailing period."""
    text = unicodedata.normalize("NFKC", text).casefold()
    text = re.sub(r"\s+", " ", text).strip()
    return text.rstrip(".,;:").strip()


def tidy(text: str) -> str:
    """Display text: NFKC (the PDF's `ﬁ` ligature becomes `fi`) and single spaces."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text)).strip()


def join(text: str, more: str) -> str:
    """Append a continuation line, undoing the PDF's line-end hyphenation."""
    more = more.strip()
    if not text:
        return more
    if re.search(r"[A-Za-z]-$", text) and more[:1].islower():
        return text[:-1] + more
    if text.endswith("/"):
        return text + more
    return text + " " + more


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def number(value) -> int | float:
    """A weight as the document means it: 10, not 10.0; 3.33 stays 3.33."""
    value = round(float(value), 2)
    return int(value) if value == int(value) else value


# ==== extract ====
#
#   scripts/curriculum_diff.py extract --pdf CKA_Curriculum_v1.37.pdf --cert cka --version 1.37 \
#       --repo cncf/curriculum --commit <sha> --path CKA_Curriculum_v1.37.pdf --committed 2026-10-15 \
#       -o syllabi/cka/v1.37.yaml            # add --check to verify a committed snapshot instead
#
# CNCF curricula print two columns of `NN% - Domain` headers and `•` objectives.
# `pdftotext -layout` keeps the columns side by side, so one text line holds the
# end of a left objective and the start of a right one. Each line is cut into
# segments at runs of two or more spaces; a segment belongs to the right column
# when it starts at (or one before) the leftmost right-column marker: a header or
# bullet whose start lies past the widest gap (>= 10) between marker starts.
# Columns are read left first, as the page flows. Continuation lines join their
# objective (see `join`); pure page numbers are dropped; text before the first
# header is not part of the tree. Domains are numbered by the position of their
# header (top to bottom, then left to right), objectives by their order inside
# the domain. A tree with no domains, an empty domain, or weights that do not
# sum to 100 is refused.

BULLET = "•"
HEADER = re.compile(r"^(\d{1,3})\s?%\s*[-–]\s*(.*)$")
SEGMENT = re.compile(r"\S+(?: \S+)*")          # text runs separated by two or more spaces
PAGE_NUMBER = re.compile(r"^\d{1,3}$")


def _segments(lines: list[str]) -> list[tuple[int, int, str]]:
    return [(n, m.start(), m.group()) for n, line in enumerate(lines) for m in SEGMENT.finditer(line)]


def _is_marker(text: str) -> bool:
    return text.startswith(BULLET) or bool(HEADER.match(text))


def _right_start(segments: list[tuple[int, int, str]]) -> int | None:
    """The first column of the right-hand column, or None if the page has one column."""
    starts = sorted({start for _, start, text in segments if _is_marker(text)})
    if len(starts) < 2:
        return None
    gap, index = max((b - a, i) for i, (a, b) in enumerate(zip(starts, starts[1:])))
    return starts[index + 1] if gap >= 10 else None


def parse_layout(text: str) -> list[dict]:
    """Domains with their weight and objectives, from `pdftotext -layout` output."""
    stream: list[tuple[tuple[int, int, int], str]] = []   # ((page, line, column), segment text)
    for page_no, page in enumerate(text.split("\f")):
        segments = _segments(page.splitlines())
        if not any(HEADER.match(t) for _, _, t in segments):
            continue
        right = _right_start(segments)
        columns: dict[int, list] = {0: [], 1: []}
        for n, start, seg in segments:
            column = 1 if right is not None and start >= right - 1 else 0
            columns[column].append(((page_no, n, column), seg))
        stream += columns[0] + columns[1]

    domains: list[dict] = []
    current: dict | None = None      # the objective being read
    naming: dict | None = None       # the domain whose name may continue on the next line
    for position, seg in stream:
        if PAGE_NUMBER.match(seg):
            continue
        header = HEADER.match(seg)
        if header:
            naming = {"weight": int(header.group(1)), "name": header.group(2).strip(), "objectives": [],
                      "position": position}
            domains.append(naming)
            current = None
        elif seg.startswith(BULLET):
            if not domains:
                continue
            current = {"text": seg[1:].strip()}
            domains[-1]["objectives"].append(current)
            naming = None
        elif current is not None:
            current["text"] = join(current["text"], seg)
        elif naming is not None:
            naming["name"] = join(naming["name"], seg)

    domains.sort(key=lambda d: d["position"])
    return [{"id": str(i), "name": tidy(d["name"]).rstrip(","), "weight": d["weight"],
             "objectives": [{"id": f"{i}.{j}", "text": tidy(o["text"])} for j, o in enumerate(d["objectives"], 1)]}
            for i, d in enumerate(domains, 1)]


def check_tree(domains: list[dict]) -> list[str]:
    """What a real curriculum always satisfies: domains, objectives in each, weights summing to 100."""
    problems = [] if domains else ["no domains found"]
    problems += [f"domain {d['id']} ({d['name']}) has no objectives" for d in domains if not d["objectives"]]
    total = sum(number(d["weight"]) for d in domains)
    if domains and round(total, 2) != 100:
        problems.append(f"domain weights sum to {total}, not 100")
    return problems


def tree_sha256(domains: list[dict]) -> str:
    """Hash of the objective tree itself, so two PDFs with the same objectives compare equal."""
    canon = [[normalize(d["name"]), number(d["weight"]), [normalize(o["text"]) for o in d["objectives"]]]
             for d in domains]
    return sha256_text(json.dumps(canon, ensure_ascii=False, separators=(",", ":")))


def snapshot(domains: list[dict], *, cert: str, version: str, repo: str, commit: str, path: str,
             committed: str, sha256: str) -> dict:
    problems = check_tree(domains)
    if problems:
        raise SystemExit("extraction looks wrong:\n  " + "\n  ".join(problems))
    return {
        "cert": cert,
        "version": str(version),
        "source": {"repo": repo, "commit": commit, "path": path,
                   "url": f"https://github.com/{repo}/raw/{commit}/{path}",
                   "sha256": sha256, "committed": committed},
        "extraction": {"tool": "scripts/curriculum_diff.py extract",
                       "method": "pdftotext -layout; two columns split at the widest gap between marker starts"},
        "tree_sha256": tree_sha256(domains),
        "domains": domains,
    }


def _extract_args(p: argparse.ArgumentParser) -> None:
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--pdf", type=Path)
    src.add_argument("--text", type=Path, help="pdftotext -layout output instead of the PDF (then pass --sha256)")
    p.add_argument("--sha256", help="the PDF's sha256 (computed from --pdf when not given)")
    for flag in ("--cert", "--version", "--repo", "--commit", "--path", "--committed"):
        p.add_argument(flag, required=True)
    p.add_argument("-o", "--out")
    p.add_argument("--check", action="store_true", help="fail if --out is not what the PDF produces")


def _extract_run(args) -> int:
    if args.pdf:
        text = subprocess.run(["pdftotext", "-layout", str(args.pdf), "-"], check=True, capture_output=True,
                              text=True, encoding="utf-8").stdout
    else:
        text = args.text.read_text(encoding="utf-8")
    digest = args.sha256 or hashlib.sha256(args.pdf.read_bytes()).hexdigest()
    snap = snapshot(parse_layout(text), cert=args.cert, version=args.version, repo=args.repo,
                    commit=args.commit, path=args.path, committed=args.committed, sha256=digest)
    return write(dump_yaml(snap), args.out, args.check)


COMMANDS["extract"] = ("freeze an official PDF as a syllabus snapshot", _extract_args, _extract_run)


# ==== main ====

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, (help_, add_arguments, _) in COMMANDS.items():
        add_arguments(sub.add_parser(name, help=help_))
    args = ap.parse_args(argv)
    return COMMANDS[args.cmd][2](args)


if __name__ == "__main__":
    sys.exit(main())
