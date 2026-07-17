#!/usr/bin/env bash
set -euo pipefail

# CKA v1.35 - Tema 4.5: Use Helm and Kustomize to install cluster components
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Laboratorio break & fix pensado para una VM descartable con kubectl, helm
# y soporte de kustomize integrado (kubectl apply -k) ya configurados contra
# un cluster de práctica.

NS="lab-455-helm-kustomize"
WORKDIR="$(mktemp -d /tmp/cka-4.5-XXXXXX)"
CHART_DIR="${WORKDIR}/webapp"
KUSTOMIZE_DIR="${WORKDIR}/kustomize-app"

echo "==> Namespace: ${NS}"
echo "==> Workdir: ${WORKDIR}"

command -v helm >/dev/null || { echo "helm no está instalado"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl no está instalado"; exit 1; }

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 1. Chart Helm mínimo ----------
mkdir -p "${CHART_DIR}/templates"

cat > "${CHART_DIR}/Chart.yaml" <<'EOF'
apiVersion: v2
name: webapp
description: Chart de laboratorio para CKA 4.5
type: application
version: 0.1.0
appVersion: "1.25"
EOF

cat > "${CHART_DIR}/values.yaml" <<'EOF'
replicaCount: 2
image:
  repository: nginx
  tag: "1.25"
service:
  port: 80
EOF

cat > "${CHART_DIR}/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: webapp
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 80
EOF

cat > "${CHART_DIR}/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 80
EOF

echo "==> Instalando release Helm 'webapp' (baseline OK)..."
helm install webapp "${CHART_DIR}" -n "${NS}" --wait --timeout 120s

# ---------- 2. Proyecto Kustomize (base + overlay dev) ----------
mkdir -p "${KUSTOMIZE_DIR}/base" "${KUSTOMIZE_DIR}/overlays/dev"

cat > "${KUSTOMIZE_DIR}/base/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greeter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: greeter
  template:
    metadata:
      labels:
        app: greeter
    spec:
      containers:
        - name: greeter
          image: nginx:1.25
          envFrom:
            - configMapRef:
                name: greeter-config
          ports:
            - containerPort: 80
EOF

cat > "${KUSTOMIZE_DIR}/base/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
configMapGenerator:
  - name: greeter-config
    literals:
      - GREETING=hello-from-base
EOF

cat > "${KUSTOMIZE_DIR}/overlays/dev/replica-patch.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greeter
spec:
  replicas: 3
EOF

cat > "${KUSTOMIZE_DIR}/overlays/dev/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: replica-patch.yaml
    target:
      kind: Deployment
      name: greeter
configMapGenerator:
  - name: greeter-config
    behavior: merge
    literals:
      - GREETING=hello-from-dev
EOF

echo "==> Aplicando overlay Kustomize 'dev' (baseline OK)..."
kubectl apply -k "${KUSTOMIZE_DIR}/overlays/dev" -n "${NS}"
kubectl -n "${NS}" rollout status deployment/greeter --timeout=120s

echo
echo "==> Baseline desplegado correctamente. Rompiendo el entorno..."
echo

# ---------- 3. BREAK ----------
# Rotura 1 (Helm): se fuerza un tag de imagen inexistente en values.yaml
# y se aplica con helm upgrade, sin --wait para no bloquear el script.
sed -i 's/tag: "1.25"/tag: "1.25-does-not-exist"/' "${CHART_DIR}/values.yaml"
helm upgrade webapp "${CHART_DIR}" -n "${NS}"

# Rotura 2 (Kustomize): se renombra el archivo de patch pero la referencia
# dentro de kustomization.yaml sigue apuntando al nombre original.
mv "${KUSTOMIZE_DIR}/overlays/dev/replica-patch.yaml" \
   "${KUSTOMIZE_DIR}/overlays/dev/replica-patch.yaml.bak"

echo "=================================================================="
echo "LAB ROTO - CKA 4.5: Use Helm and Kustomize to install cluster components"
echo "=================================================================="
echo
echo "Workdir del laboratorio: ${WORKDIR}"
echo "Namespace: ${NS}"
echo
echo "SÍNTOMA 1 (Helm):"
echo "  kubectl -n ${NS} get pods -l app=webapp"
echo "  Los pods del release 'webapp' quedan en ImagePullBackOff/ErrImagePull."
echo "  'helm status webapp -n ${NS}' muestra el último release como deployed,"
echo "  pero los pods nunca llegan a Ready."
echo
echo "  OBJETIVO: sin hacer 'helm uninstall', corregir la causa en el chart"
echo "  (${CHART_DIR}) y aplicar un nuevo 'helm upgrade' para que el"
echo "  deployment 'webapp' vuelva a estar Running/Ready."
echo
echo "SÍNTOMA 2 (Kustomize):"
echo "  kubectl apply -k ${KUSTOMIZE_DIR}/overlays/dev -n ${NS}"
echo "  El comando falla con un error indicando que no encuentra el archivo"
echo "  del patch declarado en overlays/dev/kustomization.yaml."
echo
echo "  OBJETIVO: identificar qué referencia de kustomization.yaml quedó"
echo "  rota, restaurar el archivo necesario y reaplicar el overlay 'dev'"
echo "  para que 'greeter' termine corriendo con 3 réplicas."
echo
echo "Comandos de diagnóstico sugeridos:"
echo "  helm get values webapp -n ${NS}"
echo "  helm history webapp -n ${NS}"
echo "  kubectl -n ${NS} describe pod -l app=webapp"
echo "  kubectl apply -k ${KUSTOMIZE_DIR}/overlays/dev -n ${NS}"
echo "  ls ${KUSTOMIZE_DIR}/overlays/dev"
echo
echo "Para limpiar todo al terminar:"
echo "  helm uninstall webapp -n ${NS}"
echo "  kubectl delete -k ${KUSTOMIZE_DIR}/overlays/dev -n ${NS} --ignore-not-found"
echo "  kubectl delete namespace ${NS}"
echo "  rm -rf ${WORKDIR}"
echo

# =================================================================
# SOLUCIÓN PASO A PASO (comentada, no se ejecuta automáticamente)
# =================================================================
#
# --- Diagnóstico y arreglo del release Helm ---
# 1) kubectl -n "${NS}" get pods -l app=webapp
#    -> Estado ImagePullBackOff.
# 2) kubectl -n "${NS}" describe pod <pod> | grep -A5 Events
#    -> "Failed to pull image ...1.25-does-not-exist: not found"
# 3) helm get values webapp -n "${NS}"
#    -> Confirma que image.tag=1.25-does-not-exist quedó activo en el release.
# 4) Corregir el chart local:
#    sed -i 's/tag: "1.25-does-not-exist"/tag: "1.25"/' "${CHART_DIR}/values.yaml"
# 5) helm upgrade webapp "${CHART_DIR}" -n "${NS}" --wait --timeout 120s
# 6) kubectl -n "${NS}" rollout status deployment/webapp
#    -> Debe quedar Running/Ready.
#
# --- Diagnóstico y arreglo del overlay Kustomize ---
# 1) kubectl apply -k "${KUSTOMIZE_DIR}/overlays/dev" -n "${NS}"
#    -> Error del estilo "accumulating resources: ... replica-patch.yaml:
#       no such file or directory".
# 2) cat "${KUSTOMIZE_DIR}/overlays/dev/kustomization.yaml"
#    -> El bloque 'patches' referencia 'path: replica-patch.yaml'.
# 3) ls "${KUSTOMIZE_DIR}/overlays/dev"
#    -> Aparece 'replica-patch.yaml.bak' en vez de 'replica-patch.yaml'.
# 4) Restaurar el nombre correcto del archivo:
#    mv "${KUSTOMIZE_DIR}/overlays/dev/replica-patch.yaml.bak" \
#       "${KUSTOMIZE_DIR}/overlays/dev/replica-patch.yaml"
# 5) kubectl kustomize "${KUSTOMIZE_DIR}/overlays/dev"
#    -> Valida que el render ya incluye replicas: 3 sin errores.
# 6) kubectl apply -k "${KUSTOMIZE_DIR}/overlays/dev" -n "${NS}"
# 7) kubectl -n "${NS}" rollout status deployment/greeter
#    -> Debe quedar 3/3 réplicas Ready.
#
# =================================================================