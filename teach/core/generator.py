"""Generador de contenido — backends intercambiables.

Backends (env TEACH_BACKEND o --backend en la CLI):
  litellm   API del cluster (default). Config: LITELLM_BASE_URL, LITELLM_API_KEY,
            LITELLM_MODEL.
  claude    Claude Code CLI local:  claude -p "<prompt>"
  codex     OpenAI Codex CLI local: codex exec "<prompt>"
  gemini    Gemini CLI local (Antigravity): gemini -p "<prompt>"
  custom    Comando propio en TEACH_AGENT_CMD; recibe el prompt como último arg.

Con backends locales el flujo es: generar en tu máquina → revisar → pushear al
repo que publica la página (make publish).

Por cada tema genera en certs/<cert>/<topic>/:
  content.md       texto con ejemplos y referencias a docs oficiales
  exercises.md     pasos guiados con preguntas
  lab/break_fix.sh script romper-y-arreglar
  lab/lab.yaml     spec declarativo del lab (contrato con el runner)
  meta.yaml        trazabilidad: backend, modelo, fecha, fuentes usadas

Reglas: status 'edited' nunca se pisa (salvo --force); se regenera lo
'pending' y 'stale'.
"""

import datetime
import os
import shlex
import shutil
import subprocess
from collections.abc import Callable

import yaml

from . import certs


class GeneratorConfigError(Exception):
    pass


AGENT_COMMANDS = {
    "claude": ["claude", "-p"],
    "codex": ["codex", "exec"],
    "gemini": ["gemini", "-p"],
}

Completer = Callable[[str, str], str]


def _litellm_completer() -> tuple[Completer, dict]:
    base_url = os.environ.get("LITELLM_BASE_URL")
    api_key = os.environ.get("LITELLM_API_KEY")
    model = os.environ.get("LITELLM_MODEL")
    missing = [
        name
        for name, value in [
            ("LITELLM_BASE_URL", base_url),
            ("LITELLM_API_KEY", api_key),
            ("LITELLM_MODEL", model),
        ]
        if not value
    ]
    if missing:
        raise GeneratorConfigError(
            f"Faltan variables de entorno para el LiteLLM del cluster: {', '.join(missing)}"
        )
    from openai import OpenAI

    client = OpenAI(base_url=base_url, api_key=api_key)

    def complete(system: str, user: str) -> str:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return response.choices[0].message.content or ""

    return complete, {"backend": "litellm", "model": model, "base_url": base_url}


def _agent_completer(backend: str) -> tuple[Completer, dict]:
    if backend == "custom":
        raw = os.environ.get("TEACH_AGENT_CMD")
        if not raw:
            raise GeneratorConfigError(
                "Backend 'custom' requiere TEACH_AGENT_CMD (ej: 'mi-agente --flag')"
            )
        command = shlex.split(raw)
    else:
        command = AGENT_COMMANDS[backend]
    if shutil.which(command[0]) is None:
        raise GeneratorConfigError(
            f"No se encontró '{command[0]}' en el PATH. Instalar la CLI o elegir otro backend."
        )

    def complete(system: str, user: str) -> str:
        result = subprocess.run(
            [*command, f"{system}\n\n{user}"], capture_output=True, text=True
        )
        if result.returncode != 0:
            raise GeneratorConfigError(
                f"'{command[0]}' falló (exit {result.returncode}):\n{result.stderr.strip()}"
            )
        return result.stdout.strip()

    return complete, {"backend": backend, "model": command[0]}


def make_completer(backend: str | None = None) -> tuple[Completer, dict]:
    backend = backend or os.environ.get("TEACH_BACKEND", "litellm")
    if backend == "litellm":
        return _litellm_completer()
    if backend in AGENT_COMMANDS or backend == "custom":
        return _agent_completer(backend)
    valid = ["litellm", *AGENT_COMMANDS, "custom"]
    raise GeneratorConfigError(f"Backend desconocido '{backend}'. Válidos: {valid}")


