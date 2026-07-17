#!/usr/bin/env bash
#
# CKA v1.35 - Dominio 5: Networking
# Tema 5.6 - Understand and use CoreDNS (peso examen: 3.34)
# Fuente de referencia (curriculum oficial, no se copia texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
#
# Script "break & fix": rompe la resolución de DNS interna del clúster
# introduciendo una directiva inválida en el Corefile de CoreDNS.
# Diseñado para correr UNA sola vez contra un clúster de laboratorio
# descartable (kind/minikube/kubeadm de un solo nodo, etc).
#
# Uso:
#   CONFIRM=yes ./break-coredns.sh
#
set -euo pipefail

NAMESPACE="kube-system"
DEPLOYMENT="coredns"
CONFIGMAP="coredns"
BACKUP_DIR="/var/tmp/cka-5.6-coredns-lab"
BACKUP_FILE="${BACKUP_DIR}/Corefile.orig.$$"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Guardas de seguridad -----------------------------------------------

command -v kubectl >/dev/null 2>&1 || fail "kubectl no está disponible en el PATH."

if [ "${CONFIRM:-}" != "yes" ]; then
  fail "Este script rompe DNS a propósito. Volvé a ejecutarlo como: CONFIRM=yes $0"
fi

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo "")"
[ -n "$CURRENT_CTX" ] || fail "No se pudo determinar el contexto actual de kubectl."

case "$CURRENT_CTX" in
  *prod*|*production*)
    fail "El contexto actual ('$CURRENT_CTX') parece de producción. Abortando."
    ;;
esac

kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "No se encontró el deployment '$DEPLOYMENT' en el namespace '$NAMESPACE'. ¿Es un clúster estándar con CoreDNS?"

echo "Contexto actual: $CURRENT_CTX"
echo "Este script va a modificar el ConfigMap '$CONFIGMAP' en el namespace '$NAMESPACE'."
read -r -p "Confirmás que este es un clúster de laboratorio descartable? (escribí 'si' para continuar): " ans
[ "$ans" = "si" ] || fail "Cancelado por el usuario."

# --- Backup del estado original (red de seguridad, no es la solución) --

mkdir -p "$BACKUP_DIR"
kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" -o jsonpath='{.data.Corefile}' > "$BACKUP_FILE"
echo "Backup del Corefile original guardado en: $BACKUP_FILE"

# --- Rotura controlada ----------------------------------------------------
# Se inserta una directiva inexistente dentro del bloque del server block
# principal del Corefile. CoreDNS valida el Corefile al arrancar el proceso:
# si encuentra una directiva desconocida, el proceso termina con exit code
# distinto de 0, lo que produce CrashLoopBackOff en los Pods nuevos.

BROKEN_FILE="$(mktemp)"
sed '/errors/a\    bogus_directive_no_deberia_existir' "$BACKUP_FILE" > "$BROKEN_FILE"

kubectl create configmap "$CONFIGMAP" \
  --from-file="Corefile=${BROKEN_FILE}" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$BROKEN_FILE"

# Forzamos que los Pods relean el Corefile roto en el arranque del proceso
# (el plugin "reload" en caliente rechaza una config inválida sin tirar
# abajo el proceso ya corriendo; para reproducir el fallo real hace falta
# un arranque nuevo del contenedor).
kubectl -n "$NAMESPACE" rollout restart deployment "$DEPLOYMENT"

cat <<'EOF'

============================================================
 LABORATORIO ROTO A PROPÓSITO - CKA 5.6 Understand and use CoreDNS
============================================================

Síntoma que vas a observar en los próximos minutos:

  - Algunos o todos los Pods de CoreDNS en kube-system van a quedar
    en estado CrashLoopBackOff (o Error).
  - Las resoluciones de nombres DNS internas del clúster (por ejemplo
    "kubernetes.default", o el nombre de cualquier Service) empiezan
    a fallar o a tardar mucho (timeout) desde los Pods de la aplicación.

Comandos útiles para empezar a diagnosticar (no son la solución,
son punto de partida):

  kubectl -n kube-system get pods -l k8s-app=kube-dns
  kubectl -n kube-system get endpoints kube-dns
  kubectl -n kube-system describe deployment coredns
  kubectl -n kube-system logs <pod-coredns> --previous

Objetivo a lograr:

  Dejar la resolución de DNS del clúster funcionando de nuevo,
  con TODOS los Pods de CoreDNS en estado Running/Ready, sin usar
  el archivo de backup guardado por este script ni "kubectl rollout
  undo". La idea es que llegues a la causa raíz mirando el Corefile
  y los logs, y corrijas el ConfigMap vos mismo.

  Para validar que quedó arreglado, podés correr un Pod descartable
  y probar una resolución:

    kubectl run dnsutils --rm -it --restart=Never \
      --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
      -- nslookup kubernetes.default

============================================================
EOF

# ==========================================================================
# SOLUCIÓN PASO A PASO (leer solo después de intentarlo)
# ==========================================================================
#
# 1) Confirmar el estado roto:
#      kubectl -n kube-system get pods -l k8s-app=kube-dns
#    Vas a ver uno o más Pods en CrashLoopBackOff.
#
# 2) Ver el motivo real del crash en los logs del contenedor anterior:
#      kubectl -n kube-system logs <pod-coredns> --previous
#    El mensaje va a indicar algo como:
#      "Error: Corefile:3 - Error during parsing: Unknown directive
#       'bogus_directive_no_deberia_existir'"
#
# 3) Inspeccionar el Corefile actual del ConfigMap:
#      kubectl -n kube-system get configmap coredns -o yaml
#    Identificar la línea agregada de más ("bogus_directive_no_deberia_existir")
#    dentro del bloque ".:53 { ... }".
#
# 4) Editar el ConfigMap y quitar esa línea, dejando el resto del Corefile
#    intacto (kubernetes, forward, cache, loop, reload, loadbalance, etc):
#      kubectl -n kube-system edit configmap coredns
#
# 5) Forzar que los Pods tomen el Corefile corregido con un restart
#    controlado del Deployment (el "reload" plugin también lo detectaría
#    solo en el próximo ciclo, pero el restart es determinístico):
#      kubectl -n kube-system rollout restart deployment coredns
#      kubectl -n kube-system rollout status deployment coredns --timeout=120s
#
# 6) Verificar que todos los Pods de CoreDNS están Running/Ready:
#      kubectl -n kube-system get pods -l k8s-app=kube-dns
#
# 7) Confirmar que la resolución de nombres volvió a funcionar:
#      kubectl run dnsutils --rm -it --restart=Never \
#        --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
#        -- nslookup kubernetes.default
#    Debe devolver la ClusterIP del Service "kubernetes" en el namespace
#    "default", sin timeouts ni SERVFAIL.
#
# (Emergencia: si algo sale mal, el Corefile original quedó guardado por
#  este mismo script en /var/tmp/cka-5.6-coredns-lab/Corefile.orig.<pid>,
#  para reconstruir el ConfigMap manualmente con "kubectl create configmap
#  coredns --from-file=Corefile=<ese-archivo> -n kube-system --dry-run=client
#  -o yaml | kubectl apply -f -" seguido de un rollout restart.)
# ==========================================================================