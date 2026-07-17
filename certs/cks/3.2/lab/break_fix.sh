#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 3.2: Exercise caution in using service accounts
#            (disable defaults, minimize permissions on newly created ones)
# Peso en el examen: 3.75
#
# Fuente de referencia (curriculum oficial, no se copia texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Script tipo "break & fix". Pensado para correr en una VM de laboratorio
# DESCARTABLE con un cluster de Kubernetes ya funcionando (kubeadm, kind, minikube, etc.)
# y kubectl con permisos de cluster-admin. NO correr contra un cluster real.
#
# Qué hace: crea un namespace de laboratorio y deja instalados DOS escenarios
# de mala praxis con ServiceAccounts, tal como los pediría el examen:
#   1) Un Pod que usa la ServiceAccount "default" del namespace, con el
#      automount de token habilitado (el default de Kubernetes) y esa SA
#      "default" atada por error a un ClusterRole demasiado amplio.
#   2) Una ServiceAccount recién creada para una app ("app-sa") que quedó
#      sobre-permisionada: le dieron un ClusterRole cluster-wide cuando la
#      app solo necesita leer ConfigMaps en su propio namespace.
#
# El script NO arregla nada. Al final, comentado paso a paso, está la solución.

set -euo pipefail

NS="${CKS_LAB_NS:-cks-3-2-lab}"

c_red()    { printf '\033[1;31m%s\033[0m\n' "$1"; }
c_green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
c_yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
c_blue()   { printf '\033[1;34m%s\033[0m\n' "$1"; }

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    c_red "kubectl no está instalado. Este script requiere un cluster de Kubernetes accesible."
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    c_red "No se puede contactar al cluster con el kubeconfig actual."
    exit 1
  fi
}

confirm_disposable_vm() {
  c_yellow "=============================================================="
  c_yellow " Este script crea recursos de RBAC de CLUSTER (ClusterRole y"
  c_yellow " ClusterRoleBinding) para simular un incidente de seguridad."
  c_yellow " Context actual: $(kubectl config current-context 2>/dev/null || echo 'desconocido')"
  c_yellow " Usalo solo en una VM de laboratorio descartable."
  c_yellow "=============================================================="
  if [ "${CKS_LAB_YES:-0}" != "1" ]; then
    read -r -p "Escribí 'si' para confirmar que este es un cluster de laboratorio descartable: " ans
    if [ "$ans" != "si" ]; then
      c_red "Cancelado."
      exit 1
    fi
  fi
}

break_lab() {
  c_blue ">> Creando namespace '${NS}'..."
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  c_blue ">> Escenario 1: ServiceAccount 'default' con automount habilitado y RBAC excesivo..."
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cks-lab-broad-reader
rules:
  - apiGroups: [""]
    resources: ["secrets", "pods", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cks-lab-default-sa-broad-reader
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: cks-lab-broad-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: cks-lab-default-pod
  namespace: ${NS}
  labels:
    app: cks-lab-default-pod
spec:
  containers:
    - name: shell
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF

  c_blue ">> Escenario 2: ServiceAccount 'app-sa' recién creada, sobre-permisionada..."
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cks-lab-app-power
rules:
  - apiGroups: [""]
    resources: ["secrets", "pods", "configmaps"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cks-lab-app-sa-power
subjects:
  - kind: ServiceAccount
    name: app-sa
    namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: cks-lab-app-power
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-deploy
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-deploy
  template:
    metadata:
      labels:
        app: app-deploy
    spec:
      serviceAccountName: app-sa
      containers:
        - name: shell
          image: curlimages/curl:8.10.1
          command: ["sleep", "infinity"]
EOF

  c_blue ">> Esperando a que los Pods estén Running..."
  kubectl -n "${NS}" wait --for=condition=Ready pod/cks-lab-default-pod --timeout=60s >/dev/null 2>&1 || true
  kubectl -n "${NS}" rollout status deployment/app-deploy --timeout=60s >/dev/null 2>&1 || true

  c_green "Laboratorio listo en el namespace '${NS}'."
}

show_symptom_and_objective() {
  cat <<MSG

================================================================
SÍNTOMA
================================================================
En el namespace '${NS}' hay dos workloads corriendo:

  - cks-lab-default-pod: un Pod que NO necesita hablar con la API
    de Kubernetes para nada (solo hace sleep), pero está usando la
    ServiceAccount "default" del namespace con el token montado
    automáticamente.

  - app-deploy (usa la SA "app-sa"): una app que en teoría solo
    necesita leer ConfigMaps de su propio namespace, pero su
    ServiceAccount tiene permisos de cluster-admin-light: puede
    leer Secrets de TODO el cluster, y hasta crear/borrar Pods y
    Secrets en cualquier namespace.

Para comprobarlo, exec a cualquiera de los dos Pods y usá el token
montado en /var/run/secrets/kubernetes.io/serviceaccount/token para
hablar con la API. Ejemplo con el Pod default:

  kubectl -n ${NS} exec -it cks-lab-default-pod -- sh -c '
    TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \\
      -H "Authorization: Bearer \$TOKEN" \\
      https://kubernetes.default.svc/api/v1/namespaces/kube-system/secrets
  '

También podés auditarlo sin entrar al Pod, con kubectl auth can-i:

  kubectl auth can-i list secrets --all-namespaces \\
    --as=system:serviceaccount:${NS}:default

  kubectl auth can-i create pods -n kube-system \\
    --as=system:serviceaccount:${NS}:app-sa

Ambos comandos van a devolver "yes", lo cual es el problema.

================================================================
OBJETIVO
================================================================
Aplicá el principio de menor privilegio sobre las dos ServiceAccounts:

  1) cks-lab-default-pod no necesita acceso a la API en absoluto.
     - Deshabilitá el automount del token de la SA "default" en
       este namespace (o en el Pod).
     - Eliminá el ClusterRoleBinding que le da permisos de lectura
       cluster-wide a la SA "default".

  2) app-sa sí necesita hablar con la API, pero solo para leer
     ConfigMaps dentro de '${NS}'.
     - Reemplazá el ClusterRole/ClusterRoleBinding cluster-wide por
       un Role + RoleBinding acotado al namespace, con únicamente
       los verbos "get" y "list" sobre "configmaps".
     - Eliminá el ClusterRole y el ClusterRoleBinding excesivos.

Se considera resuelto cuando:

  kubectl auth can-i list secrets --all-namespaces \\
    --as=system:serviceaccount:${NS}:default
  # -> no

  kubectl auth can-i create pods -n kube-system \\
    --as=system:serviceaccount:${NS}:app-sa
  # -> no

  kubectl auth can-i get configmaps -n ${NS} \\
    --as=system:serviceaccount:${NS}:app-sa
  # -> yes

  kubectl -n ${NS} get pod cks-lab-default-pod \\
    -o jsonpath='{.spec.automountServiceAccountToken}{"\n"}{.spec.serviceAccountName}'
  # el automount debe quedar deshabilitado (false) para la SA default

MSG
}

