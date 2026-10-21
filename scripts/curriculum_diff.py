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
import difflib
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import curriculum_citations as cc  # noqa: E402

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


# ==== diff ====
#
#   scripts/curriculum_diff.py diff certs/cka.md syllabi/cka/v1.37.yaml     # JSON on stdout
#
# Either side is a snapshot (syllabi/<cert>/v<ver>.yaml) or a frozen
# certs/<cert>.md, whose `topic: "N - Name"` gives the domain. CNCF publishes a
# weight per domain only; the per-objective weights in certs/<cert>.md are that
# weight split over the objectives, so they are never compared: a domain's weight
# is the sum of its objectives'. Matching, old tree to new tree, in this order:
# 1. Domains match by normalized name, the rest by similarity >= MATCH.
# 2. Objectives match by normalized text (see `normalize`).
# 3. The remaining pairs are scored with difflib's ratio (autojunk off) and taken
#    greedily, highest first, ties by position: ratio >= REWORD is `reworded`,
#    MATCH <= ratio < REWORD is `changed`, below MATCH they are `removed` + `added`.
# 4. A matched objective whose domain is not its old domain's match is `moved`.

REWORD = 0.90   # at or above: the same objective, new wording
MATCH = 0.60    # at or above (and below REWORD): the same slot, substantively changed
FROZEN_DOMAIN = re.compile(r"^\s*(\d+)\s*-\s*(.+?)\s*$")


def similarity(a: str, b: str) -> float:
    return round(difflib.SequenceMatcher(None, normalize(a), normalize(b), autojunk=False).ratio(), 4)


def load_syllabus(path: Path) -> dict:
    """A syllabus as {version, domains, file_sha256}: a snapshot YAML, or a frozen certs/<cert>.md."""
    text = path.read_text(encoding="utf-8")
    if path.suffix != ".md":
        return dict(yaml.safe_load(text), file_sha256=sha256_text(text))
    front = yaml.safe_load(text.split("---", 2)[1])
    domains: dict[str, dict] = {}
    for t in front.get("topics") or []:
        m = FROZEN_DOMAIN.match(str(t.get("topic") or ""))
        did, name = (m.group(1), m.group(2)) if m else ("0", str(t.get("topic") or ""))
        d = domains.setdefault(did, {"id": did, "name": name, "weight": 0.0, "objectives": []})
        d["weight"] += float(t.get("weight") or 0)
        d["objectives"].append({"id": str(t["id"]), "text": tidy(str(t.get("title") or ""))})
    return {"cert": front.get("cert"), "version": str(front.get("version")), "file_sha256": sha256_text(text),
            "domains": [dict(d, weight=number(d["weight"])) for d in domains.values()]}


def _match_domains(old: list[dict], new: list[dict]) -> dict[str, str]:
    """old domain id -> new domain id."""
    by_name = {normalize(d["name"]): d["id"] for d in new}
    pairs = {d["id"]: by_name[normalize(d["name"])] for d in old if normalize(d["name"]) in by_name}
    taken = set(pairs.values())
    scored = sorted((-similarity(a["name"], b["name"]), i, j, a["id"], b["id"])
                    for i, a in enumerate(old) if a["id"] not in pairs
                    for j, b in enumerate(new) if b["id"] not in taken)
    for score, _, _, a, b in scored:
        if -score >= MATCH and a not in pairs and b not in taken:
            pairs[a] = b
            taken.add(b)
    return pairs


def _match_objectives(oobj: list, nobj: list) -> list[tuple[int, int, float]]:
    """(old index, new index, similarity): exact normalized text first, then greedy by ratio >= MATCH."""
    pairs, used_o, used_n = [], set(), set()
    index: dict[str, list[int]] = {}
    for j, (o, _) in enumerate(nobj):
        index.setdefault(normalize(o["text"]), []).append(j)
    for i, (o, _) in enumerate(oobj):
        j = next((j for j in index.get(normalize(o["text"]), []) if j not in used_n), None)
        if j is not None:
            pairs.append((i, j, 1.0))
            used_o.add(i)
            used_n.add(j)
    scored = sorted((-similarity(a["text"], b["text"]), i, j)
                    for i, (a, _) in enumerate(oobj) if i not in used_o
                    for j, (b, _) in enumerate(nobj) if j not in used_n)
    for score, i, j in scored:
        if -score >= MATCH and i not in used_o and j not in used_n:
            pairs.append((i, j, -score))
            used_o.add(i)
            used_n.add(j)
    return sorted(pairs)


