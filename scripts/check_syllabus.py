#!/usr/bin/env python3
"""Does the frozen syllabus cover the exam, or only its table of contents?

The quality floor asks "is this file good material" and every LPIC-3 305 file
passes it — 32 KB each, well structured, correct. It still teaches a third of the
exam, because the syllabus it was generated from has 3 topics and the exam has 14
objectives. No per-file check can see that: the defect is in the list of things to
write, not in anything written.

`tracker.snapshot_topics()` asks a model for the topics and validated exactly one
thing — that the weights sum to 100. An even split satisfies that perfectly, so
the guardrail was passed most easily by the worst answer: return the chapter
headings, divide 100 by their count, done. That is what happened, seven times.

Four signals, none of which needs a model, and each of which catches a different
way the list can be wrong:

1. **Uniform weights.** Real syllabi weight objectives by importance and never
   land on 33.33/33.33/33.34. Identical weights across more than two topics means
   nobody read a weight — they were computed from the count.

2. **One child per parent.** Ids `1.1, 2.1, 3.1, 4.1` are sub-numbering applied to
   a flat list. A real syllabus that numbers `<area>.<objective>` has areas with
   several objectives, or it would not number them.

3. **Source is an overview page.** `.../lpic-1-overview/` describes a
   certification; it does not list objectives. A syllabus built from one cannot be
   complete regardless of what it contains, and this is checkable without opening
   either.

4. **Upstream objective count** (`--upstream`, network, no quota). LPI publishes
   objective ids as `351.1`, `301.2` — a three-digit area and an index. Counting
   distinct matches on the official page is a regex, so it is deterministic and
   repeatable, and it is the authoritative answer rather than a smell.

Signals 1-3 are free and offline, so they gate `make verify`. Signal 4 is the one
that produced the numbers in the table, and needs the objectives URL to be in the
syllabus `sources` — which is also why signal 3 exists: a cert citing an overview
page has no URL to count against, and that is itself the finding.

    scripts/check_syllabus.py                # every syllabus, offline
    scripts/check_syllabus.py lpic-3-305     # one
    scripts/check_syllabus.py --upstream     # also count objectives at the source

Exit 1 if any syllabus looks fabricated.
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core.tracker import objective_ids as _objective_ids  # noqa: E402

# The same definition the snapshot validates against, imported rather than
# repeated: two copies of "what counts as an objective" would drift, and the
# check would stop agreeing with the thing it is checking.

# A page that describes a certification instead of listing its objectives. A
# syllabus sourced from one was never looking at the objectives at all.
OVERVIEW = re.compile(r"-overview/?$")

USER_AGENT = "teach-plat syllabus check (+https://github.com/villadalmine)"


def load_syllabus(path: Path) -> dict:
    try:
        return yaml.safe_load(path.read_text().split("---")[1]) or {}
    except (IndexError, yaml.YAMLError):
        return {}


def smells(topics: list[dict], sources: list[str]) -> list[str]:
    """Structural signs the topic list was computed rather than read. Offline."""
    found = []
    weights = [round(float(t.get("weight") or 0), 2) for t in topics]

    # 1. Weights derived from the count. `sum == 100` was the only rule, and
    #    dividing 100 by len(topics) passes it without reading a single weight.
    if len(topics) > 2 and len(set(weights)) <= 2 and max(weights) - min(weights) < 0.02:
        found.append(
            f"all {len(topics)} weights are {weights[0]:g} — that is 100 divided by the "
            f"topic count, not a weighting anyone published"
        )

    # 2. Sub-numbering with nothing under it.
    ids = [str(t.get("id", "")) for t in topics]
    children: dict[str, int] = {}
    for topic_id in ids:
        if "." in topic_id:
            children[topic_id.rsplit(".", 1)[0]] = children.get(topic_id.rsplit(".", 1)[0], 0) + 1
    if children and all(count == 1 for count in children.values()) and len(children) > 1:
        found.append(
            f"every one of the {len(children)} parents has exactly one child — the ids are "
            f"numbered as if there were sub-objectives, and there are none"
        )

    # 3. No source that could contain objectives. An overview page ALONGSIDE the
    #    objectives page is fine — it is extra context. An overview page as the
    #    only source is the finding: there was nothing there to read.
    overview = [s for s in sources if OVERVIEW.search(str(s))]
    if overview and not any("objectives" in str(s) for s in sources):
        found.append(
            f"the only source is an overview page ({overview[0]}) — it describes the "
            f"certification and does not list objectives, so nothing built from it can "
            f"be complete"
        )
    return found


def upstream_objectives(sources: list[str]) -> tuple[int | None, str | None]:
    """How many objectives the official page publishes. Network, no model."""
    total, used = 0, None
    for source in sources:
        url = str(source)
        if "objectives" not in url:
            continue
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read().decode("utf-8", "replace")
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
        # The page repeats each id in a summary and again in the detail.
        found = _objective_ids(body)
        if found:
            total += len(found)
            used = url if used is None else f"{used}, {url}"
    return (total or None), used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("certs", nargs="*", help="default: every syllabus")
    parser.add_argument("--upstream", action="store_true",
                        help="also count objectives at the official source (network)")
    args = parser.parse_args()

    paths = ([REPO / "certs" / f"{c}.md" for c in args.certs] if args.certs
             else sorted((REPO / "certs").glob("*.md")))

    suspect: list[tuple[str, list[str]]] = []
    short: list[tuple[str, int, int]] = []
    for path in paths:
        if not path.exists():
            print(f"no syllabus at {path}")
            return 2
        front = load_syllabus(path)
        topics = front.get("topics") or []
        if not topics:
            continue
        sources = front.get("sources") or []
        problems = smells(topics, sources)

        if args.upstream:
            count, url = upstream_objectives(sources)
            if count and count > len(topics):
                short.append((path.stem, len(topics), count))
                problems.append(
                    f"the official source lists {count} objectives and this syllabus has "
                    f"{len(topics)} — {count - len(topics)} are not covered at all ({url})"
                )
        if problems:
            suspect.append((path.stem, problems))

    if not suspect:
        print(f"{len(paths)} syllabi checked: topic lists look read, not computed.")
        return 0

    print(f"{len(suspect)} syllabi look fabricated rather than scraped:\n")
    for cert, problems in suspect:
        print(f"  {cert}")
        for problem in problems:
            print(f"    - {problem}")
        print()

    if short:
        print("Coverage, where the official page could be counted:\n")
        print(f"    {'cert':16} {'frozen':>7} {'upstream':>9} {'covered':>8}")
        for cert, have, want in sorted(short, key=lambda r: r[1] / r[2]):
            print(f"    {cert:16} {have:>7} {want:>9} {have / want:>7.0%}")
        print()

    print("A syllabus is the list of things to write. Content generated from a short one\n"
          "passes every per-file check and still omits the exam: re-snapshot before\n"
          "generating anything else for these.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
