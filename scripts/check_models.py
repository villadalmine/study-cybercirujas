#!/usr/bin/env python3
"""Did the models the study bot offers change price, or stop existing?

`models.yaml` is what we froze and what the UI is built from; OpenRouter's
`/api/v1/models` is what exists right now. The comparison is the same shape as
`check_versions.py` for exam syllabi, for the same reason: a catalogue that
refreshes itself in place destroys the comparison it is supposed to enable.

What it reports, per model:

  GONE      the id no longer exists upstream — the bot would 404 on it
  PRICE     in/out cost moved; the number shown to students is wrong
  PAID      a `:free` model started charging — the most user-visible surprise
  PARAM     it stopped advertising `reasoning`, so the effort selector lies

    scripts/check_models.py              # report drift, exit 1 if any
    scripts/check_models.py --update     # rewrite models.yaml prices in place

Network only, no API key, no quota: the models endpoint is public.

What it CANNOT see is whether a listed model answers: the catalogue is upstream's
claim about itself. `scripts/probe_models.py` calls each one and grades the
reply — that costs a fraction of a cent and the bot's own key, which is why the
two are separate scripts rather than two flags of one.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from teach.core import catalog  # noqa: E402

CATALOGUE = REPO / "models.yaml"
API = "https://openrouter.ai/api/v1/models"
# Below this relative move a price change is noise (providers wobble in the
# fourth decimal); above it a student would notice the bill.
PRICE_TOLERANCE = 0.01


def live() -> dict:
    data = httpx.get(API, timeout=30, follow_redirects=True).json()["data"]
    return {m["id"]: m for m in data}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update", action="store_true",
                        help="rewrite models.yaml with current prices")
    args = parser.parse_args()

    frozen = catalog.load_models(CATALOGUE)
    try:
        upstream = live()
    except Exception as error:  # noqa: BLE001
        print(f"Could not reach OpenRouter ({error}). Nothing checked — which is "
              f"not the same as nothing wrong.")
        return 1

    problems, checked = [], 0
    for tier, models in (frozen.get("tiers") or {}).items():
        for entry in models:
            checked += 1
            mid = entry["id"]
            m = upstream.get(mid)
            if not m:
                problems.append(f"GONE   {mid} ({tier}) — no longer offered upstream")
                continue
            pin = float(m["pricing"]["prompt"] or 0) * 1e6
            pout = float(m["pricing"]["completion"] or 0) * 1e6
            was_in, was_out = float(entry["in"]), float(entry["out"])
            if mid.endswith(":free") and (pin or pout):
                problems.append(f"PAID   {mid} — was free, now ${pin:g}/${pout:g} per 1M")
            elif abs(pin - was_in) > max(was_in * PRICE_TOLERANCE, 1e-6) or \
                    abs(pout - was_out) > max(was_out * PRICE_TOLERANCE, 1e-6):
                problems.append(
                    f"PRICE  {mid} — ${was_in:g}/${was_out:g} → ${pin:g}/${pout:g} per 1M")
            if entry.get("reasoning") and "reasoning" not in (m.get("supported_parameters") or []):
                problems.append(f"PARAM  {mid} — no longer advertises `reasoning`")
            if args.update:
                # `5` rather than `5.0`: the price is the same number either
                # way, and a rewrite that flips every integer to a float turns
                # a one-line price change into an eighteen-line diff.
                tidy = lambda x: int(x) if float(x).is_integer() else round(x, 4)
                entry["in"], entry["out"] = tidy(pin), tidy(pout)
                entry["ctx"] = (m.get("context_length") or 0) // 1000
                entry["reasoning"] = "reasoning" in (m.get("supported_parameters") or [])

    if args.update:
        import datetime
        frozen["checked"] = datetime.date.today().isoformat()
        # The writer keeps the header comments, which explain why this file is
        # frozen, and the indentation, so the diff is the change and nothing else.
        catalog.save_models(frozen, CATALOGUE)
        print(f"models.yaml updated ({checked} models).")
        return 0

    print(f"{checked} models checked against {API}")
    if not problems:
        print("No drift: every model still exists at the price the UI shows.")
        return 0
    print(f"\n{len(problems)} finding(s):")
    for p in problems:
        print(f"  {p}")
    print("\n`scripts/check_models.py --update` refreshes the prices; a GONE model "
          "needs a human to choose a replacement.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
