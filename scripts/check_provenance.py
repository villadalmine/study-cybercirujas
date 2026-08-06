#!/usr/bin/env python3
"""Guardrails: content must be traceable, accounted for, and authored correctly.

The quality floor answers "is this material good enough". It cannot answer "where
did this come from" or "does the pipeline know it exists", and those are the two
ways content has actually gone wrong when more than one agent works the repo.

Three checks, all mechanical, none costing API quota:

1. **Provenance.** Every `<topic>/<lang>/` with content must have a `meta.yaml`
   naming the backend, model and date. Files that appear without one cannot be
   audited, reproduced, or blamed — and this has happened (lpic-2/1.1 and 1.2 on
   2026-08-05).

2. **Bookkeeping.** The syllabus `status` must match the disk. A topic marked
   `pending` whose files exist means STATUS.md and the audit are both lying, in
   opposite directions: the matrix under-reports and the work queue keeps
   offering finished work.

3. **Ordering.** A certification's content comes before its video: a video
   narrates material that must already exist and have been verified. A video with
   no content behind it is a claim about something that is not there.

Which backend authored is deliberately NOT restricted — any provider is fine.
What is not fine is not knowing which one it was, which is why check 1 is the
strict one.

    scripts/check_provenance.py            # everything active in pipeline.yaml
    scripts/check_provenance.py lpic-1     # one certification

Exit code 1 if anything fails, so it can gate a commit.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core import certs, pipeline  # noqa: E402

# What every meta.yaml must record. The backend VALUE is unconstrained on
# purpose — any provider may author — but its absence is not: content whose
# origin is unknown cannot be reproduced, compared or rolled back.
REQUIRED_META = ("backend", "model", "generated_at")


def _topics(cert: str) -> list[dict]:
    front = yaml.safe_load((REPO / "certs" / f"{cert}.md").read_text().split("---")[1])
    return front.get("topics") or []


def check_cert(cert: str, languages: list[str]) -> list[str]:
    problems: list[str] = []
    try:
        topics = _topics(cert)
    except (FileNotFoundError, IndexError):
        return [f"{cert}: no syllabus to check against"]

    for topic in topics:
        topic_id = str(topic["id"])
        status = topic.get("status", "pending")
        directory = REPO / "certs" / cert / topic_id
        present = []

        for lang in languages:
            lang_dir = directory / lang
            content = lang_dir / "content.md"
            if not content.exists():
                continue
            present.append(lang)

            meta_file = lang_dir / "meta.yaml"
            if not meta_file.exists():
                problems.append(
                    f"{cert}/{topic_id} ({lang}): content exists with no meta.yaml — "
                    f"no backend, model or date recorded, so it cannot be traced"
                )
                continue
            try:
                meta = yaml.safe_load(meta_file.read_text()) or {}
            except yaml.YAMLError as error:
                problems.append(f"{cert}/{topic_id} ({lang}): meta.yaml does not parse ({error})")
                continue

            missing = [k for k in REQUIRED_META if not meta.get(k)]
            if missing:
                problems.append(
                    f"{cert}/{topic_id} ({lang}): meta.yaml is missing {', '.join(missing)}"
                )

        if present and status == "pending":
            problems.append(
                f"{cert}/{topic_id}: files exist in {', '.join(present)} but the syllabus still "
                f"says 'pending' — STATUS.md under-reports it and the work queue keeps "
                f"offering it as work to redo"
            )
        if not present and status == "generated":
            problems.append(
                f"{cert}/{topic_id}: syllabus says 'generated' but no content exists in "
                f"{', '.join(languages)}"
            )

    # Ordering: a video narrates content, so the content has to exist and clear
    # the floor first. A video rendered over a half-written certification tells a
    # student the material is there when it is not.
    for lang in pipeline.video_languages(cert):
        if not (REPO / "media" / "certs" / cert / lang / "video.mp4").exists():
            continue
        ready = sum(
            1 for topic in topics
            if (REPO / "certs" / cert / str(topic["id"]) / lang / "content.md").exists()
        )
        if ready < len(topics):
            problems.append(
                f"{cert} ({lang}): a video exists but only {ready} of {len(topics)} topics "
                f"have content in that language — the video promises material that is not there"
            )
    return problems


def main() -> int:
    wanted = sys.argv[1:]
    targets = pipeline.targets()
    if wanted:
        targets = [(c, l) for c, l in targets if c in wanted]
        if not targets:
            raise SystemExit(f"No active certification matches {wanted}")

    all_problems: list[str] = []
    for cert, languages in targets:
        all_problems += check_cert(cert, languages)

    if not all_problems:
        print(f"{len(targets)} certifications checked: provenance, bookkeeping and "
              f"authoring backend all consistent.")
        return 0

    print(f"{len(all_problems)} problems:\n")
    for problem in all_problems:
        print(f"  - {problem}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
