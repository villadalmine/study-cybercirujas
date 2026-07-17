# teach-plat

Plataforma educativa self-service. Ver [PLAN.MD](PLAN.MD) para el diseño
completo, [CHANGELOG.MD](CHANGELOG.MD) para lo entregado,
[BACKLOG.MD](BACKLOG.MD) para lo pendiente y [STATUS.MD](STATUS.MD) para la
matriz de qué cert/idioma/lab/video está terminado ahora mismo (`.venv/bin/python3
scripts/status_matrix.py` la regenera desde el filesystem real).

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

Build sin GitHub ni workflows: `make image-cluster` corre Kaniko como pod
simple con el contexto local por stdin. Deploy local: `make deploy-local`
(values-local.yaml gitignored, host study.cluster.home).

Pre-requisitos (ya existen en el cluster): Gateway `cluster-gateway` con
listener HTTPS para study.cybercirujas.club, ClusterIssuer `letsencrypt-prod`,
DNS público → HAProxy y `study.cluster.home` local.

**Registry interno**: los nodos necesitan `/etc/rancher/k3s/registries.yaml`
con el mirror http de `registry.registry:5000` (hoy solo lo tiene
srv-super6c-01-nvme; sin eso el pull falla con ImagePullBackOff en el resto):

```yaml
mirrors:
  "registry.registry:5000":
    endpoint: ["http://registry.registry:5000"]
```

Los nodos rk1 ya lo tienen (etiquetados `registry-access=true`; values-local usa ese pool como nodeSelector). Al agregar la config a los super6c rearmados, etiquetarlos igual o quitar el selector. Reiniciar `k3s-agent` (workers) / `k3s` (control-plane, de a uno y con etcd
sano — no reiniciar CPs mientras un miembro esté caído).

Web: http://127.0.0.1:8000 — sin login (deshabilitado).
Docs de la API: http://127.0.0.1:8000/docs

## Timer de generación automática

Un timer de systemd (`teach-resume.timer`) corre `scripts/resume-generation.sh`
cada 20 minutos. El script:

1. Ejecuta `scripts/fix_corrupted_content.py` (detecta y regenera contenido
   corrupto — idempotente, converge a 0).
2. Genera contenido pendiente para los targets definidos en el script
   (hoy: lpi-010-160 traducciones + CKAD es + CKA es).

**Estado actual**: parado y deshabilitado (2026-07-16) para no consumir tokens
de Claude CLI innecesariamente. Ojo: un `disable` anterior (2026-07-13) no
sobrevivió un reboot de la máquina (`stop` sin `disable` real, o el unit
quedó igual "enabled" — el timer se reactivó solo el 2026-07-14 18:37 y
corrió sin supervisión ~2 días, cosa que en este caso vino bien porque
terminó de converger la limpieza de contenido corrupto a 0, pero no hay que
asumir que "estado actual: deshabilitado" en este archivo siga siendo cierto
sin correr `systemctl --user status teach-resume.timer` primero).

```bash
# Reactivar
systemctl --user enable --now teach-resume.timer

# Parar
systemctl --user stop teach-resume.timer
systemctl --user disable teach-resume.timer

# Ver estado
systemctl --user status teach-resume.timer
systemctl --user list-timers | grep teach

# Ver log de ejecuciones
tail -50 ~/.local/state/teach-plat/resume.log

# Correr una pasada a mano (sin timer)
scripts/resume-generation.sh
```

Los archivos del timer viven en `~/.config/systemd/user/`:
- `teach-resume.timer` — dispara cada 20 min
- `teach-resume.service` — ejecuta `scripts/resume-generation.sh`
