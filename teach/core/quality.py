"""Piso de calidad del material generado, igual para todos los backends.

Un backend distinto no debería producir un estándar distinto. Antes esto vivía
repartido y descoordinado: el generador aceptaba cualquier respuesta de más de
400 bytes, mientras que la auditoría rechazaba todo lo que bajara de 1500. Un
tema de 500 bytes pasaba el generador, se escribía a disco, quedaba marcado
`generated`, y recién después la auditoría lo llamaba corrupto. Dos estándares
en dos lugares, la misma clase de problema que las dos listas de targets.

Ahora los umbrales están en pipeline.yaml y los leen los dos.
"""
from __future__ import annotations

import re

from . import pipeline

# Nombre de archivo → clave en pipeline.yaml. El material se valida por lo que
# es, no por el idioma: un tema flojo en japonés es tan flojo como en español.
KINDS = {"content.md": "content", "exercises.md": "exercises"}


def rules(kind: str) -> dict:
    """Reglas para 'content' o 'exercises'. Sin bloque `quality` en el YAML no
    hay reglas, y todo pasa — el piso es opcional, no un requisito de arranque."""
    return dict((pipeline.load().get("quality") or {}).get(kind) or {})


def check(kind: str, text: str) -> list[str]:
    """Devuelve los problemas encontrados. Lista vacía = cumple el piso.

    `kind` es 'content' o 'exercises'. No mide si el material es *bueno* —eso
    no se automatiza— sino si tiene el tamaño mínimo y la estructura que el
    propio prompt pidió. Es un piso, no una nota.
    """
    spec = rules(kind)
    if not spec:
        return []

    problems: list[str] = []
    stripped = (text or "").strip()

    min_bytes = spec.get("min_bytes")
    if min_bytes and len(stripped.encode("utf-8")) < int(min_bytes):
        problems.append(
            f"{len(stripped.encode('utf-8'))} bytes, por debajo del mínimo de {min_bytes}"
        )

    prefix = spec.get("starts_with")
    if prefix and not stripped.startswith(str(prefix)):
        problems.append(f"no empieza con {prefix!r}")

    for requirement in spec.get("requires") or []:
        pattern = requirement.get("pattern")
        if not pattern:
            continue
        if not re.search(pattern, stripped, re.IGNORECASE | re.MULTILINE):
            problems.append(f"falta {requirement.get('description') or pattern}")

    return problems


def check_file(path) -> list[str]:
    """Igual que `check`, resolviendo el tipo por el nombre del archivo. Un
    archivo que no se puede leer se reporta como problema en vez de asumirse
    sano: si no se puede probar que cumple, no cumple."""
    kind = KINDS.get(getattr(path, "name", ""))
    if kind is None:
        return []
    try:
        return check(kind, path.read_text(errors="replace"))
    except OSError as error:
        return [f"ilegible: {error}"]
