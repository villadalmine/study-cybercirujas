#!/usr/bin/env python3
"""Which exam version is our material built on, and which one is current?

Two different questions that were being answered by one field. `catalog.yaml`
carries `tracked_version`, and `tracker.sync_cncf()` **overwrites it** with
whatever upstream now publishes — so after a sync it no longer says what our
content is based on, it says what exists. The comparison the field looks like it
supports is destroyed by the act of refreshing it.

The two facts are already recorded separately, in the right places:

  what we froze   certs/<cert>.md frontmatter: `version` + `snapshot_date`
                  written by `teach cert snapshot`, never by a sync
  what is current catalog.yaml: `curriculum_updated` (date upstream last changed)
                  written by `teach tracker sync`, never by a snapshot

Two ways to answer it, in order of how directly they answer it:

  version   the objectives document states its own version, and so does our
            syllabus. Equality is exact and about the same thing. Preferred.
  date      upstream changed AFTER we snapshotted. A proxy, used when no version
            is published on either side.

Both are deterministic and repeatable: running twice on the same tree gives the
same answer. LPI publishes no change date at all, so twelve certifications read
"unknown" until the version path existed — and one of them, lpi-devops, had been
outdated the whole time (frozen 1.0, published 2.0, exam code 701-100 -> 701-200).

    scripts/check_versions.py            # every catalogued certification
    scripts/check_versions.py --stale    # only the ones that have moved
    scripts/check_versions.py --refresh  # sync upstream first (network + AI for LPI)

Costs no API quota unless --refresh is passed.
"""
from __future__ import annotations

import argparse
import datetime
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))


def frozen(cert: str) -> tuple[str | None, str | None]:
    """(version, snapshot_date) as the syllabus records them — what we built on."""
    path = REPO / "certs" / f"{cert}.md"
    if not path.exists():
        return None, None
    try:
        front = yaml.safe_load(path.read_text().split("---")[1]) or {}
    except (IndexError, yaml.YAMLError):
        return None, None
    version = str(front.get("version") or "") or None
    date = str(front.get("snapshot_date") or front.get("frozen_at") or "") or None
    return version, date


def _same_version(a: str | None, b: str | None) -> bool | None:
    """True/False if both versions are known and comparable, else None.

    "3.0" and "3.0.0" are the same release written twice — LPI prints the short
    form on the page and the snapshot recorded the long one — so they are
    compared as numbers with trailing zeros dropped, not as strings. Doing it by
    string would report every one of those as outdated and the table would be
    ignored within a day.
    """
    if not a or not b or "unknown" in (a, b):
        return None
    def parts(v: str) -> tuple[int, ...]:
        try:
            out = [int(p) for p in v.split(".")]
        except ValueError:
            return ()
        while len(out) > 1 and out[-1] == 0:
            out.pop()
        return tuple(out)
    pa, pb = parts(a), parts(b)
    return None if not pa or not pb else pa == pb


def state(snapshot_date: str | None, upstream_date: str | None,
          frozen_version: str | None = None,
          upstream_version: str | None = None) -> str:
    """current | outdated | unknown.

    `unknown` is a real answer and is reported as such rather than assumed to be
    fine: a certification nobody has snapshotted, or one whose upstream has never
    been checked, is not 'current' — it is unmeasured, and saying otherwise is how
    a dashboard becomes reassuring instead of informative.
    """
    # Versions first when both are known: it is an exact statement about the same
    # thing, where the dates are only a proxy for it. LPI publishes no change
    # date at all, so twelve certifications read "unknown" on the date path while
    # the page states its version plainly — and one of them (lpi-devops, frozen
    # 1.0 against a published 2.0) was outdated the whole time.
    same = _same_version(frozen_version, upstream_version)
    if same is not None:
        return "current" if same else "outdated"
    if not snapshot_date or not upstream_date:
        return "unknown"
    return "outdated" if upstream_date > snapshot_date else "current"


def survey() -> list[dict]:
    catalog = yaml.safe_load((REPO / "catalog.yaml").read_text()) or {}
    rows = []
    for cert, entry in (catalog.get("certs") or {}).items():
        entry = entry or {}
        version, snapshot_date = frozen(cert)
        upstream_date = str(entry.get("curriculum_updated") or "") or None
        rows.append({
            "cert": cert,
            "version": version,
            "snapshot": snapshot_date,
            "upstream_version": str(entry.get("tracked_version") or "") or None,
            "upstream_changed": upstream_date,
            "last_checked": str(entry.get("last_checked") or "") or None,
            "state": state(snapshot_date, upstream_date, version,
                           str(entry.get("tracked_version") or "") or None),
        })
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stale", action="store_true", help="only what has moved")
    parser.add_argument("--refresh", action="store_true",
                        help="run the upstream sync first (network; LPI also uses a model)")
    args = parser.parse_args()

    if args.refresh:
        from teach.core import catalog as catalog_mod, tracker
        print("refreshing upstream …", flush=True)
        for change in tracker.sync_cncf():
            print(f"  {change}")
        # LPI publishes no change date, so sync_cncf leaves those twelve
        # unmeasured. The objectives page states its own version, which is a
        # better comparison than a date anyway: exact, and about the same thing.
        data = catalog_mod.load()
        today = datetime.date.today().isoformat()
        for cert_id, entry in (data.get("certs") or {}).items():
            entry = entry or {}
            url = (entry.get("sources") or {}).get("objectives") or ""
            if entry.get("vendor") != "LPI" or not url:
                continue
            try:
                found = tracker.published_version(tracker.fetch_text(url))
            except Exception as error:
                print(f"  {cert_id}: could not read {url} ({error})")
                continue
            entry["last_checked"] = today
            if found and str(entry.get("tracked_version") or "") != found:
                print(f"  {cert_id}: upstream version -> {found}")
                entry["tracked_version"] = found
        catalog_mod.save(data)

    rows = survey()
    shown = [r for r in rows if r["state"] == "outdated"] if args.stale else rows
    if not shown:
        print("Nothing outdated: no certification's syllabus predates its upstream.")
        return 0

    print(f"{'cert':14} {'built on':10} {'snapshot':11} {'upstream':10} "
          f"{'changed':11} {'checked':11} state")
    print("-" * 84)
    for row in sorted(shown, key=lambda r: (r["state"] != "outdated", r["cert"])):
        mark = {"outdated": "!! ", "unknown": " ? ", "current": "   "}[row["state"]]
        print(f"{row['cert']:14} {str(row['version'] or '—'):10} "
              f"{str(row['snapshot'] or '—'):11} {str(row['upstream_version'] or '—'):10} "
              f"{str(row['upstream_changed'] or '—'):11} "
              f"{str(row['last_checked'] or 'never'):11} {mark}{row['state']}")

    outdated = [r for r in rows if r["state"] == "outdated"]
    stale_checks = [r for r in rows if not r["last_checked"]
                    or r["last_checked"] < (datetime.date.today()
                                            - datetime.timedelta(days=30)).isoformat()]
    print()
    if outdated:
        print(f"{len(outdated)} certification(s) built on a syllabus older than upstream. "
              f"Re-snapshot marks the changed topics stale, and the pipeline picks them up:")
        for row in outdated:
            print(f"  teach cert snapshot {row['cert']} --force")
    if stale_checks:
        print(f"\n{len(stale_checks)} have not been checked against upstream in 30 days "
              f"(or ever). `--refresh` updates that; the answer above is only as fresh "
              f"as the last check.")
    return 1 if outdated else 0


if __name__ == "__main__":
    sys.exit(main())
