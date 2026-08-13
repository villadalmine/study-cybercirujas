#!/usr/bin/env bash
#
# =====================================================================
#  CAPA · Tema 4.1 — Argo Rollouts  ·  Laboratorio BREAK & FIX
# =====================================================================
#  Peso en el examen: 20%
#
#  Qué hace este script:
#    1. Verifica prerequisitos y que estés en un cluster DESCARTABLE.
#    2. Instala el controller de Argo Rollouts si no está.
#    3. Despliega un Rollout canary SANO (nginx:1.25.3) y espera Healthy.
#    4. ROMPE de forma controlada y reversible: dispara una nueva
#       revision canary apuntando a un tag de imagen que NO existe.
#    5. Te explica el sintoma y el objetivo.
#
#  Todo ocurre dentro del namespace 'capa-lab-41'. No toca nada mas.
#  La averia es 100% reversible (no se borran datos, solo se cambia un tag).
#
#  Fuentes oficiales:
#    - Curriculum CNCF CAPA:
#        https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
#    - Argo Rollouts (canary):
#        https://argo-rollouts.readthedocs.io/en/stable/features/canary/
#    - kubectl-argo-rollouts plugin:
#        https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation
# =====================================================================

set -euo pipefail

NS="capa-lab-41"
ROLLOUT="rollouts-demo"
CONTAINER="rollouts-demo"
IMG_GOOD="nginx:1.25.3"
IMG_BROKEN="nginx:1.25.4-esta-imagen-no-existe"
ARGO_NS="argo-rollouts"
ARGO_MANIFEST="https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml"

# ---------- helpers ---------------------------------------------------
c_reset=$'\e[0m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'
info() { printf '%s[INFO]%s %s\n'  "$c_cyn" "$c_reset" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$c_ylw" "$c_reset" "$*"; }
die()  { printf '%s[FAIL]%s %s\n'  "$c_red" "$c_reset" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Falta el binario '$1' en el PATH."; }

# ---------- 0. guardas de seguridad ----------------------------------
need kubectl
kubectl cluster-info >/dev/null 2>&1 || die "kubectl no alcanza ningun cluster. Levanta un kind/k3s/minikube descartable."

CTX="$(kubectl config current-context 2>/dev/null || echo desconocido)"
info "Contexto activo: ${CTX}"
case "$CTX" in
  *prod*|*production*|*prd*)
    die "El contexto parece PRODUCCION. Abortando: este lab SOLO corre en una VM/cluster descartable." ;;
esac

cat <<BANNER

  ${c_ylw}================  LAB DESCARTABLE  ================${c_reset}
  Este script instala Argo Rollouts y crea el namespace '${NS}'.
  Ejecutalo unicamente en una VM de laboratorio que puedas destruir.
  Limpieza total al terminar:  kubectl delete ns ${NS}

BANNER
read -r -p "  Escribi 'rompelo' para continuar: " ANSWER
[ "$ANSWER" = "rompelo" ] || die "Cancelado por el usuario."

# ---------- 1. controller de Argo Rollouts ---------------------------
if ! kubectl get ns "$ARGO_NS" >/dev/null 2>&1; then
  info "Instalando el controller de Argo Rollouts en '${ARGO_NS}'..."
  kubectl create namespace "$ARGO_NS"
  kubectl apply -n "$ARGO_NS" -f "$ARGO_MANIFEST"
else
  ok "El namespace '${ARGO_NS}' ya existe; asumo controller instalado."
fi

info "Esperando a que el controller este disponible (hasta 180s)..."
kubectl -n "$ARGO_NS" rollout status deploy/argo-rollouts --timeout=180s \
  || warn "El deployment del controller tardo; sigo igual, revisa luego 'kubectl -n ${ARGO_NS} get pods'."

# plugin opcional pero MUY recomendado para la parte de diagnostico
if kubectl argo rollouts version >/dev/null 2>&1; then
  HAVE_PLUGIN=1; ok "Plugin 'kubectl argo rollouts' detectado."
else
  HAVE_PLUGIN=0
  warn "No tenes el plugin 'kubectl-argo-rollouts'. Podras diagnosticar con kubectl puro,"
  warn "pero instalalo para la experiencia real del examen:"
  warn "  https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation"
fi

# ---------- 2. estado SANO de partida --------------------------------
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

info "Desplegando el Rollout canary SANO (${IMG_GOOD})..."
cat <<EOF | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Service
metadata:
  name: ${ROLLOUT}-stable
spec:
  selector:
    app: ${ROLLOUT}
  ports:
  - port: 80
    targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: ${ROLLOUT}-canary
spec:
  selector:
    app: ${ROLLOUT}
  ports:
  - port: 80
    targetPort: http
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: ${ROLLOUT}
spec:
  replicas: 5
  revisionHistoryLimit: 3
  # progressDeadlineSeconds bajo para que el sintoma "Degraded" aparezca rapido en el lab.
  progressDeadlineSeconds: 120
  selector:
    matchLabels:
      app: ${ROLLOUT}
  template:
    metadata:
      labels:
        app: ${ROLLOUT}
    spec:
      containers:
      - name: ${CONTAINER}
        image: ${IMG_GOOD}
        ports:
        - name: http
          containerPort: 80
        readinessProbe:
          httpGet: { path: /, port: http }
          initialDelaySeconds: 3
          periodSeconds: 5
        resources:
          requests: { cpu: 10m, memory: 32Mi }
          limits:   { cpu: 100m, memory: 64Mi }
  strategy:
    canary:
      stableService: ${ROLLOUT}-stable
      canaryService: ${ROLLOUT}-canary
      steps:
      - setWeight: 20
      - pause: { duration: 15 }
      - setWeight: 50
      - pause: { duration: 15 }
      - setWeight: 80
      - pause: { duration: 15 }
EOF

info "Esperando a que el Rollout llegue a Healthy (hasta 180s)..."
if [ "$HAVE_PLUGIN" = "1" ]; then
  kubectl argo rollouts status "$ROLLOUT" -n "$NS" --timeout 180s \
    || die "El Rollout base no llego a Healthy; revisa el cluster antes de romper nada."
else
  for _ in $(seq 1 36); do
    PHASE="$(kubectl get rollout "$ROLLOUT" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$PHASE" = "Healthy" ] && break
    sleep 5
  done
  [ "${PHASE:-}" = "Healthy" ] || die "El Rollout base no llego a Healthy (phase=${PHASE:-vacio})."
