#!/usr/bin/env bash
#
# break-fix: CKS v1.34 - Dominio "Cluster Setup"
# Tema 1.1 - Use Network security policies to restrict cluster level access (peso: 3)
# Fuente de referencia (curriculum oficial, NO copiar texto literal):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Este script está pensado para correr en una VM de laboratorio DESCARTABLE
# con un cluster de Kubernetes ya funcionando y un CNI que soporte NetworkPolicy
# (Calico, Cilium, etc). NO correr contra un cluster real ni de producción.
#
# Uso:
#   ./cks-1-1-netpol-breakfix.sh break   -> rompe el escenario (default)
#   ./cks-1-1-netpol-breakfix.sh clean   -> borra todos los recursos del lab
#
set -euo pipefail

NAMESPACE="cks-1-1-netpol-lab"
ACTION="${1:-break}"

log()  { printf '\n[LAB] %s\n' "$1"; }
warn() { printf '\n[LAB][ATENCION] %s\n' "$1"; }

# --- Guardas de seguridad -----------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Falta el comando '$1' en PATH."; exit 1; }
}
require_cmd kubectl

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo '')"
if [ -z "$CURRENT_CTX" ]; then
  echo "No se pudo determinar el contexto de kubectl. Abortando."
  exit 1
fi
case "$CURRENT_CTX" in
  *prod*|*production*)
    echo "El contexto actual ('$CURRENT_CTX') parece de producción. Abortando por seguridad."
    exit 1
    ;;
esac

if [ "${NONINTERACTIVE:-}" != "yes" ]; then
  warn "Esto va a crear/borrar recursos en el namespace '$NAMESPACE' del cluster con contexto '$CURRENT_CTX'."
  read -r -p "Escribí 'confirmo' para continuar: " ans
  [ "$ans" = "confirmo" ] || { echo "Cancelado por el usuario."; exit 1; }
fi

# --- Escenario -----------------------------------------------------------
# db      -> simula una base de datos / servicio sensible (nginx en :80)
# frontend-> pod AUTORIZADO a hablar con db
# attacker-> pod NO autorizado que representa una carga comprometida en el
#            mismo namespace (o un vecino que no debería tener acceso)

deploy_scenario() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: db
  labels:
    app: db
    tier: data
spec:
  containers:
    - name: db
      image: nginx:alpine
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: db-svc
spec:
  selector:
    app: db
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app: frontend
    tier: web
spec:
  containers:
    - name: frontend
      image: busybox:1.36
      command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  labels:
    app: attacker
spec:
  containers:
    - name: attacker
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF

  kubectl wait -n "$NAMESPACE" --for=condition=Ready pod/db pod/frontend pod/attacker --timeout=90s
}

# --- La "rotura" ----------------------------------------------------------
# Se aplica una NetworkPolicy que DEBERIA restringir el acceso a "db" para
# que solo "frontend" pueda alcanzarlo, pero su podSelector tiene un typo:
# apunta a "app: database" en lugar de "app: db". Como ningún pod tiene esa
# label, la policy no selecciona a NINGÚN pod y por lo tanto no restringe
# absolutamente nada: el tráfico hacia "db" queda tan abierto como si la
# policy no existiera.
break_networkpolicy() {
  kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-restrict
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 80
EOF
}

