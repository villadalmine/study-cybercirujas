#!/usr/bin/env bash
# ============================================================================
# CKAD 1.35 - Tema 5.4 Kustomize (peso examen: 5)
# Break & Fix de laboratorio - Kustomize: configMapGenerator y name reference
#
# Fuente de referencia (curricula oficial, solo como guia de alcance del tema):
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Este script:
#   1) crea un namespace y un recurso de laboratorio 100% descartables
#   2) despliega una app funcional armada con kustomize (base + configMapGenerator)
#   3) rompe DELIBERADAMENTE la referencia al ConfigMap generado
#   4) reaplica con kustomize dejando el cluster en estado roto
#   5) te dice que sintoma vas a ver y que tenes que lograr para arreglarlo
#
# Ejecutar solo en una VM/cluster de laboratorio descartable (kind, minikube,
# vagrant, etc.). NUNCA en un cluster real.
# ============================================================================

set -euo pipefail

NS="ckad-542-kustomize-lab"
LAB_DIR="$(mktemp -d /tmp/ckad-542-kustomize.XXXXXX)"
APP_NAME="webapp"

log()  { printf '\n[LAB] %s\n' "$*"; }
warn() { printf '\n[LAB][ATENCION] %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Falta el comando '$1' en el PATH."; exit 1; }
}

safety_check() {
  require_cmd kubectl
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo desconocido)"
  warn "Contexto actual de kubectl: '$ctx'"
  case "$ctx" in
    *prod*|*production*)
      echo "El contexto parece de produccion. Abortando por seguridad." >&2
      exit 1
      ;;
  esac
  log "Este script solo va a tocar el namespace '$NS'. Se asume VM/cluster de laboratorio descartable."
}

setup_lab() {
  log "Creando namespace de laboratorio '$NS'..."
  kubectl delete namespace "$NS" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl wait --for=delete namespace/"$NS" --timeout=60s >/dev/null 2>&1 || true
  kubectl create namespace "$NS" >/dev/null

  mkdir -p "$LAB_DIR/base"

  cat > "$LAB_DIR/base/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  labels:
    app: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: webapp
          image: nginx:1.25-alpine
          envFrom:
            - configMapRef:
                name: webapp-config
          ports:
            - containerPort: 80
EOF

  cat > "$LAB_DIR/base/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
configMapGenerator:
  - name: webapp-config
    literals:
      - GREETING=hello-from-kustomize
      - ENVIRONMENT=lab
EOF

  log "Estado BUENO: desplegando con 'kubectl apply -k' antes de romper nada..."
  kubectl apply -k "$LAB_DIR/base" -n "$NS" >/dev/null
  kubectl -n "$NS" rollout status deployment/"$APP_NAME" --timeout=90s >/dev/null

  log "Deploy inicial saludable. Pods actuales:"
  kubectl -n "$NS" get pods -o wide
}

break_it() {
  log "Rompiendo el lab: introduciendo un typo en la referencia al ConfigMap generado..."
  # El configMapGenerator declara el nombre logico "webapp-config". Kustomize
  # reescribe automaticamente cualquier referencia a ese nombre logico por el
  # nombre real con hash (ej: webapp-config-8f9d7b6c5t). Si el nombre de la
  # referencia en el Deployment no coincide EXACTO con el nombre declarado en
  # el generator, Kustomize no lo reconoce como el mismo recurso y lo deja
  # como texto literal sin resolver.
  sed -i 's/name: webapp-config/name: webapp-cofig/' "$LAB_DIR/base/deployment.yaml"

  log "Reaplicando con kustomize para llevar el cluster al estado roto..."
  kubectl apply -k "$LAB_DIR/base" -n "$NS" >/dev/null
  sleep 5
}