main() {
  require_kubectl
  confirm_disposable_vm
  break_lab
  show_symptom_and_objective
}

main "$@"

################################################################################
# SOLUCIÓN PASO A PASO (para revisar después de intentarlo)
################################################################################
#
# --- Paso 1: cortar el acceso innecesario de la SA "default" ---------------
#
# 1a) Borrar el ClusterRoleBinding que le da lectura cluster-wide a la SA
#     "default" del namespace de laboratorio:
#
#   kubectl delete clusterrolebinding cks-lab-default-sa-broad-reader
#
# 1b) Deshabilitar el automount del token en la propia ServiceAccount
#     "default" (mejor que hacerlo por Pod, porque cubre a todo lo que se
#     despliegue después en el namespace sin especificar otra SA):
#
#   kubectl -n cks-3-2-lab patch serviceaccount default \
#     -p '{"automountServiceAccountToken": false}'
#
# 1c) Como el Pod ya está corriendo con el token montado (el patch a la SA
#     no afecta Pods existentes), hay que recrearlo para que tome el cambio:
#
#   kubectl -n cks-3-2-lab delete pod cks-lab-default-pod
#   kubectl -n cks-3-2-lab run cks-lab-default-pod \
#     --image=curlimages/curl:8.10.1 --command -- sleep infinity
#   # (opcional pero más explícito) declarar automountServiceAccountToken: false
#   # también a nivel Pod en el manifiesto, en vez de depender solo de la SA.
#
# 1d) El ClusterRole "cks-lab-broad-reader" ya quedó sin bindings; se puede
#     borrar directamente (no hace falta mantenerlo "por si acaso"):
#
#   kubectl delete clusterrole cks-lab-broad-reader
#
# --- Paso 2: minimizar permisos de la SA nueva "app-sa" ---------------------
#
# 2a) Borrar el ClusterRoleBinding y el ClusterRole sobre-permisionados:
#
#   kubectl delete clusterrolebinding cks-lab-app-sa-power
#   kubectl delete clusterrole cks-lab-app-power
#
# 2b) Crear un Role acotado al namespace con solo lo que la app necesita
#     (get/list sobre configmaps):
#
#   cat <<EOF | kubectl apply -f -
#   apiVersion: rbac.authorization.k8s.io/v1
#   kind: Role
#   metadata:
#     name: app-sa-configmap-reader
#     namespace: cks-3-2-lab
#   rules:
#     - apiGroups: [""]
#       resources: ["configmaps"]
#       verbs: ["get", "list"]
#   ---
#   apiVersion: rbac.authorization.k8s.io/v1
#   kind: RoleBinding
#   metadata:
#     name: app-sa-configmap-reader
#     namespace: cks-3-2-lab
#   subjects:
#     - kind: ServiceAccount
#       name: app-sa
#       namespace: cks-3-2-lab
#   roleRef:
#     kind: Role
#     name: app-sa-configmap-reader
#     apiGroup: rbac.authorization.k8s.io
#   EOF
#
# --- Paso 3: verificar ------------------------------------------------------
#
#   kubectl auth can-i list secrets --all-namespaces \
#     --as=system:serviceaccount:cks-3-2-lab:default
#   # -> no
#
#   kubectl auth can-i create pods -n kube-system \
#     --as=system:serviceaccount:cks-3-2-lab:app-sa
#   # -> no
#
#   kubectl auth can-i get configmaps -n cks-3-2-lab \
#     --as=system:serviceaccount:cks-3-2-lab:app-sa
#   # -> yes
#
#   kubectl -n cks-3-2-lab get sa default \
#     -o jsonpath='{.automountServiceAccountToken}{"\n"}'
#   # -> false
#
# --- Nota conceptual ---------------------------------------------------------
# La ServiceAccount "default" existe automáticamente en todo namespace y no
# debería usarse nunca para workloads reales: no se le deben atar
# RoleBindings/ClusterRoleBindings, y conviene deshabilitarle el automount
# del token para que ningún Pod la herede "sin querer". Toda carga de trabajo
# que sí necesite hablar con la API debe tener su propia ServiceAccount,
# creada explícitamente, con un Role/RoleBinding namespaced que otorgue
# solo los verbos y recursos estrictamente necesarios (least privilege),
# evitando ClusterRole/ClusterRoleBinding salvo que el acceso realmente
# deba ser cluster-wide.
################################################################################