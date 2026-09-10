#!/usr/bin/env python3
"""Prune old image tags from the cluster registry, then reclaim the space.

Written after 2026-09-10, when the registry hit 100% of its 98 GB volume and
every image push in the cluster failed — not just this project's. This
repository publishes one image per finished certification, each carrying
`certs/` and `media/`, and nothing ever pruned. Neither did the other
repositories sharing that registry.

Three safeties, because this deletes things:

  * **dry run by default.** `--apply` is required to touch anything.
  * **a deployed tag is never pruned.** Every deployment in every namespace is
    read first, and any tag in use is kept regardless of age. If that list
    cannot be read, the run aborts rather than guessing.
  * **keep-N on top of that**, newest first, so a rollback target survives.

    scripts/clean_registry.py                 # show the plan
    scripts/clean_registry.py --apply         # prune, then garbage-collect
    scripts/clean_registry.py --keep 5        # keep more per repository
    scripts/clean_registry.py --repo teach-plat

Needs `kubectl` with access to the registry namespace. Costs no quota.
"""
from __future__ import annotations

import argparse
import subprocess
import sys

NS = "registry"
DEPLOY = "deploy/registry"
ROOT = "/var/lib/registry/docker/registry/v2"
CONFIG = "/etc/docker/registry/config.yml"


def kubectl(*args: str, check: bool = True) -> str:
    result = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip()[:300])
    return result.stdout


def in_registry(script: str) -> str:
    return kubectl("exec", "-n", NS, DEPLOY, "--", "sh", "-c", script)


def deployed_tags() -> set[str]:
    """Every image referenced by a deployment, as `repo:tag`."""
    out = kubectl(
        "get", "deploy,statefulset,daemonset", "-A", "-o",
        "jsonpath={range .items[*]}{range .spec.template.spec.containers[*]}{.image}{'\\n'}{end}{end}",
    )
    tags = set()
    for image in out.split():
        if ":" not in image:
            continue
        repo, tag = image.rsplit(":", 1)
        tags.add(f"{repo.split('/')[-1]}:{tag}")
    return tags


def usage() -> str:
    """Disk usage of the registry volume, read by column name rather than index.

    `df -h` wraps onto two lines when the device name is long, so positional
    parsing silently reads the wrong column — the first version of this
    reported free space as used. `--output` fixes the columns.
    """
    # Everything after the header, joined: `df -h` wraps onto two lines when
    # the device name is long, and `--output=` is coreutils-only (the registry
    # image ships busybox). The last five fields are always
    # size / used / avail / use% / mountpoint, wrapped or not.
    fields = in_registry(f"df -h {ROOT} | tail -n +2").split()
    if len(fields) < 5:
        return "unknown"
    size, used, avail, pct, _ = fields[-5:]
    return f"{used} used, {avail} free of {size} ({pct})"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep", type=int, default=3,
                        help="tags to keep per repository, newest first (default 3)")
    parser.add_argument("--repo", help="only this repository")
    parser.add_argument("--apply", action="store_true", help="actually delete")
    args = parser.parse_args()

    try:
        protected = deployed_tags()
    except Exception as error:  # noqa: BLE001
        print(f"Cannot read what is deployed ({error}).\nRefusing to prune blind — "
              f"a tag in use would be deleted and the next pod start would fail.")
        return 1
    print(f"Before: {usage()}")
    print(f"In use and never pruned: {len(protected)} tag(s)\n")

    repos = [args.repo] if args.repo else in_registry(f"ls {ROOT}/repositories").split()
    planned: list[tuple[str, list[str]]] = []
    for repo in repos:
        tags = in_registry(
            f"ls -t {ROOT}/repositories/{repo}/_manifests/tags 2>/dev/null || true"
        ).split()
        if not tags:
            continue
        keep = set(tags[: args.keep]) | {t for t in tags if f"{repo}:{t}" in protected}
        drop = [t for t in tags if t not in keep]
        if drop:
            planned.append((repo, drop))
        print(f"  {repo:22} {len(tags):>4} tags · keep {len(keep):>3} · prune {len(drop):>4}")

    if not planned:
        print("\nNothing to prune.")
        return 0
    total = sum(len(d) for _, d in planned)
    if not args.apply:
        print(f"\n{total} tag(s) would be pruned. Nothing written — re-run with --apply.")
        return 0

    for repo, drop in planned:
        # One call per repository, tags quoted individually: a tag name is
        # attacker-free here (we listed it ourselves) but shell-quoting keeps
        # an odd character from turning into a wider delete.
        names = " ".join(f"'{t}'" for t in drop)
        in_registry(f"cd {ROOT}/repositories/{repo}/_manifests/tags && rm -rf -- {names}")
        print(f"  pruned {len(drop)} from {repo}")
    print("\nOrphaned uploads (debris from failed pushes)…")
    in_registry(f"rm -rf {ROOT}/repositories/*/_uploads/* 2>/dev/null || true")
    print("Garbage collection — this is the step that frees bytes…")
    out = kubectl("exec", "-n", NS, DEPLOY, "--",
                  "registry", "garbage-collect", CONFIG, "--delete-untagged")
    print("  " + (out.strip().splitlines() or ["done"])[-1])
    print(f"\nAfter: {usage()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
