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

## Idiomas

Contenido por idioma en `certs/<cert>/<topic>/<lang>/` (es default; en, fr, de,
zh, ja, pt). Generar traducciones: `teach cert generate <cert> --lang en`.
La web tiene selector de idioma con fallback al español.

## Deploy en Kubernetes

Mismo esquema que online-game (Gateway API Cilium + cert-manager acme-dns +
registry interno con Kaniko). El contenido va horneado en la imagen:
publicar = rebuild + upgrade.

```bash
# 1. build in-cluster (ajustar tag en el manifest)
kubectl create -f deploy/build/teach-plat-kaniko.yaml
# 2. valores reales (dominios study.cybercirujas.club + study.cluster.home):
cp deploy/helm/values-study.example.yaml deploy/helm/values-local.yaml  # editar secretos
# 3. deploy
helm upgrade --install study deploy/helm -n teach-plat --create-namespace \
  -f deploy/helm/values-local.yaml
```

Pre-requisitos (ya existen en el cluster): Gateway `cluster-gateway` con
listener HTTPS para study.cybercirujas.club, ClusterIssuer `letsencrypt-prod`,
DNS público → HAProxy y `study.cluster.home` local.

Web: http://127.0.0.1:8000 — login `admin/admin` (solo para probar).
Docs de la API: http://127.0.0.1:8000/docs
