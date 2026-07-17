#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CKAD 2.3 - Use the Helm package manager to deploy existing packages
# Break & Fix de laboratorio
#
# Qué hace este script:
#   1. Empaqueta un chart mínimo local (simula un "existing package" ya
#      empaquetado, sin depender de repos de Helm externos que puedan
#      desaparecer o requerir suscripción con el tiempo).
#   2. Lo instala con Helm en un namespace dedicado, en un estado sano.
#   3. Lo rompe con un 'helm upgrade' que apunta a un tag de imagen
#      inexistente (una operación 100% de Helm, no edición manual de YAML).
#   4. Te dice qué síntoma vas a ver y qué tenés que lograr para arreglarlo.
#
# Usalo SOLO en una VM de laboratorio descartable, nunca contra un cluster
# real. Requiere 'helm' y 'kubectl' apuntando a un cluster de prueba.
# =============================================================================

NAMESPACE="ckad-2-3-helm"
RELEASE="lab-nginx"
GOOD_TAG="latest"
BAD_TAG="99.99.99-no-existe"
CHART_DIR="$(mktemp -d -t ckad-2-3-helm-chart.XXXXXX)"

confirm() {
  if [[ "${CKAD_LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  read -r -p "Esto instala y luego ROMPE un release de Helm en el namespace '${NAMESPACE}' del contexto actual ('${ctx}'). Usalo solo en una VM de laboratorio descartable. ¿Continuar? [y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 1; }
}

require_tools() {
  for bin in helm kubectl; do
    command -v "${bin}" >/dev/null 2>&1 || { echo "Falta '${bin}' en el PATH." >&2; exit 1; }
  done
}

write_chart() {
  mkdir -p "${CHART_DIR}/templates"

  cat > "${CHART_DIR}/Chart.yaml" <<'YAML'
apiVersion: v2
name: lab-nginx
description: Chart minimo para el laboratorio break-and-fix de Helm (CKAD 2.3)
type: application
version: 0.1.0
appVersion: "1.0"
YAML

  cat > "${CHART_DIR}/values.yaml" <<YAML
replicaCount: 1
image:
  repository: nginx
  tag: ${GOOD_TAG}
  pullPolicy: IfNotPresent
service:
  port: 80
YAML

  cat > "${CHART_DIR}/templates/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: nginx
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 80
YAML

  cat > "${CHART_DIR}/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 80
YAML
}

setup() {
  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

  if helm status "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Ya existe el release '${RELEASE}' en '${NAMESPACE}'. Eliminalo antes de correr este script de nuevo:" >&2
    echo "  helm uninstall ${RELEASE} -n ${NAMESPACE}" >&2
    exit 1
  fi

  echo "Instalando release '${RELEASE}' (chart local en ${CHART_DIR}) en namespace '${NAMESPACE}'..."
  helm install "${RELEASE}" "${CHART_DIR}" \
    -n "${NAMESPACE}" \
    --wait --timeout 3m

  echo "Release instalado y sano:"
  kubectl get pods -n "${NAMESPACE}" -l app="${RELEASE}"
}

break_it() {
  echo
  echo "Rompiendo el release con 'helm upgrade' a un tag de imagen inexistente..."
  helm upgrade "${RELEASE}" "${CHART_DIR}" \
    -n "${NAMESPACE}" \
    --set image.tag="${BAD_TAG}"

  cat <<MSG

============================================================
 SINTOMA
============================================================
El release de Helm '${RELEASE}' en el namespace '${NAMESPACE}'
fue actualizado con 'helm upgrade' y el Pod ya no llega a
Running. Vas a ver algo como:

  kubectl get pods -n ${NAMESPACE}
  NAME                          READY   STATUS             RESTARTS   AGE
  lab-nginx-xxxxxxxxxx-yyyyy    0/1     ImagePullBackOff   0          30s

============================================================
 OBJETIVO
============================================================
Sin editar manifests de Kubernetes a mano, usa el CLI de Helm
para devolver el release a un estado sano:

  1. Confirma que el problema esta en la imagen del release
     (helm get values, helm history, kubectl describe pod).
  2. Arreglalo con Helm, ya sea:
     a) haciendo 'helm rollback' a la revision anterior que
        funcionaba, o
     b) haciendo un nuevo 'helm upgrade' seteando un tag de
        imagen valido (el chart local sigue disponible en
        ${CHART_DIR} si lo necesitas).
  3. Verifica con 'helm status' y 'kubectl get pods' que el
     Pod queda Running/Ready, y que 'helm history' registra
     el cambio como una revision nueva.

Para limpiar el laboratorio cuando termines:
  helm uninstall ${RELEASE} -n ${NAMESPACE}
  kubectl delete namespace ${NAMESPACE}
  rm -rf ${CHART_DIR}
============================================================
MSG
}

require_tools
confirm
write_chart
setup
break_it

# =============================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
#
# 1) Confirmar el sintoma:
#      kubectl get pods -n ckad-2-3-helm
#      kubectl describe pod -n ckad-2-3-helm -l app=lab-nginx
#      -> Reason: ImagePullBackOff / ErrImagePull
#
# 2) Revisar el historial y los valores del release:
#      helm history lab-nginx -n ckad-2-3-helm
#      helm get values lab-nginx -n ckad-2-3-helm
#      -> se ve que la revision mas reciente cambio image.tag a
#         "99.99.99-no-existe"
#
# 3a) Opcion A: rollback a la revision anterior sana
#      helm rollback lab-nginx 1 -n ckad-2-3-helm --wait
#
# 3b) Opcion B: upgrade con un tag de imagen valido
#      helm upgrade lab-nginx <ruta-al-chart> \
#        -n ckad-2-3-helm \
#        --set image.tag=latest \
#        --wait
#
# 4) Verificar que quedo sano:
#      helm status lab-nginx -n ckad-2-3-helm
#      kubectl get pods -n ckad-2-3-helm
#      helm history lab-nginx -n ckad-2-3-helm
#      -> el Pod debe estar Running/Ready y helm history debe mostrar
#         una revision nueva marcada como "deployed"
# =============================================================================