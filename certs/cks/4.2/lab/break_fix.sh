#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CKS v1.34 - Dominio 4.2: Understand your supply chain (SBOM, CI/CD,
# artifact repositories) - peso en el examen: 5%
#
# Ejercicio: "whitelist de registries confiables" con OPA Gatekeeper como
# admission controller. Simula el último control dentro del cluster que
# debería detener un artifact que se coló sin pasar por tu pipeline de CI/CD
# (scan de vulnerabilidades, generación de SBOM, firma de imagen, push a un
# artifact repository interno confiable).
#
# Fuentes:
#   - CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - OPA Gatekeeper (admission controller usado en este lab): https://open-policy-agent.github.io/gatekeeper/website/docs/
#
# USAR SOLO EN UNA VM/CLUSTER DE LABORATORIO DESCARTABLE. Este script instala
# Gatekeeper a nivel cluster (namespace gatekeeper-system) y crea/rompe un
# Constraint. Todo es reversible con el subcomando "cleanup".
# ==============================================================================

SCRIPT_NAME="$(basename "$0")"
NS="cks-supply-chain"
CT_NAME="k8sallowedrepos"
CONSTRAINT_NAME="trusted-registries-only"
CRD_NAME="${CT_NAME}.constraints.gatekeeper.sh"

log()  { printf '[INFO]  %s\n' "$*"; }
ok()   { printf '[OK]    %s\n' "$*"; }
fail() { printf '[FALLA] %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [setup|check|cleanup]

  setup    (default) instala el entorno, aplica el guardrail de supply
           chain y lo rompe. Deja planteado el objetivo para el estudiante.
  check    verifica si el estudiante ya arregló el guardrail.
  cleanup  borra los recursos creados por este ejercicio (namespace,
           ConstraintTemplate y Constraint). No desinstala Gatekeeper.
EOF
}

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl no está disponible en esta VM"
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    fail "No hay un cluster de Kubernetes accesible con el kubeconfig actual"
    exit 1
  fi
}

install_gatekeeper() {
  if kubectl get ns gatekeeper-system >/dev/null 2>&1 \
     && kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=5s >/dev/null 2>&1; then
    log "Gatekeeper ya está instalado, se reutiliza"
    return
  fi

  log "Instalando OPA Gatekeeper (admission controller)..."
  local ver
  ver=$(curl -fsSL https://api.github.com/repos/open-policy-agent/gatekeeper/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d '"' -f4 || true)
  ver=${ver:-v3.17.1}
  kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${ver}/deploy/gatekeeper.yaml"
  kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=180s
  sleep 10  # dar tiempo a que el webhook quede completamente disponible
}

setup_namespace() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
}

apply_good_policy() {
  log "Aplicando el guardrail de supply chain: sólo imágenes de registries confiables..."

  cat <<EOF | kubectl apply -f -
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: ${CT_NAME}
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.repos[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("la imagen '%v' no proviene de un registry autorizado (%v)", [container.image, input.parameters.repos])
        }
EOF

  log "Esperando a que Gatekeeper registre el CRD del constraint..."
  for _ in $(seq 1 30); do
    kubectl get crd "$CRD_NAME" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl wait --for=condition=Established "crd/${CRD_NAME}" --timeout=60s

  cat <<EOF | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: ${CONSTRAINT_NAME}
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - ${NS}
  parameters:
    repos:
      - "registry.k8s.io/"
      - "docker.io/library/nginx"
EOF

  sleep 15  # dar tiempo a que OPA sincronice el constraint antes de usarlo
}

verify_baseline() {
  log "Verificando el guardrail ANTES de romper nada (baseline)..."

  if kubectl -n "$NS" run baseline-trusted --image=registry.k8s.io/pause:3.9 --dry-run=server >/tmp/cks-baseline-trusted.out 2>&1; then
    ok "Imagen confiable (registry.k8s.io) aceptada, como se espera"
  else
    fail "El caso confiable falló; revisá la instalación de Gatekeeper:"
    cat /tmp/cks-baseline-trusted.out
    exit 1
  fi

  if kubectl -n "$NS" run baseline-untrusted --image=docker.io/library/busybox --dry-run=server >/tmp/cks-baseline-untrusted.out 2>&1; then
    fail "Se aceptó una imagen no confiable (busybox) antes de romper nada; algo no está bien instalado:"
    cat /tmp/cks-baseline-untrusted.out
    exit 1
  else
    ok "Imagen no confiable (busybox) rechazada, como se espera"
  fi
}

