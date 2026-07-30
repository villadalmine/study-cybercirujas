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
import json
import os
import re
import shlex
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

import yaml

from . import certs, quality


class GeneratorConfigError(Exception):
    pass


# claude -p corre en el cwd del repo con acceso a herramientas por default:
# sin restricción, el modelo a veces actúa como agente de código (explora el
# repo, intenta escribir el archivo él mismo) y lo que llega por stdout es un
# resumen de esa acción ("ja/content.md に完全な学習コンテンツを書きました...")
# en vez del contenido pedido. --disallowedTools lo fuerza a responder en
# texto plano, que es lo único que puede hacer sin herramientas.
_CLAUDE_NO_TOOLS = (
    "Write,Edit,Bash,Read,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task"
)

AGENT_COMMANDS = {
    "claude": ["claude", "-p", "--disallowedTools", _CLAUDE_NO_TOOLS, "--"],
    "codex": ["codex", "exec"],
    "gemini": ["gemini", "-p"],
}

# Firma del bug de arriba (y variantes: "Escribí", "Wrote", "Fichier créé",
# "已创建", "を作成しました", autorreferencias a "content.md`", claims de
# haber verificado con wc -c) — si el completer devuelve esto en vez del
# contenido pedido, mejor fallar fuerte que guardar un stub silencioso.
_RECAP_RE = re.compile(
    r"^`?certs/"
    r"|^(He |Wrote|Written|Escribí|Creado|Created|Content (file )?(written|created)"
    r"|Fichier créé|J'ai créé|Ich habe|Datei erstellt|已创建|作成しました|を作成"
    r"|Listo\.|Done\.|Fertig\.|Task complete)"
    # This has to stay the full phrase ("content.md was created"), not the bare
    # mention: a plain `content\.md\b` rejects legitimate material that names
    # the file — explaining the certs/<cert>/<topic>/<lang>/ layout is an
    # ordinary case — and fails generation for no real reason.
    r"|content\.md`? (fue |was |está )?(creado|escrito|written|created)"
    r"|verificad[oa] con `?wc -c`?"
    r"|no es un stub|not a stub",
    re.IGNORECASE,
)


def _strip_fence(text: str) -> str:
    """A veces el backend envuelve toda la respuesta en un fence ```markdown
    ... ``` a pesar de que el prompt pide el contenido "pelado" — no es
    corrupción (el contenido real está bien), pero rompe el render en la web."""
    stripped = text.strip()
    stripped = re.sub(r"^```[a-zA-Z]*\n?", "", stripped)
    stripped = re.sub(r"\n?```\s*$", "", stripped)
    return stripped.strip()


def _reject_if_recap(text: str, label: str) -> str:
    text = _strip_fence(text)
    lines = text.strip().splitlines()
    # el resumen de proceso puede aparecer al principio (bug original) O al
    # final (visto en lpi-010-160/2.3/de: contenido real completo + un último
    # párrafo tipo "no tengo acceso a herramientas de archivo, así que acá va
    # el texto para pegar a mano" que un chequeo solo-primera-línea no agarra)
    first_line = lines[0] if lines else ""
    last_line = lines[-1] if lines else ""
    if len(text.strip()) < 400 or _RECAP_RE.search(first_line) or _RECAP_RE.search(last_line):
        raise GeneratorConfigError(
            f"El backend devolvió un resumen de proceso en vez de {label} "
            f"(bug conocido de agentes de código corriendo sin restricción de "
            f"herramientas). Primera línea: {first_line[:150]!r}"
        )
    return text