print_briefing() {
  cat <<MSG

============================================================
 SINTOMA
============================================================
En el namespace '$NAMESPACE' hay un pod 'db' (nginx, puerto 80)
que debería ser accesible SOLO desde el pod 'frontend'.

Existe una NetworkPolicy llamada 'db-restrict' que en teoría
implementa esa restricción... pero no está funcionando.

Podés comprobarlo vos mismo:

  kubectl exec -n $NAMESPACE frontend -- wget -qO- --timeout=2 http://db-svc
  kubectl exec -n $NAMESPACE attacker -- wget -qO- --timeout=2 http://db-svc

Vas a ver que AMBOS pods, 'frontend' y 'attacker', logran acceder
a 'db-svc'. El pod 'attacker' no debería poder hacerlo.

============================================================
 OBJETIVO
============================================================
Corregí la configuración de NetworkPolicy en el namespace
'$NAMESPACE' para que:

  1. El pod 'frontend' siga pudiendo acceder a 'db-svc' en el
     puerto 80/TCP.
  2. El pod 'attacker' NO pueda acceder a 'db-svc' (el intento
     debe timeoutear/fallar).
  3. Ningún otro pod del namespace (salvo 'frontend') pueda
     alcanzar a 'db' por ningún puerto.

Pista: inspeccioná el resource con
  kubectl get networkpolicy db-restrict -n $NAMESPACE -o yaml
y compará las labels de la policy contra las labels reales del
pod 'db' (kubectl get pod db -n $NAMESPACE --show-labels).

============================================================
MSG
}

clean_scenario() {
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
  log "Namespace '$NAMESPACE' eliminado."
}

case "$ACTION" in
  break)
    deploy_scenario
    break_networkpolicy
    print_briefing
    ;;
  clean)
    clean_scenario
    ;;
  *)
    echo "Uso: $0 [break|clean]"
    exit 1
    ;;
esac

# ============================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# ============================================================
#
# 1. Confirmar qué labels tiene realmente el pod 'db':
#
#      kubectl get pod db -n cks-1-1-netpol-lab --show-labels
#      -> app=db,tier=data
#
# 2. Confirmar qué labels busca la NetworkPolicy actual:
#
#      kubectl get networkpolicy db-restrict -n cks-1-1-netpol-lab -o yaml
#      -> podSelector.matchLabels: app=database  (NO matchea ningún pod)
#
# 3. Corregir el podSelector para que apunte al pod 'db' real, por ejemplo
#    editando el resource:
#
#      kubectl edit networkpolicy db-restrict -n cks-1-1-netpol-lab
#
#    o reemplazándolo directamente:
#
#      kubectl apply -n cks-1-1-netpol-lab -f - <<EOF
#      apiVersion: networking.k8s.io/v1
#      kind: NetworkPolicy
#      metadata:
#        name: db-restrict
#      spec:
#        podSelector:
#          matchLabels:
#            app: db
#        policyTypes:
#          - Ingress
#        ingress:
#          - from:
#              - podSelector:
#                  matchLabels:
#                    app: frontend
#            ports:
#              - protocol: TCP
#                port: 80
#      EOF
#
#    Con podSelector.matchLabels=app:db, la policy ahora SI selecciona al
#    pod 'db' y, como tiene policyTypes=[Ingress] con una única regla
#    "from", pasa a comportarse en modo default-deny para ingress salvo lo
#    explícitamente permitido (el resto del tráfico de ingress hacia 'db'
#    queda bloqueado por la semántica whitelist de NetworkPolicy).
#
# 4. Validar el resultado:
#
#      kubectl exec -n cks-1-1-netpol-lab frontend -- wget -qO- --timeout=2 http://db-svc
#        -> responde el HTML de nginx (OK, tráfico permitido)
#
#      kubectl exec -n cks-1-1-netpol-lab attacker -- wget -qO- --timeout=2 http://db-svc
#        -> timeout / "wget: download timed out" (OK, tráfico bloqueado)
#
# 5. (Opcional, buena práctica CKS) Reforzar con un default-deny-ingress
#    a nivel namespace para que ningún pod nuevo quede expuesto por
#    omisión, y documentar explícitamente qué se permite:
#
#      kubectl apply -n cks-1-1-netpol-lab -f - <<EOF
#      apiVersion: networking.k8s.io/v1
#      kind: NetworkPolicy
#      metadata:
#        name: default-deny-ingress
#      spec:
#        podSelector: {}
#        policyTypes:
#          - Ingress
#      EOF
#
#    Esto no cambia el resultado para 'db' (ya estaba restringido por
#    'db-restrict'), pero cierra por defecto cualquier pod futuro que no
#    tenga una NetworkPolicy propia que lo autorice explícitamente.
#
# ============================================================