def diff(old: dict, new: dict) -> dict:
    """The machine-readable difference between two syllabi. Pure: same inputs, same output."""
    odom = {d["id"]: d for d in old["domains"]}
    ndom = {d["id"]: d for d in new["domains"]}
    dmap = _match_domains(old["domains"], new["domains"])
    oobj = [(o, d) for d in old["domains"] for o in d["objectives"]]
    nobj = [(o, d) for d in new["domains"] for o in d["objectives"]]
    pairs = _match_objectives(oobj, nobj)

    out = {"unchanged": [], "reworded": [], "changed": [], "moved": [], "added": [], "removed": []}
    for i, j, score in pairs:
        (o, od), (n, nd) = oobj[i], nobj[j]
        entry = {"old_id": o["id"], "new_id": n["id"], "similarity": score}
        if dmap.get(od["id"]) != nd["id"]:
            out["moved"].append(dict(entry, text=n["text"], from_domain=od["name"], to_domain=nd["name"]))
        if score == 1.0:
            if dmap.get(od["id"]) == nd["id"]:
                out["unchanged"].append(dict(entry, text=n["text"]))
        else:
            out["reworded" if score >= REWORD else "changed"].append(dict(entry, old=o["text"], new=n["text"]))
    matched_o, matched_n = {i for i, _, _ in pairs}, {j for _, j, _ in pairs}
    out["removed"] = [{"old_id": o["id"], "text": o["text"], "domain": d["name"]}
                      for i, (o, d) in enumerate(oobj) if i not in matched_o]
    out["added"] = [{"new_id": n["id"], "text": n["text"], "domain": d["name"]}
                    for j, (n, d) in enumerate(nobj) if j not in matched_n]

    domains = {"renamed": [], "weight_changed": [], "added": [], "removed": []}
    for oid, nid in sorted(dmap.items()):
        if normalize(odom[oid]["name"]) != normalize(ndom[nid]["name"]):
            domains["renamed"].append({"old_id": oid, "new_id": nid, "old": odom[oid]["name"],
                                       "new": ndom[nid]["name"]})
        if number(odom[oid]["weight"]) != number(ndom[nid]["weight"]):
            domains["weight_changed"].append({"old_id": oid, "new_id": nid, "domain": ndom[nid]["name"],
                                              "old": number(odom[oid]["weight"]),
                                              "new": number(ndom[nid]["weight"])})
    domains["removed"] = [{"old_id": d["id"], "name": d["name"]} for d in old["domains"] if d["id"] not in dmap]
    mapped = set(dmap.values())
    domains["added"] = [{"new_id": d["id"], "name": d["name"]} for d in new["domains"] if d["id"] not in mapped]

    changes = sum(len(v) for k, v in out.items() if k != "unchanged") + sum(len(v) for v in domains.values())
    return {"identical": changes == 0, "thresholds": {"match": MATCH, "reword": REWORD},
            "old": {"version": str(old.get("version")), "objectives": len(oobj), "domains": len(odom)},
            "new": {"version": str(new.get("version")), "objectives": len(nobj), "domains": len(ndom)},
            "domains": domains, "objectives": out}


def _diff_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("old", type=Path)
    p.add_argument("new", type=Path)


def _diff_run(args) -> int:
    return write(dump_json(diff(load_syllabus(args.old), load_syllabus(args.new))), None, False)


COMMANDS["diff"] = ("diff two syllabi (snapshot .yaml or frozen certs/<cert>.md) as JSON", _diff_args, _diff_run)


# ==== plan ====
#
#   scripts/curriculum_diff.py plan docs/upgrades/<upgrade>.yaml [-o <upgrade>.plan.json] [--check]
#
# The spec names, per cert, `tracked` (the frozen syllabus the material was built
# against, default certs/<cert>.md), `target` (the new snapshot) and optionally
# `upstream_base` (the old version's own snapshot). The plan holds three diffs per
# cert: impact (tracked -> target, which drives the classes), upstream
# (upstream_base -> target: what the vendor changed) and drift (tracked ->
# upstream_base: where the frozen file already differed from its own PDF). Every
# topic of the tracked syllabus gets exactly one class, by CLASS_RULES in order;
# every new objective no topic covers is `new`. PLANNED_FILES says what each class
# may touch in the PRs that follow, which is what `guard` enforces.

CLASSES = ("keep", "revalidate", "regenerate", "new", "retire")
CLASS_RULES = (   # the plan and the report print exactly this table
    ("retire", "its objective is not in the new syllabus (removed, or below MATCH similarity to every new one)",
     "archive the topic directory; redirect its links"),
    ("regenerate", f"its objective changed: best match has MATCH ({MATCH}) <= similarity < REWORD ({REWORD})",
     "one PR through the whole content process (content, exercises, lab, translations)"),
    ("revalidate", "its objective was reworded (REWORD <= similarity < 1), moved to another domain, "
     "or its domain's published weight changed",
     "re-run every check against the new text; record the result in meta.yaml; a failed check makes it regenerate"),
    ("keep", "its objective text, domain and domain weight are identical",
     "no content change; only its listed technical version lines may be rewritten in place, by the version bump"),
    ("new", "an objective of the new syllabus that no topic covers",
     "a new topic directory, through the whole content process"),
)
# What each class may touch: `{t}` is certs/<cert>/<topic>, `{lang}` each language the topic has.
PLANNED_FILES = {
    "keep": [],
    "revalidate": ["{t}/{lang}/meta.yaml"],
    "regenerate": ["{t}/**"],
    "new": ["{t}/**"],
    "retire": ["{t}/**"],
}


def classify(d: dict, old: dict) -> dict[str, tuple[str, list[str], str | None, float | None]]:
    """old topic id -> (class, reasons, new objective id, similarity), by CLASS_RULES in order."""
    o = d["objectives"]
    by_old = lambda kind: {e["old_id"]: e for e in o[kind]}  # noqa: E731
    removed, changed, reworded, moved = by_old("removed"), by_old("changed"), by_old("reworded"), by_old("moved")
    matched = {**by_old("unchanged"), **reworded, **moved}
    weights = {w["old_id"]: w for w in d["domains"]["weight_changed"]}
    result = {}
    for dom in old["domains"]:
        for obj in dom["objectives"]:
            tid = obj["id"]
            if tid in removed:
                result[tid] = ("retire", ["objective removed"], None, None)
            elif tid in changed:
                c = changed[tid]
                result[tid] = ("regenerate", [f"objective changed (similarity {c['similarity']})"],
                               c["new_id"], c["similarity"])
            else:
                reasons = []
                if tid in reworded:
                    reasons.append(f"objective reworded (similarity {reworded[tid]['similarity']})")
                if tid in moved:
                    reasons.append(f"moved: {moved[tid]['from_domain']} -> {moved[tid]['to_domain']}")
                if dom["id"] in weights:
                    reasons.append(f"domain weight {weights[dom['id']]['old']}% -> {weights[dom['id']]['new']}%")
                result[tid] = ("revalidate" if reasons else "keep", reasons or ["unchanged"],
                               matched[tid]["new_id"], matched[tid]["similarity"])
    return result


def _glob(path: str, pattern: str) -> bool:
    return path.startswith(pattern[:-2]) if pattern.endswith("/**") else path == pattern


