#!/usr/bin/env python3
"""Replace a dead or moved citation URL in a topic, in every language, without re-translating.

`check_citations.py` finds a URL that no longer resolves (a 404 on an official domain is usually a
page that moved). The URL is the same in every language, so fixing it is not a translation: editing
the English by hand and then running `teach cert translate --force` pays a model to copy the text
back, and editing every file by hand leaves each translation's `source_sha256` pointing at the old
English (check_source_chain.py -> stale).

    scripts/fix_citation.py nca-aiio 1.8 OLD_URL NEW_URL            # replace, re-stamp, print what changed
    scripts/fix_citation.py nca-aiio 1.8 OLD_URL NEW_URL --dry-run

1. every text file under `certs/<cert>/<topic>/` that contains OLD_URL gets NEW_URL, exactly (no regex);
2. a translation whose `source_sha256` matched its source BEFORE the edit gets the new hash; one that
   was already stale stays stale (this script never hides a real drift);
3. a lab.yaml v2 whose `derived_from.content_sha256` matched before is re-stamped the same way.

It refuses when OLD_URL is not cited in the topic, when NEW_URL is not an http(s) URL, and, unless
`--offline`, when NEW_URL does not answer 200. Quality blocks are not touched: run
`scripts/quality_score.py` after it, as after any content change.
"""
from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core.certs import chain_sha256, translation_source_sha256  # noqa: E402

TEXT = (".md", ".sh", ".yaml", ".yml")


def _meta(path: Path) -> dict:
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


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


def _set_key(path: Path, key: str, old: str, new: str) -> None:
    """Change one hash in place, keeping the file's layout and comments."""
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected {key} {old} exactly once")
    path.write_text(text.replace(old, new), encoding="utf-8")


def fix(cert: str, topic: str, old: str, new: str, root: Path = REPO, dry_run: bool = False) -> list[str]:
    topic_dir = root / "certs" / cert / topic
    if not topic_dir.is_dir():
        raise SystemExit(f"{topic_dir} does not exist")
    if not new.startswith(("https://", "http://")) or old == new:
        raise SystemExit("NEW_URL must be an http(s) URL different from OLD_URL")
    files = [f for f in sorted(topic_dir.rglob("*"))
             if f.is_file() and f.suffix in TEXT and old in f.read_text(encoding="utf-8", errors="replace")]
    if not files:
        raise SystemExit(f"{old} is not cited under {topic_dir}")
    keep = current_links(topic_dir, root)
    report = [f"replace in {f.relative_to(root)} ({f.read_text(encoding='utf-8').count(old)}x)" for f in files]
    if dry_run:
        return report + [f"re-stamp {p.relative_to(root)} ({why})" for p, why in keep.items()]
    for f in files:
        f.write_text(f.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")
    for path, why in keep.items():
        if why == "translation":
            meta = _meta(path)
            fresh = translation_source_sha256(topic_dir, str(meta["translated_from"]))
            if fresh != meta["source_sha256"]:
                _set_key(path, "source_sha256", meta["source_sha256"], fresh)
                report.append(f"re-stamp {path.relative_to(root)} source_sha256")
        else:
            derived = _meta(path)["derived_from"]
            fresh = chain_sha256(root / derived["content"])
            if fresh != derived["content_sha256"]:
                _set_key(path, "content_sha256", derived["content_sha256"], fresh)
                report.append(f"re-stamp {path.relative_to(root)} derived_from.content_sha256")
    return report


def resolves(url: str) -> bool:
    request = urllib.request.Request(url, headers={"User-Agent": "study-cybercirujas fix_citation"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status == 200
    except Exception:  # noqa: BLE001 - any failure means "do not write this URL"
        return False


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
    if not args.offline and not resolves(args.new_url):
        raise SystemExit(f"{args.new_url} does not answer 200: not writing a citation that does not resolve")
    for line in fix(args.cert, args.topic, args.old_url, args.new_url, args.root.resolve(), args.dry_run):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
