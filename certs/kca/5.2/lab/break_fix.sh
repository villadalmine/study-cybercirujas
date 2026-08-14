#!/usr/bin/env bash
#
# =============================================================================
#  KCA 5.2 — Preconditions  |  Laboratorio break & fix
# =============================================================================
#
#  Certificacion : Kyverno Certified Associate (KCA)
#  Dominio 5.2   : Preconditions            (peso aproximado en el examen: 2.91)
#
#  QUE ENTRENA ESTE LAB
#    Las preconditions son el filtro fino que corre DESPUES de que `match`/`exclude`
#    ya seleccionaron el recurso, y ANTES de que se evalue el cuerpo de la regla
#    (validate / mutate / generate). Se escriben sobre variables JMESPath del
#    AdmissionReview, y ahi viven los tres errores mas caros de produccion:
#      1. una clave inexistente rompe la sustitucion de variables y, con
#         failurePolicy=Fail, bloquea admisiones que nada tenian que ver;
#      2. una comparacion que nunca da true convierte la policy en decorado:
#         READY=true, 0 violaciones, 0 proteccion (falso negativo silencioso);
#      3. variables que solo existen en admission (request.userInfo, request.roles,
#         serviceAccountName) son ilegales con background=true y la policy
#         directamente no se admite en el cluster.
#
#  FUENTES OFICIALES
#    - KCA Curriculum (CNCF):
#        https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#    - Preconditions:
#        https://kyverno.io/docs/writing-policies/preconditions/
#    - Variables y sustitucion (operador `||` como default):
#        https://kyverno.io/docs/writing-policies/variables/
#    - JMESPath en Kyverno:
#        https://kyverno.io/docs/writing-policies/jmespath/
#    - Policy settings (background, failurePolicy, validationFailureAction):
#        https://kyverno.io/docs/writing-policies/policy-settings/
#
#  SEGURIDAD
#    Ejecutar SOLO en una VM / cluster de laboratorio descartable (kind, k3d,
#    minikube, k3s efimero). El script crea dos namespaces propios (kca52-dev,
#    kca52-prod) y limita el `match` de las policies a esos namespaces, de modo
#    que ningun workload existente puede quedar bloqueado. Aun asi instala
#    ClusterPolicies, que son objetos cluster-scoped: no lo corras contra nada
#    que te importe.
#
#  USO
#    ./kca-5.2-preconditions-breakfix.sh break     # rompe (default)
#    ./kca-5.2-preconditions-breakfix.sh verify    # corrige tu trabajo
#    ./kca-5.2-preconditions-breakfix.sh status    # policies, reports, logs
#    ./kca-5.2-preconditions-breakfix.sh hint      # pistas progresivas
#    ./kca-5.2-preconditions-breakfix.sh clean     # borra todo el lab
#
#  La solucion completa, paso a paso, esta comentada al final del archivo.
# =============================================================================

set -euo pipefail

# ------------------------------- parametros ---------------------------------
NS_DEV="kca52-dev"
NS_PROD="kca52-prod"
POLICY_A="kca52-owner-required"
POLICY_B="kca52-no-default-sa"
WORKDIR="${KCA_LAB_DIR:-/tmp/kca-5.2-preconditions}"
SETTLE="${KCA_SETTLE:-6}"          # segundos de espera para que Kyverno reconfigure webhooks
PAUSE_IMAGE="${KCA_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
ERRFILE=""

# --------------------------------- salida -----------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RST=$(tput sgr0); C_R=$(tput setaf 1); C_G=$(tput setaf 2)
  C_Y=$(tput setaf 3); C_B=$(tput setaf 4); C_BOLD=$(tput bold)
else
  C_RST=""; C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""
fi