fi
ok "Rollout base SANO y Healthy en la revision 1 (${IMG_GOOD})."

# ---------- 3. LA AVERIA (controlada y reversible) -------------------
info "Rompiendo: disparo una nueva revision canary con una imagen inexistente..."
# JSON patch preciso: cambia SOLO el tag del contenedor 0, sin tocar ports/probes.
kubectl patch rollout "$ROLLOUT" -n "$NS" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${IMG_BROKEN}\"}]"

sleep 8
ok "Averia inyectada. La nueva revision canary usa: ${IMG_BROKEN}"

# ---------- 4. briefing para el estudiante ---------------------------
cat <<BRIEF

${c_cyn}=====================================================================${c_reset}
${c_cyn} BREAK & FIX — Argo Rollouts canary atascado${c_reset}
${c_cyn}=====================================================================${c_reset}

 SINTOMA que vas a observar:
   - El Rollout '${ROLLOUT}' NO progresa mas alla del primer paso canary
     (setWeight: 20). Queda en estado 'Progressing' y, pasados
     ~120s (progressDeadlineSeconds), pasa a '${c_red}Degraded${c_reset}'.
   - El nuevo ReplicaSet canary tiene un pod en '${c_red}ImagePullBackOff${c_reset}' /
     'ErrImagePull'. El pod canary nunca queda Ready.
   - El trafico estable sigue servido por la revision vieja (${IMG_GOOD}):
     la aplicacion NO se cayo. Eso es exactamente lo que la estrategia
     canary debe garantizar.

 OBJETIVO (que tenes que lograr):
   1. Diagnosticar por que la revision canary no avanza y cual es la
      imagen culpable.
   2. Dejar el Rollout de nuevo en '${c_grn}Healthy${c_reset}', con TODAS las replicas
      corriendo una imagen que exista, sin borrar el Rollout ni el
      namespace.

 PISTAS (comandos de arranque):
   kubectl argo rollouts get rollout ${ROLLOUT} -n ${NS} --watch
   kubectl get pods -n ${NS} -o wide
   kubectl describe pod -n ${NS} -l app=${ROLLOUT}

 Cuando lo tengas resuelto, valida con:
   kubectl argo rollouts get rollout ${ROLLOUT} -n ${NS}
   kubectl get rollout ${ROLLOUT} -n ${NS} -o jsonpath='{.status.phase}{"\n"}'
   # Debe imprimir: Healthy

 Limpieza del lab cuando termines:
   kubectl delete ns ${NS}
${c_cyn}=====================================================================${c_reset}

BRIEF

ok "Lab listo. A diagnosticar. La solucion esta al final del script (comentada)."
exit 0

