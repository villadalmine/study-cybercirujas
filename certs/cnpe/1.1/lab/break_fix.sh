#!/usr/bin/env bash
#
# ============================================================================
# CNPE - Tema 1.1: Applying Platform Architecture Best Practices for
#                  Networking, Storage, and Compute
#
# Script tipo "break & fix" para laboratorio DESCARTABLE (kind/minikube/<PERSON>).
#
# Este script rompe, de forma controlada, TRES aspectos independientes de
# un mismo Deployment dentro de un namespace de laboratorio:
#   1) COMPUTE  -> requests de CPU irracionales (no aplican best practices
#                  de sizing) que provocan que el scheduler no pueda colocar
#                  los Pods.
#   2) STORAGE  -> un PersistentVolumeClaim que referencia una StorageClass
#                  inexistente, dejando el volumen sin poder provisionar.
#   3) NETWORKING -> una NetworkPolicy "deny all ingress" sin reglas de
#                  excepción, que bloquea el tráfico hacia la app.
#
# El objetivo del estudiante es diagnosticar cada capa por separado y
# aplicar la corrección siguiendo las best practices del área (sizing de
# recursos, StorageClass válida, y micro-segmentación con NetworkPolicy
# permitiendo solo el tráfico necesario).
#
# IMPORTANTE: ejecutar SOLO contra un cluster de laboratorio descartable.
# El script verifica el nombre del context y pide <PERSON>
# ============================================================================

set -euo pipefail

NAMESPACE="cnpe-lab-1-1"
APP_LABEL="lab-web"

# ----------------------------------------------------------------------------
# Guardas de seguridad
# ----------------------------------------------------------------------------
check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl no encontrado."; exit 1; }

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: no hay un context de kubectl configurado."
    exit 1
  fi

  echo "Context actual: $ctx"
  if [[ ! "$ctx" =~ (kind|minikube|k3d|lab|test) ]]; then
    echo
    echo "<PERSON>: el nombre del context no sugiere un cluster de laboratorio."
    echo "Este script MODIFICA y ROMPE recursos deliberadamente."
    read -r -p "¿Confirmás que este es un cluster DESCARTABLE? (escribí 'si' para continuar): " ans
    [[ "$ans" == "si" ]] || { echo "Abortado."; exit 1; }
  fi
}

usage() {
  cat <<EOF
Uso: $0 [comando]

Comandos:
  deploy     Crea el namespace de laboratorio y <PERSON> los recursos rotos.
  status     Muestra el estado actual con pistas de diagnóstico.
  cleanup    Elimina por completo el namespace de laboratorio.
  help       Muestra esta ayuda.
EOF
}

# ----------------------------------------------------------------------------
# Despliegue "roto" a propósito
# ----------------------------------------------------------------------------
deploy_broken_lab() {
  echo ">> Creando namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  echo ">> <PERSON> con StorageClass inexistente (rotura #2: STORAGE)..."
  kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nonexistent-sc
  resources:
    requests:
      storage: 1Gi
EOF

  echo ">> Aplicando Deployment con requests de CPU excesivos (rotura #1: COMPUTE)..."
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "500"
              memory: "128Mi"
            limits:
              cpu: "500"
              memory: "128Mi"
          volumeMounts:
            - name: data
              mountPath: /usr/share/nginx/html
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: web-data
EOF

  echo ">> Aplicando Service..."
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: ${APP_LABEL}
  ports:
    - port: 80
      targetPort: 80
EOF

  echo ">> <PERSON> deny-all-ingress sin excepciones (rotura #3: NETWORKING)..."
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-deny-ingress
spec:
  podSelector:
    matchLabels:
      app: ${APP_LABEL}
  policyTypes:
    - Ingress
  ingress: []
EOF

  echo ">> <PERSON>tester' para validar conectividad (no afectado por la NetworkPolicy)..."
  kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: tester
  labels:
    role: tester
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.8.0
      command: ["sleep", "3600"]
EOF

  cat <<EOF

============================================================================
LABORATORIO DESPLEGADO en el namespace '${NAMESPACE}'.

SÍNTOMAS que vas a observar (puede tardar unos segundos en manifestarse):

  1) El Pod del Deployment 'web' va a quedar en estado Pending.
     -> Ejecutá: kubectl get pods -n ${NAMESPACE}
     -> Ejecutá: kubectl describe pod -n ${NAMESPACE} -l app=${APP_LABEL}
        Vas a ver eventos de "FailedScheduling" y también problemas
        <PERSON>.

  2) El PVC 'web-data' va a quedar en estado Pending indefinidamente.
     -> Ejecutá: kubectl get pvc -n ${NAMESPACE}
     -> Ejecutá: kubectl describe pvc web-data -n ${NAMESPACE}

  3) Una vez el Pod finalmente corra (después de arreglar 1 y 2),
     el tráfico desde 'tester' hacia el Service NO va a llegar.
     -> Ejecutá: kubectl exec -n ${NAMESPACE} tester -- curl -m 3 web-svc

OBJETIVO: dejar el Pod 'web' en estado Running, el PVC 'web-data' en
estado Bound, y lograr una respuesta HTTP 200 desde 'tester' hacia
'web-svc', aplicando las best practices de la plataforma (sizing correcto
de resources, StorageClass válida, y una NetworkPolicy que permita
únicamente el tráfico necesario, no que la elimines por completo).
============================================================================
EOF
}