def inventory(root: Path, cert: str, topic: str) -> dict:
    t = root / "certs" / cert / topic
    langs = sorted(p.name for p in t.iterdir() if p.is_dir() and p.name != "lab") if t.is_dir() else []
    return {"dir": f"certs/{cert}/{topic}", "languages": langs, "lab": (t / "lab" / "lab.yaml").is_file()}


def planned(cls: str, inv: dict) -> list[str]:
    files = []
    for pattern in PLANNED_FILES[cls]:
        langs = inv["languages"] if "{lang}" in pattern else [None]
        files += [pattern.format(t=inv["dir"], lang=lang) for lang in langs]
    return files


# Below topic level. A `revalidate` or `regenerate` topic lists the sections (markdown headings) of
# its content.md and exercises.md that name what changed: the old domain name (moved), the old
# objective title verbatim (reworded or changed), or a weight line (domain weight changed). Only
# those sections are candidates for an edit; every other section stays byte-identical. Separately,
# every topic lists the lines that name the tracked version (`v1.35`, `1.35`): `curriculum` lines
# cite the curriculum document, `label` lines are headings or banners, `technical` lines are
# commands, outputs or prose about that Kubernetes version, the only ones a version bump may need
# to rewrite by hand. `# ...` lines inside code fences are not headings. Lab files (lab.yaml, *.sh)
# are scanned too, and all their version lines are technical: the runner reads `kubernetes:`.
DOC_FILES = ("content.md", "exercises.md")
HEADING = re.compile(r"^#{1,4} ")


FENCE = re.compile(r"^\s*(```|~~~)")


def _headings(text: str) -> list[bool]:
    """Per line: is it a markdown heading? A `# ...` line inside a code fence is a comment or an output, not one."""
    out, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
            out.append(False)
        else:
            out.append(not fenced and bool(HEADING.match(line)))
    return out


def _sections(text: str) -> list[tuple[int, str, str]]:
    """(first line number, heading, body) per markdown section; text before the first heading is line 1."""
    out, start, title, body = [], 1, "(top)", []
    for n, (line, heading) in enumerate(zip(text.splitlines(), _headings(text)), 1):
        if heading:
            if body or out:
                out.append((start, title, "\n".join(body)))
            start, title, body = n, line.lstrip("# ").strip(), [line]
        else:
            body.append(line)
    out.append((start, title, "\n".join(body)))
    return out


def minor_below(minor: str) -> str:
    return str(int(minor) - 1)


def scan(root: Path, cert: str, topic: str, langs: list[str], version: str, needles: list[tuple[str, str]],
         citation_want: dict | None = None) -> dict:
    """Sections that name a changed field, and lines that name the tracked version.

    Lab files (`lab/lab.yaml`: `kubernetes:`, `runner_image`; `lab/*.sh`) are scanned too: every version
    line there is `technical`, since the runner and the Killercoda export read them."""
    ver = re.compile(rf"(^|[^0-9.]){re.escape(version)}([^0-9]|$)")
    major, _, minor = version.partition(".")
    companion = (re.compile(rf"(^|[^0-9.])v{major}\.({minor_below(minor)})\.\d+(?!\d)")
                 if minor.isdigit() and int(minor) > 2 else None)
    sections, lines = [], {"curriculum": 0, "label": 0, "technical": [], "citations": []}
    topic_dir = root / "certs" / cert / topic
    docs = [(f"{lang}/{name}", True) for lang in langs for name in DOC_FILES]
    labs = sorted(p.relative_to(topic_dir).as_posix() for p in (topic_dir / "lab").glob("*")
                  if p.is_file() and (p.name == "lab.yaml" or p.suffix == ".sh")) if (topic_dir / "lab").is_dir() else []
    for name, is_doc in docs + [(lab, False) for lab in labs]:
        path = topic_dir / name
        if not path.is_file():
            continue
        rel = f"certs/{cert}/{topic}/{name}"
        text = path.read_text(encoding="utf-8")
        if is_doc:
            for start, title, body in _sections(text):
                why = [label for label, needle in needles if needle.casefold() in body.casefold()]
                if why:
                    sections.append({"file": rel, "line": start, "heading": title, "why": why})
        heads = _headings(text) if is_doc else [False] * len(text.splitlines())
        found = []
        for n, (line, heading) in enumerate(zip(text.splitlines(), heads), 1):
            if not ver.search(line):
                continue
            if is_doc and "curriculum" in line.casefold():
                lines["curriculum"] += 1
            elif is_doc and (heading or line.startswith("**")):
                lines["label"] += 1
            else:
                found.append(n)
        if is_doc and found and companion:
            # A sample that shows an upgrade names the version it starts from too ("Cluster version: v1.34.1"
            # next to a table "v1.34.1 -> v1.35.1"): a bump that moves only the tracked minor would leave
            # the sample contradicting itself. Same file, patch-qualified `v1.N.P` of the minor below.
            found = sorted(set(found) | {n for n, line in enumerate(text.splitlines(), 1) if companion.search(line)
                                         and "curriculum" not in line.casefold()})
        lines["technical"] += [f"{rel}:{n}" for n in found]
        if is_doc and citation_want:
            # Citation lines (#220): the curriculum version and link the material cites, against the catalog's target.
            lines["citations"] += [f"{rel}:{n}" for n, ln in enumerate(text.splitlines(), 1)
                                   if cc.fix_line(ln, citation_want) != ln]
    return {"sections": sections, "version_lines": lines}


def _needles(cls: str, reasons: list[str], obj: dict, dom: dict) -> list[tuple[str, str]]:
    if cls not in ("revalidate", "regenerate"):
        return []
    out = []
    if any(r.startswith("moved") for r in reasons):
        out.append((f"old domain: {dom['name']}", dom["name"]))
    if any(r.startswith(("objective reworded", "objective changed")) for r in reasons):
        out.append(("old objective title", obj["text"]))
    if any(r.startswith("domain weight") for r in reasons):
        out.append(("weight", "weight"))
    return out