hr()   { printf '%s\n' "-----------------------------------------------------------------------"; }
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[X]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
title(){ printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RST"; hr; }

cleanup_tmp() { [ -n "$ERRFILE" ] && rm -f "$ERRFILE" 2>/dev/null || true; }
trap cleanup_tmp EXIT
ERRFILE="$(mktemp -t kca52.XXXXXX)"

# ------------------------------ prerrequisitos -------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "falta el binario requerido: $1"; }

preflight() {
  need kubectl
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl no puede hablar con ningun cluster. Revisa tu KUBECONFIG."
}

# Salvaguarda: este lab instala ClusterPolicies en modo Enforce.
safety_gate() {
  local ctx nodes
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  title "Contexto de ejecucion"
  printf '  context : %s\n  nodes   : %s\n  workdir : %s\n' "$ctx" "$nodes" "$WORKDIR"

  case "$ctx" in
    kind-*|k3d-*|minikube*|*lab*|*sandbox*|*dev*|*test*) return 0 ;;
  esac

  if [ "${KCA_LAB_I_UNDERSTAND:-}" = "yes" ]; then
    warn "contexto no reconocido como laboratorio; continuo por KCA_LAB_I_UNDERSTAND=yes"
    return 0
  fi

  warn "El contexto '$ctx' no parece un cluster descartable (kind/k3d/minikube/lab)."
  warn "Este script aplica ClusterPolicies de Kyverno en modo Enforce."
  printf '    Escribi exactamente "romper" para continuar: '
  local answer=""
  read -r answer || true
  [ "$answer" = "romper" ] || die "abortado por el usuario. Nada fue modificado."
}

# ------------------------------ deteccion Kyverno ----------------------------
KYVERNO_NS=""
KYVERNO_VER=""
KYVERNO_MINOR=""

detect_kyverno() {
  kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1 || install_kyverno

  KYVERNO_NS="$(kubectl get deploy -A -l app.kubernetes.io/part-of=kyverno \
                 -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [ -n "$KYVERNO_NS" ] || KYVERNO_NS="kyverno"

  local img
  img="$(kubectl -n "$KYVERNO_NS" get deploy -l app.kubernetes.io/component=admission-controller \
          -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [ -n "$img" ] || img="$(kubectl -n "$KYVERNO_NS" get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"

  KYVERNO_VER="${img##*:}"
  KYVERNO_MINOR="$(printf '%s' "$KYVERNO_VER" | sed -nE 's/^v?[0-9]+\.([0-9]+).*/\1/p')"
  [ -n "$KYVERNO_MINOR" ] || KYVERNO_MINOR="12"

  log "Kyverno detectado: ns=$KYVERNO_NS version=${KYVERNO_VER:-desconocida} (minor=$KYVERNO_MINOR)"

  # Los webhooks deben estar arriba o las admisiones fallan por timeout, no por policy.
  kubectl -n "$KYVERNO_NS" wait --for=condition=Available deploy --all --timeout=300s >/dev/null 2>&1 \
    || warn "algun deployment de Kyverno no reporta Available; el lab puede dar falsos rojos"
}

install_kyverno() {
  warn "Kyverno no esta instalado en este cluster."
  if ! command -v helm >/dev/null 2>&1; then
    die "instala Kyverno primero:
     helm repo add kyverno https://kyverno.github.io/kyverno/
     helm install kyverno kyverno/kyverno -n kyverno --create-namespace"
  fi
  log "Instalando Kyverno con Helm (namespace kyverno)..."
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 10m
  ok "Kyverno instalado."
}

# En Kyverno >= 1.13 la accion de fallo vive en spec.rules[].validate.failureAction;
# en versiones previas en spec.validationFailureAction. Emitimos la correcta.
VFA_SPEC=""
VFA_RULE=""
pick_failure_action_field() {
  if [ "$KYVERNO_MINOR" -ge 13 ] 2>/dev/null; then
    VFA_SPEC=""
    VFA_RULE="        failureAction: Enforce"
  else
    VFA_SPEC="  validationFailureAction: Enforce"
    VFA_RULE=""
  fi
}

# ------------------------------- manifiestos ---------------------------------
write_manifests() {
  mkdir -p "$WORKDIR"

  # ---- Policy A: rota a proposito (BUG 1 y BUG 2) ----
  cat > "$WORKDIR/policy-a.yaml" <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_A}
  annotations:
    policies.kyverno.io/title: Owner label required on prod frontend Pods
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Todo Pod con label tier=frontend que corra en el namespace de produccion
      debe declarar la label owner. Los Pods de desarrollo, y los que no son
      frontend, quedan fuera del alcance de la regla.
spec:
${VFA_SPEC}
  background: false
  rules:
    - name: owner-required-prod-frontend
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS_DEV}
                - ${NS_PROD}
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier }}"
            operator: Equals
            value: frontend
          - key: "{{ request.namespace }}"
            operator: Equals
            value: prod
      validate:
