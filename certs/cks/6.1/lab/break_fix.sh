#!/usr/bin/env bash
#
# CKS v1.34 - Monitoring, Logging and Runtime Security
# Tema 6.1: Perform behavioral analytics to detect malicious activities (peso: 4)
# Fuente: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Script "break & fix". Deja un laboratorio con Falco en un estado roto de
# forma controlada para que practiques la detección y remediación del
# problema vos mismo. USAR SOLO EN UNA VM DE LABORATORIO DESCARTABLE.
#
# Requisitos previos en la VM (no los provee este script):
#   - Falco instalado y corriendo como servicio systemd
#     (instalación oficial: https://falco.org/docs/getting-started/installation/)
#   - kubectl configurado contra un cluster accesible (kind, minikube, etc.)
#
set -euo pipefail

RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

log()  { echo "${CYAN}[lab]${RESET} $*"; }
warn() { echo "${YELLOW}[lab]${RESET} $*"; }
err()  { echo "${RED}[lab] ERROR:${RESET} $*" >&2; }

FALCO_LOCAL_RULES="/etc/falco/falco_rules.local.yaml"
BACKUP_DIR="/root/.cks_6_1_lab_backup"
BACKUP_FILE="${BACKUP_DIR}/falco_rules.local.yaml.orig"
MARK_START="# >>> CKS-LAB-BREAK-6.1 >>>"
MARK_END="# <<< CKS-LAB-BREAK-6.1 <<<"
TEST_NS="cks-lab"
TEST_POD="behavioral-victim"

# --- 0. chequeos de seguridad -----------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "Este script tiene que correr como root (modifica /etc/falco)."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-unit-files 2>/dev/null | grep -q '^falco\.service'; then
  err "No se encontró el servicio systemd 'falco'. Instalá Falco antes de correr este lab:"
  err "  curl -s https://falco.org/script/install | bash"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1 || ! kubectl get nodes >/dev/null 2>&1; then
  err "No se pudo contactar un cluster con kubectl. Necesitás un cluster accesible (kind/minikube)."
  exit 1
fi

echo "${BOLD}${RED}=========================================================${RESET}"
echo "${BOLD}${RED} Este script rompe la detección de comportamiento de Falco${RESET}"
echo "${BOLD}${RED} en esta VM. Usalo SOLO en un laboratorio descartable.${RESET}"
echo "${BOLD}${RED}=========================================================${RESET}"
read -r -p "Escribí CONFIRMAR para continuar: " ans
if [[ "${ans}" != "CONFIRMAR" ]]; then
  log "Cancelado."
  exit 0
fi

# --- 1. asegurar que Falco esté corriendo antes de romper nada --------
systemctl start falco >/dev/null 2>&1 || true
sleep 2
if ! systemctl is-active --quiet falco; then
  err "Falco no logra arrancar de entrada (antes de tocar nada). Revisá 'journalctl -u falco' y arreglá eso primero."
  exit 1
fi
log "Falco está activo. Continuando con la ruptura del lab."

# --- 2. crear un pod de prueba para poder reproducir el síntoma -------
kubectl get ns "${TEST_NS}" >/dev/null 2>&1 || kubectl create ns "${TEST_NS}" >/dev/null
if ! kubectl -n "${TEST_NS}" get pod "${TEST_POD}" >/dev/null 2>&1; then
  log "Creando pod de prueba '${TEST_POD}' en el namespace '${TEST_NS}'..."
  kubectl -n "${TEST_NS}" run "${TEST_POD}" --image=busybox:stable --restart=Never -- sh -c "sleep 3600" >/dev/null
fi
kubectl -n "${TEST_NS}" wait --for=condition=Ready "pod/${TEST_POD}" --timeout=60s >/dev/null

# --- 3. backup del archivo de reglas locales de Falco ------------------
mkdir -p "${BACKUP_DIR}"
touch "${FALCO_LOCAL_RULES}"
if [[ ! -f "${BACKUP_FILE}" ]]; then
  cp "${FALCO_LOCAL_RULES}" "${BACKUP_FILE}"
  log "Backup del estado original guardado en ${BACKUP_FILE}"
fi

# --- 4. LA RUPTURA: desactivar silenciosamente una regla de Falco ------
if grep -q "${MARK_START}" "${FALCO_LOCAL_RULES}" 2>/dev/null; then
  warn "El lab ya estaba roto (marca CKS-LAB-BREAK-6.1 presente). No se vuelve a tocar el archivo."
else
  cat >>"${FALCO_LOCAL_RULES}" <<EOF
${MARK_START}
- rule: Terminal shell in container
  enabled: false
${MARK_END}
EOF
  log "Override aplicado en ${FALCO_LOCAL_RULES}"
fi

