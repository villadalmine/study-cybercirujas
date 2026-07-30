#!/usr/bin/env python3
"""Genera un lote acotado de topics, respetando el presupuesto de pipeline.yaml.

Sustituye a los scripts ad-hoc con el tamaño de lote y la política de reintentos
escritos a mano. Todo lo que decide cuánto trabajo hacer y qué errores merecen
otro intento sale del YAML, no de acá.

    scripts/run_batch.py cks --lang en
    scripts/run_batch.py cks --lang en --topics 4

Idempotente: pregunta al auditor qué falta, así que relanzarlo continúa donde
quedó sin llevar estado propio.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from teach.core import pipeline  # noqa: E402

import fix_corrupted_content as audit  # noqa: E402

TEACH = REPO / ".venv" / "bin" / "teach"


def _sort_key(topic: str) -> list[int]:
    try:
        return [int(part) for part in topic.split(".")]
    except ValueError:
        return [10**6]


def pending(cert: str, lang: str) -> list[str]:
    """Topics que le faltan a esta combinación, en orden de temario."""
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cert")
    parser.add_argument("--lang", default="es")
    parser.add_argument("--backend", default="claude")
    parser.add_argument(
        "--topics", type=int, default=None,
        help="cuántos topics generar (default: budget.topics_per_run de pipeline.yaml)",
    )
    args = parser.parse_args()

    limit = args.topics if args.topics is not None else pipeline.topics_per_run()
    attempts = int(pipeline.budget().get("retry_attempts") or 1)
    delay = int(pipeline.budget().get("retry_delay_seconds") or 0)

    queue = pending(args.cert, args.lang)
    if not queue:
        print(f"{args.cert} ({args.lang}): nada pendiente")
        return 0

    batch = queue[:limit] if limit else queue
    print(f"{args.cert} ({args.lang}): {len(queue)} pendientes, "
          f"generando {len(batch)}: {', '.join(batch)}", flush=True)

    done = 0
    for topic in batch:
        for attempt in range(1, attempts + 1):
            print(f"--- {topic} (intento {attempt}/{attempts}) ---", flush=True)
            ok, output = generate(topic=topic, cert=args.cert, lang=args.lang,
                                  backend=args.backend)
            if ok:
                done += 1
                break
            if pipeline.is_fatal(output):
                print(f"FATAL: reintentar no ayuda, corto el lote.\n{output}", flush=True)
                print(f"generados {done}/{len(batch)}", flush=True)
                return 2
            if not pipeline.is_retryable(output) or attempt == attempts:
                print(f"FALLO en {topic}:\n{output}", flush=True)
                print(f"generados {done}/{len(batch)}", flush=True)
                return 1
            print(f"transitorio, reintento en {delay}s", flush=True)
            time.sleep(delay)

    remaining = len(queue) - done
    print(f"lote completo: {done} generados, quedan {remaining} en {args.cert} ({args.lang})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
