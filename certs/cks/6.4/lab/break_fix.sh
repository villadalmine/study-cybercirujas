#!/usr/bin/env bash
#
# break-fix: CKS 6.4 - Ensure immutability of containers at runtime
# Peso en el examen: 4 (CKS Curriculum v1.34)
# Referencia: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# USAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE (kind/minikube/killercoda/etc).
# El script crea su propio namespace y no toca nada fuera de él, pero
# asume que el cluster completo es descartable.
#
# Uso:
#   ./break-fix-6.4-immutability.sh          -> rompe el escenario
#   ./break-fix-6.4-immutability.sh --cleanup -> borra el namespace del lab
#
set -euo pipefail

NS="cks-6-4-immutability"
APP="webapp"

info()  { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m $*"; }

if [[ "${1:-}" == "--cleanup" ]]; then
  info "Borrando namespace ${NS}..."
  kubectl delete namespace "${NS}" --ignore-not-found
  exit 0
fi

command -v kubectl >/dev/null || { fail "kubectl no encontrado."; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { fail "No hay acceso a un cluster. Abortando."; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo desconocido)"
warn "Este script va a crear recursos en el contexto '${CTX}'."
warn "Confirmá que este es un cluster de laboratorio DESCARTABLE antes de seguir."
read -r -p "Escribí 'si' para continuar: " CONFIRM
[[ "${CONFIRM}" == "si" ]] || { info "Cancelado por el usuario."; exit 0; }

info "Preparando namespace ${NS}..."
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- BREAK -------------------------------------------------------------
# Desplegamos una app nginx "as-is", sin ningún control de immutability:
# el securityContext no fija readOnlyRootFilesystem, así que por default
# el filesystem raíz del contenedor queda writable en runtime.
info "Desplegando ${APP} SIN protección de immutability (root filesystem writable)..."

kubectl apply -n "${NS}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  labels:
    app: ${APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
        - name: ${APP}
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
EOF

info "Esperando a que el pod esté Ready..."
kubectl rollout status deployment/"${APP}" -n "${NS}" --timeout=90s

POD="$(kubectl get pod -n "${NS}" -l app="${APP}" -o jsonpath='{.items[0].metadata.name}')"
ok "Pod corriendo: ${POD}"

# Simulamos lo que haría un atacante con acceso de ejecución dentro del
# contenedor (por ejemplo vía una RCE en la app): reescribir contenido
# servido y dejar un archivo de persistencia en el propio filesystem
# de la imagen, algo que en un contenedor immutable no debería ser posible.
info "Simulando escritura maliciosa en runtime (defacement + persistencia)..."
kubectl exec -n "${NS}" "${POD}" -- sh -c \
  'echo "<h1>PWNED - contenido modificado en runtime</h1>" > /usr/share/nginx/html/index.html
   echo "backdoor" > /usr/share/nginx/html/.hidden_backdoor'

echo
kubectl exec -n "${NS}" "${POD}" -- wget -qO- http://127.0.0.1:80/
echo

echo "=========================================================================="
echo " SINTOMA"
echo "=========================================================================="
echo "El Deployment '${APP}' en el namespace '${NS}' quedó con el filesystem"
echo "raíz de su contenedor WRITABLE en runtime. Recién se demostró que, con"
echo "acceso de ejecución al contenedor, se puede:"
echo "  - reescribir /usr/share/nginx/html/index.html (defacement)"
echo "  - dejar un archivo nuevo persistido en la imagen en ejecución"
echo
echo "=========================================================================="
echo " OBJETIVO"
echo "=========================================================================="
echo "Hacé que el filesystem raíz del contenedor sea immutable en runtime,"
echo "SIN romper la aplicación. Al terminar debe cumplirse TODO esto:"
echo
echo "  1) kubectl get pods -n ${NS} muestra el pod Running y 1/1 Ready"
echo "     (no CrashLoopBackOff)."
echo "  2) Un intento de escritura en runtime falla, por ejemplo:"
echo "       kubectl exec -n ${NS} <pod> -- touch /root/test"
echo "     debe devolver un error 'Read-only file system'."
echo "  3) nginx sigue sirviendo tráfico correctamente."
echo
echo "PISTA: activar readOnlyRootFilesystem: true a secas va a romper nginx"
echo "(CrashLoopBackOff), porque el proceso necesita escribir en un par de"
echo "directorios puntuales al arrancar y al atender requests. Identificá"
echo "cuáles son y dales almacenamiento writable con volumes (emptyDir),"
echo "dejando el resto del filesystem read-only."
echo "=========================================================================="

exit 0

# =====================================================================
# SOLUCION (para el instructor / autocorrección - no se ejecuta)
# =====================================================================
#
# 1) nginx (imagen oficial) necesita escribir en runtime en:
#      /var/cache/nginx   -> buffers temporales (client/proxy/fastcgi/etc)
#      /var/run            -> nginx.pid
#    (/var/log/nginx apunta por symlink a /dev/stdout y /dev/stderr en la
#    imagen oficial, así que no requiere volumen aparte)
#
# 2) Corregir el Deployment agregando readOnlyRootFilesystem: true al
#    securityContext del container, más los volumes/volumeMounts writables:
#
#    kubectl apply -n cks-6-4-immutability -f - <<'EOF'
#    apiVersion: apps/v1
#    kind: Deployment
#    metadata:
#      name: webapp
#      labels:
#        app: webapp
#    spec:
#      replicas: 1
#      selector:
#        matchLabels:
#          app: webapp
#      template:
#        metadata:
#          labels:
#            app: webapp
#        spec:
#          containers:
#            - name: webapp
#              image: nginx:1.27-alpine
#              ports:
#                - containerPort: 80
#              securityContext:
#                readOnlyRootFilesystem: true
#              volumeMounts:
#                - name: cache-volume
#                  mountPath: /var/cache/nginx
#                - name: run-volume
#                  mountPath: /var/run
#          volumes:
#            - name: cache-volume
#              emptyDir: {}
#            - name: run-volume
#              emptyDir: {}
#    EOF
#
# 3) Verificar el rollout:
#      kubectl rollout status deployment/webapp -n cks-6-4-immutability
#      kubectl get pods -n cks-6-4-immutability   # debe estar Running 1/1
#
# 4) Verificar immutability:
#      POD=$(kubectl get pod -n cks-6-4-immutability -l app=webapp \
#            -o jsonpath='{.items[0].metadata.name}')
#      kubectl exec -n cks-6-4-immutability "$POD" -- touch /root/test
#      # -> "touch: /root/test: Read-only file system"
#
# 5) Verificar que la app sigue funcionando:
#      kubectl exec -n cks-6-4-immutability "$POD" -- wget -qO- http://127.0.0.1:80/
#      # -> sirve el index.html original de la imagen (ya no el defaced)
#
# Nota: readOnlyRootFilesystem NO forma parte del perfil "restricted" de
# Pod Security Admission (temas 5.x del curriculum); es un control
# adicional que hay que aplicar explícitamente, típicamente combinado con
# allowPrivilegeEscalation: false y capabilities: drop [ALL] (tema 6.1),
# y con políticas admission-time (OPA/Gatekeeper o Kyverno, tema 5.2) que
# lo exijan para todos los workloads del cluster.