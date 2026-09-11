#!/usr/bin/env python3
"""Do the models the study bot offers actually answer — and does thinking apply?

`check_models.py` asks OpenRouter's public catalogue whether an id still exists
at the price the UI shows. That is free, and it is not the same question a
student asks. A model can be listed, priced and advertised as supporting
`reasoning` and still hand the browser a 404 ("no endpoints match your data
policy"), an empty string, or a bill for thinking tokens the student switched
off. Phase 1 feedback was exactly that: *not all of the models work, and the
thinking control is not understandable*.

So this script calls each model, once, through the SAME path the browser takes
(openrouter.ai/api/v1/chat/completions, same headers), and grades the answer
mechanically:

  ok        replied, and the reply contains the expected word
  answers   replied something else — alive, but ignored a one-word instruction
  empty     HTTP 200 with no content (usually the whole cap went to thinking)
  dead      404 — gone, or no endpoint will serve this account
  rate      429 — rate limited; the `:free` tier does this and it is not a bug
  error     anything else, with the provider's own message kept verbatim

and answers the second question separately, because "supports reasoning" in the
catalogue says nothing about what the effort selector DOES:

  none      the request is rejected when `reasoning` is sent — the selector lies
  ignored   accepted, but no thinking tokens are ever billed — it does nothing
  effort    off = 0 thinking tokens, low > 0 — the control works as advertised
  always    thinking tokens billed even with `reasoning` omitted — "off" is not off

DETERMINISTIC BY CONSTRUCTION: one fixed prompt, `temperature: 0`, a fixed seed,
a fixed token cap, one graded substring. Two runs of this script differ only
where the provider changed. Nothing here is judged by a model.

CHEAP BY CONSTRUCTION: the prompt is ~25 tokens and the answer is capped at 48
(the retry at 400, and only for models that spend the first cap on thinking). The worst case for the whole catalogue is printed BEFORE the first
request and is a few cents; `--dry-run` prints it and stops.

    scripts/probe_models.py                 # probe every model, report
    scripts/probe_models.py --dry-run       # what it would cost, no requests
    scripts/probe_models.py --tier free     # one tier
    scripts/probe_models.py --model openai/gpt-5-mini
    scripts/probe_models.py --update        # write the verdicts into models.yaml
    scripts/probe_models.py --json out.json # machine-readable report

Credential: LITELLM_API_KEY_BOT, and deliberately not LITELLM_API_KEY. The bot
key is a separate OpenRouter key with its own limit, so a probe can never eat
the translation budget, and a leaked probe cannot spend the working key.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import time
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from teach.core import catalog, generator  # noqa: E402  (also loads .env)

CATALOGUE = REPO / "models.yaml"
API = "https://openrouter.ai/api/v1/chat/completions"

# The probe itself. One word in, one word out, graded by substring — the point
# is liveness and instruction-following, not knowledge, so the question must be
# one that every general model answers and no model needs to think about.
SYSTEM = "Answer with one word and nothing else."
USER = "What is the capital of France?"
EXPECTED = "paris"
SEED = 7
# The SAME cap `botAsk()` sends. Not an arbitrary small number: OpenRouter maps
# `reasoning.effort` onto a per-provider thinking budget derived from
# `max_tokens`, so the answer to "does the effort selector do anything" is only
# true for the max_tokens the student actually sends. A first version probed at
# 48 and concluded that gpt-5-mini never thinks; at 2000 it thinks on every
# request, including the ones with reasoning switched off. The cap is a ceiling,
# not a charge — a model that answers in one word is billed for one word — so
# matching the bot costs nothing except on the models that really do think,
# which is precisely what is being measured.
CAP = 2000
TIMEOUT = 120
# Hard stop. Real cost comes back on every response, so the script can count
# what it has spent and refuse to continue — a ceiling that holds even if a
# provider starts thinking for the full cap on a one-word question.
DEFAULT_BUDGET = 0.25
# A `:free` model that is rate-limited upstream right now is not a broken model,
# and reporting it as one makes the report differ between two identical runs.
# One retry, one fixed pause: enough to settle the common case, bounded enough
# that a genuinely saturated provider still shows up as RATE.
RATE_RETRY_DELAY = 6


def _price(entry: dict) -> tuple[float, float]:
    return float(entry.get("in") or 0), float(entry.get("out") or 0)


def worst_case(entries: list[dict], deep: bool) -> float:
    """Upper bound in USD, assuming every model burns every cap it is offered.

    Printed before anything is sent. An estimate that arrives after the spend
    is not a budget, it is a receipt.
    """
    total = 0.0
    calls = 3 if deep else 2          # reasoning off, low, (high)
    for entry in entries:
        pin, pout = _price(entry)
        total += calls * (40 * pin / 1e6 + CAP * pout / 1e6)
    return total


def ask(client: httpx.Client, key: str, model: str, effort: str | None,
        cap: int, reasoning: dict | None = None) -> dict:
    """One completion. Returns a plain dict; never raises for an HTTP error.

    `usage.include` asks OpenRouter for the real cost of this call, so the
    script reports what it spent rather than what it estimated — the same rule
    the rest of the pipeline follows in usage.jsonl.
    """
    body = {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": USER}],
        "max_tokens": cap,
        "temperature": 0,
        "seed": SEED,
        "usage": {"include": True},
    }
    if effort:
        body["reasoning"] = {"effort": effort}
    elif reasoning is not None:
        body["reasoning"] = reasoning

    started = time.monotonic()
    try:
        response = client.post(
            API, json=body, timeout=TIMEOUT,
            headers={"Authorization": f"Bearer {key}",
                     # The browser sends these; a provider that gates on them
                     # must fail here too, or the probe proves the wrong path.
                     "HTTP-Referer": "https://study.cybercirujas.club",
                     "X-Title": "Cert Landscape study bot"})
    except Exception as error:                                    # noqa: BLE001
        return {"status": 0, "message": f"{type(error).__name__}: {error}",
                "ms": int((time.monotonic() - started) * 1000)}

    out = {"status": response.status_code,
           "ms": int((time.monotonic() - started) * 1000)}
    try:
        data = response.json()
    except Exception:                                             # noqa: BLE001
        out["message"] = response.text[:200]
        return out

    error = data.get("error")
    if error or response.status_code >= 400:
        out["message"] = (error or {}).get("message") or str(error) or response.text[:200]
        # OpenRouter reports the upstream provider's own refusal here; it is
        # the part that says WHY, so it is kept rather than summarised.
        meta = (error or {}).get("metadata") or {}
        if meta.get("raw"):
            out["message"] += f" | {str(meta['raw'])[:160]}"
        return out

    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    usage = data.get("usage") or {}
    details = usage.get("completion_tokens_details") or {}
    out.update({
        "content": (message.get("content") or "").strip(),
        # Three different shapes mean "it thought", and a model can use any of
        # them: a token count, the thinking text itself, or an opaque
        # `reasoning_details` blob (OpenAI returns encrypted reasoning that way
        # — visible nowhere, billed all the same).
        "reasoning_text": bool(message.get("reasoning")),
        "reasoning_blob": bool(message.get("reasoning_details")),
        "reasoning_tokens": int(details.get("reasoning_tokens") or 0),
        "in": int(usage.get("prompt_tokens") or 0),
        "out": int(usage.get("completion_tokens") or 0),
        "cost": float(usage.get("cost") or 0.0),
        "finish": choice.get("finish_reason"),
        "served_by": data.get("provider"),
    })
    return out


def ask_retrying(client: httpx.Client, key: str, model: str, effort: str | None,
                 cap: int, reasoning: dict | None = None) -> tuple[dict, int]:
    """`ask` plus one retry for a rate limit. Returns (response, calls made).

    A `:free` model that is saturated right now is not a broken model, and
    reporting it as one makes two identical runs disagree — which would cost
    this script the only property that makes it worth running: determinism.
    One retry, one fixed pause; a genuinely saturated provider still shows up
    as RATE.
    """
    probe = ask(client, key, model, effort, cap, reasoning)
    if verdict(probe) != "rate":
        return probe, 1
    time.sleep(RATE_RETRY_DELAY)
    return ask(client, key, model, effort, cap, reasoning), 2


def verdict(probe: dict) -> str:
    """Grade one response. Pure function of the dict — see the tests."""
    status = probe.get("status")
    if status == 0:
        return "error"
    if status == 429:
        return "rate"
    if status in (401, 402, 403):
        return "auth"
    if status == 404:
        return "dead"
    if status >= 400:
        return "error"
    content = (probe.get("content") or "").strip()
    if not content:
        return "empty"
    if EXPECTED in content.lower():
        return "ok"
    return "answers"


def rejects_reasoning(probe: dict) -> bool:
    """Did the provider refuse BECAUSE of the `reasoning` field?

    A 400/422 naming the parameter is the honest signal. A model that is simply
    dead fails the same way with or without it, so the caller only asks this
    once the plain probe has already succeeded.
    """
    if probe.get("status") not in (400, 404, 422, 500):
        return False
    message = (probe.get("message") or "").lower()
    return any(word in message for word in
               ("reasoning", "thinking", "effort", "unsupported parameter",
                "unknown parameter", "not supported"))


def thought(probe: dict) -> bool:
    """Did this response involve thinking, in any of the three shapes?"""
    return bool(probe.get("reasoning_tokens") or probe.get("reasoning_text")
                or probe.get("reasoning_blob"))


def thinking_mode(off: dict, low: dict) -> str:
    """How the effort selector behaves for this model, from two probes.

    off  = exactly what the bot sends when "no reasoning" is chosen (no
           `reasoning` field at all)
    low  = the same request plus reasoning.effort = low

    `always` is deliberately the conservative verdict: some models decide for
    themselves whether a question is worth thinking about, and OpenRouter may
    route two identical requests to different upstream providers, so a model
    that thought once with reasoning off can be trusted to do it again. The UI
    does not have to guess either way — see `off_switch` below.
    """
    if rejects_reasoning(low):
        return "none"
    if verdict(low) in ("error", "dead", "auth", "rate"):
        return "unknown"
    if thought(off):
        # Thinking is billed even though the student switched it off. The UI
        # calls that option "No reasoning (cheapest)", and for these models it
        # is neither.
        return "always"
    if thought(low):
        return "effort"
    return "ignored"


def reasoning_mandatory(killed: dict) -> bool:
    """Did the endpoint say, in so many words, that it will not stop thinking?

    OpenRouter answers `reasoning: {enabled: false}` with HTTP 400 "Reasoning is
    mandatory for this endpoint and cannot be disabled." That sentence is better
    evidence than the token counters: a model can reason without reporting a
    single reasoning token (gpt-6-astra bills thinking and shows none), and the
    student is paying for it either way.
    """
    if killed.get("status") not in (400, 422):
        return False
    message = (killed.get("message") or "").lower()
    return "mandatory" in message or "cannot be disabled" in message


def off_switch(killed: dict) -> str:
    """Does `reasoning: {enabled: false}` actually stop this model thinking?

    Asked of every model that answers, not only the ones caught thinking with
    the field omitted: omitting it is a request to use the DEFAULT, which the
    provider is free to change and, for adaptive models, decides per question.
    Sending the switch explicitly is the only form of "off" that means off, and
    this records for which models it is safe to send.
    """
    if rejects_reasoning(killed) or verdict(killed) in ("error", "dead"):
        return "rejected"      # sending it would break the request
    if thought(killed):
        return "none"          # accepted and ignored: thinking is in the price
    return "enabled:false"


def tally(row: dict, probe: dict) -> None:
    """Add one response's real token counts to the row.

    Exact numbers, from the response itself — the same standard the rest of the
    pipeline records by. A failed call reports none, and a null there is honest
    where a zero would not be.
    """
    row["in"] += probe.get("in") or 0
    row["out"] += probe.get("out") or 0


def probe_one(client: httpx.Client, key: str, entry: dict, deep: bool) -> dict:
    """Three calls for a model that answers, one for a model that does not.

    Order matters: liveness first, and the reasoning questions only for a model
    that answered — there is nothing to learn about the effort selector of a
    model the student cannot reach at all.
    """
    model = entry["id"]
    row: dict = {"id": model, "cost": 0.0, "calls": 0, "in": 0, "out": 0}

    off, made = ask_retrying(client, key, model, None, CAP)
    row["calls"] += made
    row["cost"] += off.get("cost", 0.0)
    tally(row, off)
    row["ms"] = off.get("ms")
    row["served_by"] = off.get("served_by")
    row["verdict"] = verdict(off)

    if row["verdict"] in ("auth", "dead", "rate", "error", "empty"):
        row["thinking"] = "unknown"
        row["off_switch"] = "unknown"
        row["message"] = off.get("message", "")[:200]
        row["reply"] = off.get("content", "")[:60]
        if row["verdict"] == "empty":
            # 2000 tokens of room and not one character back. Whatever the
            # cause, the student sees a blank answer.
            row["message"] = (f"200 OK, no content "
                              f"(finish={off.get('finish')}, "
                              f"{off.get('reasoning_tokens', 0)} thinking tokens)")
        return row

    row["reply"] = (off.get("content") or "")[:60]
    row["off_thinking"] = off.get("reasoning_tokens", 0)

    low, made = ask_retrying(client, key, model, "low", CAP)
    row["calls"] += made
    row["cost"] += low.get("cost", 0.0)
    tally(row, low)
    row["thinking"] = thinking_mode(off, low)
    row["low_thinking"] = low.get("reasoning_tokens", 0)
    # Can the student SEE the thinking, or only pay for it? Neither is a
    # failure, but a UI can only show what comes back as text.
    row["thinking_visible"] = bool(low.get("reasoning_text"))
    if row["thinking"] == "none":
        row["message"] = low.get("message", "")[:200]
        row["off_switch"] = "rejected"
        return row

    killed, made = ask_retrying(client, key, model, None, CAP,
                                reasoning={"enabled": False})
    row["calls"] += made
    row["cost"] += killed.get("cost", 0.0)
    tally(row, killed)
    row["off_switch"] = off_switch(killed)
    if reasoning_mandatory(killed):
        # The provider's own words outrank the counters: a model whose thinking
        # cannot be switched off is thinking on every request, whether or not
        # the response admits to a single reasoning token.
        row["thinking"] = "always"
        row["off_switch_message"] = (killed.get("message") or "")[:120]

    if deep and row["thinking"] == "effort":
        high, made = ask_retrying(client, key, model, "high", CAP)
        row["calls"] += made
        row["cost"] += high.get("cost", 0.0)
        tally(row, high)
        row["high_thinking"] = high.get("reasoning_tokens", 0)
        if row["high_thinking"] <= row["low_thinking"]:
            # Accepted and billed, but the dial does not move: the student pays
            # for "high" and gets the thinking of "low".
            row["thinking"] = "flat"
    return row


MARK = {"ok": "OK    ", "answers": "ANSWER", "empty": "EMPTY ", "dead": "DEAD  ",
        "rate": "RATE  ", "auth": "AUTH  ", "error": "ERROR "}
THINK_NOTE = {
    "effort": "effort works (off = 0 thinking tokens)",
    "always": "ALWAYS thinks — 'off' does not disable it",
    "ignored": "accepted but never thinks — the selector does nothing",
    "none": "rejects `reasoning` — the selector would 400",
    "flat": "accepted, but high thinks no more than low",
    "unknown": "not determined",
}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tier", help="probe one tier only (top|mid|low|free)")
    parser.add_argument("--model", action="append", default=[],
                        help="probe one id (repeatable)")
    parser.add_argument("--deep", action="store_true",
                        help="also send effort=high, to check the dial actually moves")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the worst-case cost and send nothing")
    parser.add_argument("--budget", type=float, default=DEFAULT_BUDGET,
                        metavar="USD",
                        help=f"stop once this much has really been spent "
                             f"(default ${DEFAULT_BUDGET:.2f})")
    parser.add_argument("--update", action="store_true",
                        help="write the verdicts back into models.yaml")
    parser.add_argument("--json", metavar="FILE", help="write the full report as JSON")
    args = parser.parse_args()

    frozen = catalog.load_models(CATALOGUE)
    tiers = frozen.get("tiers") or {}
    selected: list[tuple[str, dict]] = []
    for tier, models in tiers.items():
        if args.tier and tier != args.tier:
            continue
        for entry in models:
            if args.model and entry["id"] not in args.model:
                continue
            selected.append((tier, entry))
    if not selected:
        print("Nothing selected. --tier top|mid|low|free, or --model <id>.")
        return 2

    ceiling = worst_case([e for _, e in selected], args.deep)
    print(f"{len(selected)} model(s) · worst case ${ceiling:.4f} if every model "
          f"burned the whole {CAP}-token cap on a one-word question\n"
          f"stops at ${args.budget:.2f} of real spend · measured runs land "
          f"around $0.02\n")
    if args.dry_run:
        for tier, entry in selected:
            print(f"  {tier:5} {entry['id']}")
        return 0

    key = os.environ.get("LITELLM_API_KEY_BOT")
    if not key:
        print("LITELLM_API_KEY_BOT is not set. It is the bot's own OpenRouter key,\n"
              "kept apart from LITELLM_API_KEY so a probe can never spend the\n"
              "translation budget. Put it in .env and run again.", file=sys.stderr)
        return 2

    # Every completion this project makes is accounted for, through any backend
    # (CLAUDE.md). A probe is not an exception just because it is small.
    generator._usage_context.clear()
    generator._usage_context.update({"op": "probe", "kind": "bot-model"})

    rows, spent, calls = [], 0.0, 0
    with httpx.Client(follow_redirects=True) as client:
        for tier, entry in selected:
            row = probe_one(client, key, entry, args.deep)
            row["tier"] = tier
            row["name"] = entry.get("name", entry["id"])
            rows.append(row)
            spent += row["cost"]
            calls += row["calls"]
            generator._record_plain_usage(
                "openrouter", row["id"], cost_usd=row["cost"] or None,
                input_tokens=row["in"] or None, output_tokens=row["out"] or None,
                duration_ms=row.get("ms"))
            mark = MARK.get(row["verdict"], row["verdict"])
            print(f"  {mark} {row['id']:42} {tier:5} "
                  f"thinking={row['thinking']:8} ${row['cost']:.5f}"
                  + (f"  {row['message']}" if row.get("message") else ""))
            if row["verdict"] == "answers":
                print(f"         replied {row['reply']!r} instead of '{EXPECTED}'")
            if spent > args.budget:
                # Real cost, from the responses themselves. Stopping here is
                # the honest failure: the report covers what was probed and says
                # how far it got, rather than quietly costing more than promised.
                print(f"\n  BUDGET reached (${spent:.4f} > ${args.budget:.2f}) — "
                      f"stopped after {len(rows)} of {len(selected)} models.")
                break

        # The key's own remaining credit, from the same key. Free call, and the
        # one number that says whether the next probe will even run.
        try:
            left = client.get("https://openrouter.ai/api/v1/key", timeout=20,
                              headers={"Authorization": f"Bearer {key}"}).json().get("data", {})
        except Exception:                                         # noqa: BLE001
            left = {}

    # Three states, not two. A `:free` model saturated for six seconds is not a
    # dead model, and calling it one would drop a working model from the menu.
    flaky = [r for r in rows if r["verdict"] in ("rate", "empty")]
    broken = [r for r in rows if r["verdict"] in ("dead", "auth", "error")]
    lying = [r for r in rows if r["thinking"] in ("none", "ignored", "always", "flat")]
    print(f"\n{len(rows)} probed in {calls} calls · spent ${spent:.5f}")
    if left:
        used, limit = left.get("usage"), left.get("limit")
        if limit is not None:
            print(f"bot key: ${used:.4f} used of ${limit:.2f}")
        elif used is not None:
            print(f"bot key: ${used:.4f} used, no limit set")

    if broken:
        print(f"\n{len(broken)} model(s) a student cannot use at all:")
        for r in broken:
            print(f"  {r['verdict'].upper():7} {r['id']} — {r.get('message', '')[:140]}")
    if flaky:
        print(f"\n{len(flaky)} model(s) that answered nothing this time — "
              f"kept in the menu, marked:")
        for r in flaky:
            print(f"  {r['verdict'].upper():7} {r['id']} — {r.get('message', '')[:140]}")
    if lying:
        print(f"\n{len(lying)} model(s) where the effort selector is not what it looks like:")
        for r in lying:
            extra = {"enabled:false": " · `reasoning:{enabled:false}` DOES stop it",
                     "none": " · accepted and ignored; thinking is in the price",
                     "rejected": " · cannot be switched off at all"}.get(
                         r.get("off_switch"), "")
            print(f"  {r['thinking'].upper():8} {r['id']} — "
                  f"{THINK_NOTE[r['thinking']]}{extra}")
    if not broken and not flaky and not lying:
        print("\nEvery model answered, and every effort selector does what it says.")

    if args.json:
        Path(args.json).write_text(json.dumps(
            {"at": datetime.datetime.now().isoformat(timespec="seconds"),
             "prompt": {"system": SYSTEM, "user": USER, "expected": EXPECTED,
                        "cap": CAP, "seed": SEED},
             "spent_usd": round(spent, 6), "calls": calls, "models": rows},
            indent=2) + "\n")
        print(f"\nreport → {args.json}")

    if args.update:
        by_id = {r["id"]: r for r in rows}
        for models in tiers.values():
            for entry in models:
                row = by_id.get(entry["id"])
                if not row:
                    continue
                # What the UI needs to stop lying: does it answer, and does the
                # effort control mean anything for this model. Three states,
                # not a boolean: a `:free` model that was rate-limited for six
                # seconds is not a dead model, and writing `false` for it would
                # drop a working model from the menu on the strength of one
                # unlucky second.
                # Rewritten in a fixed order, so a re-probe changes values and
                # not the shape of the file.
                for key in ("probe", "thinking", "thinking_off", "probed"):
                    entry.pop(key, None)
                entry["probe"] = {"ok": "ok", "answers": "ok",
                                  "rate": "flaky", "empty": "flaky"}.get(
                                      row["verdict"], "broken")
                entry["thinking"] = row["thinking"]
                # The UI needs this one: for most models "no reasoning" only
                # means anything if the switch is sent explicitly, and for a
                # few, sending it breaks the request.
                if row.get("off_switch") == "enabled:false":
                    entry["thinking_off"] = "enabled:false"
                entry["probed"] = datetime.date.today().isoformat()
        catalog.save_models(frozen, CATALOGUE)
        print(f"models.yaml updated ({len(by_id)} entries carry a probe verdict).")

    # Exit non-zero only for a model that is genuinely unusable: a rate limit
    # would otherwise fail `make verify` on a good day for the wrong reason.
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
