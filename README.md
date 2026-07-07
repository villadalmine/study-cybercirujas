# teach-plat

Plataforma educativa self-service. Ver [PLAN.MD](PLAN.MD) para el diseño completo.

## Quickstart

```bash
make install                                   # venv + CLI
make list                                      # catálogo
make show CERT=lpi-010-160                     # temario + estado por tema
make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
make serve                                     # API + web en :8000
make publish MSG="contenido 1.1"               # commit+push al repo que publica
```

`make help` lista todos los targets (labs, git-init, etc.).

## Backends de generación

`BACKEND=` (o `TEACH_BACKEND`):

- `litellm` (default) — el LiteLLM del cluster. Requiere `LITELLM_BASE_URL`,
  `LITELLM_API_KEY`, `LITELLM_MODEL`.
- `claude` — Claude Code CLI local (`claude -p`).
- `codex` — OpenAI Codex CLI local (`codex exec`).
- `gemini` — Gemini CLI local (`gemini -p`).
- `custom` — tu comando en `TEACH_AGENT_CMD` (recibe el prompt como último argumento).

Con backends locales el flujo es: generar en tu máquina → revisar → `make publish`.

Web: http://127.0.0.1:8000 — login `admin/admin` (solo para probar).
Docs de la API: http://127.0.0.1:8000/docs
