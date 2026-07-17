#!/usr/bin/env bash
#
# Certificación: CKS (Certified Kubernetes Security Specialist) - examen v1.34
# Tema 2.3: Understand and implement isolation techniques
#           (multi-tenancy, sandboxed containers, etc.) - peso en el examen: 5%
# Fuente de referencia:
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Escenario: un tenant (namespace) ejecuta cargas no confiables que deben
# correr sobre un runtime "sandboxed" (gVisor) en lugar del runtime por
# defecto (runc), como capa extra de aislamiento multi-tenant a nivel de
# kernel/syscalls. El script arma ese escenario, lo deja funcionando, y
# luego rompe la configuración de containerd que sostiene esa sandbox.
#
# IMPORTANTE - SOLO PARA VM DE LABORATORIO DESCARTABLE:
#   Este script edita /etc/containerd/config.toml y reinicia containerd.
#   No lo ejecutes en un cluster real ni en un nodo que no puedas recrear.
#
# Uso:
#   sudo ./breakfix-2.3-isolation.sh break     # arma el lab y lo rompe (default)
#   sudo ./breakfix-2.3-isolation.sh check     # valida si ya lo arreglaste
#   sudo ./breakfix-2.3-isolation.sh cleanup   # borra todo y restaura containerd
#
# Flags:
#   -y   no pedir confirmación interactiva

set -euo pipefail

NS="tenant-a"
RUNTIMECLASS="gvisor"
HANDLER="runsc"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
ORIG_BACKUP="/etc/containerd/config.toml.orig-breakfix"
MARKER='[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]'
ASSUME_YES="false"

log()  { echo -e "\n[breakfix] $*"; }
warn() { echo -e "\n[breakfix][ATENCIÓN] $*" >&2; }
die()  { echo -e "\n[breakfix][ERROR] $*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" = "true" ] && return 0
  read -r -p "[breakfix] $1 [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelado por el usuario."
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "Corré este script como root (sudo)."
  command -v kubectl >/dev/null 2>&1 || die "kubectl no encontrado."
  command -v systemctl >/dev/null 2>&1 || die "systemctl no encontrado."
  [ -f "$CONTAINERD_CONFIG" ] || die "No existe $CONTAINERD_CONFIG. Este lab asume containerd, no docker/CRI-O."

  local rt
  rt="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)"
  [[ "$rt" == containerd* ]] || die "El nodo no reporta containerd como runtime (reportó: '${rt:-desconocido}')."
}

wait_for_pod_running() {
  local ns="$1" label="$2" timeout="${3:-90}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local phase
    phase="$(kubectl get pods -n "$ns" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Running" ] && return 0
    sleep 3; waited=$((waited + 3))
    echo -n "."
  done
  return 1
}

setup_baseline() {
  log "Creando namespace de tenant '$NS' y RuntimeClass '$RUNTIMECLASS' (handler: $HANDLER)..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if [ ! -f "$ORIG_BACKUP" ]; then
    cp "$CONTAINERD_CONFIG" "$ORIG_BACKUP"
    log "Backup del containerd original guardado en $ORIG_BACKUP"
  fi

  if ! grep -qF "$MARKER" "$CONTAINERD_CONFIG"; then
    log "Registrando el runtime handler '$HANDLER' en containerd..."
    # NOTA PEDAGÓGICA: en un cluster real, BinaryName apuntaría al shim real
    # de gVisor (/usr/local/bin/runsc). Como esta VM de lab descartable puede
    # no tener gVisor instalado, lo apuntamos a runc para que el mecanismo
    # de RuntimeClass -> containerd runtime handler sea 100% reproducible.
    # Lo que se rompe/arregla en este ejercicio es exactamente ese cableado,
    # que es igual de válido para runsc que para runc.
    cat >> "$CONTAINERD_CONFIG" <<-EOF

$MARKER
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
    BinaryName = "/usr/bin/runc"
EOF
    systemctl restart containerd
    sleep 3
  fi

  kubectl apply -f - >/dev/null <<-EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $RUNTIMECLASS
handler: $HANDLER
EOF

  kubectl apply -n "$NS" -f - >/dev/null <<-EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sandboxed-app
  labels:
    app: sandboxed-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sandboxed-app
  template:
    metadata:
      labels:
        app: sandboxed-app
    spec:
      runtimeClassName: $RUNTIMECLASS
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
EOF

  log "Esperando a que el pod sandboxed arranque en estado bueno (baseline)..."
  if wait_for_pod_running "$NS" "app=sandboxed-app" 90; then
    log "Baseline OK: el pod corre con runtimeClassName=$RUNTIMECLASS."
  else
    die "El baseline nunca llegó a Running. Revisá 'kubectl describe pod -n $NS' antes de continuar."
  fi
}

