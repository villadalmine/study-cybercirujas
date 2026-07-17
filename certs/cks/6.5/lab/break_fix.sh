#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 6, tema 6.5: "Use Kubernetes audit logs to monitor access"
# Peso en el examen: 4
#
# Break & Fix lab. Pensado para correr como root en el control-plane node
# de un cluster kubeadm DESCARTABLE (una VM de laboratorio, no un cluster real).
#
# Fuentes (solo como referencia, no se copia texto literal):
#   - CNCF CKS Curriculum v1.34:
#     https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - Kubernetes docs - Auditing:
#     https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
#
# Uso:
#   ./cks-6.5-audit-break-fix.sh break   [--force]
#   ./cks-6.5-audit-break-fix.sh status
#   ./cks-6.5-audit-break-fix.sh restore [--force]

set -euo pipefail

MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
POLICY=/etc/kubernetes/audit-policy.yaml
AUDIT_LOG_DIR=/var/log/kubernetes/audit
AUDIT_LOG="${AUDIT_LOG_DIR}/audit.log"
BACKUP_DIR=/root/cks-6.5-backup
export POLICY AUDIT_LOG AUDIT_LOG_DIR

log()  { echo -e "\e[1;34m[lab]\e[0m $*"; }
warn() { echo -e "\e[1;33m[atencion]\e[0m $*"; }
err()  { echo -e "\e[1;31m[error]\e[0m $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Corré este script como root en el control-plane node."
    exit 1
  fi
}

check_environment() {
  if [ ! -f "$MANIFEST" ]; then
    err "No se encontró $MANIFEST. Este lab requiere un control-plane node de un cluster kubeadm."
    exit 1
  fi
  for bin in crictl yq kubectl; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      err "Falta el binario '$bin'. Instalalo antes de continuar."
      exit 1
    fi
  done
}

confirm() {
  local force="${1:-}"
  if [ "$force" = "--force" ]; then
    return
  fi
  warn "Esto va a interrumpir temporalmente el acceso al kube-apiserver de ESTA VM."
  warn "Usá esto solo en una VM de laboratorio descartable."
  read -r -p "Escribí ROMPER para continuar: " ans
  if [ "$ans" != "ROMPER" ]; then
    log "Cancelado."
    exit 0
  fi
}

backup_pristine() {
  if [ -d "$BACKUP_DIR" ]; then
    return
  fi
  mkdir -p "$BACKUP_DIR"
  cp "$MANIFEST" "$BACKUP_DIR/kube-apiserver.yaml"
  if [ -f "$POLICY" ]; then
    cp "$POLICY" "$BACKUP_DIR/audit-policy.yaml"
  fi
  log "Backup del estado original guardado en $BACKUP_DIR"
}

ensure_baseline_policy() {
  if [ -f "$POLICY" ]; then
    log "Ya existe una audit policy en $POLICY, se respeta la existente."
    return
  fi
  mkdir -p "$AUDIT_LOG_DIR"
  cat > "$POLICY" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods"]
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services"]
  - level: Metadata
EOF
  log "Audit policy baseline creada en $POLICY"
}

ensure_apiserver_audit_flags() {
  mkdir -p "$AUDIT_LOG_DIR"
  if grep -q -- '--audit-policy-file=' "$MANIFEST"; then
    log "El kube-apiserver ya tiene flags de audit configurados."
    return
  fi
  yq -i '.spec.containers[0].command += ["--audit-policy-file=" + strenv(POLICY), "--audit-log-path=" + strenv(AUDIT_LOG), "--audit-log-maxage=30", "--audit-log-maxbackup=10", "--audit-log-maxsize=100"]' "$MANIFEST"
  yq -i '.spec.volumes += [{"name":"audit-policy","hostPath":{"path": strenv(POLICY), "type":"File"}}, {"name":"audit-log","hostPath":{"path": strenv(AUDIT_LOG_DIR), "type":"DirectoryOrCreate"}}]' "$MANIFEST"
  yq -i '.spec.containers[0].volumeMounts += [{"name":"audit-policy","mountPath": strenv(POLICY), "readOnly": true}, {"name":"audit-log","mountPath": strenv(AUDIT_LOG_DIR)}]' "$MANIFEST"
  log "Flags de audit logging agregados al manifest. Esperando a que kubelet recree el static pod..."
  sleep 15
}

restart_apiserver() {
  local cid
  cid=$(crictl ps -a --name kube-apiserver -q | head -n1 || true)
  if [ -n "$cid" ]; then
    crictl stop "$cid" >/dev/null 2>&1 || true
  fi
  sleep 5
}

corrupt_policy() {
  if grep -q "CKS-LAB-BROKEN-MARKER" "$POLICY" 2>/dev/null; then
    log "La corrupción ya está aplicada en $POLICY."
    return
  fi
  cat >> "$POLICY" <<'EOF'

  # CKS-LAB-BROKEN-MARKER
  - level: RequestResponse
    resources:
    - group: ""
     resources: ["secrets"]
EOF
  log "Audit policy modificada."
}

