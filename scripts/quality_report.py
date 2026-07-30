#!/usr/bin/env python3
"""Informe de calidad por certificación, sin generar ni gastar cuota.

Responde la pregunta que motivó el piso: qué material cumple el estándar y qué
material se marcó como `generated` sin llegar. Lee los umbrales de
pipeline.yaml, los mismos que aplica el generador antes de escribir.

    scripts/quality_report.py            # todas las certs activas
    scripts/quality_report.py cnpe cnpa  # solo estas
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

from teach.core import pipeline, quality  # noqa: E402


def main() -> int:
    wanted = sys.argv[1:]
    targets = pipeline.targets(active_only=not wanted)
    if wanted:
        targets = [(c, langs) for c, langs in targets if c in wanted]
        for cert in wanted:
            if cert not in {c for c, _ in targets}:
                targets.append((cert, pipeline.languages_for(cert)))

    print(f"{'cert':<14} {'lang':<5} {'ok':>4} {'bajo estándar':>14}   detalle")
    print("-" * 78)

    total_ok = total_bad = 0
    for cert, langs in targets:
        for lang in langs:
            ok = 0
            reasons: dict[str, int] = defaultdict(int)
            for kind in ("content.md", "exercises.md"):
                for path in sorted((REPO / "certs" / cert).glob(f"*/{lang}/{kind}")):
                    problems = quality.check_file(path)
                    if problems:
                        for problem in problems:
                            # agrupar "N bytes, por debajo del mínimo" en una
                            # sola categoría legible
                            key = ("tamaño" if "por debajo del mínimo" in problem
                                   else problem)
                            reasons[f"{kind}: {key}"] += 1
                    else:
                        ok += 1
            bad = sum(reasons.values())
            if ok == 0 and bad == 0:
                continue
            total_ok += ok
            total_bad += bad
            detail = ", ".join(f"{k} ×{v}" for k, v in sorted(reasons.items())) or "—"
            print(f"{cert:<14} {lang:<5} {ok:>4} {bad:>14}   {detail}")

    print("-" * 78)
    print(f"{'TOTAL':<20} {total_ok:>4} {total_bad:>14}")
    if total_bad:
        print("\nUmbrales en pipeline.yaml → quality. Regenerar con:")
        print("  scripts/run_batch.py <cert> --lang <lang>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
