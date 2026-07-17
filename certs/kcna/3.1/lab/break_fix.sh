#!/usr/bin/env bash
# ============================================================================
# KCNA - Dominio 3.1 Administration (peso: 4)
# Break & Fix: kubeconfig con server endpoint incorrecto
#
# Fuente de referencia (consultar para profundizar, no copiada literalmente):
#   https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# Este script rompe, de forma controlada y reversible, el archivo kubeconfig
# del cluster de laboratorio: reapunta el "server" del cluster activo a un
# puerto incorrecto usando el propio subcomando "kubectl config", sin tocar
# ningún componente del control plane ni de los nodos.
#
# USAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE. No ejecutar contra un
# kubeconfig o cluster que te importe conservar.
# ============================================================================

set -euo pipefail

MARKER_FILE="/tmp/kcna-admin-lab-3.1.marker"

if [[ -f "$MARKER_FILE" ]]; then
  echo "Ya hay un lab roto pendiente de resolver (marker: $MARKER_FILE)."
  echo "Resolvé el lab actual antes de volver a ejecutar este script, o borrá"
  echo "el marker manualmente si querés forzar un nuevo intento."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "No se encontró 'kubectl' en el PATH. Este lab requiere un cluster"
  echo "Kubernetes accesible desde esta VM."
  exit 1
fi

echo "============================================================"
echo " KCNA 3.1 Administration - Lab: kubeconfig roto"
echo "============================================================"
echo
echo "Este script va a modificar el kubeconfig ACTUAL de esta VM de"
echo "laboratorio (contexto en uso), reapuntando el 'server' del cluster"
echo "a un puerto incorrecto. Es una operación de solo lectura sobre el"
echo "cluster real: no se toca ni el control plane ni los nodos."
echo
read -r -p "Escribí 'romper' para continuar: " CONFIRM
if [[ "$CONFIRM" != "romper" ]]; then
  echo "Cancelado. No se modificó nada."
  exit 0
fi

CURRENT_CONTEXT="$(kubectl config current-context)"
CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${CURRENT_CONTEXT}\")].context.cluster}")"
ORIGINAL_SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${CLUSTER_NAME}\")].cluster.server}")"

if [[ -z "$ORIGINAL_SERVER" ]]; then
  echo "No se pudo leer el 'server' del cluster '$CLUSTER_NAME'. Abortando."
  exit 1
fi

if [[ ! "$ORIGINAL_SERVER" =~ ^(https?://[^:]+):([0-9]+)(.*)$ ]]; then
  echo "El formato del server '$ORIGINAL_SERVER' no es el esperado. Abortando."
  exit 1
fi

HOST_PART="${BASH_REMATCH[1]}"
ORIGINAL_PORT="${BASH_REMATCH[2]}"
REST_PART="${BASH_REMATCH[3]}"
BROKEN_PORT=$((ORIGINAL_PORT + 1))
BROKEN_SERVER="${HOST_PART}:${BROKEN_PORT}${REST_PART}"

# Guardamos el estado original para que el instructor pueda auditar el lab.
# El estudiante NO necesita este archivo para resolverlo: la resolución
# esperada es diagnosticar y corregir el kubeconfig con kubectl config.
cat > "$MARKER_FILE" <<EOF
context=${CURRENT_CONTEXT}
cluster=${CLUSTER_NAME}
original_server=${ORIGINAL_SERVER}
broken_server=${BROKEN_SERVER}
EOF

kubectl config set-cluster "$CLUSTER_NAME" --server="$BROKEN_SERVER" >/dev/null

echo
echo "------------------------------------------------------------"
echo " SÍNTOMA"
echo "------------------------------------------------------------"
echo "Intentando contactar al cluster con el kubeconfig actual..."
echo
timeout 5 kubectl get nodes 2>&1 || true
echo
echo "------------------------------------------------------------"
echo " OBJETIVO DEL ESTUDIANTE"
echo "------------------------------------------------------------"
cat <<'EOF'
kubectl ya no puede hablar con el API server: vas a ver algo como
"The connection to the server <host>:<puerto> was refused" o un timeout.

El cluster está sano. El problema vive únicamente en el kubeconfig de
esta VM (por defecto en ~/.kube/config o en $KUBECONFIG).

Tenés que:
  1. Inspeccionar el kubeconfig activo (contexto, cluster, server) con
     los subcomandos de "kubectl config".
  2. Identificar qué campo del cluster quedó mal configurado.
  3. Corregirlo usando "kubectl config set-cluster" (no editar el YAML
     a mano, para practicar el flujo idiomático de administración).
  4. Confirmar que "kubectl get nodes" vuelve a responder correctamente.

Cuando lo logres, borrá el archivo de marcador para cerrar el lab:
  rm -f /tmp/kcna-admin-lab-3.1.marker
EOF
echo "------------------------------------------------------------"

# ============================================================================
# SOLUCIÓN (comentada — no se ejecuta como parte del script)
#
# 1. Confirmar el contexto activo y el cluster asociado:
#      kubectl config current-context
#      kubectl config get-contexts
#
# 2. Ver el server configurado para ese cluster:
#      kubectl config view -o jsonpath='{.clusters[*].cluster.server}'
#    Va a mostrar un puerto que no corresponde al API server real
#    (el original + 1, por ejemplo 6443 -> 6444).
#
# 3. Restaurar el server correcto usando el propio kubectl (sin tocar
#    el YAML a mano):
#      kubectl config set-cluster <CLUSTER_NAME> --server=https://<host>:<puerto-original>
#
#    Si no se conoce el puerto original, se puede consultar cómo se
#    inicializó el cluster (por ejemplo, el puerto por defecto de la
#    API de Kubernetes es 6443 en instalaciones vía kubeadm).
#
# 4. Verificar que el acceso se restableció:
#      kubectl get nodes
#      kubectl cluster-info
#
# 5. Cerrar el lab eliminando el marcador:
#      rm -f /tmp/kcna-admin-lab-3.1.marker
# ============================================================================