${VFA_RULE}
        message: >-
          Los Pods frontend de produccion deben declarar la label 'owner'
          (ej: owner=sre-platform). Politica: ${POLICY_A}
        pattern:
          metadata:
            labels:
              owner: "?*"
EOF

  # ---- Policy B: rota a proposito (BUG 3) — ni siquiera se admite en el cluster ----
  cat > "$WORKDIR/policy-b.yaml" <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_B}
  annotations:
    policies.kyverno.io/title: Humans must not run Pods with the default ServiceAccount
    policies.kyverno.io/description: >-
      Bloquea Pods creados con la ServiceAccount 'default' en produccion, pero
      solo cuando el creador es un usuario o SA distinto de los controladores
      internos de Kyverno.
spec:
${VFA_SPEC}
  background: true
  rules:
    - name: no-default-sa-for-humans
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - ${NS_PROD}
      preconditions:
        all:
          - key: "{{ request.userInfo.username }}"
            operator: NotEquals
            value: "system:serviceaccount:${KYVERNO_NS}:kyverno-background-controller"
      validate:
${VFA_RULE}
        message: >-
          En produccion no se admite la ServiceAccount 'default'.
          Politica: ${POLICY_B}
        pattern:
          spec:
            serviceAccountName: "!=default"
EOF

  ok "Manifiestos escritos en $WORKDIR (policy-a.yaml, policy-b.yaml)"
}

# ------------------------------ helpers de prueba ----------------------------
pod_manifest() {
  # uso: pod_manifest <ns> <name> [k=v ...]
  local ns="$1" name="$2"; shift 2
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
  if [ "$#" -gt 0 ]; then
    printf '  labels:\n'
    local kv
    for kv in "$@"; do printf '    %s: "%s"\n' "${kv%%=*}" "${kv#*=}"; done
  fi
  printf 'spec:\n  restartPolicy: Never\n  containers:\n    - name: app\n      image: %s\n' "$PAUSE_IMAGE"
}

# Admision real contra los webhooks, sin persistir nada: --dry-run=server.
# Kyverno declara sideEffects=NoneOnDryRun, por lo que el webhook si es invocado.
admits() {
  pod_manifest "$@" | kubectl apply --dry-run=server -f - >/dev/null 2>"$ERRFILE"
}

last_error() { tr '\n' ' ' < "$ERRFILE" | cut -c1-320; }

PASS=0; FAIL=0
check() {
  # uso: check "<descripcion>" <admit|reject> <ns> <name> [labels...]
  local desc="$1" expect="$2"; shift 2
  if admits "$@"; then
    if [ "$expect" = "admit" ]; then
      PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$desc"
    else
      FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$desc"
      printf '         esperaba RECHAZO y el Pod fue admitido (la policy no esta protegiendo nada)\n'
    fi
  else
    if [ "$expect" = "reject" ]; then
      PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$desc"
    else
      FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$desc"
      printf '         esperaba ADMISION y fue rechazado: %s\n' "$(last_error)"
    fi
  fi
}

check_cmd() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$desc"
  fi
}

