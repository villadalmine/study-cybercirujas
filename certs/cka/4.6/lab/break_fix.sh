#!/usr/bin/env bash
#
# break-fix: CKA 4.6 - Understand extension interfaces (CNI, CSI, CRI, etc.)
# Peso en el examen (CKA v1.35): 3.57%
#
# Fuente de referencia (curriculum oficial, solo como referencia de alcance del tema):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# ADVERTENCIA: este script modifica archivos de configuración de sistema
# (CNI) en el nodo donde se ejecuta. Usalo SOLO en una VM de laboratorio
# descartable (kubeadm + containerd, con un plugin CNI tipo Calico/Flannel/
# Weave ya instalado). Nunca lo corras contra un cluster real.
#
# Requisitos:
#   - Ejecutarse como root (o con sudo) EN el nodo que se va a romper.
#   - kubectl configurado y con acceso al cluster (para crear el Pod de
#     demostración y para que el estudiante diagnostique con él).
#
# Uso:
#   sudo ./cka-4.6-break-fix.sh break [NODE_NAME]   # rompe el laboratorio (default: hostname local)
#   sudo ./cka-4.6-break-fix.sh status              # muestra el estado actual
#   sudo ./cka-4.6-break-fix.sh revert              # deshace el break usando el backup (salida de emergencia)

set -euo pipefail

CNI_DIR="/etc/cni/net.d"
BACKUP_ROOT="/root/cka-4.6-break-fix/backups"
LAB_NAMESPACE="cka-4-6-lab"
LAB_POD_NAME="cni-symptom-demo"
LATEST_BACKUP_LINK="/root/cka-4.6-break-fix/latest-backup"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: este script tiene que correr como root (sudo)." >&2
        exit 1
    fi
}

require_kubeadm_node() {
    if [ ! -d "$CNI_DIR" ]; then
        echo "ERROR: no existe $CNI_DIR. Este script espera un nodo kubeadm con un plugin CNI ya instalado." >&2
        exit 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "ERROR: kubectl no está disponible en este nodo. Requerido para el Pod de demostración." >&2
        exit 1
    fi
}

confirm_disposable_lab() {
    if [ "${FORCE:-0}" = "1" ]; then
        return 0
    fi
    echo "Este script va a romper la configuración de CNI de este nodo."
    echo "Confirmá que esta es una VM de laboratorio descartable escribiendo: romper"
    read -r -p "> " respuesta
    if [ "$respuesta" != "romper" ]; then
        echo "Cancelado. No se modificó nada."
        exit 1
    fi
}

cmd_break() {
    require_root
    require_kubeadm_node
    confirm_disposable_lab

    local node_name="${1:-$(hostname)}"
    if ! kubectl get node "$node_name" >/dev/null 2>&1; then
        echo "ERROR: '$node_name' no es un nodo registrado en el cluster." >&2
        echo "Pasá el nombre correcto: $0 break <NODE_NAME>" >&2
        echo "Nodos disponibles:" >&2
        kubectl get nodes -o name >&2
        exit 1
    fi

    if [ -z "$(ls -A "$CNI_DIR" 2>/dev/null)" ]; then
        echo "ERROR: $CNI_DIR ya está vacío. ¿Ya corriste 'break' antes sin hacer 'revert'?" >&2
        exit 1
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$BACKUP_ROOT/$ts"
    mkdir -p "$backup_dir"
    cp -a "$CNI_DIR"/. "$backup_dir"/
    ln -sfn "$backup_dir" "$LATEST_BACKUP_LINK"

    # El "break": se retira la configuración del plugin CNI del nodo.
    # No se toca el binario del plugin ni su DaemonSet, así que el
    # arreglo NO requiere reinstalar nada, solo restaurar la config.
    find "$CNI_DIR" -maxdepth 1 -type f -exec mv {} "$backup_dir"/../moved-away-$ts-{} \; 2>/dev/null || true
    find "$CNI_DIR" -maxdepth 1 -type f -print0 | xargs -0 -r rm -f

    kubectl create namespace "$LAB_NAMESPACE" >/dev/null 2>&1 || true
    kubectl delete pod "$LAB_POD_NAME" -n "$LAB_NAMESPACE" --ignore-not-found=true --now >/dev/null 2>&1 || true
    kubectl run "$LAB_POD_NAME" \
        --image=nginx:alpine \
        --restart=Never \
        --namespace "$LAB_NAMESPACE" \
        --overrides="{\"spec\":{\"nodeName\":\"$node_name\"}}" >/dev/null

    cat <<EOF

================================================================
  CKA 4.6 - Extension interfaces (CNI, CSI, CRI) - LAB ROTO
================================================================

Backup de la config original guardado en:
  $backup_dir

SÍNTOMA que vas a observar:
  - El Pod "$LAB_POD_NAME" en el namespace "$LAB_NAMESPACE" va a
    quedar trabado en estado ContainerCreating (o Pending) y no
    va a progresar.
  - Los Pods que ya estaban corriendo en este nodo ANTES del break
    siguen funcionando sin problema.
  - El nodo "$node_name" sigue en estado Ready.

TU OBJETIVO:
  Diagnosticar a cuál de las interfaces de extensión de Kubernetes
  (CNI, CSI o CRI) pertenece esta falla, identificar la causa raíz
  en este nodo, y resolverla para que "$LAB_POD_NAME" (y cualquier
  Pod nuevo) pase a Running con una IP asignada.

RESTRICCIONES (para forzar el diagnóstico correcto):
  - No reinicies el nodo.
  - No reinstales ni redespliegues el plugin CNI completo
    (su DaemonSet y binarios siguen intactos).
  - No borres ni recrees el namespace "$LAB_NAMESPACE".

Comandos que probablemente vas a necesitar (sin decirte cuál es
la causa): kubectl describe pod, kubectl get events, crictl,
journalctl -u kubelet, journalctl -u containerd, y revisar qué
directorios usa el runtime para configuración de red.

Si te trabás del todo, podés hacer:
  sudo $0 revert
para restaurar el estado original y volver a intentar.
================================================================
EOF
}