def _ref(root: Path, file: str, data: dict) -> dict:
    return {"file": file, "version": data["version"], "sha256": data["file_sha256"],
            "source": data.get("source"), "tree_sha256": data.get("tree_sha256")}


def plan_cert(root: Path, cert: str, spec: dict) -> dict:
    tracked_file = spec.get("tracked") or f"certs/{cert}.md"
    tracked = load_syllabus(root / tracked_file)
    target = load_syllabus(root / spec["target"])
    impact = diff(tracked, target)
    classes = classify(impact, tracked)
    catalog = yaml.safe_load((root / "catalog.yaml").read_text(encoding="utf-8"))["certs"].get(cert, {}) \
        if (root / "catalog.yaml").is_file() else {}
    citation_want = cc.wanted(catalog, cert, root, strict=True) if catalog else None
    topics = []
    for dom in tracked["domains"]:
        for o in dom["objectives"]:
            cls, reasons, new_id, score = classes[o["id"]]
            inv = inventory(root, cert, o["id"])
            found = scan(root, cert, o["id"], inv["languages"], tracked["version"], _needles(cls, reasons, o, dom),
                         citation_want)
            files = planned(cls, inv)
            if cls in ("keep", "revalidate"):   # scoped edits: only files holding a listed section or line
                files = sorted(set(files) | {s["file"] for s in found["sections"]}
                               | {ref.rsplit(":", 1)[0] for ref in found["version_lines"]["technical"]
                                                                  + found["version_lines"]["citations"]})
            topics.append({"topic": o["id"], "title": o["text"], "domain": dom["name"], "class": cls,
                           "reasons": reasons, "maps_to": new_id, "similarity": score,
                           "languages": inv["languages"], "lab": inv["lab"], "planned_files": files, **found})
    new = [{"objective": a["new_id"], "title": a["text"], "domain": a["domain"], "class": "new",
            "planned_files": [f"certs/{cert}/<new topic for {a['new_id']}>/**"]}
           for a in impact["objectives"]["added"]]
    counts = {c: sum(1 for t in topics if t["class"] == c) for c in CLASSES}
    counts["new"] = len(new)
    topic_files = sorted(str(p.relative_to(root)) for p in (root / "certs" / cert).glob("*/**/*") if p.is_file())
    globs = [g for t in topics for g in t["planned_files"]]
    efficiency = {"topic_files": len(topic_files),
                  "planned_files": sum(1 for f in topic_files if any(_glob(f, g) for g in globs)),
                  "sections_to_edit": sum(len(t["sections"]) for t in topics),
                  "version_lines": {k: sum(len(t["version_lines"][k]) if k == "technical" else t["version_lines"][k]
                                           for t in topics) for k in ("curriculum", "label", "technical")}}
    out = {"cert": cert, "tracked": {k: v for k, v in _ref(root, tracked_file, tracked).items()
                                     if k in ("file", "version", "sha256")},
           "target": _ref(root, spec["target"], target),
           "impact": impact, "topics": topics, "new": new, "counts": counts, "efficiency": efficiency}
    if spec.get("upstream_base"):
        base = load_syllabus(root / spec["upstream_base"])
        out["upstream_base"] = _ref(root, spec["upstream_base"], base)
        out["upstream"] = diff(base, target)
        out["drift"] = diff(tracked, base)
    return out


def plan(root: Path, spec_file: str) -> dict:
    spec = yaml.safe_load((root / spec_file).read_text(encoding="utf-8"))
    return {"upgrade": spec["upgrade"], "milestone": spec.get("milestone"), "issue": spec.get("issue"),
            "spec": spec_file,
            "rules": [{"class": c, "rule": r, "action": a} for c, r, a in CLASS_RULES],
            "planned_files": PLANNED_FILES,
            "thresholds": {"match": MATCH, "reword": REWORD},
            "certs": {cert: plan_cert(root, cert, s) for cert, s in sorted(spec["certs"].items())}}


def _plan_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("spec", help="the upgrade spec, relative to the repository root")
    p.add_argument("-o", "--out", help="default: <spec>.plan.json")
    p.add_argument("--check", action="store_true", help="fail if --out is not what the inputs produce")


def _plan_run(args) -> int:
    out = args.out or str(Path(args.spec).with_suffix(".plan.json"))
    return write(dump_json(plan(REPO, args.spec)), out, args.check)


COMMANDS["plan"] = ("classify every topic of an upgrade spec", _plan_args, _plan_run)


# ==== guard ====
#
#   scripts/curriculum_diff.py guard docs/upgrades/<upgrade>.plan.json [--base origin/main | --files ...]
#
# A changed file under certs/<cert>/<topic>/ of a cert in the plan must be one of
# that topic's planned files; a directory that is not a topic yet is allowed only
# when the plan has a `new` objective for that cert. A topic with listed sections or
# version lines may also update its <lang>/meta.yaml, where the provenance of the edit
# goes. Everything else (certs/<cert>.md, catalog.yaml, code, docs) is not this guard's
# business: check_pr covers it.
#
# The allowlist is the plan as committed on the BASE (`git show <merge-base>:<plan>`), so
# a PR cannot widen its own scope by editing plan.json. Only the PR that adds the plan
# reads it from the head, and then it must be exactly what its inputs produce.

def allowed(path: str, plan_data: dict) -> bool:
    for cert, c in plan_data["certs"].items():
        prefix = f"certs/{cert}/"
        if not path.startswith(prefix):
            continue
        topic = path[len(prefix):].split("/", 1)[0]
        known = {t["topic"]: t for t in c["topics"]}
        if topic not in known:
            return bool(c["new"])
        t = known[topic]
        scoped = t["class"] in ("keep", "revalidate") and (t["sections"] or t["version_lines"]["technical"]
                                                           or t["version_lines"].get("citations"))
        rest = path[len(prefix) + len(topic) + 1:].split("/")
        if scoped and len(rest) == 2 and rest[1] == "meta.yaml":
            return True
        return any(_glob(path, g) for g in t["planned_files"])
    return True


