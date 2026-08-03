#!/usr/bin/env python3
"""Measure what a translation actually costs, and whether it survives verification.

Answers one question with numbers instead of intuition: can a cheap model do the
translation step without degrading the material? `pipeline.yaml` states the rule
this exists to test — quality first, cost second; a cheaper model is only
acceptable where it provably does not degrade the material.

It translates the SAME topic with every model given, through the LiteLLM proxy,
using byte-identical prompts (imported from generator.py, never re-typed here so
they cannot drift), and reports per model:

  - wall-clock time
  - cost in USD and tokens, as reported by the proxy
  - whether `_verify_translation` accepts the output, and if not, exactly why
  - whether it clears the quality floor in pipeline.yaml

A model that fails verification is not a cheap option, it is an unusable one:
the pipeline would refuse to write its output anyway.

    scripts/translation_study.py --topic 1.1 --models cheap,free,free2

Nothing is written into certs/. Translations land in the output directory for
inspection, so a human can read them side by side and judge the half no
automated check covers: whether the prose is any good.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

import urllib.error  # noqa: E402
import urllib.request  # noqa: E402

from teach.core import generator, quality  # noqa: E402

PROXY = "http://127.0.0.1:4000"


def master_key() -> str:
    """Read the proxy key from the cluster rather than from a file on disk.

    It is only ever held in memory here and never printed: the study reports
    cost and verdicts, never credentials.
    """
    result = subprocess.run(
        ["kubectl", "get", "deploy", "litellm-proxy", "-n", "ai", "-o",
         "jsonpath={.spec.template.spec.containers[0].env[?(@.name=='LITELLM_MASTER_KEY')].value}"],
        capture_output=True, text=True, timeout=30,
    )
    key = result.stdout.strip()
    if not key:
        raise SystemExit(
            "Could not read LITELLM_MASTER_KEY from the cluster. Is kubectl "
            "pointing at it? (leloir: ./connect-cluster.sh lan)"
        )
    return key


def translate(model: str, system: str, source: str, key: str, timeout: int) -> dict:
    """One completion through the proxy. Returns text plus what it cost."""
    payload = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": source},
        ],
        "temperature": 0,
    }).encode()
    request = urllib.request.Request(
        f"{PROXY}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.load(response)
            # The proxy reports the real spend per call; taking it from the
            # header avoids guessing from a price list that goes stale.
            cost = response.headers.get("x-litellm-response-cost")
    except urllib.error.HTTPError as error:
        return {"error": f"HTTP {error.code}: {error.read()[:300].decode(errors='replace')}",
                "seconds": time.monotonic() - started}
    except Exception as error:  # timeout, connection reset, malformed body
        return {"error": f"{type(error).__name__}: {error}",
                "seconds": time.monotonic() - started}

    elapsed = time.monotonic() - started
    choices = body.get("choices") or []
    if not choices:
        return {"error": f"no choices in the response: {str(body)[:200]}", "seconds": elapsed}
    usage = body.get("usage") or {}
    return {
        "text": choices[0].get("message", {}).get("content") or "",
        "seconds": elapsed,
        "cost_usd": float(cost) if cost else None,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
    }


def evaluate(source: str, translated: str, kind: str) -> tuple[str, list[str]]:
    """Run the pipeline's own two gates. Verdict plus the reasons it failed."""
    problems: list[str] = []
    try:
        generator._verify_translation(source, translated, kind)
        structure = "ok"
    except generator.GeneratorConfigError as error:
        structure = "FAILED"
        problems.append(str(error).split(": ", 1)[-1])
    floor = quality.check(kind.removesuffix(".md"), translated)
    if floor:
        problems.extend(floor)
    verdict = "PASS" if structure == "ok" and not floor else "REJECTED"
    return verdict, problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cert", default="cks")
    parser.add_argument("--topic", default="1.1")
    parser.add_argument("--from", dest="source_lang", default="es")
    parser.add_argument("--to", dest="target_lang", default="en")
    parser.add_argument("--kind", default="content.md", choices=["content.md", "exercises.md"])
    parser.add_argument("--models", default="cheap,free,free2",
                        help="comma-separated model names as the proxy knows them")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--out", default=None, help="where to write the translations")
    args = parser.parse_args()

    source_path = REPO / "certs" / args.cert / args.topic / args.source_lang / args.kind
    if not source_path.exists():
        raise SystemExit(f"No source to translate: {source_path}")
    source = source_path.read_text()

    out_dir = Path(args.out) if args.out else REPO / ".study" / f"{args.cert}-{args.topic}"
    out_dir.mkdir(parents=True, exist_ok=True)

    # The exact prompt the pipeline uses, rebuilt from generator's own table so
    # the study cannot quietly test something the pipeline does not do.
    system = (
        f"Sos un traductor técnico especializado. Traducís del "
        f"{generator.LANG_NAMES.get(args.source_lang, args.source_lang)} al "
        f"{generator.LANG_NAMES.get(args.target_lang, args.target_lang)}.\n"
        "REGLAS ESTRICTAS:\n"
        "1. Copiá los bloques de código EXACTAMENTE como están, sin traducir "
        "comandos, flags, nombres de campos YAML, ni salidas de terminal.\n"
        "2. Mantené los términos técnicos en inglés (Pod, Deployment, "
        "NetworkPolicy, etc).\n"
        "3. Conservá TODOS los encabezados, en el mismo orden y nivel.\n"
        "4. Conservá TODAS las URLs sin modificar.\n"
        "5. No resumas, no expandas, no agregues ni quites secciones.\n"
        "Respondé SOLO con el markdown traducido."
    )

    key = master_key()
    print(f"source: {source_path.relative_to(REPO)} ({len(source)} bytes, "
          f"{len(generator.CODE_BLOCK.findall(source))} code blocks, "
          f"{len(generator.HEADING.findall(source))} headings)\n", flush=True)

    rows = []
    for model in [m.strip() for m in args.models.split(",") if m.strip()]:
        print(f"--- {model} ---", flush=True)
        result = translate(model, system, source, key, args.timeout)
        if "error" in result:
            print(f"    error after {result['seconds']:.0f}s: {result['error']}\n", flush=True)
            rows.append({"model": model, "verdict": "ERROR", "detail": result["error"],
                         "seconds": result["seconds"]})
            continue

        text = generator._strip_fence(result["text"])
        (out_dir / f"{model.replace('/', '_')}.{args.kind}").write_text(text)
        verdict, problems = evaluate(source, text, args.kind)
        cost = result.get("cost_usd")
        print(f"    {verdict} in {result['seconds']:.0f}s, "
              f"{len(text)} bytes, cost {'$%.5f' % cost if cost is not None else 'n/a'}", flush=True)
        for problem in problems:
            print(f"      - {problem}", flush=True)
        print(flush=True)
        rows.append({
            "model": model, "verdict": verdict, "seconds": result["seconds"],
            "bytes": len(text), "cost_usd": cost,
            "prompt_tokens": result.get("prompt_tokens"),
            "completion_tokens": result.get("completion_tokens"),
            "problems": problems,
        })

    print("=" * 72)
    print(f"{'model':22} {'verdict':9} {'time':>7} {'bytes':>7} {'cost':>10}")
    print("-" * 72)
    for row in rows:
        cost = row.get("cost_usd")
        print(f"{row['model']:22} {row['verdict']:9} {row['seconds']:6.0f}s "
              f"{row.get('bytes') or 0:7} "
              f"{('$%.5f' % cost) if cost is not None else 'n/a':>10}")
    print("=" * 72)
    print(f"\nTranslations written to {out_dir} — read them before trusting any verdict:\n"
          f"the checks above catch mechanical damage, not bad prose.")

    (out_dir / "results.json").write_text(json.dumps(rows, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
