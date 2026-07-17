#!/usr/bin/env bash
#
# KCNA - Tema 3.6: Troubleshooting (peso en el examen: 4)
# Script "break & fix" para laboratorio descartable (VM/kind/minikube/k3d)
#
# Fuente de referencia (curriculum oficial de CNCF, contenido de este
# script es original, no copia texto de la fuente):
# https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
#
# ADVERTENCIA: ejecutar SOLO en un cluster de laboratorio descartable.
# El script crea, rompe y borra recursos reales dentro de un namespace
# dedicado; no toca nada fuera de ese namespace.
#
set -euo pipefail

NAMESPACE="kcna-366-lab"
DEPLOY="web"
SVC="web-svc"

info() { printf '\n\033[1;34m[LAB]\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$1"; }

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl no encontrado. Abortando."; exit 1; }
}

confirm_disposable() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  warn "Este script va a crear y romper recursos en el contexto actual: '$ctx'"
  warn "Usalo SOLO en un cluster de laboratorio descartable (kind/minikube/k3d)."
  read -r -p "¿Confirmás que este cluster es descartable? (escribí 'si' para continuar): " ans
  [[ "$ans" == "si" ]] || { echo "Cancelado."; exit 1; }
}

setup() {
  info "Creando namespace y aplicación de base..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: $SVC
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

  info "Esperando a que el Deployment esté disponible..."
  kubectl rollout status deployment/"$DEPLOY" -n "$NAMESPACE" --timeout=120s

  info "Estado inicial (todo funcionando):"
  kubectl get pods,svc,endpoints -n "$NAMESPACE"
}

break_it() {
  info "Rompiendo el laboratorio de forma controlada..."
  kubectl patch service "$SVC" -n "$NAMESPACE" \
    --type=merge -p '{"spec":{"selector":{"app":"web-frontend"}}}'

  cat <<'MSG'

==================== SINTOMA ====================
Los Pods del Deployment "web" siguen en estado Running (podés confirmarlo
con "kubectl get pods -n kcna-366-lab"), pero cualquier intento de acceder
a la aplicación a través del Service falla.

Para reproducir el síntoma, corré un Pod temporal y probá el acceso:

  kubectl run tmp-client --rm -it --restart=Never -n kcna-366-lab \
    --image=busybox:1.36 -- wget -qO- --timeout=3 http://web-svc

Vas a ver un timeout o "wget: download timed out" en vez de la respuesta
HTML de nginx ("Welcome to nginx!").

==================== OBJETIVO ====================
Diagnosticar por qué el Service "web-svc" no está enrutando tráfico hacia
los Pods del Deployment "web", y arreglarlo SIN borrar ni recrear el
Deployment. El laboratorio se considera resuelto cuando:

  1) "kubectl get endpoints web-svc -n kcna-366-lab" muestra al menos
     una IP de Pod (no debe estar vacío).
  2) El comando de wget de arriba devuelve el HTML de nginx.

Herramientas sugeridas para investigar (sin revelar la causa):
kubectl describe, kubectl get pods --show-labels, kubectl get svc -o yaml.
====================================================

MSG
}

status_check() {
  info "Verificación rápida del estado actual:"
  kubectl get pods -n "$NAMESPACE" --show-labels
  echo
  kubectl get endpoints "$SVC" -n "$NAMESPACE"
}

cleanup() {
  info "Eliminando namespace del laboratorio..."
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
}

usage() {
  cat <<EOF
Uso: $0 [setup|break|status|cleanup]

  setup    crea el Deployment + Service funcionando (ejecutar primero)
  break    rompe el laboratorio (selector del Service) y muestra el enunciado
  status   muestra pods/endpoints para que el estudiante verifique su diagnóstico
  cleanup  borra todo el namespace del laboratorio

Flujo típico:
  $0 setup
  $0 break
  # ... el estudiante investiga y aplica el fix con kubectl ...
  $0 status
  $0 cleanup
EOF
}

main() {
  require_kubectl
  case "${1:-}" in
    setup)   confirm_disposable; setup ;;
    break)   break_it ;;
    status)  status_check ;;
    cleanup) cleanup ;;
    *)       usage ;;
  esac
}

main "$@"

#
# ==========================================================================
# SOLUCIÓN PASO A PASO (para el instructor / autocorrección del estudiante)
# ==========================================================================
#
# 1) Confirmar que los Pods están corriendo pero el Service no tiene endpoints:
#      kubectl get pods -n kcna-366-lab --show-labels
#      kubectl get endpoints web-svc -n kcna-366-lab
#    -> Los Pods tienen la label "app=web", pero la columna ENDPOINTS del
#       Service aparece vacía ("<none>"), lo que indica que el Service no
#       está matcheando ningún Pod.
#
# 2) Inspeccionar el selector real del Service:
#      kubectl get svc web-svc -n kcna-366-lab -o yaml
#    -> spec.selector quedó en "app: web-frontend", que no coincide con
#       la label "app: web" que tienen los Pods del Deployment.
#
# 3) Corregir el selector para que coincida con las labels de los Pods:
#      kubectl patch service web-svc -n kcna-366-lab \
#        --type=merge -p '{"spec":{"selector":{"app":"web"}}}'
#
# 4) Verificar que el Service ahora tiene endpoints:
#      kubectl get endpoints web-svc -n kcna-366-lab
#    -> Debe listar las IPs de los Pods en el puerto 80.
#
# 5) Confirmar que el tráfico llega a la aplicación:
#      kubectl run tmp-client --rm -it --restart=Never -n kcna-366-lab \
#        --image=busybox:1.36 -- wget -qO- --timeout=3 http://web-svc
#    -> Debe devolver el HTML "Welcome to nginx!".
#
# Concepto evaluado: los Services de Kubernetes enrutan tráfico usando un
# selector de labels que arma dinámicamente el objeto Endpoints; un
# mismatch entre el selector del Service y las labels del Pod/Deployment
# es una causa clásica de "Service sin backend" y encaja directamente en
# el dominio de Troubleshooting del curriculum de KCNA.
# Referencia: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
# ==========================================================================