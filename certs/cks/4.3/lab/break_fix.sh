#!/usr/bin/env bash
#
# CKS v1.34 - Dominio 4.3: Secure your supply chain
#             (permitted registries, sign and validate artifacts)
# Peso en el examen: 5
#
# Laboratorio "break & fix". Ejecutalo SOLO en una VM de laboratorio
# DESCARTABLE con kubectl apuntando a un cluster Kubernetes >= 1.30
# (necesita ValidatingAdmissionPolicy GA en admissionregistration.k8s.io/v1).
# No lo corras contra un cluster real: crea y rompe reglas de admisión.
#
# Uso:
#   ./break-fix-4.3-supply-chain.sh setup   # crea la linea base (funcionando)
#   ./break-fix-4.3-supply-chain.sh break   # introduce la falla controlada
#   ./break-fix-4.3-supply-chain.sh check   # verifica si ya lo arreglaste
#   ./break-fix-4.3-supply-chain.sh clean   # borra todo lo creado por el lab
#
# Fuente de referencia (curriculum oficial, usado solo como guia de temario):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="supplychain-lab"
POLICY_NAME="cks-allowed-registries"
BINDING_NAME="cks-allowed-registries-binding"

die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl no encontrado en PATH"
  kubectl cluster-info >/dev/null 2>&1 || die "No hay acceso a un cluster Kubernetes"
  kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
    | grep -q '^validatingadmissionpolicies' \
    || die "El cluster no expone ValidatingAdmissionPolicy (admissionregistration.k8s.io/v1). Necesitas Kubernetes >= 1.30."
}

confirm_lab() {
  if [[ "${FORCE:-}" == "1" ]]; then return 0; fi
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "desconocido")
  warn "Este script crea y rompe reglas de admisión en el cluster actual."
  warn "Contexto actual: ${ctx}"
  warn "Usalo SOLO en una VM de laboratorio descartable, nunca en un cluster real."
  read -r -p "Escribi 'si' para continuar: " ans
  [[ "${ans}" == "si" ]] || die "Cancelado por el usuario."
}

setup_baseline() {
  info "Creando namespace ${NAMESPACE}..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  info "Aplicando ValidatingAdmissionPolicy + Binding (linea base funcional)..."
  cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ${POLICY_NAME}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.startsWith('registry.k8s.io/') ||
          c.image.startsWith('registry.internal.lab/')
        )
      message: "Imagen rechazada: solo se permiten imagenes de registry.k8s.io/ o registry.internal.lab/"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ${BINDING_NAME}
spec:
  policyName: ${POLICY_NAME}
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ${NAMESPACE}
EOF

  info "Esperando a que el API server registre la policy..."
  sleep 3

  info "Verificando linea base: una imagen de registry NO permitido debe ser rechazada..."
  if kubectl run baseline-bad --image=docker.io/library/nginx -n "${NAMESPACE}" --restart=Never 2>/tmp/baseline-bad.log; then
    kubectl delete pod baseline-bad -n "${NAMESPACE}" --ignore-not-found --wait=false
    die "La linea base no quedo bien: el pod no permitido NO fue rechazado. Revisa el cluster antes de seguir."
  else
    info "OK: el pod no permitido fue rechazado como se esperaba."
    cat /tmp/baseline-bad.log
  fi

  info "Verificando linea base: una imagen de registry permitido debe poder crearse..."
  kubectl run baseline-good --image=registry.k8s.io/pause:3.9 -n "${NAMESPACE}" --restart=Never >/dev/null
  kubectl wait --for=condition=Ready pod/baseline-good -n "${NAMESPACE}" --timeout=60s || true
  info "OK: el pod permitido se creo correctamente."

  info "Limpiando pods de prueba..."
  kubectl delete pod baseline-good -n "${NAMESPACE}" --ignore-not-found --wait=false

  info "Linea base lista. Ahora podes correr: $0 break"
}

break_it() {
  info "Aplicando una falla controlada sobre la politica de supply chain..."
  kubectl patch validatingadmissionpolicybinding "${BINDING_NAME}" \
    --type=merge -p '{"spec":{"validationActions":["Audit"]}}' >/dev/null

  cat <<'MSG'

================================================================
 SINTOMA
================================================================
En el namespace "supplychain-lab" existe una ValidatingAdmissionPolicy
llamada "cks-allowed-registries" que en teoria solo deberia permitir
pods con imagenes de "registry.k8s.io/" o "registry.internal.lab/".

Sin embargo, ahora podes crear pods con imagenes de CUALQUIER
registry (por ejemplo docker.io) y el cluster los deja pasar, como
si la politica no existiera.

Probalo vos mismo:

  kubectl run test-bad --image=docker.io/library/nginx \
    -n supplychain-lab --restart=Never

  (el pod se crea, cuando NO deberia)

================================================================
 OBJETIVO
================================================================
Sin borrar ni recrear la ValidatingAdmissionPolicy ni el Binding
desde cero, encontra por que dejo de bloquear y arreglalo para que:

  1. Un pod con imagen de un registry no autorizado sea RECHAZADO
     en el momento de crearlo (no despues, no solo registrado en logs).
  2. Un pod con imagen de registry.k8s.io/ siga funcionando normal.

Pistas de comandos para investigar (no dan la solucion directamente):
  kubectl get validatingadmissionpolicies
  kubectl get validatingadmissionpolicybindings
  kubectl get validatingadmissionpolicybinding <nombre> -o yaml

Cuando creas que lo arreglaste, corre:
  ./break-fix-4.3-supply-chain.sh check
================================================================

MSG
}