# ----------------------------------------------------------------------------
# Estado / pistas
# ----------------------------------------------------------------------------
show_status() {
  echo "== Pods =="
  kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || echo "(namespace no existe, corré '$0 deploy')"
  echo
  echo "== PVCs =="
  kubectl get pvc -n "${NAMESPACE}" 2>/dev/null
  echo
  echo "== StorageClasses disponibles en el cluster =="
  kubectl get storageclass 2>/dev/null
  echo
  echo "== NetworkPolicies =="
  kubectl get networkpolicy -n "${NAMESPACE}" 2>/dev/null
  echo
  echo "== <PERSON> nodos =="
  kubectl describe nodes 2>/dev/null | grep -A 5 "Allocatable" | grep cpu || true
}

cleanup_lab() {
  echo ">> Eliminando namespace '${NAMESPACE}'..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  case "${1:-help}" in
    deploy)
      check_prereqs
      deploy_broken_lab
      ;;
    status)
      show_status
      ;;
    cleanup)
      check_prereqs
      cleanup_lab
      ;;
    help|*)
      usage
      ;;
  esac
}

main "$@"

# ============================================================================
# SOLUCIÓN PASO A PASO (comentada, no se ejecuta automáticamente)
# ============================================================================
#
# PASO 0 - Diagnóstico general
# -----------------------------
#   kubectl get pods -n cnpe-lab-1-1
#   kubectl describe pod -n cnpe-lab-1-1 -l app=lab-web
#   -> Vas a ver eventos "Insufficient cpu" (problema de COMPUTE) <PERSON>
#      referencias al volumen que no puede montarse (problema de STORAGE).
#
# PASO 1 - Arreglar COMPUTE (requests/limits irracionales)
# ----------------------------------------------------------
#   El Deployment pide 500 cores de CPU, muy por encima de la capacidad
#   real de un nodo de laboratorio. La best practice es dimensionar
#   requests/limits según el uso real esperado del workload.
#
#   kubectl patch deployment web -n cnpe-lab-1-1 --type='json' -p='[
#     {"op":"replace","path":"/spec/template/spec/containers/0/resources",
#      "value":{"requests":{"cpu":"100m","memory":"64Mi"},
#               "limits":{"cpu":"250m","memory":"128Mi"}}}
#   ]'
#
# PASO 2 - Arreglar STORAGE (StorageClass inexistente)
# -------------------------------------------------------
#   Primero identificá qué StorageClass existe realmente en el cluster:
#
#   kubectl get storageclass
#
#   Los PVC son inmutables en el campo storageClassName una vez creados,
#   así que hay que borrar y recrear el PVC apuntando a una StorageClass
#   válida (por ejemplo 'standard' en kind, o la que liste el comando
#   anterior):
#
#   kubectl delete pvc web-data -n cnpe-lab-1-1
#   kubectl apply -n cnpe-lab-1-1 -f - <<'YAML'
#   apiVersion: v1
#   kind: PersistentVolumeClaim
#   metadata:
#     name: web-data
#   spec:
#     accessModes: ["ReadWriteOnce"]
#     storageClassName: standard   # reemplazar por una StorageClass real
#     resources:
#       requests:
#         storage: 1Gi
#   YAML
#
#   Como el Deployment referencia el mismo claimName, un rollout restart
#   alcanza para que el nuevo Pod monte el PVC ya corregido:
#
#   kubectl rollout restart deployment/web -n cnpe-lab-1-1
#
# PASO 3 - Verificar que el Pod llegó a Running y el PVC a Bound
# -----------------------------------------------------------------
#   kubectl get pods -n cnpe-lab-1-1
#   kubectl get pvc -n cnpe-lab-1-1
#
# PASO 4 - Arreglar NETWORKING (NetworkPolicy deny-all sin excepciones)
# -------------------------------------------------------------------------
#   Probá primero el síntoma:
#
#   kubectl exec -n cnpe-lab-1-1 tester -- curl -m 3 web-svc
#   -> Va a hacer timeout porque la NetworkPolicy bloquea todo ingress.
#
#   La best practice de networking NO es borrar la NetworkPolicy, sino
#   agregar una regla explícita que permita únicamente el tráfico
#   necesario (principio de mínimo privilegio / zero trust):
#
#   kubectl apply -n cnpe-lab-1-1 -f - <<'YAML'
#   apiVersion: networking.k8s.io/v1
#   kind: NetworkPolicy
#   metadata:
#     name: web-deny-ingress
#   spec:
#     podSelector:
#       matchLabels:
#         app: lab-web
#     policyTypes:
#       - Ingress
#     ingress:
#       - from:
#           - podSelector:
#               matchLabels:
#                 role: tester
#         ports:
#           - protocol: TCP
#             port: 80
#   YAML
#
# PASO 5 - Validación final
# ----------------------------
#   kubectl exec -n cnpe-lab-1-1 tester -- curl -m 3 <PERSON> -o /dev/null \
#     -w "%{http_code}\n" web-svc
#   -> Debe devolver 200.
#
#   Con esto quedan resueltas, de forma independiente, las tres capas:
#   compute (sizing correcto), storage (StorageClass válida y PVC Bound),
#   y networking (<PERSON> restrictiva pero funcional).
#
# PASO 6 - Limpieza del laboratorio
# ------------------------------------
#   ./este_script.sh cleanup
#
# ============================================================================