break_it() {
  log "Rompiendo el guardrail de supply chain..."
  kubectl patch k8sallowedrepos "${CONSTRAINT_NAME}" --type merge -p '{"spec":{"enforcementAction":"dryrun"}}'
  sleep 10

  cat <<EOF

================================================================================
SÍNTOMA
================================================================================
La política "sólo imágenes de registries confiables" sigue instalada y
"parece" activa: el Constraint existe (kubectl get k8sallowedrepos), los
pods de Gatekeeper están Running, no hay errores visibles. Sin embargo, un
pod con una imagen que NO está en la lista de registries permitidos (por
ejemplo docker.io/library/busybox) se puede crear sin ningún rechazo:

  kubectl -n ${NS} run test --image=docker.io/library/busybox --dry-run=server

Esto NO debería pasar: cualquier imagen que no venga de registry.k8s.io/ ni
de docker.io/library/nginx tiene que ser rechazada por el admission
controller. Es el tipo de falla silenciosa que en un pipeline de CI/CD
dejaría pasar al cluster un artifact no escaneado y sin SBOM, saltándose el
control de supply chain.

================================================================================
OBJETIVO
================================================================================
Encontrá por qué el guardrail dejó de bloquear imágenes no confiables y
arreglalo, SIN borrar ni recrear el ConstraintTemplate ni el Constraint.
Vas a saber que lo lograste cuando:

  1. Un pod con imagen docker.io/library/busybox sea RECHAZADO por el
     admission webhook de Gatekeeper.
  2. Un pod con imagen registry.k8s.io/pause:3.9 (o docker.io/library/nginx)
     siga siendo ACEPTADO sin problema.

Pistas de comandos para investigar (no son la solución):
  kubectl get constrainttemplates
  kubectl get k8sallowedrepos -o yaml
  kubectl -n gatekeeper-system logs deploy/gatekeeper-controller-manager

Cuando creas que lo arreglaste, corré:
  ./$SCRIPT_NAME check
================================================================================
EOF
}

check() {
  log "Verificando si el guardrail está arreglado..."
  local untrusted_accepted=1
  local trusted_accepted=1

  kubectl -n "$NS" run check-untrusted --image=docker.io/library/busybox --dry-run=server >/tmp/cks-check-untrusted.out 2>&1 \
    && untrusted_accepted=0 || untrusted_accepted=1

  kubectl -n "$NS" run check-trusted --image=registry.k8s.io/pause:3.9 --dry-run=server >/tmp/cks-check-trusted.out 2>&1 \
    && trusted_accepted=0 || trusted_accepted=1

  if [[ $untrusted_accepted -eq 0 ]]; then
    fail "Todavía roto: busybox (no confiable) fue ACEPTADO."
    return 1
  fi
  if [[ $trusted_accepted -ne 0 ]]; then
    fail "El guardrail quedó demasiado estricto: incluso pause (confiable) fue rechazado."
    cat /tmp/cks-check-trusted.out
    return 1
  fi

  ok "¡Arreglado! busybox fue rechazado y las imágenes confiables se siguen aceptando."
}

cleanup() {
  log "Limpiando recursos del ejercicio..."
  kubectl delete k8sallowedrepos "${CONSTRAINT_NAME}" --ignore-not-found
  kubectl delete constrainttemplate "${CT_NAME}" --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found
  echo "Nota: Gatekeeper (namespace gatekeeper-system) queda instalado; en una VM descartable no hace falta desinstalarlo."
}

main() {
  case "${1:-setup}" in
    setup)
      cat <<EOF
================================================================================
 CKS v1.34 - Dominio 4.2: Understand your supply chain (peso: 5%)
 Este script instala OPA Gatekeeper y aplica/rompe un Constraint.
 Usalo SOLO en una VM/cluster de laboratorio descartable.
================================================================================
EOF
      require_kubectl
      install_gatekeeper
      setup_namespace
      apply_good_policy
      verify_baseline
      break_it
      ;;
    check)
      require_kubectl
      check
      ;;
    cleanup)
      require_kubectl
      cleanup
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

# ==============================================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# ==============================================================================
#
# 1. Inspeccionar el Constraint:
#      kubectl get k8sallowedrepos trusted-registries-only -o yaml
#    En spec.enforcementAction vas a ver "dryrun" en vez de "deny". Con
#    enforcementAction=dryrun, Gatekeeper evalúa la política y registra las
#    violaciones (en status.violations y en los logs del controller), pero
#    NO bloquea el request. Por eso el Constraint "parece" activo pero no
#    hace nada.
#
# 2. Corregir el enforcementAction:
#      kubectl patch k8sallowedrepos trusted-registries-only \
#        --type merge -p '{"spec":{"enforcementAction":"deny"}}'
#
# 3. Esperar unos segundos (5-15s) a que el cache de OPA dentro de
#    Gatekeeper resincronice el constraint.
#
# 4. Confirmar el fix manualmente:
#      kubectl -n cks-supply-chain run t1 --image=docker.io/library/busybox --dry-run=server
#      # -> Error from server (Forbidden): admission webhook
#      #    "validation.gatekeeper.sh" denied the request: ...
#
#      kubectl -n cks-supply-chain run t2 --image=registry.k8s.io/pause:3.9 --dry-run=server
#      # -> pod/t2 created (server dry run)
#
# 5. O directamente:
#      ./break-fix-4.2.sh check
#
# Por qué esto importa para supply chain security:
#   - "docker.io/library/nginx" y "registry.k8s.io/" simulan tu artifact
#     repository confiable (podría ser Harbor, ECR o GCR, con imágenes
#     escaneadas, firmadas y con SBOM generado en el pipeline de CI/CD, p.ej.
#     con syft para el SBOM y cosign para la firma).
#   - El Constraint es la última barrera dentro del cluster: aunque el
#     pipeline de CI/CD falle o alguien haga kubectl apply a mano, ninguna
#     imagen fuera de la lista permitida debería poder correr.
#   - enforcementAction=dryrun es útil para probar políticas nuevas sin
#     bloquear tráfico real, pero si queda así en producción por error, es
#     una falla de supply chain silenciosa: todo parece controlado pero en
#     realidad no se está bloqueando nada.
# ==============================================================================