#!/usr/bin/env python3
"""Are the citations pointing at official documentation, and whose?

`check_citations.py` asks whether a URL resolves. This asks a different question:
does it belong to a project we recognise as authoritative. A live URL to a blog
post is a worse citation than a dead one to kubernetes.io, because the dead link
is obviously broken while the blog quietly passes as a source.

The catalogue is `docs/sources.yaml`, and extending it is one entry — which is
the design: every topic here rests on some project's official docs, and the set
of projects grows with each certification.

An unrecognised domain is NOT reported as wrong. It is reported as unattributed,
for a human to either add to the catalogue or replace in the material. Calling it
an error would be false: the corpus cites 319 distinct domains and the long tail
is mostly legitimate primary sources nobody has catalogued yet.

    scripts/check_sources.py                    # whole corpus
    scripts/check_sources.py certs/kcsa         # one certification
    scripts/check_sources.py --unknown-only     # just what needs a decision

Costs no API quota.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core.generator import URL_RE  # noqa: E402

CATALOGUE = REPO / "docs" / "sources.yaml"
REFS_HEADING = re.compile(
    r"^#+\s*(?:[0-9]+[.)]?\s*)?(Referencias|References|Références|Referenzen|Referências)",
    re.I | re.M,
)


def catalogue() -> tuple[dict[str, str], set[str], dict]:
    """(domain -> project, neutral domains, raw config)."""
    data = yaml.safe_load(CATALOGUE.read_text()) or {}
    owner: dict[str, str] = {}
    for project, config in (data.get("projects") or {}).items():
        for domain in (config or {}).get("domains") or []:
            owner[domain.lower()] = project
    return owner, {d.lower() for d in data.get("neutral_domains") or []}, data


def cited_domains(path: Path) -> list[str]:
    """Hosts cited in the references section only. URLs in the body are examples
    and cluster addresses, not sources."""
    text = path.read_text(errors="replace")
    match = REFS_HEADING.search(text)
    if not match:
        return []
    return [re.sub(r"^https?://", "", url).split("/")[0].lower()
            for url in URL_RE.findall(text[match.end():])]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", default=["certs"])
    parser.add_argument("--unknown-only", action="store_true")
    args = parser.parse_args()

    owner, neutral, data = catalogue()
    files: list[Path] = []
    for raw in args.paths:
        path = Path(raw)
        files.extend(sorted(path.glob("**/content.md")) if path.is_dir() else [path])

    per_project: Counter[str] = Counter()
    unknown: Counter[str] = Counter()
    unknown_where: dict[str, set[str]] = defaultdict(set)
    total = 0
    for path in files:
        for domain in cited_domains(path):
            total += 1
            if domain in owner:
                per_project[owner[domain]] += 1
            elif domain in neutral:
                per_project["(neutral)"] += 1
            else:
                unknown[domain] += 1
                unknown_where[domain].add(str(path.parent.parent.parent.name))

    if not total:
        print("No citations found in those paths.")
        return 0

    known = total - sum(unknown.values())
    if not args.unknown_only:
        print(f"{total:,} citations · {known:,} attributed to a catalogued project "
              f"({100*known/total:.0f}%) · {len(data.get('projects') or {})} projects catalogued\n")
        for project, count in per_project.most_common(15):
            print(f"  {count:6,}  {project}")

    if unknown:
        print(f"\n{sum(unknown.values()):,} citations from {len(unknown)} "
              f"uncatalogued domains — add the good ones to docs/sources.yaml, "
              f"replace the rest in the material:\n")
        for domain, count in unknown.most_common(25):
            certs = ", ".join(sorted(unknown_where[domain])[:3])
            print(f"  {count:5}  {domain:44} ({certs})")
    else:
        print("\nEvery cited domain is catalogued.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
