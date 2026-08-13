#!/usr/bin/env bash
#
# ============================================================================
#  KCA — Kubernetes and Cloud Native Associate
#  Tema 1.2: YAML Manifests  (peso en el examen: 4.5)
#  Fuente: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
#
#  Laboratorio 'break & fix'  —  NIVEL: producción
#  ----------------------------------------------------------------------------
#  Este script ROMPE de forma controlada un Deployment escribiendo un manifiesto
#  YAML con tres defectos clásicos que aparecen todos los días en producción y
#  que el examen KCA evalúa directamente:
#
#    (1) un TAB en la indentación        -> error de PARSEO (el YAML ni carga)
#    (2) 'replicas' como string "2"      -> error de TIPO   (schema)
#    (3) 'ports' mal anidado             -> campo desconocido (schema)
#
#  El apiserver los reporta en CAPAS: primero muere el parser, y solo cuando el
#  documento carga aparecen los errores de schema. Aprender a pelar esas capas
#  de a una es la habilidad que se practica acá.
#
#  SEGURIDAD: el script NO crea, modifica ni borra ninguna carga real. Todo se
#  valida con --dry-run=server (o client como fallback). La única escritura es un
#  Namespace vacío y aislado. Está pensado para una VM de laboratorio DESCARTABLE
#  (kind / minikube / k3d). Aun así, rechaza contextos que parezcan de producción.
# ============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# Presentación (colores solo si hay TTY)
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

say()  { printf '%s\n' "$*"; }
head() { printf '\n%s══════ %s ══════%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s[STOP]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

NS="kca-lab-yaml"
LAB_DIR="${LAB_DIR:-$HOME/kca-lab/1.2-yaml-manifests}"
BROKEN="$LAB_DIR/deployment-roto.yaml"

# --------------------------------------------------------------------------
# 0. Precondiciones y guardas de seguridad
# --------------------------------------------------------------------------
head "0. Verificando el entorno de laboratorio"

command -v kubectl >/dev/null 2>&1 || die "kubectl no está en el PATH. Instalalo antes de continuar."

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "No hay un cluster accesible. Levantá uno descartable, p.ej.:  kind create cluster --name kca-lab"
fi

CTX="$(kubectl config current-context 2>/dev/null || echo '')"
say "Contexto actual de kubectl: ${BOLD}${CTX:-<desconocido>}${RESET}"

# Solo dejamos correr en contextos que parezcan de laboratorio. Esto evita
# que alguien ejecute el ejercicio, sin querer, apuntando a un cluster real.
case "$CTX" in
  kind-*|minikube|k3d-*|docker-desktop|*lab*|*test*|*dev*|*sandbox*)
    ok "Contexto reconocido como entorno descartable." ;;
  *)
    warn "El contexto '$CTX' NO parece de laboratorio."
    if [[ "${LAB_I_UNDERSTAND:-no}" != "yes" ]]; then
      die "Abortado por seguridad. Si de verdad es un cluster descartable, reejecutá con:  LAB_I_UNDERSTAND=yes $0"
    fi
    warn "Continuando bajo tu responsabilidad (LAB_I_UNDERSTAND=yes)." ;;
esac

# Detectamos si el server soporta dry-run=server (validación de campos completa).
DRYRUN="server"
if ! kubectl auth can-i create deployments -n default >/dev/null 2>&1; then
  DRYRUN="client"
  warn "Sin permiso de create; se usará --dry-run=client (validación de schema más limitada)."
fi

# Namespace aislado. Idempotente: si ya existe, no falla.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Namespace de laboratorio '$NS' listo (aislado y vacío)."

mkdir -p "$LAB_DIR"

# --------------------------------------------------------------------------
# 1. ROMPER — escribimos el manifiesto defectuoso
# --------------------------------------------------------------------------
head "1. Sembrando el manifiesto ROTO"

# TAB real inyectado con una variable dentro de un here-doc expandible.
# Es la única forma segura de meter un carácter de tabulación 'invisible'.
TAB=$'\t'

cat > "$BROKEN" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yaml-lab
  namespace: ${NS}
  labels:
    app: yaml-lab
spec:
  replicas: "2"
  selector:
    matchLabels:
      app: yaml-lab
  template:
    metadata:
      labels:
        app: yaml-lab
    spec:
      containers:
      - name: web
${TAB}image: nginx:1.27-alpine
      ports:
      - containerPort: 80