# --------------------------------- BREAK -------------------------------------
do_break() {
  preflight
  safety_gate
  detect_kyverno
  pick_failure_action_field

  title "Preparando el escenario"
  for ns in "$NS_DEV" "$NS_PROD"; do
    kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
  done
  kubectl label ns "$NS_DEV"  env=dev  --overwrite >/dev/null
  kubectl label ns "$NS_PROD" env=prod --overwrite >/dev/null
  ok "namespaces listos: $NS_DEV (env=dev), $NS_PROD (env=prod)"

  # idempotencia: partimos siempre del mismo estado roto
  kubectl delete cpol "$POLICY_A" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete cpol "$POLICY_B" --ignore-not-found >/dev/null 2>&1 || true

  write_manifests

  title "Rompiendo (aplicando las policies defectuosas)"
  kubectl apply -f "$WORKDIR/policy-a.yaml" >/dev/null
  ok "ClusterPolicy $POLICY_A aplicada (con dos defectos en sus preconditions)"

  if kubectl apply -f "$WORKDIR/policy-b.yaml" >"$ERRFILE" 2>&1; then
    warn "ClusterPolicy $POLICY_B se aplico; tu version de Kyverno es mas permisiva de lo esperado"
  else
    ok "ClusterPolicy $POLICY_B RECHAZADA por el API server, tal como esperabamos"
    printf '     %s\n' "$(last_error)"
  fi

  log "esperando ${SETTLE}s a que Kyverno reconfigure sus webhooks..."
  sleep "$SETTLE"

  title "Reproduccion del sintoma (esto es lo que rompimos)"
  printf '%s$ kubectl -n %s run demo --image=%s --dry-run=server%s\n' "$C_BOLD" "$NS_DEV" "$PAUSE_IMAGE" "$C_RST"
  if kubectl -n "$NS_DEV" run demo --image="$PAUSE_IMAGE" --dry-run=server >"$ERRFILE" 2>&1; then
    printf '  (admitido)\n'
  else
    printf '  %s\n' "$(last_error)"
  fi

  cat <<TXT

$C_BOLD== SINTOMA ==$C_RST

  1) Un Pod trivial, SIN labels, en el namespace de DESARROLLO ($NS_DEV) es
     rechazado en admision. El mensaje no habla de la label 'owner' sino de una
     falla de sustitucion de variables / JMESPath, algo parecido a:

        Error from server: admission webhook "validate.kyverno.svc-fail" denied
        the request: policy Pod/$NS_DEV/demo for resource violation:
        $POLICY_A: owner-required-prod-frontend:
          failed to substitute variables in preconditions:
          JMESPath query failed: Unknown key "tier" in path

     Es decir: la regla rompe recursos que ni siquiera deberia estar mirando.
     Con failurePolicy=Fail (el default), un error de evaluacion NO es un
     "skip": es un DENY. Este es el modo de falla que saca aplicaciones de
     produccion cuando alguien publica una policy mal probada.

  2) Al mismo tiempo, y en sentido contrario, la policy no protege nada:
     un Pod frontend SIN 'owner' en PRODUCCION ($NS_PROD) pasa sin problemas.
     'kubectl get cpol' muestra READY=true, el PolicyReport muestra 0 fallas,
     y la conclusion equivocada es "la policy funciona".

  3) La segunda policy ($POLICY_B) directamente NO se pudo crear: el API server
     la rechazo antes de existir, por un conflicto entre su precondition y el
     modo de operacion declarado en la policy.

$C_BOLD== TU OBJETIVO ==$C_RST

  Dejar $POLICY_A con este comportamiento exacto, en modo Enforce:

     Pod sin labels           en $NS_DEV   -> ADMITIDO
     Pod tier=frontend        en $NS_DEV   -> ADMITIDO   (dev fuera de alcance)
     Pod sin labels           en $NS_PROD  -> ADMITIDO
     Pod tier=batch           en $NS_PROD  -> ADMITIDO   (no es frontend)
     Pod tier=frontend s/owner en $NS_PROD -> RECHAZADO
     Pod tier=frontend c/owner en $NS_PROD -> ADMITIDO

  Y ademas: lograr que $POLICY_B se cree en el cluster SIN eliminar su
  precondition sobre {{ request.userInfo.username }}.

$C_BOLD== REGLAS DE JUEGO ==$C_RST

  - No vale borrar la policy, ni pasarla a Audit, ni vaciar el 'validate'.
    El fix va en las PRECONDITIONS y en los policy settings.
  - Los manifiestos editables estan en:
        $WORKDIR/policy-a.yaml
        $WORKDIR/policy-b.yaml
  - Herramientas de diagnostico sugeridas:
        kubectl describe cpol $POLICY_A
        kubectl -n $KYVERNO_NS logs deploy/kyverno-admission-controller --tail=80 | grep -iE 'precondition|variable|jmespath'
        kubectl get policyreport -A
        kyverno apply $WORKDIR/policy-a.yaml --resource <pod.yaml>   # test offline, sin cluster
  - Tras cada 'kubectl apply' de una policy, esperá unos segundos: Kyverno
    reconfigura sus webhooks de forma asincronica.

  Cuando creas que esta, corré:

        $0 verify

