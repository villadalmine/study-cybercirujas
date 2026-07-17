#!/usr/bin/env bash
# ============================================================================
# CKS (v1.34) - Dominio 1.3: Properly set up Ingress objects with TLS
# Peso en el examen: 3
# Fuente de referencia (curriculum oficial): 
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
# Documentacion tecnica de referencia (para profundizar, no copiada aqui):
#   https://kubernetes.io/docs/concepts/services-networking/ingress/#tls
#   https://kubernetes.github.io/ingress-nginx/user-guide/tls/
#
# Script "break & fix". Pensado para correr SOLO en un cluster de laboratorio
# descartable (kind/minikube/VM efimera) con un Ingress controller (nginx)
# ya instalado. Crea un namespace propio, no toca nada fuera de el.
#
# Uso:
#   ./cks-1.3-ingress-tls.sh setup     -> arma el escenario y ROMPE el TLS del Ingress
#   ./cks-1.3-ingress-tls.sh verify    -> chequea si ya lo arreglaste
#   ./cks-1.3-ingress-tls.sh cleanup   -> borra todo lo creado por el lab
#
# Agrega --yes a "setup" para saltear la confirmacion interactiva.
# ============================================================================

set -euo pipefail

NAMESPACE="cks-1-3-ingress-tls-lab"
HOST="secure.cks.local"
SECRET_NAME="secure-cks-tls"
CERT_DIR="/tmp/${NAMESPACE}-certs"
PF_PID_FILE="/tmp/${NAMESPACE}-portforward.pid"
LOCAL_PORT="18443"

log()  { printf '\033[1;34m[cks-1.3]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cks-1.3][WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[cks-1.3][ERROR]\033[0m %s\n' "$*" >&2; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Falta el binario '$1' en el PATH."; exit 1; }
}

confirm_lab_environment() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "desconocido")"
  log "Contexto actual de kubectl: ${ctx}"
  if echo "${ctx}" | grep -qiE 'prod|production'; then
    err "El contexto '${ctx}' parece de produccion. Este script rompe TLS a proposito. Abortando."
    exit 1
  fi
  if [[ "${1:-}" != "--yes" ]]; then
    read -r -p "Vas a modificar el cluster del contexto '${ctx}' (namespace '${NAMESPACE}'). Continuar? [y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || { log "Cancelado por el usuario."; exit 0; }
  fi
}

detect_ingress_controller() {
  local line
  line="$(kubectl get svc -A -l app.kubernetes.io/component=controller \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
  if [[ -z "${line}" ]]; then
    line="$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
  fi
  if [[ -z "${line}" ]]; then
    err "No se encontro un Ingress controller (nginx) corriendo en el cluster."
    err "Instalalo antes de correr este lab, por ejemplo:"
    err "  minikube addons enable ingress"
    err "  o el manifest oficial: https://kubernetes.github.io/ingress-nginx/deploy/"
    exit 1
  fi
  INGRESS_NS="$(echo "${line}" | awk '{print $1}')"
  INGRESS_SVC="$(echo "${line}" | awk '{print $2}')"
  INGRESS_CLASS="$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -z "${INGRESS_CLASS}" ]] && INGRESS_CLASS="nginx"
  log "Ingress controller detectado: svc/${INGRESS_SVC} -n ${INGRESS_NS} (ingressClass: ${INGRESS_CLASS})"
}

