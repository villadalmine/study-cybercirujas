#!/usr/bin/env bash
# =====================================================================
# CKAD 4.6 — Create & consume Secrets (peso en el examen: 3)
# Lab "break & fix": Secrets rotos en un backend de base de datos
# =====================================================================
# Uso:      ./break-fix-4.6-secrets.sh
# Entorno:  VM de laboratorio DESCARTABLE con un cluster Kubernetes
#           funcional (kind, minikube, k3s o similar) y kubectl
#           configurado. No lo ejecutes contra un cluster real:
#           el script crea y borra recursos sin pedir confirmación.
# Alcance:  todo ocurre dentro del namespace "lab-secrets-46";
#           para limpiar: kubectl delete namespace lab-secrets-46
#
# Fuentes de referencia (consultadas, no copiadas):
# - Curriculum CKAD v1.35:
#   https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
# - Kubernetes docs — Secrets:
#   https://kubernetes.io/docs/concepts/configuration/secret/
# - Kubernetes docs — Distribute Credentials Securely Using Secrets:
#   https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
# =====================================================================

set -euo pipefail

NS="lab-secrets-46"

# ---------------------------------------------------------------------
# Chequeos previos
# ---------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: no se encontró kubectl en el PATH." >&2
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl no puede hablar con ningún cluster." >&2
  echo "Verificá tu kubeconfig (kubectl config current-context)." >&2
  exit 1
fi

echo ">>> Preparando el laboratorio en el namespace ${NS}..."
kubectl delete namespace "${NS}" --ignore-not-found >/dev/null 2>&1 || true
kubectl wait --for=delete "namespace/${NS}" --timeout=60s >/dev/null 2>&1 || true
kubectl create namespace "${NS}" >/dev/null

# ---------------------------------------------------------------------
# ROTURA 1: Secret con nombres de key equivocados
# El Pod "api-backend" espera las keys DB_USER y DB_PASSWORD, pero el
# Secret se crea con las keys db_user y db_pass. Resultado:
# CreateContainerConfigError.
# ---------------------------------------------------------------------
kubectl -n "${NS}" create secret generic db-creds \
  --from-literal=db_user=appuser \
  --from-literal=db_pass='S3cr3t-P4ss!' >/dev/null

cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: api-backend
  namespace: lab-secrets-46
  labels:
    app: api-backend
spec:
  restartPolicy: Always
  containers:
  - name: api
    image: busybox:1.36
    command:
    - sh
    - -c
    - 'echo "Conectando como $DB_USER"; sleep 3600'
    env:
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-creds
          key: DB_USER
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-creds
          key: DB_PASSWORD
EOF

# ---------------------------------------------------------------------
# ROTURA 2: volumen que referencia un Secret que no existe
# El Secret real se llama "tls-certs" (plural), pero el Pod "web-tls"
# monta un Secret llamado "tls-cert" (singular). Resultado: el Pod
# queda clavado en ContainerCreating con eventos FailedMount.
# ---------------------------------------------------------------------
TMPDIR_CERTS="$(mktemp -d)"
echo "certificado-de-laboratorio-no-usar-en-produccion" > "${TMPDIR_CERTS}/tls.crt"
echo "clave-privada-de-laboratorio-no-usar-en-produccion" > "${TMPDIR_CERTS}/tls.key"

kubectl -n "${NS}" create secret generic tls-certs \
  --from-file=tls.crt="${TMPDIR_CERTS}/tls.crt" \
  --from-file=tls.key="${TMPDIR_CERTS}/tls.key" >/dev/null

rm -rf "${TMPDIR_CERTS}"

cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: web-tls
  namespace: lab-secrets-46
  labels:
    app: web-tls
spec:
  restartPolicy: Always
  containers:
  - name: web
    image: busybox:1.36
    command:
    - sh
    - -c
    - 'ls -l /etc/tls; sleep 3600'
    volumeMounts:
    - name: certs
      mountPath: /etc/tls
      readOnly: true
  volumes:
  - name: certs
    secret:
      secretName: tls-cert
EOF

sleep 5

# ---------------------------------------------------------------------
# Instrucciones para el estudiante
# ---------------------------------------------------------------------
cat <<EOF

=====================================================================
 LAB LISTO — CKAD 4.6: Create & consume Secrets
=====================================================================

ESCENARIO
  En el namespace "${NS}" hay dos Pods que consumen Secrets y
  ninguno de los dos llega al estado Running:

    kubectl -n ${NS} get pods

SÍNTOMAS QUE VAS A VER
  1) El Pod "api-backend" queda en CreateContainerConfigError.
     Pista: mirá los eventos con
       kubectl -n ${NS} describe pod api-backend
     Vas a encontrar un mensaje del estilo
       couldn't find key DB_USER in Secret ${NS}/db-creds

  2) El Pod "web-tls" queda clavado en ContainerCreating.
     Pista: mirá los eventos con
       kubectl -n ${NS} describe pod web-tls
     Vas a encontrar eventos FailedMount indicando que un Secret
     no existe.

TU OBJETIVO
  - Los dos Pods deben quedar en estado Running (1/1 Ready).
  - "api-backend" debe tener las variables de entorno DB_USER y
    DB_PASSWORD con los valores appuser y S3cr3t-P4ss! tomados
    de un Secret (no las hardcodees en el Pod).
  - "web-tls" debe tener montados tls.crt y tls.key en /etc/tls
    desde un Secret.

VERIFICACIÓN (cuando creas que terminaste)
  kubectl -n ${NS} get pods
  kubectl -n ${NS} exec api-backend -- sh -c 'echo \$DB_USER; echo \$DB_PASSWORD'
  kubectl -n ${NS} exec web-tls -- ls /etc/tls