# =====================================================================
#  SOLUCION PASO A PASO  (no ejecutar: leer despues de intentarlo)
# =====================================================================
#
#  --- PASO 1: Confirmar el sintoma y ubicar la revision culpable ------
#
#    kubectl argo rollouts get rollout rollouts-demo -n capa-lab-41
#
#  Vas a ver algo asi:
#
#    Name:            rollouts-demo
#    Status:          ✖ Degraded
#    Message:         ProgressDeadlineExceeded: ReplicaSet "rollouts-demo-xxxxxxxxx"
#                     has timed out progressing.
#    Strategy:        Canary
#      Step:          0/6
#      SetWeight:     20
#      ActualWeight:  0
#    Images:          nginx:1.25.3 (stable)
#                     nginx:1.25.4-esta-imagen-no-existe (canary)
#    Replicas:
#      Desired:       5
#      Current:       6
#      Updated:       1
#      Ready:         5
#      Available:     5
#
#    revisions:
#    ✔ revision:1  (stable)  Healthy
#    ✖ revision:2  (canary)  Degraded   -> nginx:1.25.4-esta-imagen-no-existe
#
#  Notar: 'ActualWeight: 0' aunque el step pida 20 — el pod canary nunca
#  quedo Ready, asi que el controller nunca le dio trafico. La app estable
#  sigue sana (Ready 5, Available 5). Ese es el valor del canary.
#
#
#  --- PASO 2: Ver la causa raiz en el pod canary ----------------------
#
#    kubectl get pods -n capa-lab-41
#    # NAME                              READY   STATUS             RESTARTS
#    # rollouts-demo-<stable>-xxxxx      1/1     Running            0        (x5)
#    # rollouts-demo-<canary>-yyyyy      0/1     ImagePullBackOff   0
#
#    kubectl describe pod -n capa-lab-41 -l app=rollouts-demo | grep -A3 -i events
#    # Failed to pull image "nginx:1.25.4-esta-imagen-no-existe":
#    #   ... manifest ... not found: manifest unknown
#
#  Causa raiz: el tag de imagen de la revision 2 no existe en el registry.
#
#
#  --- PASO 3: Elegir la estrategia de arreglo -------------------------
#
#  Hay dos caminos correctos. Cualquiera de los dos deja Healthy.
#
#  OPCION A — Roll-forward (corregir la imagen y seguir hacia adelante):
#
#    # Con el plugin (forma idiomatica de Argo Rollouts):
#    kubectl argo rollouts set image rollouts-demo \
#        rollouts-demo=nginx:1.25.4 -n capa-lab-41
#
#    # Sin el plugin (kubectl puro, patch JSON preciso):
#    kubectl patch rollout rollouts-demo -n capa-lab-41 --type=json \
#      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.25.4"}]'
#
#    # Si el Rollout ya habia sido abortado por vos, reactivalo:
#    kubectl argo rollouts retry rollout rollouts-demo -n capa-lab-41
#
#    # Observar la progresion canary hasta el final:
#    kubectl argo rollouts get rollout rollouts-demo -n capa-lab-41 --watch
#
#    # Si un 'pause' te frena y queres avanzar manualmente:
#    kubectl argo rollouts promote rollouts-demo -n capa-lab-41
#    # (promote --full salta TODOS los pauses/steps restantes de una)
#
#  OPCION B — Rollback (volver a la ultima revision estable buena):
#
#    kubectl argo rollouts abort rollouts-demo -n capa-lab-41   # frena el canary roto
#    kubectl argo rollouts undo  rollouts-demo -n capa-lab-41   # vuelve a revision 1
#    # 'undo' tambien acepta --to-revision=1 para elegir una revision concreta.
#
#  Regla practica: si la nueva version ES la que queres entregar, roll-forward
#  con la imagen corregida (Opcion A). Si necesitas restaurar servicio YA y
#  arreglar la version despues, rollback (Opcion B).
#
#
#  --- PASO 4: Verificar que quedo Healthy -----------------------------
#
#    kubectl argo rollouts get rollout rollouts-demo -n capa-lab-41
#    # Status: ✔ Healthy   Step: 6/6   ActualWeight: 100
#
#    kubectl get rollout rollouts-demo -n capa-lab-41 -o jsonpath='{.status.phase}{"\n"}'
#    # Healthy
#
#    kubectl get pods -n capa-lab-41
#    # Las 5 replicas Running / Ready, ningun ImagePullBackOff.
#
#
#  --- PASO 5: Limpieza del laboratorio --------------------------------
#
#    kubectl delete ns capa-lab-41
#    # (opcional) desinstalar el controller:  kubectl delete ns argo-rollouts
#
#
#  --- POR QUE PASO ESTO (mecanica interna) ----------------------------
#
#  * El controller de Argo Rollouts crea un ReplicaSet nuevo por revision y
#    escala replicas para aproximar el 'setWeight' cuando no hay trafficRouting.
#  * El primer step (setWeight: 20 con replicas: 5) pide 1 pod canary. Ese pod
#    entra en ImagePullBackOff, jamas pasa el readinessProbe -> nunca Ready.
#  * Como el pod canary no queda Available, el Rollout no avanza al step
#    siguiente. Al superar 'progressDeadlineSeconds' (120s), el status pasa a
#    Degraded con 'ProgressDeadlineExceeded'.
#  * El ReplicaSet estable (revision 1) nunca se toco: sigue con 5 pods sanos
#    sirviendo trafico. Por eso el usuario final no ve caida: la esencia del
#    despliegue progresivo es que un release malo se detiene ANTES de recibir
#    el 100% del trafico.
#
#  Referencias:
#    - Canary strategy:   https://argo-rollouts.readthedocs.io/en/stable/features/canary/
#    - Comandos del plugin (get/set image/promote/abort/undo/retry):
#        https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts/
#    - Curriculum CAPA:   https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
# =====================================================================