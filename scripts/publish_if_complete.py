#!/usr/bin/env python3
"""Publish when a certification becomes complete. Part of the pass, not a decision.

Finishing a certification and shipping it were two steps, and the second one
needed a human to notice the first had happened. That is the same shape as
STATUS.md going stale: a step that only runs when someone remembers is a step
that does not run.

A certification is complete when, for every topic in its syllabus and every
language it declares, content and exercises exist and clear the quality floor,
and every declared video is rendered. Derived from the tree — not from a status
field, not from what a generator reported — so a run that dies half way through
cannot produce a publishable state.

Idempotent, and that is the whole reason it can live in an unattended pass: it
publishes when the SET of complete certifications changes, and does nothing on
every pass where it has not. Building an identical image on a timer would burn
the cluster for no reason and make "did something change?" unanswerable from the
deploy history.

    scripts/publish_if_complete.py            # publish if the set grew
    scripts/publish_if_complete.py --dry-run  # what it would do, and why
    scripts/publish_if_complete.py --force    # publish regardless of the record

Costs no API quota. Needs kubectl and helm; if the cluster is unreachable it
reports and exits non-zero without touching the record, so the next pass retries.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import pipeline, quality  # noqa: E402

import yaml  # noqa: E402

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "teach-plat"
RECORD = STATE / "published.json"


def _topic_ids(cert: str) -> list[str]:
    path = REPO / "certs" / f"{cert}.md"
    if not path.exists():
        return []
    front = yaml.safe_load(path.read_text().split("---")[1]) or {}
    return [str(t["id"]) for t in front.get("topics") or []]


def is_complete(cert: str) -> tuple[bool, str]:
    """(complete, why not). Everything the certification declares must be there.

    Existence is checked explicitly rather than inferred from the quality floor:
    `quality.check_file` keys its rules on the filename and reports no problems
    for anything it does not recognise, so a missing file passing would be an
    accident of how it fails — and publishing on an accident is worse than not
    publishing at all.
    """
    ids = _topic_ids(cert)
    if not ids:
        return False, "no syllabus"
    cert_dir = REPO / "certs" / cert
    for lang in pipeline.languages_for(cert):
        for topic in ids:
            for kind in ("content.md", "exercises.md"):
                path = cert_dir / topic / lang / kind
                if not path.exists():
                    return False, f"{topic}/{lang}/{kind} missing"
                if quality.check_file(path):
                    return False, f"{topic}/{lang}/{kind} below the floor"
    for lang in pipeline.video_languages(cert):
        if not (REPO / "media" / "certs" / cert / lang / "video.mp4").exists():
            return False, f"video for {lang} not rendered"
    return True, ""


def complete_certs() -> list[str]:
    return sorted(c for c in pipeline.certs() if is_complete(c)[0])


def _record() -> list[str]:
    if not RECORD.exists():
        return []
    try:
        return list(json.loads(RECORD.read_text()).get("certs") or [])
    except (json.JSONDecodeError, OSError):
        return []


def _save(certs: list[str], tag: str) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps(
        {"certs": certs, "tag": tag,
         "at": datetime.datetime.now().isoformat(timespec="seconds")}, indent=2))


def publish(tag: str) -> bool:
    """Build in-cluster, then deploy — with the SAME tag passed to both.

    `TAG` defaults to a fresh timestamp per make invocation, so omitting it builds
    one tag and deploys another, and the deploy silently serves the previous
    image. Computing it once here is the only way the two agree.
    """
    for target in ("image-cluster", "deploy-local"):
        print(f"  make {target} TAG={tag}", flush=True)
        result = subprocess.run(["make", target, f"TAG={tag}"], cwd=REPO,
                                capture_output=True, text=True, timeout=3600)
        if result.returncode != 0:
            tail = (result.stdout + result.stderr).strip().splitlines()[-12:]
            print(f"  {target} failed; the record is left untouched so the next "
                  f"pass retries:\n    " + "\n    ".join(tail), flush=True)
            return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true",
                        help="publish even if the set has not changed")
    args = parser.parse_args()

    complete = complete_certs()
    published = _record()
    new = [c for c in complete if c not in published]

    if not complete:
        print("Nothing is complete yet; nothing to publish.")
        return 0
    if not new and not args.force:
        print(f"{len(complete)} certifications complete, all already published "
              f"({', '.join(complete)}). Nothing to do.")
        return 0

    reason = ("forced" if not new else
              f"newly complete: {', '.join(new)}")
    tag = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    print(f"Publishing — {reason}. {len(complete)} certifications in the image.",
          flush=True)
    if args.dry_run:
        print(f"  would build and deploy TAG={tag}")
        return 0

    if not publish(tag):
        return 1
    _save(complete, tag)
    print(f"Published {tag}: {', '.join(complete)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