HERRAMIENTAS ÚTILES
  kubectl -n ${NS} get secrets
  kubectl -n ${NS} get secret db-creds -o yaml
  echo '<valor-base64>' | base64 -d
  kubectl explain pod.spec.containers.env.valueFrom.secretKeyRef
  kubectl explain pod.spec.volumes.secret

LIMPIEZA (al terminar el lab)
  kubectl delete namespace ${NS}

La solución paso a paso está comentada al final de este script.
¡No la mires hasta intentarlo!
=====================================================================
EOF

exit 0

# =====================================================================
# SOLUCIÓN PASO A PASO (spoilers — intentalo antes de leer)
# =====================================================================
#
# --- Diagnóstico general ---------------------------------------------
#
# 1. Ver el estado de los Pods:
#      kubectl -n lab-secrets-46 get pods
#    api-backend -> CreateContainerConfigError
#    web-tls     -> ContainerCreating
#
# --- Problema 1: api-backend (keys del Secret mal nombradas) ---------
#
# 2. Leer los eventos del Pod:
#      kubectl -n lab-secrets-46 describe pod api-backend
#    El evento clave dice que no encuentra la key "DB_USER" en el
#    Secret "db-creds".
#
# 3. Inspeccionar el Secret para ver qué keys tiene realmente:
#      kubectl -n lab-secrets-46 get secret db-creds -o yaml
#    Las keys son "db_user" y "db_pass", pero el Pod pide "DB_USER"
#    y "DB_PASSWORD" en sus secretKeyRef. Ese es el desajuste.
#
#    (Opcional) Decodificar un valor para confirmar el contenido:
#      kubectl -n lab-secrets-46 get secret db-creds \
#        -o jsonpath='{.data.db_user}' | base64 -d; echo
#
# 4. Arreglo recomendado: recrear el Secret con las keys que el Pod
#    espera (en el examen suele ser más rápido recrear que editar
#    base64 a mano):
#      kubectl -n lab-secrets-46 delete secret db-creds
#      kubectl -n lab-secrets-46 create secret generic db-creds \
#        --from-literal=DB_USER=appuser \
#        --from-literal=DB_PASSWORD='S3cr3t-P4ss!'
#
# 5. No hace falta borrar el Pod: con CreateContainerConfigError el
#    kubelet reintenta solo, y en cuanto el Secret tiene las keys
#    correctas el container arranca. Esperá unos segundos y verificá:
#      kubectl -n lab-secrets-46 get pod api-backend
#      kubectl -n lab-secrets-46 exec api-backend -- \
#        sh -c 'echo $DB_USER; echo $DB_PASSWORD'
#
# --- Problema 2: web-tls (nombre del Secret equivocado) --------------
#
# 6. Leer los eventos del Pod:
#      kubectl -n lab-secrets-46 describe pod web-tls
#    El evento FailedMount dice: secret "tls-cert" not found.
#
# 7. Listar los Secrets del namespace:
#      kubectl -n lab-secrets-46 get secrets
#    Existe "tls-certs" (plural); el Pod referencia "tls-cert"
#    (singular) en spec.volumes.secret.secretName.
#
# 8. Hay dos caminos válidos:
#
#    Opción A (más simple): crear un Secret con el nombre que el Pod
#    espera, copiando los datos del existente. Los volúmenes de un
#    Pod ya creado son inmutables, así que NO se puede editar
#    secretName en caliente; pero si aparece el Secret que falta,
#    el kubelet completa el mount solo.
#      kubectl -n lab-secrets-46 get secret tls-certs -o yaml \
#        | sed 's/name: tls-certs/name: tls-cert/' \
#        | kubectl apply -f -
#    (Si el YAML trae campos como resourceVersion o uid, borralos
#     antes de aplicar, o usá:
#       kubectl -n lab-secrets-46 create secret generic tls-cert \
#         --from-literal=tls.crt="$(kubectl -n lab-secrets-46 get secret tls-certs -o jsonpath='{.data.tls\.crt}' | base64 -d)" \
#         --from-literal=tls.key="$(kubectl -n lab-secrets-46 get secret tls-certs -o jsonpath='{.data.tls\.key}' | base64 -d)" )
#
#    Opción B (más prolija): recrear el Pod apuntando al Secret
#    correcto. Exportá el manifest, corregí secretName a "tls-certs",
#    borrá el Pod y aplicá de nuevo:
#      kubectl -n lab-secrets-46 get pod web-tls -o yaml > /tmp/web-tls.yaml
#      # editar /tmp/web-tls.yaml: secretName: tls-cert -> tls-certs
#      kubectl -n lab-secrets-46 delete pod web-tls
#      kubectl apply -f /tmp/web-tls.yaml
#
# 9. Verificación final:
#      kubectl -n lab-secrets-46 get pods
#      kubectl -n lab-secrets-46 exec web-tls -- ls -l /etc/tls
#    Ambos Pods deben estar Running 1/1 y /etc/tls debe contener
#    tls.crt y tls.key.
#
# --- Conceptos que este lab ejercita ---------------------------------
#
# - Un Secret es un mapa de keys a valores codificados en base64
#   (codificados, NO cifrados por defecto).
# - Consumo como variables de entorno: env[].valueFrom.secretKeyRef
#   exige que coincidan el nombre del Secret Y el nombre de la key;
#   si falta la key -> CreateContainerConfigError.
# - Consumo como volumen: volumes[].secret.secretName; si el Secret
#   no existe -> el Pod queda en ContainerCreating con FailedMount.
# - Los errores de config se reintentan: arreglar el Secret suele
#   alcanzar, sin recrear el Pod (clave para ahorrar tiempo en el
#   examen).
# =====================================================================