do_break() {
  log "Rompiendo la configuración de containerd para el runtime '$HANDLER'..."
  sed -i "\@$(printf '%s' "$MARKER" | sed 's/[.[\*^$/]/\\&/g')@,\$d" "$CONTAINERD_CONFIG"
  systemctl restart containerd
  sleep 3
  kubectl -n "$NS" rollout restart deployment/sandboxed-app >/dev/null

  cat <<-'EOF'

============================================================
 SÍNTOMA QUE VA A VER EL ESTUDIANTE
============================================================
El deployment "sandboxed-app" en el namespace "tenant-a" deja
de poder crear pods nuevos (o el pod existente entra en error
al ser reemplazado). Vas a ver algo como:

  $ kubectl get pods -n tenant-a
  NAME                              READY   STATUS                 RESTARTS
  sandboxed-app-xxxxxxxxxx-yyyyy    0/1     CreateContainerError   0

  $ kubectl describe pod -n tenant-a -l app=sandboxed-app
  ...
  Warning  FailedCreatePodSandBox  ... failed to find runtime handler
           "runsc" from runtime list

============================================================
 QUÉ TENÉS QUE LOGRAR
============================================================
El namespace "tenant-a" es un tenant que exige que sus cargas
corran aisladas con un runtime sandboxed (RuntimeClass "gvisor",
handler "runsc"). Alguien (este script) rompió el cableado de
ese handler en containerd. Tu objetivo:

  1. Diagnosticar la causa raíz (no solo reiniciar el pod).
  2. Restaurar en containerd el bloque de configuración del
     runtime handler "runsc" (ver /etc/containerd/config.toml).
  3. Reiniciar containerd y confirmar que el pod de tenant-a
     vuelve a Running usando el RuntimeClass "gvisor".

Pista: la RuntimeClass de Kubernetes ("kubectl get runtimeclass
gvisor -o yaml") sigue intacta - el problema está del lado del
node/containerd, no del lado de la API de Kubernetes.

Cuando creas que lo resolviste, corré:
  sudo ./breakfix-2.3-isolation.sh check
EOF
}

do_check() {
  log "Verificando estado..."
  if grep -qF "$MARKER" "$CONTAINERD_CONFIG"; then
    log "OK: el handler '$HANDLER' está registrado en containerd."
  else
    warn "El handler '$HANDLER' todavía NO está en $CONTAINERD_CONFIG."
  fi

  local phase
  phase="$(kubectl get pods -n "$NS" -l app=sandboxed-app -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  if [ "$phase" = "Running" ]; then
    log "ÉXITO: el pod de tenant-a está Running con runtimeClassName=$RUNTIMECLASS."
    log "La sandbox del tenant quedó restaurada."
  else
    warn "El pod todavía no está Running (fase actual: '${phase:-sin pod}')."
    warn "Revisá 'kubectl describe pod -n $NS -l app=sandboxed-app' y 'journalctl -u containerd -n 50'."
  fi
}

do_cleanup() {
  confirm "Esto borra el namespace '$NS', la RuntimeClass '$RUNTIMECLASS' y restaura containerd. ¿Continuar?"
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null
  kubectl delete runtimeclass "$RUNTIMECLASS" --ignore-not-found >/dev/null
  if [ -f "$ORIG_BACKUP" ]; then
    cp "$ORIG_BACKUP" "$CONTAINERD_CONFIG"
    rm -f "$ORIG_BACKUP"
    systemctl restart containerd
    log "containerd restaurado a su configuración original."
  fi
  log "Cleanup completo."
}

ACTION="break"
for arg in "$@"; do
  case "$arg" in
    break|check|cleanup) ACTION="$arg" ;;
    -y) ASSUME_YES="true" ;;
    *) die "Argumento desconocido: $arg" ;;
  esac
done

case "$ACTION" in
  break)
    preflight
    confirm "Vas a modificar containerd y crear recursos en este cluster de laboratorio. ¿Continuar?"
    setup_baseline
    do_break
    ;;
  check)
    preflight
    do_check
    ;;
  cleanup)
    preflight
    do_cleanup
    ;;
esac

# ============================================================
# SOLUCIÓN PASO A PASO (para el instructor / autocorrección)
# ============================================================
#
# 1. Confirmar el síntoma y descartar que sea un problema de la
#    RuntimeClass en sí (el objeto de Kubernetes está bien):
#
#      kubectl get runtimeclass gvisor -o yaml
#      kubectl describe pod -n tenant-a -l app=sandboxed-app
#      # -> Warning FailedCreatePodSandBox: failed to find runtime
#      #    handler "runsc" from runtime list
#
# 2. Confirmar que el problema está en containerd, no en kubelet:
#
#      journalctl -u containerd -n 50 --no-pager
#      grep -A3 'containerd.runtimes.runsc' /etc/containerd/config.toml
#      # -> no aparece nada: el bloque fue borrado por do_break()
#
# 3. Restaurar el bloque de configuración del runtime handler
#    "runsc" en /etc/containerd/config.toml:
#
#      cat >> /etc/containerd/config.toml <<-EOF
#
#      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
#        runtime_type = "io.containerd.runc.v2"
#        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
#          BinaryName = "/usr/bin/runc"
#      EOF
#
#    (En un cluster real con gVisor instalado, BinaryName apuntaría
#    a "/usr/local/bin/runsc" en lugar de "/usr/bin/runc".)
#
# 4. Reiniciar containerd para que tome la nueva configuración:
#
#      systemctl restart containerd
#
# 5. Forzar que el Deployment reintente crear el pod (o esperar
#    al backoff automático) y confirmar que queda Running:
#
#      kubectl -n tenant-a rollout restart deployment/sandboxed-app
#      kubectl get pods -n tenant-a -w
#
# 6. Confirmar aislamiento: el pod corre bajo runtimeClassName=gvisor,
#    es decir que cualquier carga de este tenant queda forzada a pasar
#    por ese runtime handler (en producción, con gVisor real, eso
#    significa syscalls interceptadas por el sentry de gVisor en vez
#    de ir directo al kernel del host - aislamiento extra sobre el que
#    ya da el Namespace del tenant).
#
#      sudo ./breakfix-2.3-isolation.sh check
#      # -> ÉXITO: el pod de tenant-a está Running con runtimeClassName=gvisor