#!/usr/bin/env bash
#
# CKS v1.34 - Dominio 2: Cluster Hardening
# Tema 2.1: Use appropriate Pod Security Standards
# Peso en el examen: 5
#
# Fuente de referencia (curriculum oficial, solo como guía de scope, no se
# copia texto literal de ahi):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Este script es tipo "break & fix": deja un Deployment roto por una
# violacion de Pod Security Admission (PSA) en un namespace con el nivel
# "restricted" aplicado. Uso pensado solo para una VM de laboratorio
# descartable (kind/minikube/vagrant), NUNCA contra un cluster real.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NS="cks-pss-lab"
DEPLOY="insecure-web"

log()  { echo -e "${CYAN}[lab]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }

# --- Guard rails: exigimos confirmacion explicita antes de romper nada ---
if ! command -v kubectl >/dev/null 2>&1; then
    err "kubectl no esta instalado o no esta en el PATH. Abortando."
    exit 1
fi

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
if [[ "$CURRENT_CTX" =~ prod|production ]]; then
    err "El contexto actual de kubectl ('$CURRENT_CTX') parece de produccion."
    err "Este script solo debe correr contra un cluster de laboratorio descartable. Abortando."
    exit 1
fi

if [[ "${I_KNOW_THIS_IS_A_DISPOSABLE_LAB:-}" != "yes" ]]; then
    warn "Este script va a crear un namespace roto a proposito en el cluster"
    warn "apuntado por tu kubeconfig actual (contexto: '$CURRENT_CTX')."
    warn "Corre solo contra una VM/cluster de laboratorio descartable."
    warn "Si estas seguro, volve a ejecutar asi:"
    echo
    echo "    I_KNOW_THIS_IS_A_DISPOSABLE_LAB=yes $0"
    echo
    exit 1
fi

log "Namespace de laboratorio: $NS"
log "Contexto de kubectl: $CURRENT_CTX"

# --- BREAK: namespace con Pod Security Standard "restricted" + workload que lo viola ---

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Aplicamos el Pod Security Standard "restricted" via Pod Security Admission
# (el admission controller nativo que reemplazo a PodSecurityPolicy).
# Ademas de "enforce" dejamos "warn" y "audit" en restricted para que
# cualquier "kubectl apply" futuro del estudiante muestre el warning inline.
kubectl label namespace "$NS" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted \
    --overwrite >/dev/null

log "Namespace '$NS' etiquetado con Pod Security Standard 'restricted'."

# Deployment deliberadamente "vanilla": sin securityContext de ningun tipo.
# Bajo el nivel "restricted" esto viola varios controles a la vez:
#   - allowPrivilegeEscalation no esta seteado en false
#   - runAsNonRoot no esta seteado en true (el contenedor arrancaria como root)
#   - no se dropean capabilities (se exige drop: ["ALL"])
#   - no hay seccompProfile (se exige RuntimeDefault o Localhost)
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY
  template:
    metadata:
      labels:
        app: $DEPLOY
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
EOF

log "Deployment '$DEPLOY' aplicado en '$NS'."
log "Esperando el rollout unos segundos (va a fallar, es esperado)..."
kubectl rollout status "deployment/$DEPLOY" -n "$NS" --timeout=15s 2>/dev/null || true

echo
echo "=================================================================="
echo " SINTOMA"
echo "=================================================================="
cat <<'MSG'
El Deployment quedo aplicado pero nunca llega a tener Pods corriendo.

Comandos utiles para observar el problema:

    kubectl get deployment insecure-web -n cks-pss-lab
    kubectl get rs -n cks-pss-lab
    kubectl describe rs -n cks-pss-lab -l app=insecure-web
    kubectl get events -n cks-pss-lab --sort-by=.lastTimestamp

Vas a ver:
  - READY 0/1 en el Deployment, indefinidamente.
  - Un ReplicaSet con 0 Pods creados.
  - Un evento Warning "FailedCreate" en el ReplicaSet con un mensaje del
    estilo: pods "insecure-web-xxxxx" is forbidden: violates PodSecurity
    "restricted:latest": allowPrivilegeEscalation != false, unrestricted
    capabilities, runAsNonRoot != true, seccompProfile ...

==================================================================
 OBJETIVO
==================================================================
Sin bajar el nivel de "enforce" del namespace (dejalo en restricted:
bajar el nivel seria hacer trampa, no arreglar el problema real),
modifica el Deployment "insecure-web" para que cumpla el Pod Security
Standard "restricted" y los Pods terminen en estado Running.

Pista de que campos te faltan: securityContext a nivel Pod y a nivel
container (allowPrivilegeEscalation, runAsNonRoot, capabilities,
seccompProfile).

Quedas en https://kubernetes.io/docs/concepts/security/pod-security-standards/
como referencia oficial de los tres niveles (privileged, baseline,
restricted) y sus controles exactos.
MSG
echo "=================================================================="

exit 0

# ==================================================================
# SOLUCION (comentada, no se ejecuta automaticamente)
# ==================================================================
#
# 1) Diagnostico: confirmar que el rechazo viene de PSA y por que.
#
#    kubectl describe rs -n cks-pss-lab -l app=insecure-web
#    # -> Warning FailedCreate ... violates PodSecurity "restricted:latest": ...
#
# 2) Completar el securityContext a nivel Pod y a nivel container para
#    cumplir "restricted". Via patch (usa el strategic merge patch por
#    default de kubectl, que mergea la lista containers por "name"):
#
#    kubectl patch deployment insecure-web -n cks-pss-lab -p '
#    {
#      "spec": {
#        "template": {
#          "spec": {
#            "securityContext": {
#              "runAsNonRoot": true,
#              "seccompProfile": { "type": "RuntimeDefault" }
#            },
#            "containers": [
#              {
#                "name": "app",
#                "securityContext": {
#                  "allowPrivilegeEscalation": false,
#                  "capabilities": { "drop": ["ALL"] }
#                }
#              }
#            ]
#          }
#        }
#      }
#    }'
#
#    Equivalente manual: "kubectl edit deployment insecure-web -n cks-pss-lab"
#    y agregar los mismos campos bajo spec.template.spec.
#
# 3) Verificar que el rollout ahora completa y los Pods quedan Running:
#
#    kubectl rollout status deployment/insecure-web -n cks-pss-lab --timeout=30s
#    kubectl get pods -n cks-pss-lab -o wide
#
# 4) (Opcional) Confirmar que el namespace se mantuvo en "restricted" en
#    todo momento, es decir que arreglaste el workload y no la politica:
#
#    kubectl get ns cks-pss-lab --show-labels | grep pod-security
#
# 5) Cleanup del laboratorio:
#
#    kubectl delete namespace cks-pss-lab
#
# ==================================================================