cmd_setup() {
  require_bin kubectl
  require_bin openssl
  confirm_lab_environment "${1:-}"
  detect_ingress_controller

  log "Creando namespace ${NAMESPACE}..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "Desplegando backend (Deployment + Service 'web')..."
  kubectl apply -n "${NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF

  kubectl -n "${NAMESPACE}" rollout status deployment/web --timeout=90s

  log "Generando certificado self-signed para CN=${HOST}..."
  rm -rf "${CERT_DIR}"
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/tls.key" -out "${CERT_DIR}/tls.crt" \
    -days 3 -subj "/CN=${HOST}/O=cks-lab" \
    -addext "subjectAltName=DNS:${HOST}" >/dev/null 2>&1

  # --- ACA ESTA LA ROTURA CONTROLADA -----------------------------------
  # En vez de crear el Secret con "kubectl create secret tls" (que arma
  # un Secret type=kubernetes.io/tls con las keys tls.crt / tls.key),
  # lo armamos como un Secret generico con OTROS nombres de key. Es un
  # error real y comun: alguien escribe el manifest a mano copiando el
  # contenido del cert/key pero le pone nombres "descriptivos" a los
  # campos en vez de los que Ingress/el controller esperan.
  kubectl -n "${NAMESPACE}" delete secret "${SECRET_NAME}" --ignore-not-found >/dev/null
  kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
    --from-file=certificate.pem="${CERT_DIR}/tls.crt" \
    --from-file=private.key="${CERT_DIR}/tls.key" >/dev/null
  # -----------------------------------------------------------------------

  log "Creando el Ingress con TLS (referenciando el Secret roto)..."
  kubectl apply -n "${NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: secure-cks-ingress
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${HOST}
      secretName: ${SECRET_NAME}
  rules:
    - host: ${HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
EOF

  cat <<MSG

============================================================================
ESCENARIO LISTO. Namespace: ${NAMESPACE}

SINTOMA que vas a observar:
  El Ingress "secure-cks-ingress" existe, tiene su bloque "tls:" apuntando
  al host ${HOST} y al Secret "${SECRET_NAME}", y el backend "web" esta
  levantado y sano. Sin embargo, si haces un handshake TLS contra el
  Ingress controller pidiendo ese host, NO vas a recibir tu certificado:
  vas a recibir el certificado default/fake que sirve el controller
  cuando no puede resolver un cert valido para el host (tipicamente
  emitido por "Kubernetes Ingress Controller Fake Certificate" o similar).

  Para comprobarlo vos mismo (el controller ya esta detectado en
  ${INGRESS_NS}/${INGRESS_SVC}):
    kubectl -n ${INGRESS_NS} port-forward svc/${INGRESS_SVC} ${LOCAL_PORT}:443 &
    curl -kv --resolve ${HOST}:${LOCAL_PORT}:127.0.0.1 https://${HOST}:${LOCAL_PORT}/ 2>&1 | grep -iE "subject:|issuer:"

OBJETIVO:
  Sin borrar ni recrear el objeto Ingress, arregla el Secret
  "${SECRET_NAME}" en el namespace "${NAMESPACE}" para que el Ingress
  controller sirva el certificado correcto (CN/SAN = ${HOST}) cuando
  se consulta ese host por TLS.

  Pista: inspecciona el Secret con
    kubectl -n ${NAMESPACE} get secret ${SECRET_NAME} -o yaml
  y compara el "type" y los nombres de key contra lo que Kubernetes/el
  Ingress controller esperan para un Secret de TLS.

  Cuando creas que lo arreglaste, corre:
    $0 verify
============================================================================
MSG
}

cmd_verify() {
  require_bin kubectl
  detect_ingress_controller

  local ok=1

  local sec_type
  sec_type="$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.type}' 2>/dev/null || echo "")"
  if [[ "${sec_type}" != "kubernetes.io/tls" ]]; then
    warn "El Secret ${SECRET_NAME} tiene type='${sec_type:-<no existe>}', esperado 'kubernetes.io/tls'."
    ok=0
  else
    log "Secret type OK (kubernetes.io/tls)."
  fi

  local has_crt has_key
  has_crt="$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")"
  has_key="$(kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' 2>/dev/null || echo "")"
  if [[ -z "${has_crt}" || -z "${has_key}" ]]; then
    warn "Faltan las keys tls.crt / tls.key en el Secret."
    ok=0
  else
    log "Keys tls.crt y tls.key presentes."
  fi

  if [[ "${ok}" -eq 1 ]]; then
    log "Verificando el certificado servido realmente por el Ingress controller..."
    (kubectl -n "${INGRESS_NS}" port-forward "svc/${INGRESS_SVC}" "${LOCAL_PORT}:443" >/dev/null 2>&1 &
     echo $! > "${PF_PID_FILE}")
    sleep 2
    local subject
    subject="$(curl -sk -v --resolve "${HOST}:${LOCAL_PORT}:127.0.0.1" "https://${HOST}:${LOCAL_PORT}/" 2>&1 \
      | grep -i "subject:" || true)"
    kill "$(cat "${PF_PID_FILE}")" >/dev/null 2>&1 || true
    rm -f "${PF_PID_FILE}"

    if echo "${subject}" | grep -qi "${HOST}"; then
      log "OK: el handshake TLS entrega un certificado con CN/SAN=${HOST}."
      log "RESULTADO: ARREGLADO."
    else
      warn "El certificado servido no coincide con ${HOST} (subject: '${subject}')."
      ok=0
    fi
  fi

  if [[ "${ok}" -ne 1 ]]; then
    err "RESULTADO: TODAVIA ROTO. Revisa el Secret ${SECRET_NAME} en ${NAMESPACE}."
    exit 1
  fi
}