print_instructions() {
  cat <<MSG

============================================================================
LABORATORIO ROTO - CKAD 5.4 Kustomize
============================================================================
Namespace de laboratorio : $NS
Directorio de manifiestos: $LAB_DIR/base

SINTOMA QUE VAS A VER:
  - Los pods del Deployment '$APP_NAME' no llegan a Running.
  - 'kubectl -n $NS get pods' muestra CreateContainerConfigError (o similar).
  - 'kubectl -n $NS describe pod <pod>' muestra un evento del tipo:
      Error: configmap "<algun-nombre>" not found

TU OBJETIVO:
  1. Diagnosticar, con 'kubectl describe' y 'kubectl -n $NS get configmap',
     por que el Pod no encuentra el ConfigMap que Kustomize deberia haber
     generado y referenciado.
  2. Revisar los archivos en '$LAB_DIR/base' (deployment.yaml y
     kustomization.yaml) y entender por que el 'nameReference' automatico
     de Kustomize no funciono en este caso.
  3. Corregir el/los manifiesto(s) fuente (NO edites el objeto en el cluster
     a mano) para que 'kubectl apply -k $LAB_DIR/base -n $NS' genere una
     referencia valida al ConfigMap.
  4. Verificar que el rollout termina OK:
       kubectl -n $NS rollout status deployment/$APP_NAME
       kubectl -n $NS get pods

Cuando termines, para limpiar el laboratorio:
  kubectl delete namespace $NS
  rm -rf $LAB_DIR
============================================================================
MSG
}

main() {
  safety_check
  setup_lab
  break_it
  print_instructions
}

main "$@"

# ============================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ============================================================================
#
# 1. Confirmar el sintoma:
#      kubectl -n ckad-542-kustomize-lab get pods
#    -> muestra CreateContainerConfigError en los pods de webapp.
#
# 2. Ver el detalle del error:
#      kubectl -n ckad-542-kustomize-lab describe pod <nombre-del-pod>
#    -> en Events aparece algo como:
#         Error: configmap "webapp-cofig" not found
#       (notar el typo "cofig" en vez de "config")
#
# 3. Confirmar que el ConfigMap generado por Kustomize SI existe, pero con
#    otro nombre (el que declara el generator, con su sufijo hash):
#      kubectl -n ckad-542-kustomize-lab get configmap
#    -> aparece algo como "webapp-config-<hash>", no "webapp-cofig".
#
# 4. Revisar los manifiestos fuente:
#      cat $LAB_DIR/base/kustomization.yaml
#    -> el configMapGenerator declara el nombre logico "webapp-config".
#
#      cat $LAB_DIR/base/deployment.yaml
#    -> el Deployment referencia "webapp-cofig" (typo) en envFrom.configMapRef.name.
#       Como el nombre no coincide EXACTO con el declarado en el generator,
#       el transformer de "nameReference" de Kustomize no reconoce que se
#       trata del mismo recurso, y deja el string tal cual, sin reescribirlo
#       con el sufijo hash real. Por eso el Pod busca un ConfigMap que
#       nunca existio en el cluster.
#
# 5. Corregir el typo en el manifiesto fuente (no en el cluster):
#      sed -i 's/name: webapp-cofig/name: webapp-config/' $LAB_DIR/base/deployment.yaml
#
# 6. Reconstruir y validar el render antes de aplicar (buena practica):
#      kubectl kustomize $LAB_DIR/base
#    -> confirmar que ahora el Deployment referencia el nombre con hash
#       correcto, igual al ConfigMap generado.
#
# 7. Reaplicar:
#      kubectl apply -k $LAB_DIR/base -n ckad-542-kustomize-lab
#
# 8. Verificar que el rollout se recupera:
#      kubectl -n ckad-542-kustomize-lab rollout status deployment/webapp
#      kubectl -n ckad-542-kustomize-lab get pods
#    -> todos los pods en Running, sin errores de ConfigMap.
#
# 9. Limpieza del laboratorio:
#      kubectl delete namespace ckad-542-kustomize-lab
#      rm -rf $LAB_DIR
# ============================================================================