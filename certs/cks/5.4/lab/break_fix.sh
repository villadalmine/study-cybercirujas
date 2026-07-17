#!/usr/bin/env bash
#
# CKS v1.34 - Tema 5.4: Appropriately use kernel hardening tools such as AppArmor, seccomp
# Peso en el examen: 2.5
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Script "break & fix". Rompe DOS cosas a propósito (un perfil seccomp y un perfil
# AppArmor) contra un cluster de Kubernetes de UN SOLO NODO corriendo en una VM
# de laboratorio DESCARTABLE. No lo corras contra nada que te importe: escribe
# archivos en /var/lib/kubelet/seccomp/ y en /etc/apparmor.d/ del nodo.
#
# Requiere: kubectl apuntando al cluster del laboratorio, y poder usar sudo en
# el nodo (este script asume que corre en el propio nodo, típico de un
# kubeadm de un solo nodo tipo KodeKloud/killer.sh).

set -euo pipefail

NAMESPACE="kernel-hardening-lab"
LAB_DIR="/tmp/cks-5.4-lab"
KUBELET_ROOT_DIR="${KUBELET_ROOT_DIR:-/var/lib/kubelet}"
SECCOMP_PROFILE_NAME="block-write.json"
APPARMOR_PROFILE_NAME="k8s-deny-write-tmp"

echo "=================================================================="
echo " CKS 5.4 - Kernel hardening (AppArmor / seccomp) - break & fix lab"
echo "=================================================================="
echo
read -r -p "Esto rompe cosas a nivel nodo. Confirmá que es una VM DESCARTABLE escribiendo 'romper': " confirm
if [[ "${confirm}" != "romper" ]]; then
  echo "Cancelado."
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl en el PATH."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "kubectl no puede hablar con el cluster."; exit 1; }

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
if [[ "${NODE_COUNT}" -ne 1 ]]; then
  echo "Aviso: el cluster tiene ${NODE_COUNT} nodos. Este laboratorio asume UN solo"
  echo "nodo (los perfiles se cargan solo en el nodo donde corrés este script)."
  echo "Si el pod cae en otro nodo vas a ver un síntoma distinto al esperado."
fi
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

mkdir -p "${LAB_DIR}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo
echo "------------------------------------------------------------------"
echo " Escenario 1/2: seccomp"
echo "------------------------------------------------------------------"

sudo mkdir -p "${KUBELET_ROOT_DIR}/seccomp/profiles"
sudo tee "${KUBELET_ROOT_DIR}/seccomp/profiles/${SECCOMP_PROFILE_NAME}" >/dev/null <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["write"],
      "action": "SCMP_ACT_KILL"
    }
  ]
}
EOF

cat > "${LAB_DIR}/seccomp-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-lab
  namespace: ${NAMESPACE}
  labels:
    app: seccomp-lab
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Always
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "while true; do echo tick; sleep 5; done"]
      securityContext:
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/${SECCOMP_PROFILE_NAME}
EOF

kubectl apply -f "${LAB_DIR}/seccomp-pod.yaml"
sleep 3
kubectl -n "${NAMESPACE}" get pod seccomp-lab

cat <<'MSG'

SÍNTOMA que vas a ver:
  El pod "seccomp-lab" queda en CrashLoopBackOff. "kubectl logs" no muestra
  nada (o casi nada), y "kubectl describe pod seccomp-lab" va a mostrar el
  último estado terminado con un exit code de 159 (128 + 31 = señal SIGSYS).

OBJETIVO:
  Lograr que el pod "seccomp-lab" quede Running y estable, SIN cambiar la
  imagen ni el comando del contenedor, y sin quitarle el seccompProfile
  Localhost (o sea: arreglá el perfil, no lo saques).
MSG

echo
echo "------------------------------------------------------------------"
echo " Escenario 2/2: AppArmor"
echo "------------------------------------------------------------------"