systemctl restart falco
sleep 2
if ! systemctl is-active --quiet falco; then
  err "Falco no volvió a arrancar tras el cambio. Revisá 'journalctl -u falco -n 50'."
  exit 1
fi

# --- 5. briefing para el estudiante -------------------------------------
cat <<EOF

${BOLD}${GREEN}Laboratorio listo.${RESET}

${BOLD}Contexto:${RESET}
Falco está corriendo (systemctl is-active falco = active), y en teoría
debería seguir generando alertas de comportamiento anómalo, como abrir
una shell interactiva dentro de un container (una técnica clásica post
compromiso: un atacante que ya obtuvo RCE suele abrir una shell para
moverse lateralmente).

${BOLD}Síntoma que vas a observar:${RESET}
Si ejecutás:

  kubectl -n ${TEST_NS} exec -it ${TEST_POD} -- sh

y después revisás los logs de Falco:

  journalctl -u falco -n 50 --no-pager

NO vas a ver ninguna alerta relacionada con la apertura de una shell en
un container, a pesar de que Falco está activo y sin errores visibles.
El engine de behavioral analytics está "ciego" ante ese comportamiento
puntual, aunque siga procesando y alertando sobre otras cosas.

${BOLD}Tu misión:${RESET}
1. Investigar por qué Falco no detecta la apertura de shells en
   containers, sin asumir que el servicio está "roto" (está activo).
2. Corregir la configuración para que la detección vuelva a funcionar.
3. Verificar el fix repitiendo el 'kubectl exec' de arriba y confirmando
   que aparece una alerta nueva en los logs de Falco (prioridad Notice,
   mensaje del estilo "A shell was spawned in a container...").

${BOLD}Pistas de dónde mirar (sin spoilear la solución):${RESET}
  - /etc/falco/falco.yaml -> qué archivos de reglas carga (rules_file)
  - Los archivos listados ahí, en particular los que no son el rule set
    por default de Falco.
  - El mecanismo de "rule overriding" de Falco permite redefinir el
    estado (enabled/disabled) de una regla existente sin tocar el
    archivo de reglas original.

No borres ni reinstales Falco: el problema es de configuración, no del
binario ni del servicio.

EOF

exit 0

# =========================================================================
# SOLUCIÓN PASO A PASO (comentada - no se ejecuta)
# =========================================================================
#
# 1) Confirmar que Falco está activo pero no genera la alerta esperada:
#      systemctl status falco
#      kubectl -n cks-lab exec -it behavioral-victim -- sh
#      journalctl -u falco -n 50 --no-pager   # sin alerta de shell
#
# 2) Revisar qué archivos de reglas carga Falco:
#      grep -A5 '^rules_file' /etc/falco/falco.yaml
#    Vas a ver algo como:
#      rules_file:
#        - /etc/falco/falco_rules.yaml
#        - /etc/falco/falco_rules.local.yaml
#        - /etc/falco/rules.d
#    falco_rules.local.yaml se carga DESPUÉS del rule set default, así
#    que cualquier regla redefinida ahí sobreescribe la original.
#
# 3) Inspeccionar ese archivo y encontrar el override sospechoso:
#      cat /etc/falco/falco_rules.local.yaml
#    Vas a encontrar un bloque:
#      - rule: Terminal shell in container
#        enabled: false
#    Esto usa el mecanismo de "rule overriding" de Falco: al declarar
#    de nuevo una regla existente por nombre, con solo el campo
#    'enabled', Falco actualiza esa regla en vez de reemplazarla
#    entera. Acá se usó para apagar en silencio la detección de shells
#    interactivas dentro de containers.
#
# 4) Arreglarlo. Dos formas válidas:
#      a) Editar el archivo y poner enabled: true
#           - rule: Terminal shell in container
#             enabled: true
#      b) O directamente borrar el bloque de override (así vuelve a
#         regir el 'enabled: true' que trae la regla por default):
#           sed -i '/# >>> CKS-LAB-BREAK-6.1 >>>/,/# <<< CKS-LAB-BREAK-6.1 <<</d' \
#             /etc/falco/falco_rules.local.yaml
#
# 5) Recargar Falco para que tome el cambio:
#      systemctl restart falco
#      systemctl is-active falco
#
# 6) Verificar la remediación reproduciendo el comportamiento:
#      kubectl -n cks-lab exec -it behavioral-victim -- sh
#      # (en otra terminal, en paralelo)
#      journalctl -fu falco
#    Debería aparecer una alerta de prioridad Notice con un mensaje del
#    tipo "A shell was spawned in a container with an attached
#    terminal", incluyendo container id, imagen y comando.
#
# 7) (Opcional) Restaurar el estado 100% original guardado por este
#    script antes de romper nada:
#      cp /root/.cks_6_1_lab_backup/falco_rules.local.yaml.orig \
#         /etc/falco/falco_rules.local.yaml
#      systemctl restart falco
#
# =========================================================================