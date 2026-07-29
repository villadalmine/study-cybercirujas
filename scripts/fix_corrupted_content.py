#!/usr/bin/env python3
"""Detecta y regenera content.md/exercises.md corruptos (el backend `claude`
devolvió un resumen de proceso tipo "Escribí certs/.../content.md..." en vez
del contenido pedido — bug de agente de código corriendo sin restricción de
herramientas, ver CHANGELOG.MD). teach/core/generator.py ya tiene el fix
(--disallowedTools) y valida contra este patrón antes de escribir, así que
esto es solo para limpiar lo que quedó corrupto de antes del fix.

Idempotente: escanea de nuevo en cada pasada, así que se puede cortar y
relanzar sin problema — converge solo hasta que la lista de sospechosos
quede vacía.
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
TEACH = REPO / ".venv" / "bin" / "teach"


def _cert_topic_ids(cert: str) -> list[str]:
    """Ids de todos los topics del temario (frontmatter del .md), para poder
    detectar labs faltantes sin depender de qué haya en disco."""
    md = (REPO / "certs" / f"{cert}.md").read_text()
    front = yaml.safe_load(md.split("---")[1])
    return [str(t["id"]) for t in front.get("topics", [])]

RECAP_PATTERNS = [
    r"^`?certs/",
    r"^(He |Wrote|Written|Escribí|Creado|Created|Content (file )?(written|created)"
    r"|Fichier créé|J'ai créé|Ich habe|Datei erstellt|已创建|作成しました|を作成)",
    r"content\.md`? (fue |was |está )?(creado|escrito|written|created)",
    r"verificad[oa] con `?wc -c`?",
    r"no es un stub",
    r"not a stub",
    r"chat.recap",
]
RECAP_RE = re.compile("|".join(RECAP_PATTERNS), re.IGNORECASE)
MIN_REAL_BYTES = 1500

TARGETS = [
    ("lpi-010-160", ["es", "en", "pt", "fr", "de", "zh", "ja"]),
    ("ckad", ["es", "en"]),
    ("cka", ["es", "en"]),
    ("cks", ["es", "en"]),
    ("kcna", ["es"]),
]


DEFAULT_LANG = "es"

FENCE_RE = re.compile(r"^```[a-zA-Z]*\n?|\n?```\s*$")


def strip_fences_in_place() -> int:
    """A veces el backend envuelve la respuesta entera en ```markdown ... ```
    (visto por primera vez en CKA, 2026-07-16) — no es corrupción, el
    contenido es real, pero rompe el render en la web. Se arregla en el
    archivo directamente (sin gastar cuota en regenerar vía AI).
    teach/core/generator.py ya lo evita para generaciones nuevas."""
    fixed = 0
    for cert, langs in TARGETS:
        cert_dir = REPO / "certs" / cert
        globs = [f"*/{lang}/{kind}" for lang in langs for kind in ("content.md", "exercises.md")]
        globs.append("*/lab/break_fix.sh")
        for pattern in globs:
            for f in sorted(cert_dir.glob(pattern)):
                text = f.read_text(errors="replace")
                if text.strip().startswith("```"):
                    f.write_text(FENCE_RE.sub("", text).strip() + "\n")
                    fixed += 1
    return fixed


def find_bad_combos() -> set[tuple[str, str, str]]:
    bad = set()
    for cert, langs in TARGETS:
        cert_dir = REPO / "certs" / cert
        # Enumerate topics from the syllabus, never from disk. Globbing
        # `*/{lang}` only sees language directories that already exist, so a
        # topic never generated in that language at all has no directory and
        # is silently skipped — the audit would then report "0 corrupt" for a
        # translation that is only a third done (hit for real on cks/en, which
        # stopped at 6 of 26 when the API quota ran out). Same blind spot the
        # 2026-07-16 fix closed for missing files inside an existing dir; this
        # closes it one level up, for the missing dir itself.
        try:
            topic_ids = _cert_topic_ids(cert)
        except (FileNotFoundError, IndexError):
            topic_ids = []
        for lang in langs:
            for topic in topic_ids:
                lang_dir = cert_dir / topic / lang
                for kind in ("content.md", "exercises.md"):
                    f = lang_dir / kind
                    if not f.exists():
                        bad.add((cert, topic, lang))
                        continue
                    text = f.read_text(errors="replace")
                    stripped = text.strip()
                    lines = stripped.splitlines()
                    first_line = lines[0] if lines else ""
                    last_line = lines[-1] if lines else ""
                    is_small = f.stat().st_size < MIN_REAL_BYTES
                    looks_recap = (
                        bool(RECAP_RE.search(first_line))
                        or bool(RECAP_RE.search(last_line))
                        or not stripped.startswith("#")
                    )
                    if is_small or looks_recap:
                        bad.add((cert, topic, lang))
        # break_fix.sh es compartido entre idiomas (una copia por tema, no
        # por lang) — solo se regenera con force+lang==DEFAULT_LANG. Reusa la
        # lista de topics del temario calculada arriba, por el mismo motivo:
        # detectar labs FALTANTES, no solo corruptos.
        for topic in topic_ids:
            f = cert_dir / topic / "lab" / "break_fix.sh"
            if not f.exists():
                bad.add((cert, topic, DEFAULT_LANG))
                continue
            text = f.read_text(errors="replace")
            stripped = text.strip()
            lines = stripped.splitlines()
            first_line = lines[0] if lines else ""
            last_line = lines[-1] if lines else ""
            is_small = f.stat().st_size < MIN_REAL_BYTES
            looks_recap = bool(RECAP_RE.search(first_line)) or bool(RECAP_RE.search(last_line))
            if is_small or looks_recap:
                bad.add((cert, topic, DEFAULT_LANG))
    return bad


def main() -> None:
    n_fenced = strip_fences_in_place()
    if n_fenced:
        print(f"Archivos con fence ```markdown envolvente arreglados en el lugar: {n_fenced}", flush=True)
    bad = sorted(find_bad_combos())
    print(f"Combos (cert, topic, lang) corruptos restantes: {len(bad)}", flush=True)
    for cert, topic, lang in bad:
        print(f"--- regenerando {cert} {topic} ({lang}) ---", flush=True)
        result = subprocess.run(
            [str(TEACH), "cert", "generate", cert, "--topic", topic,
             "--lang", lang, "--backend", "claude", "--force"],
            cwd=REPO,
        )
        if result.returncode != 0:
            print(f"    falló, se reintenta en la próxima pasada", flush=True)


if __name__ == "__main__":
    sys.exit(main())