TXT
}

# --------------------------------- VERIFY ------------------------------------
do_verify() {
  preflight
  detect_kyverno

  title "Verificando (esperando ${SETTLE}s a los webhooks)"
  sleep "$SETTLE"

  PASS=0; FAIL=0

  printf '\n%sComportamiento de admision%s\n' "$C_BOLD" "$C_RST"
  check "Pod sin labels en $NS_DEV es admitido"                 admit  "$NS_DEV"  p1
  check "Pod tier=frontend sin owner en $NS_DEV es admitido"    admit  "$NS_DEV"  p2 tier=frontend
  check "Pod sin labels en $NS_PROD es admitido"                admit  "$NS_PROD" p3
  check "Pod tier=batch sin owner en $NS_PROD es admitido"      admit  "$NS_PROD" p4 tier=batch
  check "Pod tier=frontend SIN owner en $NS_PROD es RECHAZADO"  reject "$NS_PROD" p5 tier=frontend
  check "Pod tier=frontend CON owner en $NS_PROD es admitido"   admit  "$NS_PROD" p6 tier=frontend owner=sre-platform

  printf '\n%sIntegridad de las policies (no vale desactivarlas)%s\n' "$C_BOLD" "$C_RST"
  check_cmd "$POLICY_A sigue existiendo" kubectl get cpol "$POLICY_A"
  if kubectl get cpol "$POLICY_A" -o yaml 2>/dev/null | grep -qE '^[[:space:]]*(validationFailureAction|failureAction):[[:space:]]*Enforce'; then
    PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$POLICY_A sigue en modo Enforce"
  else
    FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$POLICY_A no esta en Enforce (Audit no cuenta como fix)"
  fi
  if kubectl get cpol "$POLICY_A" -o yaml 2>/dev/null | grep -q 'pattern'; then
    PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$POLICY_A conserva su bloque validate"
  else
    FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$POLICY_A perdio su bloque validate"
  fi

  check_cmd "$POLICY_B fue creada en el cluster" kubectl get cpol "$POLICY_B"
  if kubectl get cpol "$POLICY_B" -o yaml 2>/dev/null | grep -q 'request.userInfo.username'; then
    PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$POLICY_B conserva su precondition sobre request.userInfo"
  else
    FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$POLICY_B ya no usa request.userInfo (borrarla no es el fix)"
  fi

  hr
  if [ "$FAIL" -eq 0 ]; then
    printf '%sRESULTADO: %d/%d — laboratorio superado.%s\n' "$C_G" "$PASS" "$((PASS+FAIL))" "$C_RST"
    printf 'Corré "%s clean" para dejar el cluster como estaba.\n' "$0"
  else
    printf '%sRESULTADO: %d/%d checks OK, %d pendientes.%s\n' "$C_Y" "$PASS" "$((PASS+FAIL))" "$FAIL" "$C_RST"
    printf 'Pistas: %s hint\n' "$0"
    exit 1
  fi
}

# ---------------------------------- STATUS -----------------------------------
do_status() {
  preflight
  detect_kyverno

  title "ClusterPolicies del lab"
  kubectl get cpol "$POLICY_A" "$POLICY_B" 2>&1 || true

  title "PolicyReports en los namespaces del lab"
  kubectl get policyreport -n "$NS_DEV" -n "$NS_PROD" 2>/dev/null \
    || kubectl get policyreport -A 2>&1 | grep -E "NAMESPACE|kca52" || true

  title "Ultimos errores del admission controller"
  kubectl -n "$KYVERNO_NS" logs deploy/kyverno-admission-controller --tail=200 2>/dev/null \
    | grep -iE 'precondition|variable|jmespath|failed' | tail -n 20 || warn "sin logs relevantes"

  title "Manifiestos editables"
  ls -l "$WORKDIR" 2>/dev/null || warn "no existe $WORKDIR; corré '$0 break' primero"
}

