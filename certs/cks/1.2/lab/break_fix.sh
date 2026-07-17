#!/usr/bin/env bash
#
# CKS 1.34 - Tema 1.2: Use CIS benchmark to review the security configuration
# of Kubernetes components (etcd, kubelet, kube-dns/coredns, kube-apiserver)
# Peso en el examen: 3
#
# Fuentes:
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   https://www.cisecurity.org/benchmark/kubernetes
#
# Qué hace este script:
#   Sobre un nodo control-plane de un cluster kubeadm DESCARTABLE, degrada de
#   forma controlada 4 configuraciones que el CIS Kubernetes Benchmark revisa
#   en kube-apiserver, etcd, kubelet y coredns. Ninguna de las 4 fallas tira
#   abajo el cluster (los componentes siguen corriendo), pero cada una queda
#   marcada como FAIL frente a una auditoría CIS. El estudiante tiene que
#   encontrarlas (manualmente o con kube-bench) y corregirlas.
#
# Uso:
#   sudo ./cks-1.2-cis-break-fix.sh break --i-know-this-is-a-throwaway-lab-vm
#   sudo ./cks-1.2-cis-break-fix.sh restore   # red de seguridad, vuelve al estado original
#
set -euo pipefail

APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
ETCD_MANIFEST="/etc/kubernetes/manifests/etcd.yaml"
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
BACKUP_DIR="/var/backups/cks-1.2-cis-lab"

log()  { echo "[cis-1.2] $*"; }
die()  { echo "[cis-1.2][ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Corré este script como root (sudo) en el nodo control-plane del lab."
}

require_lab_ack() {
  local ack="${1:-}"
  if [[ "$ack" != "--i-know-this-is-a-throwaway-lab-vm" ]]; then
    cat >&2 <<'EOF'
Este script degrada intencionalmente la seguridad de kube-apiserver, etcd,
kubelet y coredns para practicar la revisión con el CIS Benchmark.
NO lo corras en un cluster real, compartido, ni con datos que te importen.

Si estás parado en una VM de laboratorio descartable, confirmá con:
  sudo ./cks-1.2-cis-break-fix.sh break --i-know-this-is-a-throwaway-lab-vm
EOF
    exit 1
  fi
}

preflight() {
  [[ -d /etc/kubernetes/manifests ]] || die "No existe /etc/kubernetes/manifests: esto no es un control-plane kubeadm."
  [[ -f "$APISERVER_MANIFEST" ]]     || die "No se encontró $APISERVER_MANIFEST"
  [[ -f "$ETCD_MANIFEST" ]]          || die "No se encontró $ETCD_MANIFEST"
  [[ -f "$KUBELET_CONFIG" ]]         || die "No se encontró $KUBELET_CONFIG"
  command -v kubectl >/dev/null 2>&1 || die "kubectl no está en el PATH."
  mkdir -p "$BACKUP_DIR"
}

backup_file() {
  local f="$1"
  local dest="$BACKUP_DIR/$(basename "$f").orig"
  if [[ ! -f "$dest" ]]; then
    cp -p "$f" "$dest"
    log "Backup guardado: $dest"
  fi
}

# Setea un flag si ya existe en el command: de un static pod manifest,
# o lo inserta a continuación de la línea del binario (- kube-apiserver / - etcd)
# preservando la indentación real del archivo.
set_or_insert_flag() {
  local file="$1" flag="$2" value="$3" anchor="$4"

  if grep -qE -- "^[[:space:]]*- ${flag}=" "$file"; then
    sed -i -E "s#- ${flag}=.*#- ${flag}=${value}#" "$file"
    return
  fi

  local indent
  indent=$(grep -m1 -E "^[[:space:]]*- ${anchor}[[:space:]]*\$" "$file" \
            | sed -E 's/^([[:space:]]*)-.*/\1/')
  [[ -n "$indent" ]] || indent="    "

  awk -v anchor="- ${anchor}" -v newline="${indent}- ${flag}=${value}" '
    { print }
    { t=$0; sub(/^[[:space:]]*/, "", t); if (t == anchor) print newline }
  ' "$file" > "${file}.tmp"
  cat "${file}.tmp" > "$file"
  rm -f "${file}.tmp"
}

break_apiserver() {
  backup_file "$APISERVER_MANIFEST"
  set_or_insert_flag "$APISERVER_MANIFEST" "--anonymous-auth" "true" "kube-apiserver"
  log "kube-apiserver: --anonymous-auth=true inyectado (CIS 1.2.1 pasa a FAIL)"
}