check() {
  info "Probando pod con imagen NO permitida (docker.io)..."
  if kubectl run check-bad --image=docker.io/library/nginx -n "${NAMESPACE}" --restart=Never 2>/tmp/check-bad.log; then
    kubectl delete pod check-bad -n "${NAMESPACE}" --ignore-not-found --wait=false
    warn "FALLA: el pod con imagen no permitida se creo. Todavia no esta arreglado."
    return 1
  else
    info "OK: el pod con imagen no permitida fue rechazado."
    grep -i "denied\|rechaz" /tmp/check-bad.log || true
  fi

  info "Probando pod con imagen permitida (registry.k8s.io)..."
  if kubectl run check-good --image=registry.k8s.io/pause:3.9 -n "${NAMESPACE}" --restart=Never >/dev/null 2>&1; then
    kubectl delete pod check-good -n "${NAMESPACE}" --ignore-not-found --wait=false
    info "OK: el pod con imagen permitida se creo sin problemas."
  else
    warn "FALLA: el pod con imagen permitida no se pudo crear (revisa failurePolicy/matchConstraints)."
    return 1
  fi

  echo
  info "TODO CORRECTO: la politica esta bloqueando registries no permitidos otra vez."
}

clean() {
  info "Borrando recursos del lab..."
  kubectl delete validatingadmissionpolicybinding "${BINDING_NAME}" --ignore-not-found
  kubectl delete validatingadmissionpolicy "${POLICY_NAME}" --ignore-not-found
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
  info "Listo."
}

usage() {
  cat <<EOF
Uso: $0 {setup|break|check|clean}

  setup   crea el namespace, la ValidatingAdmissionPolicy y el Binding
          funcionando correctamente (linea base).
  break   introduce una falla controlada y segura para que la practiques.
  check   verifica si ya arreglaste la falla.
  clean   borra todos los recursos creados por este lab.
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    setup) check_prereqs; confirm_lab; setup_baseline ;;
    break) check_prereqs; break_it ;;
    check) check_prereqs; check ;;
    clean) check_prereqs; clean ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

# ================================================================
# SOLUCION PASO A PASO (no la leas hasta intentar resolverlo vos)
# ================================================================
#
# 1. Confirmar que la ValidatingAdmissionPolicy sigue existiendo:
#      kubectl get validatingadmissionpolicy cks-allowed-registries
#
# 2. Inspeccionar el Binding, que es lo que conecta la policy con
#    los recursos reales y define que pasa cuando se viola:
#      kubectl get validatingadmissionpolicybinding \
#        cks-allowed-registries-binding -o yaml
#
#    Vas a ver:
#      spec:
#        validationActions:
#        - Audit
#
#    "Audit" solo deja un registro en el audit log del API server,
#    NO bloquea la request. Por eso los pods con imagenes de
#    registries no autorizados se siguen creando: la politica se
#    evalua, pero su resultado no tiene efecto en la admision.
#
# 3. Corregir el modo de enforcement a "Deny":
#      kubectl patch validatingadmissionpolicybinding \
#        cks-allowed-registries-binding \
#        --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
#
# 4. Verificar que ahora si bloquea:
#      kubectl run test-bad --image=docker.io/library/nginx \
#        -n supplychain-lab --restart=Never
#      # -> Error from server: ... ValidatingAdmissionPolicy
#      #    'cks-allowed-registries' ... denied request:
#      #    Imagen rechazada: solo se permiten imagenes de
#      #    registry.k8s.io/ o registry.internal.lab/
#
# 5. Verificar que las imagenes permitidas siguen funcionando:
#      kubectl run test-good --image=registry.k8s.io/pause:3.9 \
#        -n supplychain-lab --restart=Never
#      # -> pod/test-good created
#      kubectl delete pod test-good -n supplychain-lab
#
# 6. (Extension del tema "sign and validate artifacts")
#    En un cluster real esta misma logica de "solo estos registries"
#    se combina con verificacion de firmas sigstore/cosign (por
#    ejemplo con Kyverno verifyImages o Connaisseur), para asegurar
#    no solo DE DONDE viene la imagen sino que nadie la modifico
#    despues de que el equipo la firmo:
#      cosign verify --key cosign.pub registry.k8s.io/mi-imagen:tag
#
# 7. Terminado el lab, limpiar todo:
#      ./break-fix-4.3-supply-chain.sh clean
# ================================================================