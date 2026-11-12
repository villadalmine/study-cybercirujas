#!/usr/bin/env python3
"""Replace a dead or moved citation URL in a topic, in every language, without re-translating.

`check_citations.py` finds a URL that no longer resolves (a 404 on an official domain is usually a
page that moved). The URL is the same in every language, so fixing it is not a translation: editing
the English by hand and then running `teach cert translate --force` pays a model to copy the text
back, and editing every file by hand leaves each translation's `source_sha256` pointing at the old
English (check_source_chain.py -> stale).

    scripts/fix_citation.py nca-aiio 1.8 OLD_URL NEW_URL            # replace, re-stamp, print what changed
    scripts/fix_citation.py nca-aiio 1.8 OLD_URL NEW_URL --dry-run  # the same report, nothing written

1. every text file under `certs/<cert>/<topic>/` gets NEW_URL where it cites OLD_URL as a WHOLE URL
   (the URL pattern of check_source_chain.py, trailing punctuation aside); a longer URL that merely
   starts with OLD_URL is refused, never rewritten: each of those is its own citation to check;
2. a translation whose `source_sha256` matched its source BEFORE the edit gets the new hash; one that
   was already stale stays stale (this script never hides a real drift);
3. a lab.yaml v2 whose `derived_from.content_sha256` matched before is re-stamped the same way.

Everything is computed on a scratch copy first; files are written only when every step succeeded,
with their line endings kept. A translation that cites the URL a different number of times than its
source is reported. It refuses when OLD_URL is not cited, when NEW_URL is not an http(s) URL, and,
unless `--offline`, when NEW_URL does not answer 200 itself (a redirect is refused, naming where it
leads). Quality blocks are not touched: run `scripts/quality_score.py` after it.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core.certs import chain_sha256, translation_source_sha256  # noqa: E402

TEXT = (".md", ".sh", ".yaml", ".yml")
URL = re.compile(r"https?://[^\s)\]>\"'`]+")  # check_source_chain.py's citation pattern
TRAIL = ".,;:*_"  # punctuation that ends a sentence, not a URL (curriculum_citations.py)


def _read(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as f:  # CRLF stays CRLF
        return f.read()


def _write(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _meta(path: Path) -> dict:
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else {}


def replace_url(text: str, old: str, new: str) -> tuple[str, int, list[str]]:
    """(text with every whole-URL `old` replaced, how many, longer URLs that start with `old`)."""
    out, last, count, longer = [], 0, 0, []
    for match in URL.finditer(text):
        url = match.group(0).rstrip(TRAIL)
        if url == old:
            out.append(text[last:match.start()] + new)
            last = match.start() + len(url)
            count += 1
        elif url.startswith(old):
            longer.append(url)
    out.append(text[last:])
    return "".join(out), count, longer


def current_links(topic_dir: Path, root: Path) -> dict[Path, str]:
    """Files whose recorded hash matches what they derive from now: they get the new hash after the edit."""
    keep: dict[Path, str] = {}
    for meta_file in sorted(topic_dir.glob("*/meta.yaml")):
        meta = _meta(meta_file)
        source = meta.get("translated_from")
        if source and meta.get("source_sha256") == translation_source_sha256(topic_dir, str(source)):
            keep[meta_file] = "translation"
    lab = topic_dir / "lab" / "lab.yaml"
    derived = _meta(lab).get("derived_from") or {}
    if derived.get("content") and derived.get("content_sha256") == chain_sha256(root / derived["content"]):
        keep[lab] = "lab"
    return keep


def _restamp(text: str, key: str, old: str, new: str, where: Path) -> str:
    """One hash changed in place, keeping layout and comments; refused unless it appears exactly once."""
    if text.count(old) != 1 or not re.search(rf"^\s*{key}:\s*['\"]?{old}['\"]?\s*$", text, re.M):
        raise SystemExit(f"{where}: expected '{key}: {old}' exactly once; nothing written")
    return text.replace(old, new)


def plan(cert: str, topic: str, old: str, new: str, root: Path = REPO) -> tuple[dict[Path, str], list[str]]:
    """Every file's new text and the report, computed without touching the topic."""
    topic_dir = root / "certs" / cert / topic
    if not topic_dir.is_dir():
        raise SystemExit(f"{topic_dir} does not exist")
    if not new.startswith(("https://", "http://")) or old == new:
        raise SystemExit("NEW_URL must be an http(s) URL different from OLD_URL")
    keep = current_links(topic_dir, root)
    edits: dict[Path, str] = {}
    counts: dict[Path, int] = {}
    longer: set[str] = set()
    for f in sorted(topic_dir.rglob("*")):
        if f.is_file() and f.suffix in TEXT:
            text, n, more = replace_url(_read(f), old, new)
            longer.update(more)
            if n:
                edits[f], counts[f] = text, n
    if longer:
        raise SystemExit(f"{old} is also the start of longer URLs, which are separate citations; fix each "
                         "with its own exact OLD_URL. Nothing written:\n  " + "\n  ".join(sorted(longer)))
    if not edits:
        raise SystemExit(f"{old} is not cited under {topic_dir} as a whole URL")
    report = [f"replace in {f.relative_to(root)} ({n}x)" for f, n in counts.items()]
    for meta_file in sorted(topic_dir.glob("*/meta.yaml")):
        source = _meta(meta_file).get("translated_from")
        for name in ("content.md", "exercises.md"):
            here, there = meta_file.parent / name, topic_dir / str(source) / name
            if source and counts.get(here, 0) != counts.get(there, 0):
                report.append(f"warning: {here.relative_to(root)} cites it {counts.get(here, 0)}x, "
                              f"its source {counts.get(there, 0)}x: the translation has diverged")

    # The new hashes come from a scratch copy that holds the edited files.
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp) / "certs" / cert / topic
        shutil.copytree(topic_dir, scratch)
        for f, text in edits.items():
            _write(scratch / f.relative_to(topic_dir), text)
        for path, why in keep.items():
            text = edits.get(path, _read(path))
            if why == "translation":
                meta = _meta(path)
                key, was = "source_sha256", meta["source_sha256"]
                fresh = translation_source_sha256(scratch, str(meta["translated_from"]))
            else:
                derived = _meta(path)["derived_from"]
                key, was = "content_sha256", derived["content_sha256"]
                inside = Path(tmp) / derived["content"]
                fresh = chain_sha256(inside if inside.exists() else root / derived["content"])
            if fresh != was:
                edits[path] = _restamp(text, key, was, fresh, path)
                report.append(f"re-stamp {path.relative_to(root)} {key}")
    return edits, report