if [[ ! -e /sys/module/apparmor/parameters/enabled ]] || \
   [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ]] || \
   ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "Este nodo no tiene AppArmor habilitado (kernel/distro sin soporte, ej. no-Ubuntu/Debian)."
  echo "Se salta el escenario 2. Corré este script en un nodo Ubuntu/Debian para practicarlo."
else
  sudo tee "/etc/apparmor.d/${APPARMOR_PROFILE_NAME}" >/dev/null <<'EOF'
#include <tunables/global>

profile k8s-deny-write-tmp flags=(attach_disconnected) {
  #include <abstractions/base>

  file,
  network,

  deny /tmp/** w,
}
EOF

  sudo apparmor_parser -Kr "/etc/apparmor.d/${APPARMOR_PROFILE_NAME}"

  cat > "${LAB_DIR}/apparmor-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-lab
  namespace: ${NAMESPACE}
  labels:
    app: apparmor-lab
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Always
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "while true; do echo alive > /tmp/healthy; sleep 3; done"]
      securityContext:
        appArmorProfile:
          type: Localhost
          localhostProfile: ${APPARMOR_PROFILE_NAME}
      readinessProbe:
        exec:
          command: ["sh", "-c", "cat /tmp/healthy"]
        initialDelaySeconds: 2
        periodSeconds: 5
EOF

  kubectl apply -f "${LAB_DIR}/apparmor-pod.yaml"
  sleep 3
  kubectl -n "${NAMESPACE}" get pod apparmor-lab

  cat <<'MSG'

SÍNTOMA que vas a ver:
  El pod "apparmor-lab" queda Running pero 0/1 Ready para siempre. Los logs
  del contenedor ("kubectl logs apparmor-lab -n kernel-hardening-lab") van a
  mostrar algo como "can't create /tmp/healthy: Permission denied", aunque
  /tmp tiene permisos 1777 (world-writable) - la denegación no es de UNIX,
  es del LSM.

OBJETIVO:
  Lograr que el pod "apparmor-lab" quede 1/1 Ready, sin quitarle el
  appArmorProfile Localhost ni cambiar el comando/imagen del contenedor.
MSG
fi

echo
echo "=================================================================="
echo " Diagnosticá con: kubectl -n ${NAMESPACE} get pods, describe, logs,"
echo " y (para AppArmor) 'sudo dmesg | grep -i apparmor' o journalctl -k."
echo " La solución paso a paso está comentada al final de este script."
echo "=================================================================="

# ==================================================================
# SOLUCIÓN PASO A PASO (no se ejecuta - es referencia para el alumno)
# ==================================================================
#
# --- Diagnóstico común a ambos escenarios ---
#
#   kubectl -n kernel-hardening-lab get pods
#   kubectl -n kernel-hardening-lab describe pod seccomp-lab
#   kubectl -n kernel-hardening-lab describe pod apparmor-lab
#   kubectl -n kernel-hardening-lab logs apparmor-lab
#
# --- Escenario 1: seccomp ---
#
# 1) "describe pod seccomp-lab" muestra en "Last State":
#      Reason: Error
#      Exit Code: 159        <- 128 + 31 (SIGSYS) = el kernel mató al proceso
#                                por ejecutar un syscall bloqueado por seccomp.
#    "kubectl logs" viene vacío porque el propio syscall "write" (usado para
#    imprimir stdout) es el que está bloqueado: el proceso muere antes de
#    poder loguear nada.
#
# 2) El perfil está en el nodo, no en el Pod. El Pod referencia
#    "profiles/block-write.json" con type: Localhost, y el archivo real es:
#      /var/lib/kubelet/seccomp/profiles/block-write.json
#    Revisarlo:
#      sudo cat /var/lib/kubelet/seccomp/profiles/block-write.json
#    Vas a ver que "write" tiene action "SCMP_ACT_KILL" en vez de
#    "SCMP_ACT_ALLOW" (o directamente no debería estar listado, ya que el
#    defaultAction ya es ALLOW).
#
# 3) Arreglo (elegí una):
#    a) Sacar la entrada de "write" del array "syscalls", o
#    b) Cambiar su "action" a "SCMP_ACT_ALLOW".
#
#      sudo tee /var/lib/kubelet/seccomp/profiles/block-write.json >/dev/null <<'EOF'
#      {
#        "defaultAction": "SCMP_ACT_ALLOW",
#        "syscalls": []
#      }
#      EOF
#
# 4) Punto clave del dominio: el filtro seccomp se instala en el momento en
#    que el runtime arranca el proceso del contenedor y NO se puede cambiar
#    para un proceso ya corriendo. Arreglar el archivo JSON no "cura" el
#    contenedor actual: hace falta que el kubelet vuelva a crear el
#    contenedor para que lea el perfil corregido. Como el Pod tiene
#    restartPolicy: Always y ya está en CrashLoopBackOff, alcanza con
#    esperar el próximo reintento, o forzarlo:
#
#      kubectl -n kernel-hardening-lab delete pod seccomp-lab
#      kubectl apply -f /tmp/cks-5.4-lab/seccomp-pod.yaml
#
# 5) Verificar:
#      kubectl -n kernel-hardening-lab get pod seccomp-lab -w
#      kubectl -n kernel-hardening-lab logs seccomp-lab   # debería mostrar "tick"
#
# --- Escenario 2: AppArmor ---
#
# 1) "kubectl logs apparmor-lab" muestra repetidamente algo como:
#      sh: can't create /tmp/healthy: Permission denied
#    Confirmar que es AppArmor (y no un tema de UNIX permissions) mirando el
#    audit log del kernel en el nodo:
#
#      sudo dmesg | grep -i apparmor | tail
#      # o: sudo journalctl -k | grep -i apparmor | tail
#      # Deberías ver algo como:
#      #   apparmor="DENIED" operation="open" profile="k8s-deny-write-tmp"
#      #   name="/tmp/healthy" comm="sh" requested_mask="w" denied_mask="w"
#
# 2) Revisar el perfil cargado en el nodo:
#      sudo cat /etc/apparmor.d/k8s-deny-write-tmp
#    Tiene la línea "deny /tmp/** w," que bloquea justo lo que el healthcheck
#    de la app necesita.
#
# 3) Arreglo: sacar (o acotar) la regla deny, por ejemplo permitiendo
#    explícitamente el heartbeat file:
#
#      sudo tee /etc/apparmor.d/k8s-deny-write-tmp >/dev/null <<'EOF'
#      #include <tunables/global>
#
#      profile k8s-deny-write-tmp flags=(attach_disconnected) {
#        #include <abstractions/base>
#
#        file,
#        network,
#      }
#      EOF
#
# 4) Punto clave del dominio (a diferencia de seccomp): un perfil AppArmor SÍ
#    se puede recargar en caliente con "apparmor_parser -r" y el kernel lo
#    reaplica de inmediato a los procesos ya confinados con ese profile, sin
#    necesidad de recrear el Pod ni el contenedor:
#
#      sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-write-tmp
#
# 5) Verificar (no hace falta borrar el pod, en unos segundos el próximo
#    "echo alive > /tmp/healthy" del loop va a funcionar y el readinessProbe
#    va a pasar):
#
#      kubectl -n kernel-hardening-lab get pod apparmor-lab -w
#      # Esperar a ver 1/1 Ready
#
# --- Limpieza (la VM es descartable, pero por si querés reusarla) ---
#
#   kubectl delete namespace kernel-hardening-lab
#   sudo rm -f /var/lib/kubelet/seccomp/profiles/block-write.json
#   sudo apparmor_parser -R /etc/apparmor.d/k8s-deny-write-tmp 2>/dev/null || true
#   sudo rm -f /etc/apparmor.d/k8s-deny-write-tmp
#   rm -rf /tmp/cks-5.4-lab