break_etcd() {
  backup_file "$ETCD_MANIFEST"
  set_or_insert_flag "$ETCD_MANIFEST" "--client-cert-auth" "false" "etcd"
  log "etcd: --client-cert-auth=false inyectado (CIS 2.2 pasa a FAIL)"
}

break_kubelet() {
  backup_file "$KUBELET_CONFIG"
  sed -i '/^authentication:/,/^authorization:/ s/enabled: false/enabled: true/' "$KUBELET_CONFIG"
  sed -i -E 's/^([[:space:]]*mode:[[:space:]]*)Webhook[[:space:]]*$/\1AlwaysAllow/' "$KUBELET_CONFIG"
  systemctl restart kubelet
  sleep 3
  log "kubelet: anonymous.enabled=true y authorization.mode=AlwaysAllow (CIS 4.2.1 y 4.2.2 pasan a FAIL)"
}

break_coredns() {
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  kubectl -n kube-system get deployment coredns -o yaml > "$BACKUP_DIR/coredns.yaml.orig" 2>/dev/null \
    || die "No se pudo leer el deployment coredns. ¿El cluster está arriba?"
  kubectl -n kube-system patch deployment coredns --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/securityContext",
     "value":{"allowPrivilegeEscalation":true,"readOnlyRootFilesystem":false,
              "runAsNonRoot":false,"runAsUser":0,
              "capabilities":{"add":["NET_RAW"]}}}
  ]' >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=90s
  log "coredns: securityContext debilitado (root, allowPrivilegeEscalation, capability NET_RAW)"
}

print_mission() {
  local node_ip
  node_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$node_ip" ]] || node_ip="<IP-DEL-NODO>"

  cat <<EOF

============================================================
 MISIÓN: CIS Benchmark review - kube-apiserver / etcd / kubelet / coredns
============================================================

Se rompieron 4 configuraciones. El cluster sigue funcionando, pero cada
una de estas fallaría una auditoría CIS. Tenés que encontrarlas y
corregirlas SIN mirar la solución comentada al final de este script salvo
que te quedes trabado.

Herramientas disponibles:
  - Si tenés kube-bench instalado: kube-bench run --targets master,etcd,node
  - Si no, auditá a mano leyendo los manifests/config y probando los
    endpoints expuestos (así audita el CIS Benchmark manualmente).

SÍNTOMA 1 - kube-apiserver:
  curl -sk https://${node_ip}:6443/version
  responde sin ninguna credencial. Encontrá el flag involucrado en
  $APISERVER_MANIFEST y corregilo (CIS sección 1.2, API server).

SÍNTOMA 2 - etcd:
  Revisá $ETCD_MANIFEST: uno de los flags de autenticación de clientes
  quedó en un valor que permite conexiones sin certificado válido
  (CIS sección 2, Etcd Node Configuration).

SÍNTOMA 3 - kubelet:
  curl -sk https://${node_ip}:10250/pods
  devuelve la lista completa de pods del nodo SIN autenticar. Revisá
  $KUBELET_CONFIG (CIS sección 4.2, Kubelet).

SÍNTOMA 4 - coredns (kube-dns):
  kubectl -n kube-system get deploy coredns \\
    -o jsonpath='{.spec.template.spec.containers[0].securityContext}{"\n"}'
  El contenedor quedó corriendo como root, con allowPrivilegeEscalation y
  una capability de más (CIS sección 5, Policies / Pod Security Standards).

OBJETIVO: dejar los 4 componentes en estado compliant otra vez, verificando
cada corrección con el mismo comando usado para detectar el síntoma.

Si te querés rendir y volver al estado original sin resolverlo:
  sudo $0 restore

============================================================
EOF
}

restore_all() {
  [[ -d "$BACKUP_DIR" ]] || die "No hay backups en $BACKUP_DIR (¿corriste 'break' antes?)"

  if [[ -f "$BACKUP_DIR/kube-apiserver.yaml.orig" ]]; then
    cp -p "$BACKUP_DIR/kube-apiserver.yaml.orig" "$APISERVER_MANIFEST"
    log "kube-apiserver restaurado"
  fi
  if [[ -f "$BACKUP_DIR/etcd.yaml.orig" ]]; then
    cp -p "$BACKUP_DIR/etcd.yaml.orig" "$ETCD_MANIFEST"
    log "etcd restaurado"
  fi
  if [[ -f "$BACKUP_DIR/config.yaml.orig" ]]; then
    cp -p "$BACKUP_DIR/config.yaml.orig" "$KUBELET_CONFIG"
    systemctl restart kubelet
    log "kubelet restaurado y reiniciado"
  fi
  if [[ -f "$BACKUP_DIR/coredns.yaml.orig" ]]; then
    export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
    kubectl apply -f "$BACKUP_DIR/coredns.yaml.orig" >/dev/null
    log "coredns restaurado"
  fi
  log "Restore completo. Los static pods se recrean solos en unos 20-30s."
}

