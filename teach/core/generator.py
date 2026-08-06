"""Content generator — interchangeable backends.

Backends (env TEACH_BACKEND or --backend on the CLI):
  litellm   Cluster API (default). Config: LITELLM_BASE_URL, LITELLM_API_KEY,
            LITELLM_MODEL.
  claude    Local Claude Code CLI:  claude -p "<prompt>"
  codex     Local OpenAI Codex CLI: codex exec "<prompt>"
  gemini    Local Gemini CLI (Antigravity): gemini -p "<prompt>"
  custom    Your own command in TEACH_AGENT_CMD; receives the prompt as its
            last argument.

With local backends the flow is: generate on your machine -> review -> push to
the repo that publishes the site (make publish).

For each topic it generates, under certs/<cert>/<topic>/:
  content.md       text with examples and references to official docs
  exercises.md     guided steps with questions
  lab/break_fix.sh break-and-fix script
  lab/lab.yaml     declarative lab spec (the contract with the runner)
  meta.yaml        traceability: backend, model, date, sources used

Rules: `edited` status is never overwritten (except with --force); `pending`
and `stale` are regenerated.

NOTE: the prompt strings below (`_system`, `_topic_context` and the generation
instructions) are deliberately still in Spanish. They are not comments — they
are what the model receives, and the entire existing corpus was produced with
them. Translating them would change generated output and invalidate the
baseline the quality floor in pipeline.yaml was calibrated against, so it is a
content decision rather than a cleanup one. See BACKLOG.md.
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

from . import certs, pipeline, quality


class GeneratorConfigError(Exception):
    pass


# `claude -p` runs in the repo cwd with tool access by default: unrestricted,
# the model sometimes acts as a coding agent (explores the repo, tries to write
# the file itself) and what arrives on stdout is a summary of that action
# ("ja/content.md に完全な学習コンテンツを書きました...") instead of the
# requested content. --disallowedTools forces a plain-text answer, which is all
# it can do without tools.
_CLAUDE_NO_TOOLS = (
    "Write,Edit,Bash,Read,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task"
)

# `--output-format json` is what makes spend measurable. The plain text mode
# answers and tells you nothing; the JSON envelope carries `result` (the answer)
# plus `usage`, `modelUsage` and `total_cost_usd`, so every completion can be
# attributed to a model and a token count instead of being guessed at from the
# wall clock. Only the claude CLI has it — the others stay plain text.
AGENT_COMMANDS = {
    "claude": ["claude", "-p", "--output-format", "json",
               "--disallowedTools", _CLAUDE_NO_TOOLS, "--"],
    "codex": ["codex", "exec"],
    "gemini": ["agy", "-p"],
}

USAGE_LOG = Path.home() / ".local" / "state" / "teach-plat" / "usage.jsonl"

# What the completion currently being run is FOR. `complete(system, user)` has no
# idea which topic it serves, and attributing spend after the fact by correlating
# timestamps against resume.log is guesswork. Set by generate_topic /
# translate_topic around each call.
_usage_context: dict = {}


def _record_usage(envelope: dict) -> None:
    """Append one line per completion: what it was for, and what it cost.

    Never raises. Telemetry that can break a generation is worse than no
    telemetry — the run matters, the measurement does not.
    """
    try:
        usage = envelope.get("usage") or {}
        models = {
            name: {
                "in": info.get("inputTokens"),
                "out": info.get("outputTokens"),
                "cache_read": info.get("cacheReadInputTokens"),
                "cache_write": info.get("cacheCreationInputTokens"),
                "cost_usd": info.get("costUSD"),
            }
            for name, info in (envelope.get("modelUsage") or {}).items()
        }
        row = {
            "at": datetime.datetime.now().isoformat(timespec="seconds"),
            **_usage_context,
            "cost_usd": envelope.get("total_cost_usd"),
            "duration_ms": envelope.get("duration_ms"),
            "output_tokens": usage.get("output_tokens"),
            "cache_read": usage.get("cache_read_input_tokens"),
            "cache_write": usage.get("cache_creation_input_tokens"),
            "models": models,
        }
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with USAGE_LOG.open("a") as handle:
            handle.write(json.dumps(row) + "\n")
    except Exception:
        pass

# Signature of the bug above (plus variants: "Escribí", "Wrote", "Fichier
# créé", "已创建", "を作成しました", self-references to "content.md`", claims of
# having verified with wc -c). If the completer returns this instead of the
# requested content, failing hard beats saving a silent stub.
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
    """Backends sometimes wrap the whole response in a ```markdown ... ``` fence
    even though the prompt asks for bare content — not corruption (the real
    content is fine), but it breaks rendering on the web."""
    stripped = text.strip()
    stripped = re.sub(r"^```[a-zA-Z]*\n?", "", stripped)
    stripped = re.sub(r"\n?```\s*$", "", stripped)
    return stripped.strip()


def _reject_if_recap(text: str, label: str) -> str:
    text = _strip_fence(text)
    lines = text.strip().splitlines()
    # The process recap can appear at the start (original bug) OR at the end
    # (seen in lpi-010-160/2.3/de: complete real content plus a closing
    # paragraph along the lines of "I have no file tools, so here is the text to
    # paste by hand") which a first-line-only check does not catch.
    first_line = lines[0] if lines else ""
    last_line = lines[-1] if lines else ""
    if len(text.strip()) < 400 or _RECAP_RE.search(first_line) or _RECAP_RE.search(last_line):
        raise GeneratorConfigError(
            f"The backend returned a process recap instead of {label} "
            f"(known bug of coding agents running without tool restrictions). "
            f"First line: {first_line[:150]!r}"
        )
    return text

def _reject_if_substandard(text: str, kind: str, topic_id: str, lang: str) -> None:
    """Stop generation when material does not meet the pipeline.yaml floor.

    Deliberately fails instead of saving: substandard material written to disk
    gets marked `generated` and is only discovered by the next audit, if anyone
    remembers to run one. Losing the call costs less than quietly polluting the
    syllabus.

    The rejected text IS kept, under `.rejected/`, because discarding it made a
    repeating failure impossible to diagnose without spending another call. cks
    4.1 was regenerated six times across four quota windows, rejected every time
    for the same reason, and left no evidence of what the model had actually
    written — the quota disappeared within an hour of each renewal with nothing
    to show. One file on disk would have answered it immediately.
    """
    problems = quality.check(kind, text)
    if not problems:
        return

    try:
        debris = pipeline.REPO / ".rejected" / f"{topic_id}-{lang}-{kind}.md"
        debris.parent.mkdir(parents=True, exist_ok=True)
        debris.write_text(
            f"<!-- rejected {datetime.datetime.now().isoformat(timespec='seconds')}: "
            f"{'; '.join(problems)} -->\n\n{text}"
        )
    except OSError:
        # Diagnostics must never be the reason a run dies.
        pass

    raise GeneratorConfigError(
        f"{kind} for {topic_id} ({lang}) is below the quality floor: "
        + "; ".join(problems)
        + f". Thresholds in pipeline.yaml -> quality. "
        f"Rejected text kept in .rejected/{topic_id}-{lang}-{kind}.md"
    )


def _write_meta(lang_dir: Path, lang: str, backend_meta: dict, topic: dict) -> None:
    """Provenance for one language directory: who made it, with what, when.

    Written together with the content it describes. It used to be written after
    the lab, so a process that died in between left content nobody could trace —
    which is the one defect that cannot be repaired later, because the answer is
    simply gone.
    """
    lang_dir.mkdir(parents=True, exist_ok=True)
    (lang_dir / "meta.yaml").write_text(yaml.safe_dump({
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "lang": lang,
        **backend_meta,
        "sources": topic.get("sources", []),
    }, sort_keys=False))


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
            f"Missing environment variables for the cluster LiteLLM: {', '.join(missing)}"
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
                "Backend 'custom' requires TEACH_AGENT_CMD (e.g. 'my-agent --flag')"
            )
        command = shlex.split(raw)
    else:
        command = AGENT_COMMANDS[backend]
    if shutil.which(command[0]) is None:
        raise GeneratorConfigError(
            f"'{command[0]}' not found on PATH. Install the CLI or pick another backend."
        )

    def complete(system: str, user: str) -> str:
        # stdin=DEVNULL: the prompt travels as an argument, never on stdin. Without
        # this the agent CLIs wait ~3s per call for input that never comes and emit
        # a warning on stderr, which used to mask the real error below.
        # A bounded wait, so a CLI that never returns fails instead of hanging.
        # An unbounded call also stalls the unattended timer, whose guard sees a
        # live process and keeps skipping.
        timeout = pipeline.budget().get("completion_timeout_seconds") or None
        try:
            result = subprocess.run(
                [*command, f"{system}\n\n{user}"],
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            raise GeneratorConfigError(
                f"'{command[0]}' produced no answer within {timeout}s "
                f"(completion_timeout_seconds in pipeline.yaml). Treated as a "
                f"transient failure; the topic stays pending."
            ) from None
        if result.returncode != 0:
            # Report both streams: agent CLIs write warnings to stderr and the
            # actual failure to stdout, so picking one hides the diagnosis.
            parts = [
                f"{name}:\n{stream.strip()}"
                for name, stream in (("stderr", result.stderr), ("stdout", result.stdout))
                if stream.strip()
            ]
            detail = "\n".join(parts) or "(no output)"
            raise GeneratorConfigError(
                f"'{command[0]}' failed (exit {result.returncode}):\n{detail}"
            )
        output = result.stdout.strip()
        if "--output-format" not in command:
            return output
        # Defensive on purpose: if the envelope ever changes shape, fall back to
        # the raw text rather than failing a generation that actually succeeded.
        # Losing a measurement is cheap; losing a completion costs a quota window.
        try:
            envelope = json.loads(output)
            answer = envelope.get("result")
        except (json.JSONDecodeError, AttributeError):
            return output
        if not isinstance(answer, str):
            return output
        _record_usage(envelope)
        return answer.strip()

    return complete, {"backend": backend, "model": command[0]}


def _antigravity_completer() -> tuple[Completer, dict]:
    """Backend for active Antigravity AI session (uses IDE session without external token costs).
    
    Note for Claude & future agents: This backend is used during interactive Antigravity agent
    sessions to route completions through the agent rather than making paid external API calls.
    It executes all native generator.py validations, file creation, and certs.md status updates.
    """
    prompt_file = Path(os.environ.get("ANTIGRAVITY_PROMPT_FILE", "/tmp/antigravity_prompt.json"))
    resp_file = Path(os.environ.get("ANTIGRAVITY_RESP_FILE", "/tmp/antigravity_response.txt"))
    cache_file = Path(os.environ.get("ANTIGRAVITY_CACHE_FILE", "/tmp/antigravity_cache.json"))

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
    raise GeneratorConfigError(f"Unknown backend '{backend}'. Valid: {valid}")



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
    """Generate one topic's content in one language. The lab is shared."""
    if lang not in certs.LANGS:
        raise GeneratorConfigError(f"Language '{lang}' not supported. Valid: {certs.LANGS}")
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
        return {"topic": topic_id, "skipped": "edited (use --force to overwrite)"}
    if already and not force and not outdated:
        return {"topic": topic_id, "skipped": f"already generated in {lang} (use --force)"}

    system = _system(lang)
    context = _topic_context(post.metadata, topic)
    weight = topic.get("weight", 1)

    directory = certs.content_dir(cert_id, topic_id)
    lang_dir = directory / lang

    def _reusable(kind: str) -> str | None:
        """Existing material good enough to keep instead of paying for it again.

        Only ever used to finish a HALF-WRITTEN topic — never to skip a full
        regeneration, so `--force` keeps meaning what it says. The case it exists
        for: content is authored and accepted, the exercises call then fails or
        the quota runs out, and the next pass would otherwise re-author the
        content it already paid for. Measured on cks/6.5, which cost $5.28
        instead of ~$2.10 because 46k and 47k tokens of accepted content were
        discarded and re-generated twice.

        A file only qualifies if it still clears the quality floor, so this can
        save a call but can never let weaker material survive.
        """
        if outdated:
            return None  # the syllabus moved; the old text is about the old topic
        path = lang_dir / f"{kind}.md"
        sibling = lang_dir / ("exercises.md" if kind == "content" else "content.md")
        if not path.exists() or sibling.exists():
            return None  # nothing there, or the topic is complete -> honour --force
        text = path.read_text()
        if quality.check(kind, text) or _RECAP_RE.search(text.strip().splitlines()[0] if text.strip() else ""):
            return None
        return text

    _usage_context.clear()
    _usage_context.update({"op": "author", "cert": cert_id, "topic": topic_id,
                           "lang": lang, "kind": "content", "weight": weight})
    reused = _reusable("content")
    content = reused if reused is not None else _reject_if_recap(
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
    if reused is None:
        # Accepted content goes to disk NOW, before the exercises call is made.
        # Holding both in memory until the end meant one failure threw away two
        # paid completions; writing here costs nothing and caps the loss at one.
        _reject_if_substandard(content, "content", topic_id, lang)
        lang_dir.mkdir(parents=True, exist_ok=True)
        (lang_dir / "content.md").write_text(content)

    _usage_context["kind"] = "exercises"
    reused_exercises = _reusable("exercises")
    exercises = reused_exercises if reused_exercises is not None else _reject_if_recap(
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

    lang_dir.mkdir(parents=True, exist_ok=True)
    (lang_dir / "content.md").write_text(content)
    (lang_dir / "exercises.md").write_text(exercises)
    # Provenance is written with the content, not after the lab. A process that
    # died between the two left files nobody could trace — cks/5.3/en and
    # lpi-010-160/1.2/fr both ended up that way, and check_provenance.py now
    # rejects exactly that shape.
    _write_meta(lang_dir, lang, backend_meta, topic)

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

    if status == "stale":
        # Do not mark the topic current until NO language is left behind.
        # Clearing it when Spanish — the default language — is rebuilt would
        # freeze the translations on the old syllabus with nothing reporting it.
        if not certs.topic_outdated_langs(cert_id, topic_id):
            certs.clear_topic_stale(cert_id, topic_id)
    elif lang == certs.DEFAULT_LANG:
        certs.set_topic_status(cert_id, topic_id, "generated")
    return {"topic": topic_id, "written": str(lang_dir)}


CODE_BLOCK = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)
URL_RE = re.compile(r"https?://[^\s)\]>\"'`]+")
HEADING = re.compile(r"^#+ ", re.MULTILINE)
# Comment text inside a code block: from an unquoted '#' to end of line.
COMMENT = re.compile(r"#[^\n]*")
# Unicode box-drawing block. Deliberately excludes '+', '-' and '|', which are
# everywhere in ordinary commands and would misclassify them as diagrams.
BOX = re.compile(r"[─-╿]")


def _comparable_code(block: str) -> str:
    """A code block reduced to the parts a translation must not touch.

    Code blocks are not uniformly code. They hold three kinds of content, and
    only one of them must survive byte-identical:

    - **Commands, flags, YAML keys and values, terminal output.** Translating
      any of these silently breaks the example. Compared exactly.
    - **Comments.** These are prose and must be translated: the Spanish material
      explains a manifest with `# a qué pods se aplica`, the English a student
      reads has to say `# which pods this applies to`. The authored English
      content does exactly that (12 English comments in cks/1.1 against 2
      Spanish ones in its source), so demanding byte-identical blocks rejected
      every correct translation, on every model including Claude. Comment TEXT
      is blanked; the '#' marker is kept, so a model cannot pass by DELETING a
      comment line — the marker would vanish and the blocks would differ.
    - **ASCII diagrams.** Also prose, and also deterministic: `cheap` translated
      `│ cloud-controller-manager (opcional) │` on 3 of 3 attempts, so no retry
      policy could ever get that topic through. On lines drawn with box
      characters, the labels are blanked but the box characters keep their exact
      COLUMN positions — a translation that re-pads correctly passes, and one
      that translates without re-padding leaves the diagram visibly misaligned
      and is rejected, which is the right answer.

    Both blanking rules are applied to source and translation identically, so
    they can only reduce sensitivity, never turn a real difference into a pass.
    """
    lines = []
    for line in block.splitlines():
        if BOX.search(line):
            # Keep the drawing, drop the words, preserve every column.
            lines.append("".join(c if BOX.match(c) else " " for c in line))
        else:
            lines.append(COMMENT.sub("#", line))
    return "\n".join(lines)


def _verify_translation(source: str, translated: str, label: str) -> str:
    """Structural checks a translation must satisfy but authoring cannot.

    This is what makes translating on a weaker model defensible: the substance
    is already fixed by the source, so what can go wrong is mechanical — the
    model summarising instead of translating, dropping sections, or translating
    command flags and YAML keys, which would silently break every example.

    Code blocks must survive byte-identical apart from their comments, which are
    prose and are meant to be translated. URLs must survive untouched. Headings
    must match in number. Length is allowed to drift within a band, because
    languages differ in verbosity, but not to collapse.
    """
    problems = []

    source_blocks = CODE_BLOCK.findall(source)
    result_blocks = CODE_BLOCK.findall(translated)
    if len(source_blocks) != len(result_blocks):
        problems.append(
            f"{len(source_blocks)} code blocks in the source, {len(result_blocks)} in the translation"
        )
    else:
        changed = [
            i for i, (a, b) in enumerate(zip(source_blocks, result_blocks))
            if _comparable_code(a) != _comparable_code(b)
        ]
        if changed:
            problems.append(
                f"{len(changed)} code blocks were modified beyond their comments "
                f"(commands, flags, YAML keys and output must be copied verbatim)"
            )

    source_urls, result_urls = set(URL_RE.findall(source)), set(URL_RE.findall(translated))
    if source_urls - result_urls:
        problems.append(f"{len(source_urls - result_urls)} source URLs are missing")

    if len(HEADING.findall(source)) != len(HEADING.findall(translated)):
        problems.append(
            f"{len(HEADING.findall(source))} headings in the source, "
            f"{len(HEADING.findall(translated))} in the translation"
        )

    ratio = len(translated) / max(len(source), 1)
    if not 0.6 <= ratio <= 1.6:
        problems.append(f"length ratio {ratio:.2f} (expected between 0.6 and 1.6)")

    if problems:
        raise GeneratorConfigError(
            f"The {label} translation does not preserve the source structure: "
            + "; ".join(problems)
        )
    return translated


def translate_topic(
    cert_id: str,
    topic_id: str,
    lang: str,
    source_lang: str = certs.DEFAULT_LANG,
    backend: str | None = None,
    force: bool = False,
) -> dict:
    """Translate an existing topic instead of re-authoring it.

    `generate_topic` never reads existing content: it writes every language from
    the syllabus, so each one costs full authoring. Translating reuses the work
    already done, which keeps languages structurally in sync and asks the model
    for restatement rather than reasoning — the same output length, much less
    thinking.
    """
    if lang not in certs.LANGS:
        raise GeneratorConfigError(f"Language '{lang}' not supported. Valid: {certs.LANGS}")
    if lang == source_lang:
        raise GeneratorConfigError("Source and target language are the same")

    directory = certs.content_dir(cert_id, topic_id)
    source_dir = directory / source_lang
    if not (source_dir / "content.md").exists():
        raise GeneratorConfigError(
            f"No {source_lang} content for {cert_id}/{topic_id} to translate from"
        )
    if lang in certs.topic_langs(cert_id, topic_id) and not force:
        return {"topic": topic_id, "skipped": f"already exists in {lang} (use --force)"}

    complete, backend_meta = make_completer(backend)
    system = (
        f"Sos un traductor técnico especializado. Traducís del "
        f"{LANG_NAMES.get(source_lang, source_lang)} al "
        f"{LANG_NAMES.get(lang, lang)}.\n"
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

    written = {}
    for kind in ("content.md", "exercises.md"):
        source = (source_dir / kind).read_text()
        _usage_context.clear()
        _usage_context.update({"op": "translate", "cert": cert_id, "topic": topic_id,
                               "lang": lang, "from": source_lang,
                               "kind": kind.removesuffix(".md")})
        result = _strip_fence(complete(system, source))
        _verify_translation(source, result, kind)
        _reject_if_substandard(result, kind.removesuffix(".md"), topic_id, lang)
        written[kind] = result

    target = directory / lang
    target.mkdir(parents=True, exist_ok=True)
    for kind, text in written.items():
        (target / kind).write_text(text)
    (target / "meta.yaml").write_text(yaml.safe_dump({
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "lang": lang,
        "translated_from": source_lang,
        **backend_meta,
        "sources": certs.get_topic(cert_id, topic_id).get("sources", []),
    }, sort_keys=False))
    return {"topic": topic_id, "written": str(target), "translated_from": source_lang}


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