def fix(cert: str, topic: str, old: str, new: str, root: Path = REPO, dry_run: bool = False) -> list[str]:
    edits, report = plan(cert, topic, old, new, root)
    if not dry_run:
        for path, text in edits.items():
            _write(path, text)
    return report


def resolves(url: str) -> tuple[bool, str]:
    """(answers 200 at exactly this URL, where it ended or why it failed)."""
    request = urllib.request.Request(url, headers={"User-Agent": "study-cybercirujas fix_citation"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status == 200 and response.geturl() == url, response.geturl()
    except Exception as error:  # noqa: BLE001 - any failure means "do not write this URL"
        return False, str(error)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cert")
    ap.add_argument("topic")
    ap.add_argument("old_url")
    ap.add_argument("new_url")
    ap.add_argument("--dry-run", action="store_true", help="print what would change, write nothing")
    ap.add_argument("--offline", action="store_true", help="do not check that NEW_URL answers 200")
    ap.add_argument("--root", type=Path, default=REPO, help="the checkout to fix (default: this one)")
    args = ap.parse_args(argv)
    if not args.offline:
        ok, where = resolves(args.new_url)
        if not ok:
            raise SystemExit(f"{args.new_url} does not answer 200 itself ({where}): "
                             "not writing a citation that does not resolve as written")
    for line in fix(args.cert, args.topic, args.old_url, args.new_url, args.root.resolve(), args.dry_run):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