cmd_status() {
    require_root
    echo "Contenido de $CNI_DIR:"
    ls -la "$CNI_DIR" 2>/dev/null || echo "  (no existe)"
    echo
    if command -v kubectl >/dev/null 2>&1; then
        kubectl get pod "$LAB_POD_NAME" -n "$LAB_NAMESPACE" -o wide 2>/dev/null || echo "Pod de demo no encontrado."
    fi
}

cmd_revert() {
    require_root
    if [ ! -e "$LATEST_BACKUP_LINK" ]; then
        echo "ERROR: no hay backup registrado en $LATEST_BACKUP_LINK." >&2
        exit 1
    fi
    local backup_dir
    backup_dir=$(readlink -f "$LATEST_BACKUP_LINK")
    cp -a "$backup_dir"/. "$CNI_DIR"/
    kubectl delete namespace "$LAB_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
    echo "Config de CNI restaurada desde $backup_dir. Namespace de laboratorio eliminado."
}

main() {
    local action="${1:-}"
    case "$action" in
        break)
            shift || true
            cmd_break "${1:-}"
            ;;
        status)
            cmd_status
            ;;
        revert)
            cmd_revert
            ;;
        *)
            echo "Uso: $0 {break [NODE_NAME]|status|revert}" >&2
            exit 1
            ;;
    esac
}

main "$@"

# ================================================================
# SOLUCIÓN PASO A PASO (no ejecutar hasta intentar diagnosticar solo)
# ================================================================
#
# 1. Confirmar el síntoma y descartar problemas de scheduling/imagen:
#      kubectl get pod cni-symptom-demo -n cka-4-6-lab -o wide
#      kubectl describe pod cni-symptom-demo -n cka-4-6-lab
#    En Events vas a ver algo como:
#      Warning  FailedCreatePodSandBox ... rpc error: code = Unknown desc =
#      failed to setup network for sandbox "...":
#      plugin type="calico" failed (add): stat /etc/cni/net.d: no such
#      file or directory   (o "no networks found in /etc/cni/net.d")
#    Esto ya apunta a la interfaz CNI, no a CRI: el sandbox del container
#    se crea (el runtime/CRI responde), pero falla el paso de red.
#
# 2. Descartar que sea un problema de CRI/containerd en sí mismo:
#      crictl info
#      systemctl status containerd
#      journalctl -u containerd -n 50 --no-pager
#    containerd está sano; el error específico es "failed to setup network",
#    que es el contrato entre CRI y CNI (containerd invoca al binario CNI
#    usando la config de /etc/cni/net.d).
#
# 3. Inspeccionar el directorio de configuración de CNI en el nodo:
#      ls -la /etc/cni/net.d
#    Va a estar vacío (o sin el *.conflist del plugin), confirmando que
#    falta la configuración, aunque el plugin (DaemonSet, binarios en
#    /opt/cni/bin) sigue instalado:
#      kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
#      ls /opt/cni/bin
#
# 4. Restaurar la configuración (sin reinstalar el plugin):
#      sudo ls /root/cka-4.6-break-fix/backups/
#      sudo cp -a /root/cka-4.6-break-fix/backups/<timestamp>/. /etc/cni/net.d/
#    (En un incidente real sin backup, la alternativa es volver a aplicar
#    el manifiesto del plugin CNI, p. ej. "kubectl apply -f calico.yaml",
#    que regenera esa configuración vía su DaemonSet/init container.)
#
# 5. Forzar que el Pod trabado vuelva a intentar el sandbox:
#      kubectl delete pod cni-symptom-demo -n cka-4-6-lab
#      kubectl run cni-symptom-demo --image=nginx:alpine --restart=Never \
#        -n cka-4-6-lab --overrides='{"spec":{"nodeName":"<NODE_NAME>"}}'
#
# 6. Verificar la solución:
#      kubectl get pod cni-symptom-demo -n cka-4-6-lab -o wide
#    Debe pasar a Running con una IP de Pod asignada. Opcionalmente,
#    confirmar conectividad real de red (no solo IP asignada):
#      kubectl exec -n cka-4-6-lab cni-symptom-demo -- wget -qO- <IP-de-otro-pod>
#
# 7. Limpieza del laboratorio:
#      sudo ./cka-4.6-break-fix.sh revert
