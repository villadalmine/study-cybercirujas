#!/usr/bin/env python3
"""Genera STATUS.MD: matriz cert x idioma x lab, y path x idioma de video.

Se lee siempre del filesystem real (conteo de archivos), nunca de un status
a mano — la lección de esta sesión es que "N/N temas" no prueba nada si no
se cuenta content.md, exercises.md y break_fix.sh por separado (ver
CHANGELOG.MD 2026-07-16/17). Correr de nuevo después de cualquier
generación para que el estado quede al día:

    .venv/bin/python3 scripts/status_matrix.py
"""
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
LANGS = ["es", "en", "fr", "de", "zh", "ja", "pt"]
VIDEO_LANGS = ["es", "en", "de", "zh", "ja"]


def cert_topics(cert_id: str) -> list[dict]:
    path = REPO / "certs" / f"{cert_id}.md"
    if not path.exists():
        return []
    front = yaml.safe_load(path.read_text().split("---")[1])
    return front.get("topics") or []


def lang_cell(cert_dir: Path, lang: str, n: int) -> str:
    c = len(list(cert_dir.glob(f"*/{lang}/content.md")))
    e = len(list(cert_dir.glob(f"*/{lang}/exercises.md")))
    if c == n and e == n:
        return "✅"
    if c == 0 and e == 0:
        return "❌"
    return f"🔶 {c}/{n}c·{e}/{n}e"


def lab_cell(cert_dir: Path, n: int) -> str:
    lab = len(list(cert_dir.glob("*/lab/break_fix.sh")))
    if lab == n:
        return "✅"
    if lab == 0:
        return "❌"
    return f"🔶 {lab}/{n}"


def main() -> None:
    catalog = yaml.safe_load((REPO / "catalog.yaml").read_text())
    lines = [
        "# Estado del contenido",
        "",
        "Generado por `scripts/status_matrix.py` desde el filesystem real "
        "(conteo de archivos, no un status a mano) — correr de nuevo después "
        "de cualquier generación, no editar directamente.",
        "",
        "✅ completo · 🔶 parcial (detalle) · ❌ no empezado · – no aplica "
        "(sin temario snapshoteado todavía)",
        "",
        "## Certificaciones",
        "",
        "| Cert | Temas | " + " | ".join(l.upper() for l in LANGS) + " | Labs |",
        "|---|---|" + "---|" * len(LANGS) + "---|",
    ]
    for cert_id, cert in catalog["certs"].items():
        topics = cert_topics(cert_id)
        n = len(topics)
        cert_dir = REPO / "certs" / cert_id
        if n == 0:
            row = [f"`{cert_id}`", "–"] + ["–"] * len(LANGS) + ["–"]
        else:
            row = [f"`{cert_id}`", str(n)]
            row += [lang_cell(cert_dir, lang, n) for lang in LANGS]
            row.append(lab_cell(cert_dir, n))
        lines.append("| " + " | ".join(row) + " |")

    lines += ["", "## Videos de paths", "",
              "| Path | " + " | ".join(l.upper() for l in VIDEO_LANGS) + " |",
              "|---|" + "---|" * len(VIDEO_LANGS)]
    for slug, path in (catalog.get("paths") or {}).items():
        if path.get("type"):
            continue  # achievement/info no llevan video
        row = [f"`{slug}`"]
        for lang in VIDEO_LANGS:
            video = REPO / "media" / "paths" / slug / lang / "video.mp4"
            row.append("✅" if video.exists() else "❌")
        lines.append("| " + " | ".join(row) + " |")

    (REPO / "STATUS.MD").write_text("\n".join(lines) + "\n")
    print("Escrito STATUS.MD")


if __name__ == "__main__":
    sys.exit(main())
