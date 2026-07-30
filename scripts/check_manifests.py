#!/usr/bin/env python3
"""Verifica que los manifiestos incrustados en el material parseen.

Un manifiesto YAML roto en material de estudio de Kubernetes es peor que
inútil: el estudiante lo copia, falla, y no sabe si se equivocó él o el
material. A diferencia de la prosa, esto es objetivo — parsea o no parsea — y
no cuesta cuota.

Alcance honesto: comprueba **sintaxis**, no validez contra la API de
Kubernetes. Un `spec.replicaCount` inventado (el campo real es `replicas`)
parsea perfecto y pasa este chequeo. Para eso hace falta validación contra los
esquemas reales — ver WORKFLOW.md, sección de verificación.

    scripts/check_manifests.py              # todo el repo
    scripts/check_manifests.py certs/cks    # un subárbol
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

BLOCK = re.compile(r"^```(yaml|yml|json)[ \t]*\n(.*?)^```", re.MULTILINE | re.DOTALL)

# Elisión didáctica: "..." para recortar una salida larga, tanto en su propia
# línea como al final de una (`"items":[{...},...`).
ELISION = re.compile(r"\.\.\.")

# Un documento YAML no puede empezar indentado: si el bloque arranca con
# espacios, es un fragmento que muestra parte de un manifiesto más grande, no
# un manifiesto que el estudiante vaya a aplicar entero.
FRAGMENT = re.compile(r"\A\s*\n?[ \t]+\S")

# Plantillas Helm/Go y Jinja: NO son YAML plano válido a propósito, ese es el
# punto de una plantilla. Marcarlas como rotas convertiría el informe en ruido.
TEMPLATED = re.compile(r"\{\{|\{%")

# Bloques etiquetados `yaml` cuyo contenido real es un comando de shell que
# lleva YAML adentro (`cat <<'EOF' | kubectl apply -f -`). La etiqueta es
# imprecisa pero el material es correcto y el estudiante lo usa tal cual.
SHELL_START = re.compile(
    r"^\s*(cat|kubectl|helm|echo|curl|sudo|docker|\$|#!)\b|<<-?\s*['\"]?EOF"
)


def _skip(body: str) -> bool:
    return bool(
        ELISION.search(body)
        or TEMPLATED.search(body)
        or SHELL_START.search(body)
        or FRAGMENT.match(body)
    )


def problems(path: Path) -> list[tuple[int, str]]:
    found = []
    text = path.read_text(errors="replace")
    for match in BLOCK.finditer(text):
        tag, body = match.group(1), match.group(2)
        if _skip(body):
            continue
        line = text[: match.start()].count("\n") + 1
        try:
            if tag == "json":
                json.loads(body)
            else:
                list(yaml.safe_load_all(body))
        except Exception as error:
            first = str(error).splitlines()[0][:110]
            found.append((line, f"{tag}: {first}"))
    return found


def main() -> int:
    bases = sys.argv[1:] or ["certs"]
    total = broken = 0
    report: list[str] = []
    for base in bases:
        for path in sorted(Path(base).glob("**/*.md")):
            found = problems(path)
            total += 1
            if found:
                broken += 1
                for line, message in found:
                    report.append(f"  {path}:{line}  {message}")

    if not report:
        print(f"{total} archivos revisados, todos los manifiestos parsean.")
        return 0
    print(f"{total} archivos revisados, {broken} con manifiestos que no parsean:\n")
    print("\n".join(report))
    print("\nEsto valida sintaxis, no campos de la API de Kubernetes.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
