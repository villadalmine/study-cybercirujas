#!/usr/bin/env bash
#
# break-fix: CKA v1.35 - Tema 3.2 "Use ConfigMaps and Secrets to configure applications"
# Referencia curricular: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Uso:
#   ./breakfix-3.2.sh all       -> crea el laboratorio sano y luego lo rompe (default)
#   ./breakfix-3.2.sh setup     -> solo crea el laboratorio sano
#   ./breakfix-3.2.sh break     -> rompe un laboratorio ya creado con setup
#   ./breakfix-3.2.sh hint      -> muestra comandos de diagnostico (sin revelar la solucion)
#   ./breakfix-3.2.sh clean     -> elimina el namespace del laboratorio
#
# Requiere confirmar explicitamente que se ejecuta contra un cluster de
# laboratorio descartable, seteando LAB_CONFIRM=yes.

set -euo pipefail

NS="cka-3-2-lab"

usage() {
  echo "Uso: $0 {all|setup|break|hint|clean}" >&2
  exit 1
}

require_confirmation() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  echo ">> Contexto actual de kubectl: ${ctx}"
  if [[ "${ctx,,}" == *prod* ]]; then
    echo "ABORTADO: el contexto parece apuntar a produccion. Este script solo debe correr contra un cluster/VM de laboratorio descartable." >&2
    exit 1
  fi
  if [[ "${LAB_CONFIRM:-}" != "yes" ]]; then
    echo "Este script va a crear/romper recursos en el cluster de arriba." >&2
    echo "Si es un laboratorio descartable, volve a ejecutar con: LAB_CONFIRM=yes $0 $*" >&2
    exit 1
  fi
}

setup() {
  echo ">> Creando namespace y recursos base (ConfigMap, Secret, Deployment) en '$NS'..."
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: $NS
data:
  APP_MODE: "production"
  LOG_LEVEL: "info"
  app.conf: |
    mode=production
    log_level=info
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: $NS
type: Opaque
stringData:
  DB_USER: appuser
  DB_PASS: S3cr3tPass!
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: $NS
  labels:
    app: web-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "env | egrep 'APP_MODE|DB_PASSWORD'; sleep 3600"]
          env:
            - name: APP_MODE
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: APP_MODE
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASS
          volumeMounts:
            - name: secret-vol
              mountPath: /etc/app-secret
              readOnly: true
      volumes:
        - name: secret-vol
          secret:
            secretName: app-secret
EOF

  echo ">> Esperando que el Deployment quede sano antes de romper nada..."
  kubectl -n "$NS" rollout status deployment/web-app --timeout=90s
  echo ">> Laboratorio base OK: pod corriendo con APP_MODE y DB_PASSWORD resueltos."
}

break_lab() {
  echo ">> Rompiendo el laboratorio..."
  kubectl -n "$NS" patch deployment web-app --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/secret/secretName","value":"app-secret-missing"}]' >/dev/null

  kubectl -n "$NS" patch configmap app-config --type=merge \
    -p '{"data":{"APP_MODE":null}}' >/dev/null

  kubectl -n "$NS" rollout restart deployment/web-app >/dev/null

  sleep 5
  echo
  echo "================================================================"
  echo " SINTOMA"
  echo "================================================================"
  echo "El Deployment 'web-app' en el namespace '$NS' dejo de quedar Ready."
  kubectl -n "$NS" get pods -o wide || true
  echo
  echo "================================================================"
  echo " OBJETIVO"
  echo "================================================================"
  echo "Dejar el Deployment 'web-app' con su pod en Running 1/1, sin cambiar"
  echo "la imagen ni el comando del container, usando el ConfigMap 'app-config'"
  echo "y el Secret 'app-secret' que ya existen en el namespace. Al terminar,"
  echo "los logs del pod deben mostrar tanto APP_MODE como DB_PASSWORD con"
  echo "valores no vacios."
  echo
  echo "Pistas de diagnostico:"
  echo "  kubectl -n $NS get pods"
  echo "  kubectl -n $NS describe pod -l app=web-app"
  echo "  kubectl -n $NS get events --sort-by=.lastTimestamp"
  echo "  kubectl -n $NS get configmap app-config -o yaml"
  echo "  kubectl -n $NS get deployment web-app -o yaml"
  echo "================================================================"
}

hint() {
  echo ">> Comandos de diagnostico sugeridos:"
  echo "  kubectl -n $NS get pods"
  echo "  kubectl -n $NS describe pod -l app=web-app"
  echo "  kubectl -n $NS get events --sort-by=.lastTimestamp"
}

clean() {
  echo ">> Eliminando namespace '$NS'..."
  kubectl delete namespace "$NS" --ignore-not-found
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    all)
      require_confirmation "$@"
      setup
      break_lab
      ;;
    setup)
      require_confirmation "$@"
      setup
      ;;
    break)
      require_confirmation "$@"
      break_lab
      ;;
    hint)
      hint
      ;;
    clean)
      require_confirmation "$@"
      clean
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"

# ================================================================
# SOLUCION PASO A PASO (comentada, no se ejecuta)
# ================================================================
#
# 1. Diagnosticar el estado del pod:
#      kubectl -n cka-3-2-lab get pods
#      kubectl -n cka-3-2-lab describe pod -l app=web-app
#
#    En los Events vas a ver algo como:
#      Warning  FailedMount  ...  MountVolume.SetUp failed for volume
#      "secret-vol" : secret "app-secret-missing" not found
#
# 2. El Deployment quedo apuntando a un Secret que no existe. Corregir el
#    nombre del Secret referenciado en el volumen:
#      kubectl -n cka-3-2-lab patch deployment web-app --type=json \
#        -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/secret/secretName","value":"app-secret"}]'
#
# 3. Verificar que el pod avanza (puede tardar unos segundos en recrearse):
#      kubectl -n cka-3-2-lab get pods -w
#
#    Ahora aparece un segundo problema, con el pod en CreateContainerConfigError:
#      kubectl -n cka-3-2-lab describe pod -l app=web-app
#      ...
#      Error: couldn't find key APP_MODE in ConfigMap cka-3-2-lab/app-config
#
# 4. La key APP_MODE fue borrada del ConfigMap. Restaurarla:
#      kubectl -n cka-3-2-lab patch configmap app-config --type=merge \
#        -p '{"data":{"APP_MODE":"production"}}'
#
# 5. Los Pods ya en ejecucion no releen configMapKeyRef/secretKeyRef en caliente
#    (esos valores solo se resuelven al crear el container), asi que forzar
#    un nuevo rollout para que el ReplicaSet levante un pod nuevo:
#      kubectl -n cka-3-2-lab rollout restart deployment/web-app
#      kubectl -n cka-3-2-lab rollout status deployment/web-app
#
# 6. Confirmar que el pod quedo sano y que ambas variables se resolvieron:
#      kubectl -n cka-3-2-lab get pods
#      kubectl -n cka-3-2-lab logs -l app=web-app
#
#    Salida esperada en los logs (via "env | egrep"):
#      APP_MODE=production
#      DB_PASSWORD=S3cr3tPass!
#
# ================================================================