def guard(plan_data: dict, changed: list[str]) -> list[str]:
    return [f for f in changed if not allowed(f, plan_data)]


# Provenance of what an upgrade PR rewrites (audit items 1 and 4), enforced here even though the
# old corpus is not migrated: when content.md or exercises.md of a topic in the plan changes, the
# meta.yaml next to it must name a real model id (not a CLI or alias name), carry the effort and the
# sha256 of the prompt, and say the language of its own directory. A hand edit says `model: human`; a scripted version bump records `tool_edit` (see tool_edit_ok).
ALIASES = {"", "claude", "agy", "cheap", "codex", "gemini", "opus", "sonnet", "haiku", "unknown", "none"}


def cite_checker(base_text):
    """(file, old line, new line) -> True when the new line is what the citation fix writes from the catalog on the BASE.

    Plan-free on purpose: the catalog says what each cert's citations must read, so any line `fix_line` would change may
    be rewritten to exactly that, in a topic the plan keeps or revalidates, with no widening of the plan."""
    try:
        data = yaml.safe_load(base_text("catalog.yaml") or "")
    except yaml.YAMLError:
        data = None
    certs = data.get("certs", {}) if isinstance(data, dict) else {}

    def ok(f: str, old: str, new: str) -> bool:
        parts = f.split("/")
        return (len(parts) > 2 and parts[0] == "certs" and parts[1] in certs
                and cc.fix_line(old, cc.wanted(certs[parts[1]], parts[1], strict=True)) == new)

    def meta(f: str, old: str, new: str) -> bool:
        parts = f.split("/")
        return (len(parts) > 2 and parts[0] == "certs" and parts[1] in certs
                and cc.meta_ok(old, new, cc.wanted(certs[parts[1]], parts[1], strict=True)))
    ok.meta = meta
    return ok


def citation_files_ok(plan_data: dict, f: str, base_text, head_text, cite_ok) -> bool:
    """A file the plan does not list may still change when every changed line is the citation fix (#220)."""
    parts = f.split("/")
    if len(parts) < 5 or parts[0] != "certs" or parts[1] not in plan_data["certs"]:
        return False
    topics = {t["topic"]: t["class"] for t in plan_data["certs"][parts[1]]["topics"]}
    if topics.get(parts[2]) not in ("keep", "revalidate"):
        return False
    old, new = base_text(f), head_text(f)
    if old is None or new is None:
        return False
    if parts[-1] == "meta.yaml":
        return cite_ok.meta(f, old, new)
    is_lab_script = len(parts) > 5 and parts[3] == "lab" and parts[-1].endswith(".sh")
    if (parts[-1] not in DOC_FILES and not is_lab_script) or len(old.splitlines()) != len(new.splitlines()):
        return False
    return all(cite_ok(f, x, y) for x, y in zip(old.splitlines(), new.splitlines()) if x != y)


TOOLS = {"scripts/upgrade_versions.py"}      # the only scripted editor a meta.yaml may name in `tool_edit`


def load_pins(plan_data: dict, base_text) -> dict | None:
    """The upgrade's pins file as committed on the base (`<spec>.pins.yaml` next to the spec), or None."""
    spec = plan_data.get("spec")
    text = base_text(str(Path(spec).with_suffix(".pins.yaml"))) if spec else None
    return (yaml.safe_load(text) or None) if text else None


def _listed(topic: dict) -> dict[str, set]:
    out: dict[str, set] = {}
    for ref in topic["version_lines"]["technical"]:
        f, n = ref.rsplit(":", 1)
        out.setdefault(f, set()).add(int(n))
    return out


def tool_edit_ok(root: Path, plan_data: dict, directory: str, meta: dict, changed: list[str],
                 base_text, head_text) -> bool:
    """A scripted edit stands in for a model's effort and prompt hash, and only for what the script can have done.

    All of these hold, or the topic needs the model fields like any other rewrite:
    - the topic is `keep` or `revalidate` in the plan (a regenerated one is model work);
    - `tool_edit.tool` is in TOOLS and is the pins file's `tool`, and the tool's sha256 now, the one recorded in
      the meta.yaml and the pins file's `tool_sha256` (read from the BASE) are the same: a script changed in the
      PR, or another script with its own hash, does not pass;
    - every changed doc file of the directory keeps its line count, and each line that differs is a technical
      version line the plan lists AND is exactly what the script's own function writes for the line it replaced
      (`echo pwned` on a listed line is refused)."""
    cite_ok = cite_checker(base_text)
    edit = meta.get("tool_edit")
    pins = load_pins(plan_data, base_text)
    if not isinstance(edit, dict) or edit.get("tool") not in TOOLS or not pins or pins.get("tool") != edit["tool"]:
        return False
    _, cert, topic, _ = (directory.split("/") + [""] * 4)[:4]
    t = {x["topic"]: x for x in plan_data["certs"].get(cert, {}).get("topics", [])}.get(topic)
    tool = root / edit["tool"]
    if t is None or t["class"] not in ("keep", "revalidate") or not tool.is_file():
        return False
    sha = hashlib.sha256(tool.read_bytes()).hexdigest()
    if not (sha == edit.get("script_sha256") == pins.get("tool_sha256")):
        return False
    listed = _listed(t)
    for f in changed:
        if not f.startswith(directory + "/") or Path(f).name not in DOC_FILES:
            continue
        old, new = base_text(f), head_text(f)
        if old is None or new is None or len(old.splitlines()) != len(new.splitlines()):
            return False
        for n, (x, y) in enumerate(zip(old.splitlines(), new.splitlines()), 1):
            if x != y and not ((n in listed.get(f, set()) and uv_rewrite(x, pins) == y) or cite_ok(f, x, y)):
                return False
    return True