cmd_cleanup() {
  require_bin kubectl
  [[ -f "${PF_PID_FILE}" ]] && kill "$(cat "${PF_PID_FILE}")" >/dev/null 2>&1 || true
  rm -f "${PF_PID_FILE}"
  log "Borrando namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found
  rm -rf "${CERT_DIR}"
  log "Lab limpiado."
}

case "${1:-setup}" in
  setup)   cmd_setup "${2:-}" ;;
  verify)  cmd_verify ;;
  cleanup) cmd_cleanup ;;
  *) err "Uso: $0 {setup|verify|cleanup} [--yes]"; exit 1 ;;
esac

# ============================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
#
# 1) Diagnosticar: inspeccionar el Secret que el Ingress referencia.
#      kubectl -n cks-1-3-ingress-tls-lab get secret secure-cks-tls -o yaml
#    Vas a ver:
#      type: Opaque
#      data:
#        certificate.pem: ...
#        private.key: ...
#    Eso confirma el problema: para que un Ingress sirva TLS, Kubernetes
#    espera un Secret type=kubernetes.io/tls cuyas keys de "data" se
#    llamen EXACTAMENTE "tls.crt" y "tls.key" (referencia: doc de Ingress
#    TLS de Kubernetes y guia de TLS de ingress-nginx citadas arriba).
#    Como esos nombres no coinciden, el Ingress controller no puede
#    armar el keypair y cae al certificado default/fake.
#
# 2) Confirmar tambien el sintoma en runtime (opcional, ya lo hace "verify"):
#      kubectl -n <ns-del-controller> port-forward svc/<svc-del-controller> 18443:443 &
#      curl -kv --resolve secure.cks.local:18443:127.0.0.1 \
#        https://secure.cks.local:18443/ 2>&1 | grep -iE "subject:|issuer:"
#    El "subject:" va a mostrar el certificado fake del controller, no
#    CN=secure.cks.local.
#
# 3) Arreglar: recrear el Secret con el nombre y las keys correctas.
#    Los archivos de certificado/clave ya generados por "setup" siguen
#    en /tmp/cks-1-3-ingress-tls-lab-certs/ (tls.crt, tls.key):
#
#      kubectl -n cks-1-3-ingress-tls-lab delete secret secure-cks-tls
#
#      kubectl -n cks-1-3-ingress-tls-lab create secret tls secure-cks-tls \
#        --cert=/tmp/cks-1-3-ingress-tls-lab-certs/tls.crt \
#        --key=/tmp/cks-1-3-ingress-tls-lab-certs/tls.key
#
#    "kubectl create secret tls" arma automaticamente type=kubernetes.io/tls
#    con las keys tls.crt/tls.key, que es exactamente lo que faltaba. No
#    hace falta tocar el objeto Ingress: el spec.tls[].secretName ya
#    apuntaba al nombre correcto, el problema era pura y exclusivamente
#    la forma del Secret.
#
# 4) Confirmar el fix:
#      kubectl -n cks-1-3-ingress-tls-lab get secret secure-cks-tls -o jsonpath='{.type}{"\n"}'
#      # esperado: kubernetes.io/tls
#
#      ./cks-1.3-ingress-tls.sh verify
#      # esperado: "RESULTADO: ARREGLADO."
#
# 5) Nota para el examen: el mismo sintoma (certificado fake/default
#    servido por el Ingress controller) tambien aparece si el Secret
#    esta en el namespace equivocado (Secret e Ingress deben vivir en
#    el mismo namespace) o si spec.tls[].secretName tiene un typo. Ante
#    "el Ingress tiene TLS configurado pero el navegador/curl no ve mi
#    certificado", el orden de chequeo recomendado es: namespace del
#    Secret -> nombre del Secret -> type del Secret -> nombres de key
#    dentro de "data".
# ============================================================================