# ---------------------------------- HINT -------------------------------------
do_hint() {
  cat <<'TXT'

PISTA 1 — leé el mensaje de error, no la intencion de la policy
  El rechazo en kca52-dev no menciona la label 'owner'. Menciona una variable.
  Si la precondition ni siquiera se pudo EVALUAR, Kyverno no puede decidir
  "no aplica"; con failurePolicy=Fail el default seguro es denegar.
  Pregunta guia: que devuelve la expresion JMESPath
  request.object.metadata.labels.tier cuando el Pod no tiene labels?

PISTA 2 — una precondition que nunca es true es peor que no tener policy
  Compará, literal y caracter por caracter, el valor que produce
  {{ request.namespace }} contra el valor esperado en la condicion.
  Probalo sin adivinar:
      kubectl -n kca52-prod run x --image=registry.k8s.io/pause:3.9 --dry-run=server -v=8 2>&1 | grep -i namespace
  o directamente con la CLI de Kyverno, que imprime las variables resueltas:
      kyverno apply /tmp/kca-5.2-preconditions/policy-a.yaml --resource pod.yaml -v 3

PISTA 3 — hay variables que solo existen en tiempo de admision
  El background scan reevalua policies contra recursos YA existentes: ahi no
  hay AdmissionReview, y por lo tanto no hay usuario que hizo el request.
  Kyverno lo valida al crear la policy y por eso policy-b.yaml ni entra.
  Buscá en spec cual es el flag que declara ese modo de operacion.
  Referencia: https://kyverno.io/docs/writing-policies/policy-settings/

TXT
}

# ---------------------------------- CLEAN ------------------------------------
do_clean() {
  preflight
  log "eliminando policies del lab..."
  kubectl delete cpol "$POLICY_A" "$POLICY_B" --ignore-not-found >/dev/null 2>&1 || true
  log "eliminando namespaces del lab..."
  kubectl delete ns "$NS_DEV" "$NS_PROD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  ok "lab limpio."
}

# --------------------------------- dispatch ----------------------------------
case "${1:-break}" in
  break)  do_break  ;;
  verify) do_verify ;;
  status) do_status ;;
  hint)   do_hint   ;;
  clean)  do_clean  ;;
  *) die "uso: $0 [break|verify|status|hint|clean]" ;;
esac