def uv_rewrite(line: str, pins: dict) -> str:
    import upgrade_versions          # scripts/ is on sys.path when this file runs or is imported as a module
    return upgrade_versions.rewrite(line, pins)


def wrong_rewrites(plan_data: dict, changed: list[str], base_text, head_text) -> list[str]:
    """A technical version line the plan lists may only become what the upgrade's own script writes for it.

    Applies to every listed line (material and labs), when the upgrade has a pins file on the base. Without the
    check, a listed line could be replaced by anything and still be 'in the plan'."""
    pins = load_pins(plan_data, base_text)
    if not pins:
        return []
    cite_ok = cite_checker(base_text)
    listed: dict[str, set] = {}
    for c in plan_data["certs"].values():
        for t in c["topics"]:
            if t["class"] in ("keep", "revalidate"):
                for f, ns in _listed(t).items():
                    listed.setdefault(f, set()).update(ns)
    problems = []
    kept = {(cert, t["topic"]) for cert, c in plan_data["certs"].items() for t in c["topics"]
            if t["class"] in ("keep", "revalidate")}
    for f in changed:
        parts = f.split("/")
        if len(parts) == 5 and parts[0] == "certs" and parts[-1] == "meta.yaml" and (parts[1], parts[2]) in kept:
            old, new = base_text(f), head_text(f)
            if old is None or new is None:
                continue
            try:
                a, b = yaml.safe_load(old) or {}, yaml.safe_load(new) or {}
            except yaml.YAMLError:
                problems.append(f"{f}: does not parse")
                continue
            if a.get("sources") != b.get("sources") or a.get("quality") != b.get("quality"):
                if "tool_edit" not in b:
                    problems.append(f"{f}: `sources` or `quality` moved without the tool_edit stamp")
                elif not cite_ok.meta(f, old, new):
                    problems.append(f"{f}: a scripted edit may only move `sources` to what the citation fix writes "
                                    "(and the quality and tool_edit blocks)")
    for f in changed:
        if f not in listed:
            continue
        old, new = base_text(f), head_text(f)
        if old is None or new is None or len(old.splitlines()) != len(new.splitlines()):
            continue                  # unlisted_edits reports it
        for n, (x, y) in enumerate(zip(old.splitlines(), new.splitlines()), 1):
            if x != y and n in listed[f] and uv_rewrite(x, pins) != y and not cite_ok(f, x, y):
                problems.append(f"{f}:{n}: is not what scripts/upgrade_versions.py writes for the line it replaced")
    return problems