main() {
  local cmd="${1:-break}"
  case "$cmd" in
    break)
      require_root
      require_lab_ack "${2:-}"
      preflight
      break_apiserver
      break_etcd
      break_kubelet
      break_coredns
      print_mission
      ;;
    restore)
      require_root
      restore_all
      ;;
    *)
      echo "Uso: $0 [break|restore] [--i-know-this-is-a-throwaway-lab-vm]" >&2
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ============================================================
#
# 1) kube-apiserver - CIS 1.2.1 "Ensure that the --anonymous-auth argument
#    is set to false"
#
#    Diagnóstico:
#      grep anonymous-auth /etc/kubernetes/manifests/kube-apiserver.yaml
#      curl -sk https://<node-ip>:6443/version   # responde 200 sin credenciales
#
#    Remediación:
#      sudo sed -i 's/--anonymous-auth=true/--anonymous-auth=false/' \
#        /etc/kubernetes/manifests/kube-apiserver.yaml
#      # kubelet vigila /etc/kubernetes/manifests y recrea el static pod solo,
#      # no hace falta reiniciar ningún servicio (esperar ~20-30s)
#
#    Verificación:
#      kubectl -n kube-system get pod -l component=kube-apiserver -w
#      grep anonymous-auth /etc/kubernetes/manifests/kube-apiserver.yaml
#
# 2) etcd - CIS 2.2 "Ensure that the --client-cert-auth argument is set
#    to true"
#
#    Diagnóstico:
#      grep client-cert-auth /etc/kubernetes/manifests/etcd.yaml
#
#    Remediación:
#      sudo sed -i 's/--client-cert-auth=false/--client-cert-auth=true/' \
#        /etc/kubernetes/manifests/etcd.yaml
#
#    Verificación:
#      grep client-cert-auth /etc/kubernetes/manifests/etcd.yaml
#      kubectl -n kube-system get pod -l component=etcd
#
# 3) kubelet - CIS 4.2.1 "Ensure that the --anonymous-auth argument is set
#    to false" y CIS 4.2.2 "Ensure that the --authorization-mode argument
#    is not set to AlwaysAllow"
#
#    Diagnóstico:
#      curl -sk https://<node-ip>:10250/pods   # devuelve la lista de pods sin token
#      grep -A2 "anonymous:" /var/lib/kubelet/config.yaml
#      grep "mode:" /var/lib/kubelet/config.yaml
#
#    Remediación (editar /var/lib/kubelet/config.yaml):
#      authentication:
#        anonymous:
#          enabled: false
#      authorization:
#        mode: Webhook
#      sudo systemctl restart kubelet
#
#    Verificación:
#      curl -sk https://<node-ip>:10250/pods   # ahora 401 Unauthorized
#      systemctl status kubelet
#
# 4) coredns (kube-dns) - CIS sección 5 (Policies) / Pod Security Standards:
#    ningún contenedor del control plane debería correr como root, con
#    allowPrivilegeEscalation habilitado, ni con capabilities de más
#
#    Diagnóstico:
#      kubectl -n kube-system get deploy coredns \
#        -o jsonpath='{.spec.template.spec.containers[0].securityContext}'
#
#    Remediación (restaurar el hardening por defecto de kubeadm):
#      kubectl -n kube-system patch deployment coredns --type=json -p='[
#        {"op":"replace",
#         "path":"/spec/template/spec/containers/0/securityContext",
#         "value":{"allowPrivilegeEscalation":false,
#                  "readOnlyRootFilesystem":true,
#                  "runAsNonRoot":true,
#                  "runAsUser":1000,
#                  "capabilities":{"add":["NET_BIND_SERVICE"],"drop":["all"]}}}
#      ]'
#
#    Verificación:
#      kubectl -n kube-system rollout status deployment coredns
#      kubectl -n kube-system get deploy coredns \
#        -o jsonpath='{.spec.template.spec.containers[0].securityContext}'
#
# Nota: todo este diagnóstico se puede automatizar con kube-bench
# (https://github.com/aquasecurity/kube-bench):
#   kube-bench run --targets master,etcd,node
# Los IDs de control citados arriba (1.2.1, 2.2, 4.2.1, 4.2.2) son los que
# kube-bench va a reportar como [FAIL] mientras las 4 fallas sigan activas.