def _reject_if_substandard(text: str, kind: str, topic_id: str, lang: str) -> None:
    """Stop generation when material does not meet the pipeline.yaml floor.

    Deliberately fails instead of saving: substandard material written to disk
    gets marked `generated` and is only discovered by the next audit, if anyone
    remembers to run one. Losing the call costs less than quietly polluting the
    syllabus.
    """
    problems = quality.check(kind, text)
    if problems:
        raise GeneratorConfigError(
            f"{kind} for {topic_id} ({lang}) is below the quality floor: "
            + "; ".join(problems)
            + ". Thresholds in pipeline.yaml -> quality."
        )


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
        # stdin=DEVNULL: the prompt travels as an argument, never on stdin. Without
        # this the agent CLIs wait ~3s per call for input that never comes and emit
        # a warning on stderr, which used to mask the real error below.
        result = subprocess.run(
            [*command, f"{system}\n\n{user}"],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            # Report both streams: agent CLIs write warnings to stderr and the
            # actual failure to stdout, so picking one hides the diagnosis.
            parts = [
                f"{name}:\n{stream.strip()}"
                for name, stream in (("stderr", result.stderr), ("stdout", result.stdout))
                if stream.strip()
            ]
            detail = "\n".join(parts) or "(sin salida)"
            raise GeneratorConfigError(
                f"'{command[0]}' falló (exit {result.returncode}):\n{detail}"
            )
        return result.stdout.strip()

    return complete, {"backend": backend, "model": command[0]}


def _antigravity_completer() -> tuple[Completer, dict]:
    """Backend for active Antigravity AI session (uses IDE session without external token costs).
    
    Note for Claude & future agents: This backend is used during interactive Antigravity agent
    sessions to route completions through the agent rather than making paid external API calls.
    It executes all native generator.py validations, file creation, and certs.md status updates.
    """
    prompt_file = Path(os.environ.get("ANTIGRAVITY_PROMPT_FILE", "/tmp/antigravity_prompt.json"))
    resp_file = Path(os.environ.get("ANTIGRAVITY_RESP_FILE", "/tmp/antigravity_response.txt"))
    cache_file = Path("/tmp/antigravity_cache.json")

    def complete(system: str, user: str) -> str:
        import hashlib
        cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
        # The key covers `system`, not just `user`: language lives only in the
        # system prompt ("Escribís en English"), while the user prompt is
        # identical across languages for a given topic. Keyed on `user` alone,
        # generating 1.1 in Spanish and then in English returned the cached
        # Spanish entry and wrote Spanish into en/.
        key = hashlib.md5(f"{system}\n\n{user}".encode("utf-8")).hexdigest()
        if key in cache:
            return cache[key]

        if resp_file.exists():
            content = resp_file.read_text().strip()
            resp_file.unlink()
            cache[key] = content
            cache_file.write_text(json.dumps(cache, indent=2))
            return content

        prompt_file.write_text(json.dumps({"system": system, "user": user}, indent=2))
        raise GeneratorConfigError(
            "Antigravity backend prompt written to /tmp/antigravity_prompt.json. "
            "Awaiting response in /tmp/antigravity_response.txt"
        )

    return complete, {"backend": "antigravity", "model": "antigravity-session"}



def make_completer(backend: str | None = None) -> tuple[Completer, dict]:
    backend = backend or os.environ.get("TEACH_BACKEND", "litellm")
    if backend == "litellm":
        return _litellm_completer()
    if backend == "antigravity":
        return _antigravity_completer()
    if backend in AGENT_COMMANDS or backend == "custom":
        return _agent_completer(backend)
    valid = ["litellm", *AGENT_COMMANDS, "custom", "antigravity"]
    raise GeneratorConfigError(f"Backend desconocido '{backend}'. Válidos: {valid}")



LANG_NAMES = {
    "es": "español", "en": "English", "fr": "français", "de": "Deutsch",
    "zh": "中文 (chino simplificado)", "ja": "日本語", "pt": "português",
}


def _system(lang: str) -> str:
    return (
        "Sos un Principal Platform Architect e Instructor SRE Senior redactando material "
        "de estudio avanzado de nivel producción para certificaciones CNCF. "
        f"Escribís en {LANG_NAMES.get(lang, lang)}, manteniendo los términos técnicos en inglés. "
        "Tu objetivo es que el estudiante adquiera una comprensión técnica profunda de producción: "
        "explica la mecánica interna, arquitectura, trade-offs, manifiestos completos sintácticamente "
        "válidos, comandos CLI reales con sus salidas esperadas, y técnicas avanzadas de diagnóstico. "
        "El contenido es original: citás fuentes oficiales con sus URLs. "
        "Respondé SOLO con el material pedido, sin comentarios sobre el proceso."
    )


def _topic_context(cert_meta: dict, topic: dict) -> str:
    sources = "\n".join(f"- {s}" for s in topic.get("sources", []))
    return (
        f"Certificación: {cert_meta.get('cert')} (examen {cert_meta.get('exam')}, "
        f"versión {cert_meta.get('version')})\n"
        f"Tema {topic['id']}: {topic['title']}\n"
        f"Peso en el examen: {topic.get('weight', 'N/A')}\n"
        f"Fuentes de referencia:\n{sources}"
    )


def generate_topic(
    cert_id: str,
    topic_id: str,
    force: bool = False,
    backend: str | None = None,
    lang: str = certs.DEFAULT_LANG,
) -> dict:
    """Genera el contenido de un tema en un idioma. El lab es compartido."""
    if lang not in certs.LANGS:
        raise GeneratorConfigError(f"Idioma '{lang}' no soportado. Válidos: {certs.LANGS}")
    complete, backend_meta = make_completer(backend)

    post = certs.load(cert_id)
    topic = certs.get_topic(cert_id, topic_id)
    status = topic.get("status", "pending")
    already = lang in certs.topic_langs(cert_id, topic_id)

    # A 'stale' topic holds content answering a syllabus that changed. An
    # existence check cannot detect that: the files are there, just outdated.
    # `topic_outdated_langs` compares each language against the moment of the
    # change, so this regenerates only the ones left behind and does not pay
    # again for those already rebuilt.
    outdated = status == "stale" and lang in certs.topic_outdated_langs(cert_id, topic_id)

    if status == "edited" and lang == certs.DEFAULT_LANG and not force:
        return {"topic": topic_id, "skipped": "edited (usar --force para pisar)"}
    if already and not force and not outdated:
        return {"topic": topic_id, "skipped": f"ya generado en {lang} (usar --force)"}

    system = _system(lang)
    context = _topic_context(post.metadata, topic)
    weight = topic.get("weight", 1)

    content = _reject_if_recap(
        complete(
            system,
            f"{context}\n"
            f"Redactá el material de estudio con perfil técnico avanzado SRE/Platform Architect. "
            f"Profundidad proporcional al peso ({weight}). Incluí: 1) Motivación y problema "
            f"arquitectónico de producción, 2) Comparativas técnicas con tablas de trade-offs, "
            f"3) Manifiestos YAML e infraestructura completos sin recortar, 4) Comandos CLI y "
            f"salidas de terminal reales ($), 5) Guía de verificación y diagnóstico de fallas, "
            f"6) Sección final 'Referencias' con URLs oficiales.",
        ),
        "el contenido",
    )
    exercises = _reject_if_recap(
        complete(
            system,
            f"{context}\n"
            f"Escribí ejercicios guiados de este tema en Markdown: pasos numerados que "
            f"el estudiante ejecuta, y después de cada bloque una o más preguntas para "
            f"verificar comprensión. Al final, las respuestas en una sección "
            f"'<details>' colapsable.",
        ),
        "los ejercicios",
    )

    # The quality floor is applied BEFORE writing and is identical for every
    # backend. Writing first and auditing later left thin material on disk
    # marked `generated`, which is how 45 topics averaging ~1000 bytes came to
    # be reported complete. Fail hard: nothing is saved half-done.
    _reject_if_substandard(content, "content", topic_id, lang)
    _reject_if_substandard(exercises, "exercises", topic_id, lang)

    directory = certs.content_dir(cert_id, topic_id)
    lang_dir = directory / lang
    lang_dir.mkdir(parents=True, exist_ok=True)
    (lang_dir / "content.md").write_text(content)
    (lang_dir / "exercises.md").write_text(exercises)

    # el lab es compartido entre idiomas: se crea una vez (o se regenera con
    # --force en el idioma default)
    lab_dir = directory / "lab"
    if not (lab_dir / "break_fix.sh").exists() or (force and lang == certs.DEFAULT_LANG):
        break_fix = _reject_if_recap(
            complete(
                system,
                f"{context}\n"
                f"Escribí un script bash 'break & fix' para este tema: rompe algo de forma "
                f"controlada y segura en una VM de laboratorio descartable y le explica al "
                f"estudiante qué síntoma va a ver y qué debe lograr para arreglarlo. "
                f"Incluí al final, comentada, la solución paso a paso. Respondé SOLO con "
                f"el script bash, sin markdown.",
            ),
            "el script break&fix",
        )
        lab_dir.mkdir(parents=True, exist_ok=True)
        (lab_dir / "break_fix.sh").write_text(break_fix)
        lab_spec = {
            "cert": cert_id,
            "topic": topic_id,
            "title": topic["title"],
            "provider": "local",  # v1: un solo provider; el runner futuro lee esto
            "resources": {"vms": [{"name": "lab", "os": "debian-12", "cpus": 1, "ram_mb": 1024}]},
            "setup": ["break_fix.sh"],
        }
        (lab_dir / "lab.yaml").write_text(
            yaml.safe_dump(lab_spec, sort_keys=False, allow_unicode=True)
        )

    meta = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "lang": lang,
        **backend_meta,
        "sources": topic.get("sources", []),
    }
    (lang_dir / "meta.yaml").write_text(yaml.safe_dump(meta, sort_keys=False))

    if status == "stale":
        # Do not mark the topic current until NO language is left behind.
        # Clearing it when Spanish — the default language — is rebuilt would
        # freeze the translations on the old syllabus with nothing reporting it.
        if not certs.topic_outdated_langs(cert_id, topic_id):
            certs.clear_topic_stale(cert_id, topic_id)
    elif lang == certs.DEFAULT_LANG:
        certs.set_topic_status(cert_id, topic_id, "generated")
    return {"topic": topic_id, "written": str(lang_dir)}


def generate_cert(
    cert_id: str,
    force: bool = False,
    backend: str | None = None,
    lang: str = certs.DEFAULT_LANG,
) -> list[dict]:
    return [
        generate_topic(cert_id, str(topic["id"]), force=force, backend=backend, lang=lang)
        for topic in certs.topics(cert_id)
    ]