def provenance(root: Path, plan_data: dict, changed: list[str], base_text=lambda f: None,
               head_text=lambda f: None) -> list[str]:
    problems = []
    dirs = sorted({str(Path(f).parent) for f in changed
                   if Path(f).name in DOC_FILES and any(f.startswith(f"certs/{c}/") for c in plan_data["certs"])})
    for d in dirs:
        meta_path = root / d / "meta.yaml"
        meta = yaml.safe_load(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {}
        model = str(meta.get("model") or "").strip()
        if tool_edit_ok(root, plan_data, d, meta, changed, base_text, head_text):
            pass                   # a script rewrote the listed lines; the model fields still describe who wrote the rest
        elif model != "human":
            if model.casefold() in ALIASES or not re.search(r"\d", model):
                problems.append(f"{d}/meta.yaml: model {model!r} is not a model id")
            for key in ("effort", "prompt_sha256"):
                if not meta.get(key):
                    problems.append(f"{d}/meta.yaml: {key} is missing")
        if str(meta.get("lang") or "") != Path(d).name:
            problems.append(f"{d}/meta.yaml: lang {meta.get('lang')!r} is not its directory {Path(d).name!r}")
    return problems


def unlisted_edits(plan_data: dict, changed: list[str], base_text, head_text, cite_ok=None) -> list[str]:
    """Edits outside what the plan lists, in a doc file the plan scopes (a section or a version line).

    `base_text(path)` / `head_text(path)` return a file's text before and after (None if absent).
    A listed section may change freely; a listed technical version line may be rewritten in place;
    every other line must stay byte-identical. When lines are added or removed, sections are compared
    by position instead, and only listed sections may differ."""
    sections: dict[str, set] = {}
    lines: dict[str, set] = {}
    for c in plan_data["certs"].values():
        for t in c["topics"]:
            if t["class"] not in ("keep", "revalidate"):
                continue           # regenerate / retire / new own the whole directory
            if t["class"] == "revalidate":
                for s in t["sections"]:
                    sections.setdefault(s["file"], set()).add(s["heading"])
            for ref in t["version_lines"]["technical"]:
                f, n = ref.rsplit(":", 1)
                lines.setdefault(f, set()).add(int(n))
    cites = {ref.rsplit(":", 1)[0] for c in plan_data["certs"].values() for t in c["topics"]
             if t["class"] in ("keep", "revalidate") for ref in t["version_lines"].get("citations", [])}
    problems = []
    for f in changed:
        if f not in sections and f not in lines and f not in cites:
            continue
        old, new = base_text(f), head_text(f)
        if old is None or new is None:
            problems.append(f"{f}: added or deleted, but a scoped edit only rewrites what the plan lists")
            continue
        a, b = _sections(old), _sections(new)
        if len(old.splitlines()) == len(new.splitlines()):
            ends = [s for s, _, _ in a[1:]] + [len(old.splitlines()) + 1]
            free = {n for (s, title, _), end in zip(a, ends) if title in sections.get(f, ()) for n in range(s, end)}
            bad = [n for n, (x, y) in enumerate(zip(old.splitlines(), new.splitlines()), 1)
                   if x != y and n not in free and n not in lines.get(f, ())
                   and not (cite_ok and cite_ok(f, x, y))]
            if bad:
                problems.append(f"{f}: line(s) {', '.join(map(str, bad[:8]))} changed but are not listed in the plan")
        elif f not in sections or len(a) != len(b):
            problems.append(f"{f}: lines added or removed outside a listed section")
        else:
            problems += [f"{f}: section {ta!r} changed but is not listed in the plan"
                         for (_, ta, body_a), (_, _, body_b) in zip(a, b)
                         if body_a != body_b and ta not in sections[f]]
    return problems


def _git_text(ref: str | None, path: str) -> str | None:
    if ref is None:
        p = REPO / path
        return p.read_text(encoding="utf-8") if p.is_file() else None
    r = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=REPO, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def _guard_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("plan", type=Path)
    p.add_argument("--base", default="origin/main")
    p.add_argument("--files", nargs="*",
                   help="changed files (default: git diff --name-only BASE...HEAD, so commit first: "
                        "uncommitted edits are not seen)")


def _guard_run(args) -> int:
    files = args.files
    if files is None:
        files = subprocess.run(["git", "diff", "--name-only", f"{args.base}...HEAD"], cwd=REPO, check=True,
                               capture_output=True, text=True).stdout.split()
    base = subprocess.run(["git", "merge-base", args.base, "HEAD"], cwd=REPO, capture_output=True,
                          text=True).stdout.strip() or args.base
    rel = args.plan.resolve().relative_to(REPO).as_posix()
    committed = _git_text(base, rel)
    if committed is None:      # the PR that adds the plan: it must be what its inputs produce
        committed = args.plan.read_text(encoding="utf-8")
        if dump_json(plan(REPO, json.loads(committed)["spec"])) != committed:
            print(f"STALE: {rel} is not what its spec and inputs produce; regenerate it with `plan`")
            return 1
        print(f"plan: {rel} from the head (new in this PR, verified against its inputs)")
    else:
        print(f"plan: {rel} as committed on {base[:12]} (the base), not the head's copy")
    plan_data = json.loads(committed)
    base_t, head_t = (lambda f: _git_text(base, f)), (lambda f: _git_text(None, f))
    cite_ok = cite_checker(base_t)
    bad = [f for f in guard(plan_data, files) if not citation_files_ok(plan_data, f, base_t, head_t, cite_ok)]
    for f in bad:
        print(f"NOT PLANNED: {f}")
    scoped = unlisted_edits(plan_data, files, base_t, head_t, cite_ok)
    weak = provenance(REPO, plan_data, files, base_t, head_t)
    wrong = wrong_rewrites(plan_data, files, base_t, head_t)
    for p in scoped:
        print(f"OUT OF SCOPE: {p}")
    for p in weak:
        print(f"PROVENANCE: {p}")
    for p in wrong:
        print(f"WRONG REWRITE: {p}")
    print(f"guard: {len(files)} changed file(s), {len(bad)} outside the plan, {len(scoped)} out-of-scope "
          f"edit(s), {len(weak)} provenance problem(s), {len(wrong)} wrong rewrite(s)")
    return 1 if bad or scoped or weak or wrong else 0


COMMANDS["guard"] = ("fail if a PR touches a topic file the plan does not list", _guard_args, _guard_run)


# ==== render ====
#
#   scripts/curriculum_diff.py render docs/upgrades/<upgrade>.plan.json -o docs/upgrades/<upgrade>.md [--check]
#
# The plan as a markdown report: a pure function of the plan, so as deterministic as the plan.

def _cell(text) -> str:
    return str(text).replace("|", "\\|")


def _diff_lines(d: dict) -> list[str]:
    o, dm = d["objectives"], d["domains"]
    if d["identical"]:
        return ["- identical: no domain, weight or objective changed"]
    lines = [f"- domain weight: {w['domain']} {w['old']}% -> {w['new']}%" for w in dm["weight_changed"]]
    lines += [f"- domain renamed: {r['old']} -> {r['new']}" for r in dm["renamed"]]
    lines += [f"- domain added: {a['name']}" for a in dm["added"]]
    lines += [f"- domain removed: {r['name']}" for r in dm["removed"]]
    lines += [f"- moved: {m['old_id']} -> {m['new_id']} \"{m['text']}\" ({m['from_domain']} -> {m['to_domain']})"
              for m in o["moved"]]
    lines += [f"- reworded ({r['similarity']}): {r['old_id']} \"{r['old']}\" -> {r['new_id']} \"{r['new']}\""
              for r in o["reworded"]]
    lines += [f"- changed ({c['similarity']}): {c['old_id']} \"{c['old']}\" -> {c['new_id']} \"{c['new']}\""
              for c in o["changed"]]
    lines += [f"- added: {a['new_id']} \"{a['text']}\" ({a['domain']})" for a in o["added"]]
    lines += [f"- removed: {r['old_id']} \"{r['text']}\" ({r['domain']})" for r in o["removed"]]
    return lines


def _mermaid(p: dict) -> list[str]:
    """The upgrade flow, with this plan's sources and counts."""
    lines = ["```mermaid", "flowchart LR"]
    for cert, c in p["certs"].items():
        src = c["target"].get("source") or {}
        lines.append(f'    {cert}_pdf["{src.get("path")}<br/>{src.get("repo")} @ {(src.get("commit") or "")[:7]}'
                     f'<br/>sha256 {(src.get("sha256") or "")[:12]}"] -->|extract| {cert}_target["{c["target"]["file"]}"]')
        if "upstream" in c:
            same = "identical" if c["upstream"]["identical"] else "changed"
            lines.append(f'    {cert}_base["{c["upstream_base"]["file"]}"] -.->|upstream diff: {same}| {cert}_target')
        lines.append(f'    {cert}_tracked["{c["tracked"]["file"]}<br/>tracked v{c["tracked"]["version"]}"] --> {cert}_diff')
        lines.append(f'    {cert}_target --> {cert}_diff{{"diff + classify<br/>{cert}"}}')
        for cls in CLASSES:
            lines.append(f'    {cert}_diff --> {cert}_{cls}["{cls}: {c["counts"][cls]}"]')
    lines.append('    switch["final PR: tracked_version and objectives move<br/>'
                 'check_pr: upgrade milestone + Scope: exam-version"]')
    for cert in p["certs"]:
        lines += [f"    {cert}_{cls} --> switch" for cls in ("revalidate", "regenerate", "new", "retire")]
    lines.append("```")
    return lines


def render(p: dict) -> str:
    out = [f"# Upgrade plan: {p['upgrade']}", "",
           f"<!-- Generated by scripts/curriculum_diff.py render from {p['spec']}. Do not edit by hand. -->", "",
           f"Milestone: *{p['milestone']}* · umbrella issue #{p['issue']}", "",
           "## Counts", "", "| Cert | " + " | ".join(CLASSES) + " | topic files | planned | sections to edit | "
           "version lines (curriculum / label / technical) |",
           "| :--- |" + " ---: |" * (len(CLASSES) + 4)]
    for cert, c in p["certs"].items():
        e = c["efficiency"]
        v = e["version_lines"]
        out.append(f"| {cert} | " + " | ".join(str(c["counts"][k]) for k in CLASSES) +
                   f" | {e['topic_files']} | {e['planned_files']} | {e['sections_to_edit']} | "
                   f"{v['curriculum']} / {v['label']} / {v['technical']} |")
    out += ["", "## Flow", ""] + _mermaid(p)
    out += ["", "## Rules (from the code, not judgment)", "",
            f"Thresholds: MATCH = {p['thresholds']['match']}, REWORD = {p['thresholds']['reword']} "
            "(difflib ratio on normalized text). The first rule that applies wins.", "",
            "| Class | Rule | What happens | Files it may change |", "| :--- | :--- | :--- | :--- |"]
    for r in p["rules"]:
        files = ", ".join(f"`{f.format(t='certs/<cert>/<topic>', lang='<lang>')}`"
                          for f in p["planned_files"][r["class"]]) or "none"
        if r["class"] == "new":
            files = "`certs/<cert>/<new topic>/**`"
        elif r["class"] == "revalidate":
            files += ", the listed sections and the listed technical version lines"
        elif r["class"] == "keep":
            files = "the listed technical version lines, in place"
        out.append(f"| `{r['class']}` | {_cell(r['rule'])} | {_cell(r['action'])} | {files} |")
    for cert, c in p["certs"].items():
        src = c["target"].get("source") or {}
        out += ["", f"## {cert}", "",
                f"- Tracked (what the material was built against): `{c['tracked']['file']}` v{c['tracked']['version']}"
                f", sha256 `{c['tracked']['sha256'][:12]}…`",
                f"- Target: `{c['target']['file']}` v{c['target']['version']}, from "
                f"[{src.get('path')}]({src.get('url')}) @ `{(src.get('commit') or '')[:7]}`, "
                f"PDF sha256 `{src.get('sha256')}`"]
        if "upstream" in c:
            bsrc = c["upstream_base"].get("source") or {}
            base_v, new_v = c["upstream_base"]["version"], c["target"]["version"]
            out += [f"- Upstream base: `{c['upstream_base']['file']}` v{base_v}, from "
                    f"[{bsrc.get('path')}]({bsrc.get('url')}) @ `{(bsrc.get('commit') or '')[:7]}`, "
                    f"PDF sha256 `{bsrc.get('sha256')}`",
                    "", f"### What upstream changed (v{base_v} PDF -> v{new_v} PDF)", ""]
            out += _diff_lines(c["upstream"])
            out += ["", f"### Drift: frozen `{c['tracked']['file']}` vs its own v{base_v} PDF", ""]
            out += _diff_lines(c["drift"])
        out += ["", f"### Impact: frozen `{c['tracked']['file']}` -> v{c['target']['version']} (drives the classes)", ""]
        out += _diff_lines(c["impact"])
        out += ["", "### Per-topic plan", "",
                "| Topic | Objective | Class | Why | Maps to | Sections to edit | Version lines (c/l/t) | Langs | Lab |",
                "| :--- | :--- | :--- | :--- | :--- | ---: | :--- | :--- | :--- |"]
        for t in c["topics"]:
            v = t["version_lines"]
            out.append(f"| {t['topic']} | {_cell(t['title'])} | `{t['class']}` | {_cell('; '.join(t['reasons']))} | "
                       f"{t['maps_to'] or '—'} | {len(t['sections'])} | {v['curriculum']}/{v['label']}/"
                       f"{len(v['technical'])} | {','.join(t['languages'])} | {'yes' if t['lab'] else 'no'} |")
        for n in c["new"]:
            out.append(f"| — | {_cell(n['title'])} | `new` | not covered by any topic | {n['objective']} | — | — | — | — |")
        scoped = [(t["topic"], s) for t in c["topics"] for s in t["sections"]]
        if scoped:
            out += ["", "### Sections that name what changed", ""]
            out += [f"- {tid}: `{s['file']}` line {s['line']} \"{_cell(s['heading'])}\" ({', '.join(s['why'])})"
                    for tid, s in scoped]
        technical = [line for t in c["topics"] for line in t["version_lines"]["technical"]]
        if technical:
            out += ["", f"### Technical lines that name v{c['tracked']['version']}", "",
                    "Commands, outputs or prose about that Kubernetes version: the only version lines a bump may "
                    "need to rewrite by hand (the curriculum and label lines are mechanical).", ""]
            out += [f"- `{line}`" for line in technical]
    return "\n".join(out) + "\n"


def _render_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("plan", type=Path)
    p.add_argument("-o", "--out")
    p.add_argument("--check", action="store_true", help="fail if --out is not what the plan produces")


def _render_run(args) -> int:
    return write(render(json.loads(args.plan.read_text(encoding="utf-8"))), args.out, args.check)


COMMANDS["render"] = ("the plan as a markdown report", _render_args, _render_run)


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