print_break_message() {
  cat <<'EOF'

============================================================
 SINTOMA
============================================================
"kubectl" en esta VM empieza a fallar con timeouts o con
"Unable to connect to the server". El control-plane parece
caído.

============================================================
 OBJETIVO
============================================================
1. Sin depender de kubectl (el apiserver puede estar caído),
   diagnosticá por qué el kube-apiserver no arranca.
2. Encontrá el archivo responsable y el problema concreto que
   lo rompe.
3. Corregilo para que el kube-apiserver vuelva a levantar y
   "kubectl get nodes" responda de nuevo.
4. Una vez recuperado el cluster, confirmá que el audit log
   está capturando correctamente los accesos a "secrets" a
   nivel RequestResponse: generá un acceso real
   (ej: kubectl get secrets -A) y buscá ese evento en
   /var/log/kubernetes/audit/audit.log.

No se te dice dónde está el error exacto: esa es la parte del
ejercicio.
============================================================
EOF
}

status() {
  echo "--- crictl ps -a (kube-apiserver) ---"
  crictl ps -a --name kube-apiserver
  echo
  local cid
  cid=$(crictl ps -a --name kube-apiserver -q | head -n1 || true)
  if [ -n "$cid" ]; then
    echo "--- últimas líneas de log del container $cid ---"
    crictl logs --tail 30 "$cid" 2>&1 || true
  fi
}

restore() {
  if [ ! -d "$BACKUP_DIR" ]; then
    err "No hay backup en $BACKUP_DIR, nada para restaurar."
    exit 1
  fi
  cp "$BACKUP_DIR/kube-apiserver.yaml" "$MANIFEST"
  if [ -f "$BACKUP_DIR/audit-policy.yaml" ]; then
    cp "$BACKUP_DIR/audit-policy.yaml" "$POLICY"
  else
    rm -f "$POLICY"
  fi
  restart_apiserver
  log "Estado original restaurado."
}

usage() {
  echo "Uso: $0 {break|status|restore} [--force]"
  exit 1
}

main() {
  local cmd="${1:-}"
  local flag="${2:-}"
  case "$cmd" in
    break)
      require_root
      check_environment
      confirm "$flag"
      backup_pristine
      ensure_baseline_policy
      ensure_apiserver_audit_flags
      corrupt_policy
      restart_apiserver
      print_break_message
      ;;
    status)
      require_root
      status
      ;;
    restore)
      require_root
      check_environment
      confirm "$flag"
      restore
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"

# ============================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ============================================================
#
# 1. Confirmar el síntoma:
#      kubectl get nodes
#    -> falla con timeout / "connection refused".
#
# 2. Como el apiserver puede estar caído, usar crictl (no kubectl)
#    para inspeccionar el static pod directamente en el nodo:
#      crictl ps -a --name kube-apiserver
#    -> el container aparece en estado Exited / reiniciando en loop,
#       con un restart count que sube constantemente.
#
# 3. Ver el log del container que crashea:
#      CID=$(crictl ps -a --name kube-apiserver -q | head -n1)
#      crictl logs "$CID" 2>&1 | tail -50
#    -> el error va a mencionar un problema al parsear
#       /etc/kubernetes/audit-policy.yaml (YAML inválido /
#       "mapping values are not allowed in this context" o similar),
#       en la sección agregada al final del archivo.
#
# 4. Abrir /etc/kubernetes/audit-policy.yaml y revisar el bloque
#    final (marcado con "# CKS-LAB-BROKEN-MARKER"): tiene una
#    regla con indentación inconsistente entre "group" y "resources"
#    dentro del mismo item de la lista "resources:". Corregir la
#    indentación (o eliminar el bloque roto) para que sea YAML
#    válido, por ejemplo:
#
#      - level: RequestResponse
#        resources:
#          - group: ""
#            resources: ["secrets"]
#
# 5. No hace falta tocar el manifest del kube-apiserver ni reiniciar
#    kubelet: como el container sigue en crash-loop, kubelet lo va
#    a volver a levantar solo, y esta vez el archivo de policy es
#    válido. Confirmar:
#      crictl ps -a --name kube-apiserver
#    -> Running, sin nuevos reinicios.
#
# 6. Confirmar que el cluster volvió:
#      kubectl get nodes
#      kubectl get pods -n kube-system
#
# 7. Confirmar que el audit logging realmente funciona al nivel
#    esperado para "secrets" (RequestResponse). Generar un acceso:
#      kubectl get secrets -A >/dev/null
#    Y buscarlo en el audit log:
#      tail -n 200 /var/log/kubernetes/audit/audit.log \
#        | jq -c 'select(.objectRef.resource=="secrets")' \
#        | tail -n 5
#    -> debería verse un evento con level RequestResponse,
#       incluyendo user.username, verb, objectRef y responseStatus,
#       lo que confirma que el audit log está monitoreando el
#       acceso a ese recurso como exige el tema 6.5.
#
# 8. (Opcional, como instructor) Para resetear la VM de laboratorio
#    a su estado previo al ejercicio:
#      ./cks-6.5-audit-break-fix.sh restore --force
# ============================================================