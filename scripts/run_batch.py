#!/usr/bin/env python3
"""Generate a bounded batch of topics, honouring the budget in pipeline.yaml.

Replaces the ad-hoc scripts that had batch size and retry policy written by
hand. Everything deciding how much work to do, and which errors deserve another
attempt, comes from the YAML rather than from here.

    scripts/run_batch.py cks --lang en
    scripts/run_batch.py cks --lang en --topics 4

Idempotent: it asks the auditor what is missing, so re-running continues where
it left off without keeping any state of its own.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

# Exclusion lives in teach/core/claims.py and is per (cert, topic, lang), not
# global: two agents on different topics are two agents working. The global lock
# that used to be here made them queue behind each other, which is how an
# unsynchronised orchestrator came to be written in the first place.
from teach.core import claims, pipeline  # noqa: E402

import fix_corrupted_content as audit  # noqa: E402

TEACH = REPO / ".venv" / "bin" / "teach"


def _sort_key(topic: str) -> list[int]:
    try:
        return [int(part) for part in topic.split(".")]
    except ValueError:
        return [10**6]


def pending(cert: str, lang: str) -> list[str]:
    """Topics still missing for this combination, in syllabus order."""
    return sorted(
        (t for c, t, l in audit.find_bad_combos() if c == cert and l == lang),
        key=_sort_key,
    )


def generate(cert: str, topic: str, lang: str, backend: str) -> tuple[bool, str]:
    result = subprocess.run(
        [str(TEACH), "cert", "generate", cert, "--topic", topic,
         "--lang", lang, "--backend", backend, "--force"],
        cwd=REPO, capture_output=True, text=True,
    )
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def generate_with_retries(topic: str, args, attempts: int, delay: int) -> str:
    """One topic, start to finish. Returns done | failed | skipped | fatal.

    The claim is held for exactly as long as the work takes, so a second agent
    sees this topic as busy and moves to the next one instead of duplicating it.
    """
    with claims.claim(args.cert, topic, args.lang) as mine:
        if not mine:
            # Claimed between listing and starting. Not an error — someone else
            # is doing it, which is exactly what should happen.
            print(f"--- {topic}: claimed by another run, skipping ---", flush=True)
            return "skipped"
        for attempt in range(1, attempts + 1):
            print(f"--- {topic} (attempt {attempt}/{attempts}) ---", flush=True)
            ok, output = generate(topic=topic, cert=args.cert, lang=args.lang,
                                  backend=args.backend)
            if ok:
                return "done"
            # Only a fatal error stops the batch: with quota exhausted, every
            # remaining call would fail the same way.
            if pipeline.is_fatal(output):
                print(f"FATAL: retrying cannot help, stopping the batch.\n{output}", flush=True)
                return "fatal"
            if not pipeline.is_retryable(output) or attempt == attempts:
                # One stubborn topic must not hold up the rest. Nothing was
                # written for it, so the next pass simply finds it pending again.
                print(f"GIVING UP on {topic}, moving on:\n{output}", flush=True)
                return "failed"
            print(f"transient error, retrying in {delay}s", flush=True)
            time.sleep(delay)
    return "failed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cert")
    parser.add_argument("--lang", default="es")
    parser.add_argument("--backend", default="claude")
    parser.add_argument(
        "--topics", type=int, default=None,
        help="how many topics to generate (default: budget.topics_per_run from pipeline.yaml)",
    )
    args = parser.parse_args()

    limit = args.topics if args.topics is not None else pipeline.topics_per_run()
    attempts = int(pipeline.budget().get("retry_attempts") or 1)
    delay = int(pipeline.budget().get("retry_delay_seconds") or 0)

    queue = pending(args.cert, args.lang)
    if not queue:
        print(f"{args.cert} ({args.lang}): nothing pending")
        return 0

    # Skip what another agent is already producing rather than queueing behind
    # it. Two runs on different topics are two agents working; only the same
    # topic is a collision.
    busy = [t for t in queue if claims.is_claimed(args.cert, t, args.lang)]
    free = [t for t in queue if t not in busy]
    if busy:
        print(f"{args.cert} ({args.lang}): {len(busy)} topics claimed by another "
              f"run ({', '.join(busy[:5])}), skipping them", flush=True)
    if not free:
        print(f"{args.cert} ({args.lang}): everything pending is already claimed")
        return 0

    # Probe quota before paying to load the heavy context window for the first topic.
    probe = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "quota.py"), "--quiet", "--backend", args.backend]
    )
    if probe.returncode == 1:
        print(f"FATAL: {args.backend} quota is exhausted, stopping the batch before starting.", flush=True)
        return 2
    elif probe.returncode != 0:
        print(f"WARNING: quota probe failed (exit {probe.returncode}), proceeding anyway.", flush=True)

    batch = free[:limit] if limit else free
    print(f"{args.cert} ({args.lang}): {len(queue)} pending, "
          f"generating {len(batch)}: {', '.join(batch)}", flush=True)

    done = 0
    failed: list[str] = []
    for topic in batch:
        outcome = generate_with_retries(topic, args, attempts, delay)
        if outcome == "fatal":
            print(f"generated {done}/{len(batch)}", flush=True)
            return 2
        if outcome == "done":
            done += 1
        elif outcome == "failed":
            failed.append(topic)

    remaining = len(queue) - done
    print(f"batch complete: {done} generated, {remaining} left in {args.cert} ({args.lang})")
    if failed:
        print(f"not generated this pass: {', '.join(failed)}")
    # Exit 1 only when the whole batch failed, so a caller looping over batches
    # can tell "no progress at all" from "partial progress".
    return 1 if done == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
