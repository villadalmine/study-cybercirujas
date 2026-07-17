#!/usr/bin/env bash
#
# CKAD 4.8 - Understand Application Security (SecurityContexts, Capabilities, etc.)
# Break & Fix lab: Linux Capabilities y bind de puertos privilegiados
#
# ADVERTENCIA: este script crea y borra recursos en el cluster apuntado
# por tu kubeconfig actual. Ejecutalo SOLO contra una VM de laboratorio
# descartable (kind, minikube, k3d, etc.), nunca contra un cluster
# compartido o productivo.
#
# Uso:
#   ./break-478-capabilities.sh break    # rompe el escenario
#   ./break-478-capabilities.sh status   # muestra el estado actual (diagnóstico)
#   ./break-478-capabilities.sh clean    # borra el namespace del lab
#
set -euo pipefail

NAMESPACE="ckad-478-lab"
POD_NAME="webserver"
CONTEXT="$(kubectl config current-context 2>/dev/null || echo "desconocido")"

confirm_lab_environment() {
  echo "Contexto actual de kubectl: ${CONTEXT}"
  echo "Este script va a crear/borrar recursos en el namespace '${NAMESPACE}'."
  read -r -p "¿Confirmás que este es un cluster de laboratorio descartable? [escribí 'si' para continuar]: " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado. No se modificó el cluster."
    exit 1
  fi
}

break_scenario() {
  confirm_lab_environment

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  cat <<'EOF' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Pod
metadata:
  name: webserver
  labels:
    app: webserver
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: webserver
      image: python:3.12-alpine
      command: ["python3", "-m", "http.server", "80"]
      ports:
        - containerPort: 80
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF

  echo ""
  echo "Escenario roto en el namespace '${NAMESPACE}'."
  echo "Esperando unos segundos para que el kubelet intente arrancar el Pod..."
  sleep 8
  kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" || true

  cat <<'MSG'

================================================================
SÍNTOMA
================================================================
El Pod "webserver" entra en CrashLoopBackOff (o Error) y se reinicia
en loop. Revisá:

  kubectl get pod webserver -n ckad-478-lab
  kubectl logs webserver -n ckad-478-lab
  kubectl logs webserver -n ckad-478-lab --previous

Vas a ver algo similar a:

  Traceback (most recent call last):
    ...
  PermissionError: [Errno 13] Permission denied

================================================================
OBJETIVO
================================================================
El Pod corre como usuario no-root (runAsNonRoot: true, runAsUser: 1000)
y el container tiene "capabilities.drop: [ALL]". Sin capabilities,
un proceso no-root no puede hacer bind() en puertos privilegiados
(< 1024), como el puerto 80 que usa este container.

Tu tarea: modificá el manifiesto del Pod para que el proceso pueda
bindear el puerto 80 SIN:
  - correr como root (no toques runAsNonRoot ni runAsUser)
  - otorgar más capabilities de las estrictamente necesarias
  - cambiar el puerto de escucha del container

Pista: pensá en qué Linux capability le permite a un proceso no-root
bindear puertos privilegiados, y cómo se agrega esa capability
puntual en un securityContext que ya parte de "drop: ALL".

Como el campo "securityContext.capabilities" de un container no es
mutable en un Pod ya creado, vas a necesitar borrar el Pod y
volver a aplicar un manifiesto corregido (no alcanza con
"kubectl edit").

Vas a saber que lo resolviste cuando:
  kubectl get pod webserver -n ckad-478-lab
muestre STATUS "Running" con RESTARTS en 0, y:
  kubectl logs webserver -n ckad-478-lab
muestre la línea "Serving HTTP on 0.0.0.0 port 80" sin más reinicios.
================================================================
MSG
}

show_status() {
  kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide || true
  echo "---"
  kubectl describe pod "${POD_NAME}" -n "${NAMESPACE}" | tail -n 20 || true
}

clean_scenario() {
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
}

main() {
  case "${1:-}" in
    break)  break_scenario ;;
    status) show_status ;;
    clean)  clean_scenario ;;
    *)
      echo "Uso: $0 {break|status|clean}" >&2
      exit 1
      ;;
  esac
}

main "$@"

# ================================================================
# SOLUCIÓN (comentada, no se ejecuta)
# ================================================================
#
# 1. Diagnóstico:
#      kubectl describe pod webserver -n ckad-478-lab
#      kubectl logs webserver -n ckad-478-lab --previous
#    Se confirma CrashLoopBackOff y "PermissionError: [Errno 13]
#    Permission denied" al intentar escuchar en el puerto 80, porque
#    el container corre como UID 1000 sin la capability
#    NET_BIND_SERVICE.
#
# 2. Corregir el manifiesto agregando SOLO esa capability puntual,
#    manteniendo drop: ALL, runAsNonRoot y runAsUser sin cambios:
#
#    apiVersion: v1
#    kind: Pod
#    metadata:
#      name: webserver
#      labels:
#        app: webserver
#    spec:
#      securityContext:
#        runAsNonRoot: true
#        runAsUser: 1000
#      containers:
#        - name: webserver
#          image: python:3.12-alpine
#          command: ["python3", "-m", "http.server", "80"]
#          ports:
#            - containerPort: 80
#          securityContext:
#            allowPrivilegeEscalation: false
#            capabilities:
#              drop: ["ALL"]
#              add: ["NET_BIND_SERVICE"]
#
# 3. Como securityContext.capabilities no es mutable en un Pod
#    corriendo, hay que recrear el Pod:
#
#      kubectl delete pod webserver -n ckad-478-lab
#      kubectl apply -n ckad-478-lab -f pod-fixed.yaml
#
# 4. Verificar:
#      kubectl get pod webserver -n ckad-478-lab
#      # STATUS: Running, RESTARTS: 0
#      kubectl logs webserver -n ckad-478-lab
#      # Serving HTTP on 0.0.0.0 port 80 (http://0.0.0.0:80/) ...
#
# 5. Limpieza:
#      ./break-478-capabilities.sh clean
# ================================================================