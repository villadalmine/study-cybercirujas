#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# CKA v1.35 - Tema 4.2: Create and manage Kubernetes clusters using kubeadm
# Peso en el examen: 3.57
# Referencia de la definición del tema (curricula oficial, contenido propio):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Break & Fix: static pod manifest del kube-apiserver corrupto.
# Pensado para correr como root en el (único) nodo control-plane de una
# VM de laboratorio descartable creada con kubeadm.
# ============================================================================

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_DIR="/root/teach-plat-breakfix"
BACKUP_FILE="${BACKUP_DIR}/kube-apiserver.yaml.orig"
BROKEN_FLAG="--teach-plat-lab-broken-flag=true"

if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-}" != "yes" ]]; then
  cat <<'EOF'
Este script rompe a propósito el control plane de este nodo.
Ejecutalo SOLO en una VM de laboratorio descartable de un solo nodo
control-plane creada con kubeadm. Nunca en un cluster real.

Si estás seguro, volvé a ejecutar así:
  I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes ./break-fix-4.2-kubeadm.sh
EOF
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Ejecutá este script como root (sudo)." >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "No se encontró $MANIFEST." >&2
  echo "Este nodo no parece ser un control-plane administrado por kubeadm." >&2
  exit 1
fi

command -v crictl >/dev/null 2>&1 || { echo "Falta crictl en el PATH." >&2; exit 1; }

if grep -q -- "$BROKEN_FLAG" "$MANIFEST" 2>/dev/null; then
  echo "El ejercicio ya está roto (el manifest ya tiene el flag inyectado)." >&2
  echo "Resolvelo antes de volver a correr este script." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
cp "$MANIFEST" "$BACKUP_FILE"

sed -i "/^[[:space:]]*-[[:space:]]*kube-apiserver[[:space:]]*\$/a\\    - ${BROKEN_FLAG}" "$MANIFEST"

cat <<'EOF'

============================================================
ROTO A PROPÓSITO - Tema 4.2 (kubeadm)
============================================================
Se modificó el static pod manifest del kube-apiserver
(/etc/kubernetes/manifests/kube-apiserver.yaml).

kubelet vigila ese directorio y va a reiniciar el static pod, pero el
binario kube-apiserver va a fallar al arrancar por un flag que no
existe, así que el contenedor va a quedar en loop de reinicios.

SÍNTOMA que vas a ver:
  - kubectl (cualquier comando) empieza a fallar con timeout o
    "connection refused" contra https://<IP>:6443.
  - El namespace kube-system deja de responder porque el apiserver,
    que es la puerta de entrada a la API, no está arriba.

OBJETIVO: dejar el control plane sano de nuevo. Como el apiserver
está caído, kubectl no te sirve para diagnosticar: vas a tener que
usar el runtime de contenedores directamente.

Pasos que tenés que resolver vos:
  1. Confirmar que kubectl no responde.
  2. Usar crictl (habla directo con containerd, no depende del
     apiserver) para encontrar el contenedor del kube-apiserver y
     ver por qué está reiniciando.
  3. Revisar /etc/kubernetes/manifests/kube-apiserver.yaml, encontrar
     la línea que no pertenece a los flags estándar del apiserver, y
     sacarla.
  4. Guardar el archivo y esperar a que kubelet recree el static pod
     solo (no hace falta reiniciar ningún servicio a mano).
  5. Confirmar que el cluster volvió a responder.

Comandos que probablemente necesites (sin la respuesta completa):
  crictl ps -a | grep kube-apiserver
  crictl logs <container-id>

Cuando creas que lo arreglaste, verificá con:
  kubectl get pods -n kube-system -l component=kube-apiserver
  kubectl get nodes

============================================================
EOF

# ============================================================================
# SOLUCIÓN (comentada - no se ejecuta)
#
# 1. Notás que `kubectl get nodes` da timeout o "connection refused"
#    contra :6443. El apiserver del único control-plane está caído.
#
# 2. Como kubectl no sirve, mirás los contenedores directo con crictl:
#      crictl ps -a | grep kube-apiserver
#    Vas a ver el contenedor en estado Exited con un restart count que
#    sube cada vez que lo volvés a listar (kubelet lo recrea y vuelve
#    a morir).
#
# 3. Tomás el container id más reciente y mirás el log:
#      crictl logs <container-id>
#    El mensaje va a ser algo como:
#      Error: unknown flag: --teach-plat-lab-broken-flag
#
# 4. Editás el manifest del static pod:
#      vi /etc/kubernetes/manifests/kube-apiserver.yaml
#    y borrás la línea:
#      - --teach-plat-lab-broken-flag=true
#    (no pertenece a los flags estándar de kube-apiserver).
#
# 5. Guardás el archivo. kubelet vigila staticPodPath
#    (/etc/kubernetes/manifests) y va a recrear el static pod solo en
#    unos segundos, sin necesidad de `systemctl restart kubelet` ni
#    de tocar containerd.
#
# 6. Confirmás que el nuevo contenedor quedó Running y estable:
#      crictl ps | grep kube-apiserver
#
# 7. Confirmás que el control plane volvió:
#      kubectl get nodes
#      kubectl get pods -n kube-system -l component=kube-apiserver
#    El nodo debe verse Ready y el pod kube-apiserver-<nodo> Running.
#
# 8. Alternativa de emergencia (si te trabaste): el script guardó el
#    manifest original antes de romperlo. Podés restaurarlo con:
#      cp /root/teach-plat-breakfix/kube-apiserver.yaml.orig \
#         /etc/kubernetes/manifests/kube-apiserver.yaml
#    Usalo solo como último recurso: el objetivo del ejercicio es que
#    aprendas a diagnosticar un control plane caído con crictl, no
#    solo a restaurar un backup.
# ============================================================================