#!/usr/bin/env python3
"""Verifica que las fuentes citadas existan realmente.

Qué detecta y qué no
--------------------
Esto NO valida que la explicación sea correcta. Detecta una firma concreta y
frecuente de alucinación: la URL de documentación inventada — plausible, bien
formada, con la estructura de rutas correcta del sitio oficial, y que no
existe. Ejemplo real encontrado en este repo:

    https://kubernetes.io/docs/tasks/debug/debug-application/debug-ephemeral-container/
    (la página real es .../debug-running-pod/#ephemeral-container)

Un modelo que inventa la URL de respaldo de una afirmación suele estar
inventando también la afirmación. Es una señal indirecta, pero es objetiva,
determinista y no cuesta cuota de API.

Solo mira la sección de Referencias: las URLs dentro de bloques de código son
ejemplos (`http://app.example.com`, direcciones de cluster) y no citas.

    scripts/check_citations.py                 # todo el repo
    scripts/check_citations.py certs/cks       # un subárbol
    scripts/check_citations.py --sample 50     # muestra rápida
"""
from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CACHE = Path("/tmp/teach-citations-cache.json")

REFS_SECTION = re.compile(
    r"^#+ *(?:Referencias|References|Références|Referenzen|Referências|参考文献|参考)\s*$(.*)",
    re.MULTILINE | re.DOTALL | re.IGNORECASE,
)
URL = re.compile(r"https?://[^\s)\]>\"'`]+")

# 403/429/418 son bloqueo de bots (gnu.org, freedesktop), no enlaces muertos.
# Marcarlos como rotos llenaría el informe de ruido y lo volvería inútil.
BLOCKED = {401, 403, 405, 418, 429, 503}


def citations(path: Path) -> set[str]:
    match = REFS_SECTION.search(path.read_text(errors="replace"))
    if not match:
        return set()
    return {u.rstrip(".,;:>") for u in URL.findall(match.group(1))}


def status(url: str, cache: dict) -> int | str:
    if url in cache:
        return cache[url]
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "Mozilla/5.0 (teach-plat link check)"}
    )
    try:
        code: int | str = urllib.request.urlopen(request).status
    except urllib.error.HTTPError as error:
        # Algunos sitios rechazan HEAD pero responden GET. Reintentar antes de
        # acusar a la cita de inexistente.
        if error.code in (405, 403):
            try:
                code = urllib.request.urlopen(
                    urllib.request.Request(
                        url, headers={"User-Agent": "Mozilla/5.0 (teach-plat link check)"}
                    )
                ).status
            except Exception:
                code = error.code
        else:
            code = error.code
    except Exception as error:
        code = type(error).__name__
    cache[url] = code
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", default=["certs"])
    parser.add_argument("--sample", type=int, default=0,
                        help="verificar solo N URLs al azar (revisión rápida)")
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()

    socket.setdefaulttimeout(args.timeout)
    by_url: dict[str, list[str]] = defaultdict(list)
    for base in args.paths:
        for path in sorted(Path(base).glob("**/content.md")):
            for url in citations(path):
                by_url[url].append(str(path))

    urls = sorted(by_url)
    if args.sample and args.sample < len(urls):
        import random

        random.seed(11)
        urls = sorted(random.sample(urls, args.sample))

    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    print(f"{len(by_url)} citas únicas; verificando {len(urls)}", flush=True)

    broken: list[tuple[str, int | str, list[str]]] = []
    for i, url in enumerate(urls, 1):
        code = status(url, cache)
        if code != 200 and code not in BLOCKED:
            broken.append((url, code, by_url[url]))
        if i % 25 == 0:
            print(f"  {i}/{len(urls)}", flush=True)
    CACHE.write_text(json.dumps(cache, indent=2))

    if not broken:
        print("\nTodas las citas resuelven.")
        return 0

    print(f"\n{len(broken)} citas no resuelven — revisar si la fuente fue inventada:\n")
    for url, code, files in sorted(broken, key=lambda b: str(b[1])):
        print(f"  [{code}] {url}")
        for f in sorted(files)[:3]:
            print(f"        {f}")
        if len(files) > 3:
            print(f"        (+{len(files) - 3} archivos más)")
    print("\nUn 403/429 es bloqueo de bots y no se reporta. Un 404 sobre un "
          "dominio oficial suele ser una URL inventada por el modelo.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