SYSTEM = (
    "Sos un instructor experto creando material de estudio para una certificación. "
    "Escribís en español, con términos técnicos en inglés. El contenido es original: "
    "usás las fuentes solo como referencia y siempre las citás con sus URLs. "
    "Nunca copiás texto literal de materiales de terceros. Respondé SOLO con el "
    "material pedido, sin comentarios sobre el proceso."
)


def _topic_context(cert_meta: dict, topic: dict) -> str:
    sources = "\n".join(f"- {s}" for s in topic.get("sources", []))
    return (
        f"Certificación: {cert_meta.get('cert')} (examen {cert_meta.get('exam')}, "
        f"versión {cert_meta.get('version')})\n"
        f"Tema {topic['id']}: {topic['title']}\n"
        f"Peso en el examen: {topic.get('weight')}\n"
        f"Fuentes de referencia:\n{sources}\n"
    )


def generate_topic(
    cert_id: str, topic_id: str, force: bool = False, backend: str | None = None
) -> dict:
    """Genera todo el contenido de un tema. Devuelve resumen de lo escrito."""
    complete, backend_meta = make_completer(backend)

    post = certs.load(cert_id)
    topic = certs.get_topic(cert_id, topic_id)
    status = topic.get("status", "pending")

    if status == "edited" and not force:
        return {"topic": topic_id, "skipped": "edited (usar --force para pisar)"}
    if status == "generated" and not force:
        return {"topic": topic_id, "skipped": "ya generado (usar --force para regenerar)"}

    context = _topic_context(post.metadata, topic)
    weight = topic.get("weight", 1)

    content = complete(
        SYSTEM,
        f"{context}\n"
        f"Escribí el contenido de estudio de este tema en Markdown. Profundidad "
        f"proporcional al peso ({weight}). Incluí: explicación clara, ejemplos "
        f"concretos (comandos y salidas cuando aplique) y una sección final "
        f"'Referencias' con links a la documentación oficial.",
    )
    exercises = complete(
        SYSTEM,
        f"{context}\n"
        f"Escribí ejercicios guiados de este tema en Markdown: pasos numerados que "
        f"el estudiante ejecuta, y después de cada bloque una o más preguntas para "
        f"verificar comprensión. Al final, las respuestas en una sección "
        f"'<details>' colapsable.",
    )
    break_fix = complete(
        SYSTEM,
        f"{context}\n"
        f"Escribí un script bash 'break & fix' para este tema: rompe algo de forma "
        f"controlada y segura en una VM de laboratorio descartable y le explica al "
        f"estudiante qué síntoma va a ver y qué debe lograr para arreglarlo. "
        f"Incluí al final, comentada, la solución paso a paso. Respondé SOLO con "
        f"el script bash, sin markdown.",
    )

    directory = certs.content_dir(cert_id, topic_id)
    (directory / "lab").mkdir(parents=True, exist_ok=True)
    (directory / "content.md").write_text(content)
    (directory / "exercises.md").write_text(exercises)
    (directory / "lab" / "break_fix.sh").write_text(break_fix)

    lab_spec = {
        "cert": cert_id,
        "topic": topic_id,
        "title": topic["title"],
        "provider": "local",  # v1: un solo provider; el runner futuro lee esto
        "resources": {"vms": [{"name": "lab", "os": "debian-12", "cpus": 1, "ram_mb": 1024}]},
        "setup": ["break_fix.sh"],
    }
    (directory / "lab" / "lab.yaml").write_text(
        yaml.safe_dump(lab_spec, sort_keys=False, allow_unicode=True)
    )

    meta = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        **backend_meta,
        "sources": topic.get("sources", []),
    }
    (directory / "meta.yaml").write_text(yaml.safe_dump(meta, sort_keys=False))

    certs.set_topic_status(cert_id, topic_id, "generated")
    return {"topic": topic_id, "written": str(directory)}


def generate_cert(
    cert_id: str, force: bool = False, backend: str | None = None
) -> list[dict]:
    return [
        generate_topic(cert_id, str(topic["id"]), force=force, backend=backend)
        for topic in certs.topics(cert_id)
    ]