EOF

ok "Escrito: $BROKEN"
say "Contiene tres defectos deliberados (parseo + dos de schema)."

# --------------------------------------------------------------------------
# 2. SÍNTOMA — mostramos el error tal cual lo devuelve la API
# --------------------------------------------------------------------------
head "2. SÍNTOMA que vas a ver"

say "Ejecutando: ${CYAN}kubectl apply -f deployment-roto.yaml --dry-run=${DRYRUN}${RESET}"
say ""
# Capturamos stdout+stderr sin que 'set -e' nos mate: el fallo es esperado.
OUT="$(kubectl apply -f "$BROKEN" --dry-run="$DRYRUN" 2>&1 || true)"
printf '%s%s%s\n' "$RED" "$OUT" "$RESET"
say ""
say "Lo primero que ves es un error de ${BOLD}PARSEO${RESET}, del estilo:"
say "  ${RED}error converting YAML to JSON: yaml: line 20: found character that cannot start any token${RESET}"
say ""
say "Es el TAB de la línea del 'image:'. YAML PROHÍBE tabs en la indentación y son"
say "invisibles en el editor. Hasta que no lo saques, el documento no carga y el"
say "apiserver ni llega a mirar el schema."

# --------------------------------------------------------------------------
# 3. OBJETIVO — qué tenés que lograr
# --------------------------------------------------------------------------
head "3. Tu OBJETIVO"

cat <<EOF
Editá  ${BOLD}$BROKEN${RESET}  hasta que este comando salga LIMPIO (sin error, con 'created (dry run)'):

    ${CYAN}kubectl apply -f "$BROKEN" --dry-run=${DRYRUN}${RESET}

Vas a tener que arreglar TRES cosas, y aparecen de a una (por capas):

  ${YELLOW}Capa 1 (parseo):${RESET}  encontrá y eliminá el TAB de indentación.
                     Pista para hacerlo visible:  ${CYAN}cat -A "$BROKEN"${RESET}
                     El TAB se muestra como '^I'. Reemplazalo por 8 espacios.

  ${YELLOW}Capa 2 (tipo):${RESET}    'replicas' tiene que ser un ENTERO, no un string.
                     Reejecutá el apply y leé el error 'cannot unmarshal string
                     ... into ... int32'. Sacale las comillas: replicas: 2

  ${YELLOW}Capa 3 (anidado):${RESET} 'ports' está colgando del Pod spec, no del container.
                     El error dirá 'unknown field "spec.template.spec.ports"'.
                     'ports' es una propiedad DEL container: hay que indentarlo
                     dentro del ítem '- name: web'.

Cuando el dry-run pase, aplicalo de verdad y comprobá que el Pod arranca:

    ${CYAN}kubectl apply -f "$BROKEN"
    kubectl -n $NS rollout status deployment/yaml-lab
    kubectl -n $NS get pods -o wide${RESET}

Criterio de éxito: 1 Deployment 'yaml-lab' con 2 réplicas ${GREEN}Running${RESET} y el
puerto 80 declarado en el container (verificable con
'kubectl -n $NS get deploy yaml-lab -o jsonpath='{.spec.template.spec.containers[0].ports}'').
EOF

head "Limpieza"
say "Cuando termines, borrá todo el laboratorio con:"
say "    ${CYAN}kubectl delete namespace $NS${RESET}"
say ""
say "La solución completa está comentada al final de este mismo script."
say "Intentá resolverlo vos ANTES de mirarla."

exit 0

