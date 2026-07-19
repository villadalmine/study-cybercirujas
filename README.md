# teach-plat

Plataforma de estudio para certificaciones IT. Todo el contenido se genera
dinámicamente desde fuentes oficiales (temarios scrapeados de lpi.org, PDFs
de github.com/cncf/curriculum, etc.) — nada hardcodeado.

- **[STATUS.MD](STATUS.MD)** — qué cert/idioma/lab/video está terminado
- **[PLAN.MD](PLAN.MD)** — diseño completo
- **[BACKLOG.MD](BACKLOG.MD)** — lo pendiente
- **[CHANGELOG.MD](CHANGELOG.MD)** — lo entregado

## Quickstart

```bash
make install                                   # venv + CLI
make list                                      # catálogo
make show CERT=lpi-010-160                     # temario + estado por tema
make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
make serve                                     # API + web en :8000
```

`make help` lista todos los targets.

## Imagen Docker pública

Cada push a `main` publica la imagen en GitHub Container Registry:

```bash
docker pull ghcr.io/villadalmine/study-cybercirujas:latest
docker run -p 8000:8000 ghcr.io/villadalmine/study-cybercirujas:latest
```

Web: http://localhost:8000 · API docs: http://localhost:8000/docs

## Backends de generación

`BACKEND=` (o `TEACH_BACKEND`):

- `litellm` (default) — cualquier API compatible OpenAI (LiteLLM, OpenRouter,
  etc.). Requiere `LITELLM_BASE_URL`, `LITELLM_API_KEY`, `LITELLM_MODEL`.
- `claude` — Claude Code CLI local (`claude -p`).
- `codex` — OpenAI Codex CLI local (`codex exec`).
- `gemini` — Gemini CLI local (`gemini -p`).
- `custom` — tu comando en `TEACH_AGENT_CMD` (recibe el prompt como último argumento).

Con backends locales: generar en tu máquina → revisar → `make publish`.

## Idiomas

Contenido por idioma en `certs/<cert>/<topic>/<lang>/` (es default; en, fr, de,
zh, ja, pt). Generar traducciones: `teach cert generate <cert> --lang en`.
La web tiene selector de idioma con fallback al español.

## Deploy en Kubernetes

El contenido va horneado en la imagen — publicar = rebuild + upgrade.

```bash
# Con la imagen pública de GHCR:
helm upgrade --install study deploy/helm -n teach-plat --create-namespace \
  -f deploy/helm/values-local.yaml \
  --set image.registry=ghcr.io \
  --set image.repository=villadalmine/study-cybercirujas

# O build in-cluster (Kaniko, sin GitHub Actions):
make image-cluster TAG=mytag
make deploy-local TAG=mytag
```

Para deploy en un cluster propio, copiar `values-study.example.yaml` a
`values-local.yaml` y editar dominios/secretos. Pre-requisitos: Gateway API
(Cilium o similar), cert-manager con ClusterIssuer para TLS.

## Variables de entorno

| Variable | Uso | Default |
|----------|-----|---------|
| `TEACH_ROOT` | Raíz del repo de datos | `.` (cwd) |
| `TEACH_SECRET` | Clave de firma de sesión | random |
| `TEACH_SITE_URL` | Hostname en marca de agua de videos | `study.cybercirujas.club` |
| `TEACH_BACKEND` | Backend de generación | `litellm` |
| `LITELLM_BASE_URL` | URL del proxy LiteLLM | — |
| `LITELLM_API_KEY` | API key para LiteLLM | — |
| `LITELLM_MODEL` | Modelo a usar vía LiteLLM | — |

## Timer de generación automática

Un timer de systemd (`teach-resume.timer`) puede correr `scripts/resume-generation.sh`
cada 20 minutos para generar contenido desatendido (fix de corruptos + generación
pendiente). Idempotente — salta lo ya hecho.

```bash
# Activar
systemctl --user enable --now teach-resume.timer

# Parar
systemctl --user stop teach-resume.timer && systemctl --user disable teach-resume.timer

# Estado y log
systemctl --user status teach-resume.timer
tail -50 ~/.local/state/teach-plat/resume.log

# Pasada manual (sin timer)
scripts/resume-generation.sh
```

Los unit files viven en `~/.config/systemd/user/` (`teach-resume.timer` +
`teach-resume.service`).

## Licencia

[Apache License 2.0](LICENSE)