# =============================================================================
#  SOLUCION PASO A PASO  (no leer hasta haber intentado el fix)
# =============================================================================
#
#  ---------------------------------------------------------------------------
#  PASO 0 — Reproducir y capturar la evidencia, antes de tocar nada
#  ---------------------------------------------------------------------------
#
#    $ kubectl -n kca52-dev run demo --image=registry.k8s.io/pause:3.9 --dry-run=server
#    Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#
#    resource Pod/kca52-dev/demo was blocked due to the following policies
#
#    kca52-owner-required:
#      owner-required-prod-frontend: 'failed to substitute variables in preconditions:
#        failed to resolve request.object.metadata.labels.tier: JMESPath query failed:
#        Unknown key "tier" in path'
#
#    Y en los logs del controlador:
#
#    $ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
#        | grep -iE 'precondition|variable'
#    ... "failed to evaluate preconditions" policy=kca52-owner-required
#        rule=owner-required-prod-frontend error="Unknown key \"tier\" in path"
#
#    Lectura correcta del sintoma: el nombre del webhook termina en "-fail".
#    Eso es failurePolicy=Fail. Un error de evaluacion en una precondition NO
#    se degrada a "la regla no aplica": se degrada a DENY. La policy quedo
#    acoplada a la disponibilidad de una label que la mayoria de los Pods
#    no tiene.
#
#  ---------------------------------------------------------------------------
#  PASO 1 — BUG 1: clave inexistente en la precondition
#  ---------------------------------------------------------------------------
#
#    Roto:
#      - key: "{{ request.object.metadata.labels.tier }}"
#        operator: Equals
#        value: frontend
#
#    JMESPath sobre un objeto sin la clave 'labels' (o sin 'tier' dentro de
#    ella) no devuelve "vacio": la sustitucion falla. La forma canonica de
#    darle un valor por defecto es el operador `||` de JMESPath dentro de la
#    propia variable:
#
#    Corregido:
#      - key: "{{ request.object.metadata.labels.tier || '' }}"
#        operator: Equals
#        value: frontend
#
#    Notas de produccion:
#      * Si la label tuviera puntos o barras hay que citarla:
#          {{ request.object.metadata.labels."app.kubernetes.io/name" || '' }}
#      * Alternativa declarativa equivalente, y a menudo mejor, es no usar
#        precondition y filtrar en el match con un selector, porque el
#        API server ya lo resuelve sin evaluar variables:
#          match:
#            any:
#              - resources:
#                  kinds: [Pod]
#                  selector:
#                    matchLabels:
#                      tier: frontend
#        Regla practica: lo que `match`/`exclude` pueden expresar, expresalo
#        ahi; las preconditions son para lo que match no alcanza (operacion,
#        usuario, comparaciones numericas, JMESPath sobre el spec).
#      * Kyverno documenta el patron en:
#          https://kyverno.io/docs/writing-policies/preconditions/
#          https://kyverno.io/docs/writing-policies/variables/
#
#  ---------------------------------------------------------------------------
#  PASO 2 — BUG 2: la comparacion que nunca es verdadera
#  ---------------------------------------------------------------------------
#
#    Roto:
#      - key: "{{ request.namespace }}"
#        operator: Equals
#        value: prod            # el namespace real es "kca52-prod"
#
#    Este es el falso negativo silencioso: `kubectl get cpol` reporta
#    READY=true, no hay errores en los logs y el PolicyReport queda en cero.
#    La policy existe, se evalua, y siempre se salta.
#
#    Corregido (uso AnyIn, que escala a varios namespaces sin duplicar reglas):
#      - key: "{{ request.namespace }}"
#        operator: AnyIn
#        value:
#          - kca52-prod
#
#    Verificacion honesta de que una policy protege algo: probar el caso que
#    DEBE fallar, no solo el que debe pasar.
#
#      $ kubectl -n kca52-prod run bad --image=registry.k8s.io/pause:3.9 \
#          --labels tier=frontend --dry-run=server
#      Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
#
#      resource Pod/kca52-prod/bad was blocked due to the following policies
#
#      kca52-owner-required:
#        owner-required-prod-frontend: 'validation error: Los Pods frontend de
#          produccion deben declarar la label ''owner'' ...'
#
#      $ kubectl -n kca52-prod run good --image=registry.k8s.io/pause:3.9 \
#          --labels tier=frontend,owner=sre-platform --dry-run=server
#      pod/good created (server dry run)
#
#  ---------------------------------------------------------------------------
#  PASO 3 — policy-a.yaml corregida, completa
#  ---------------------------------------------------------------------------
#
#    apiVersion: kyverno.io/v1
#    kind: ClusterPolicy
#    metadata:
#      name: kca52-owner-required
#    spec:
#      validationFailureAction: Enforce     # Kyverno < 1.13
#      background: false                    # la regla solo tiene sentido en admision
#      rules:
#        - name: owner-required-prod-frontend
#          match:
#            any:
#              - resources:
#                  kinds:
#                    - Pod
#                  namespaces:
#                    - kca52-dev
#                    - kca52-prod
#          preconditions:
#            all:
#              - key: "{{ request.object.metadata.labels.tier || '' }}"
#                operator: Equals
#                value: frontend
#              - key: "{{ request.namespace }}"
#                operator: AnyIn
#                value:
#                  - kca52-prod
#          validate:
#            # failureAction: Enforce       # Kyverno >= 1.13 (reemplaza al de spec)
#            message: >-
#              Los Pods frontend de produccion deben declarar la label 'owner'.
#            pattern:
#              metadata:
#                labels:
#                  owner: "?*"
#
#    Aplicar y esperar la reconfiguracion de webhooks:
#
#      $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-a.yaml
#      clusterpolicy.kyverno.io/kca52-owner-required configured
#      $ sleep 6
#      $ kubectl get cpol kca52-owner-required
#      NAME                    ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
#      kca52-owner-required    true        false        Enforce           True    3m
#
#  ---------------------------------------------------------------------------
#  PASO 4 — BUG 3: variables de admision con background=true
#  ---------------------------------------------------------------------------
#
#    Sintoma al aplicar policy-b.yaml:
#
#      $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-b.yaml
#      Error from server: error when creating "policy-b.yaml": admission webhook
#      "validate-policy.kyverno.svc" denied the request: spec.rules[0]:
#      "kca52-no-default-sa" - variable "request.userInfo.username" is not allowed
#      in background mode. Set spec.background=false
#
#    Causa: el background controller reevalua policies contra recursos que ya
#    existen en etcd. En ese contexto no hay AdmissionReview, por lo tanto no
#    existen request.userInfo, request.roles, request.clusterRoles,
#    serviceAccountName ni serviceAccountNamespace, y request.operation vale
#    BACKGROUND. Kyverno lo valida en tiempo de creacion de la policy en lugar
#    de fallar en silencio durante cada scan.
#
#    Fix: declarar que la policy es solo de admision.
#
#      spec:
#        background: false
#        rules:
#          - name: no-default-sa-for-humans
#            preconditions:
#              all:
#                - key: "{{ request.userInfo.username }}"
#                  operator: NotEquals
#                  value: "system:serviceaccount:kyverno:kyverno-background-controller"
#
#    Aplicar:
#      $ sed -i 's/^  background: true$/  background: false/' \
#            /tmp/kca-5.2-preconditions/policy-b.yaml
#      $ kubectl apply -f /tmp/kca-5.2-preconditions/policy-b.yaml
#      clusterpolicy.kyverno.io/kca52-no-default-sa created
#
#    Consecuencia consciente del trade-off: con background=false esta policy no
#    genera PolicyReports para los Pods preexistentes. Si tambien necesitas
#    visibilidad historica, el patron correcto son DOS policies: una de
#    admision (background=false, con las variables de request) y otra de
#    auditoria (background=true, Audit, escrita solo sobre el objeto).
#
#  ---------------------------------------------------------------------------
#  PASO 5 — Cierre
#  ---------------------------------------------------------------------------
#
#      $ ./kca-5.2-preconditions-breakfix.sh verify
#      [PASS] Pod sin labels en kca52-dev es admitido
#      [PASS] Pod tier=frontend sin owner en kca52-dev es admitido
#      [PASS] Pod sin labels en kca52-prod es admitido
#      [PASS] Pod tier=batch sin owner en kca52-prod es admitido
#      [PASS] Pod tier=frontend SIN owner en kca52-prod es RECHAZADO
#      [PASS] Pod tier=frontend CON owner en kca52-prod es admitido
#      ...
#      RESULTADO: 11/11 — laboratorio superado.
#
#      $ ./kca-5.2-preconditions-breakfix.sh clean
#
#  ---------------------------------------------------------------------------
#  LO QUE HAY QUE LLEVARSE AL EXAMEN Y A PRODUCCION
#  ---------------------------------------------------------------------------
#   1. Las preconditions se evaluan DESPUES de match/exclude y ANTES del cuerpo
#      de la regla. `all` exige que todas las condiciones sean true; `any`, al
#      menos una; pueden anidarse.
#   2. Una variable que no resuelve NO equivale a "false": rompe la evaluacion,
#      y con failurePolicy=Fail eso es un DENY. Defendete siempre con
#      `|| ''`, `|| 'default'` o `|| []`.
#   3. Los operadores comparan tipos: Equals / NotEquals / AnyIn / AllIn /
#      AnyNotIn / AllNotIn / GreaterThan(OrEquals) / LessThan(OrEquals) /
#      DurationGreaterThan / DurationLessThan. Comparar un numero con "3"
#      entre comillas es un error de evaluacion, no una comparacion falsa.
#   4. Lo que se puede filtrar en `match` (kinds, namespaces, selectors,
#      subjects) no deberia filtrarse en preconditions.
#   5. request.userInfo / request.roles / request.clusterRoles /
#      serviceAccountName / serviceAccountNamespace son exclusivas de admision:
#      exigen background=false.
#   6. Toda policy nueva se prueba con el caso que DEBE fallar. "READY=true y
#      cero violaciones" tambien es el aspecto de una policy que no evalua nada.
#      La CLI `kyverno apply <policy> --resource <recurso>` permite hacerlo en
#      CI, sin cluster: https://kyverno.io/docs/kyverno-cli/
# =============================================================================