# ============================================================================
#  SOLUCIÓN — paso a paso  (no la mires hasta haberlo intentado)
# ============================================================================
#
#  Estrategia general: el error del apiserver siempre apunta a la PRIMERA capa
#  que falla. Arreglás esa, reejecutás el dry-run, y el server te muestra la
#  siguiente. Es un bucle: apply --dry-run -> leer -> corregir -> repetir.
#
#  ------------------------------------------------------------------------
#  Paso 1 — Capa de PARSEO: el TAB invisible
#  ------------------------------------------------------------------------
#  Síntoma:
#     error converting YAML to JSON: yaml: line 20: found character that
#     cannot start any token
#
#  Diagnóstico — hacé visibles los caracteres de control:
#     cat -A deployment-roto.yaml
#  La línea del 'image:' aparece como:
#     ^Iimage: nginx:1.27-alpine        <-- '^I' es un TAB
#  (equivalente: sed -n '20l' deployment-roto.yaml  también muestra \t)
#
#  Corrección — convertí ese TAB en 8 espacios para que 'image' quede al mismo
#  nivel que 'name' dentro del ítem del container:
#     sed -i 's/\timage:/        image:/' deployment-roto.yaml
#  Regla de oro: en manifiestos K8s se usan SIEMPRE 2 espacios por nivel y
#  NUNCA tabs. Configurá tu editor con 'expandtab'.
#
#  ------------------------------------------------------------------------
#  Paso 2 — Capa de TIPO: replicas como string
#  ------------------------------------------------------------------------
#  Reejecutá:  kubectl apply -f deployment-roto.yaml --dry-run=server
#  Síntoma:
#     Error ... cannot unmarshal string into Go struct field
#     DeploymentSpec.spec.replicas of type int32
#
#  Causa: "2" (con comillas) es un string en YAML; el campo spec.replicas es un
#  int32. YAML tipa por sintaxis: 2 es entero, "2" es texto. (El mismo mecanismo
#  detrás del 'Norway problem': NO/yes/on se interpretan como booleanos si no se
#  citan — acá el problema es el inverso, se citó algo que debía ser número.)
#
#  Corrección — sacá las comillas:
#     replicas: 2
#
#  ------------------------------------------------------------------------
#  Paso 3 — Capa de ANIDADO: 'ports' fuera del container
#  ------------------------------------------------------------------------
#  Reejecutá el dry-run. Síntoma:
#     error: error validating data: ValidationError(Deployment.spec.template.spec):
#     unknown field "ports"        (o: strict decoding error: unknown field
#     "spec.template.spec.ports")
#
#  Causa: 'ports' quedó al mismo nivel que 'containers', es decir colgando del
#  PodSpec. Pero 'ports' es una propiedad de CADA container, no del Pod. La
#  indentación en YAML ES la estructura: dos espacios de más o de menos cambian
#  de quién es hijo cada campo.
#
#  Corrección — movelo DENTRO del ítem '- name: web', alineado con 'image'.
#
#  ------------------------------------------------------------------------
#  Manifiesto CORRECTO final (deployment-roto.yaml ya arreglado):
#  ------------------------------------------------------------------------
#     apiVersion: apps/v1
#     kind: Deployment
#     metadata:
#       name: yaml-lab
#       namespace: kca-lab-yaml
#       labels:
#         app: yaml-lab
#     spec:
#       replicas: 2
#       selector:
#         matchLabels:
#           app: yaml-lab
#       template:
#         metadata:
#           labels:
#             app: yaml-lab
#         spec:
#           containers:
#           - name: web
#             image: nginx:1.27-alpine
#             ports:
#             - containerPort: 80
#
#  ------------------------------------------------------------------------
#  Verificación final:
#  ------------------------------------------------------------------------
#     # 1) El dry-run pasa sin errores:
#     kubectl apply -f deployment-roto.yaml --dry-run=server
#     #   -> deployment.apps/yaml-lab created (server dry run)
#
#     # 2) Aplicá de verdad y esperá el rollout:
#     kubectl apply -f deployment-roto.yaml
#     kubectl -n kca-lab-yaml rollout status deployment/yaml-lab
#     #   -> deployment "yaml-lab" successfully rolled out
#
#     # 3) Confirmá réplicas y puerto:
#     kubectl -n kca-lab-yaml get deploy yaml-lab
#     #   -> READY 2/2
#     kubectl -n kca-lab-yaml get deploy yaml-lab \
#       -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}{"\n"}'
#     #   -> 80
#
#  ------------------------------------------------------------------------
#  Herramientas para NO repetir estos errores (validación antes de aplicar):
#  ------------------------------------------------------------------------
#     kubectl apply -f m.yaml --dry-run=server        # valida schema server-side
#     kubectl apply -f m.yaml --dry-run=client --validate=strict
#     yamllint m.yaml                                 # detecta tabs y mala indentación
#     kubeconform -strict -summary m.yaml             # valida contra el schema OpenAPI
#
#  ------------------------------------------------------------------------
#  Limpieza del laboratorio:
#  ------------------------------------------------------------------------
#     kubectl delete namespace kca-lab-yaml
#
#  Referencia oficial del temario:
#     https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
# ============================================================================