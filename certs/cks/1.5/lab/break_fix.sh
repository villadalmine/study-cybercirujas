#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CKS 1.34 - Dominio: Cluster Setup
# Tema 1.5: Verify platform binaries before deploying (peso examen: 3)
# Lab tipo "break & fix"
#
# Fuente de referencia (curricula oficial CKS):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Que practica este lab:
#   Antes de instalar/actualizar binarios de la plataforma (kubeadm,
#   kubelet, kubectl, etc.) hay que verificar su integridad contra los
#   checksums SHA-256 publicados por upstream, tal como lo documenta:
#   https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#verify-kubectl-binary
#   Instalar un binario sin verificar es la puerta de entrada clasica de
#   un ataque a la cadena de suministro (mirror comprometido, MITM,
#   descarga incompleta/corrupta, etc.).
#
# SEGURIDAD DEL LAB:
#   - No requiere privilegios de root.
#   - No toca rutas del sistema (/usr/local/bin, /usr/bin, systemd, etc.).
#   - Todo el estado vive bajo $HOME/cks-lab/1.5-verify-binaries.
#   - Los "binarios" son stand-ins inofensivos (scripts de shell), NO
#     kubeadm/kubelet/kubectl reales. Igual asi, corre esto solo en una
#     VM de laboratorio descartable, nunca en un nodo de un cluster real.
#
# Uso:
#   CKS_LAB_CONFIRM=si ./break-fix-1.5-verify-binaries.sh break
#   ./break-fix-1.5-verify-binaries.sh status
#   ./break-fix-1.5-verify-binaries.sh grade
#   ./break-fix-1.5-verify-binaries.sh reset
# ============================================================

LAB_ROOT="${CKS_LAB_ROOT:-$HOME/cks-lab/1.5-verify-binaries}"
REFERENCE_DIR="$LAB_ROOT/reference"
INCOMING_DIR="$LAB_ROOT/incoming"
INSTALLED_DIR="$LAB_ROOT/installed"
BIN_NAMES=(kubeadm kubelet kubectl)

require_confirmation() {
  if [[ "${CKS_LAB_CONFIRM:-}" != "si" ]]; then
    cat <<EOF
Este comando (re)genera y "rompe" archivos bajo:
  $LAB_ROOT
No toca nada fuera de esa carpeta ni requiere root, pero esta pensado
para una VM de laboratorio descartable, no para tu maquina de trabajo
ni para un nodo de un cluster real.

Si estas de acuerdo, volve a ejecutar asi:
  CKS_LAB_CONFIRM=si $0 break
EOF
    exit 1
  fi
}

setup_release() {
  mkdir -p "$REFERENCE_DIR" "$INCOMING_DIR"
  for name in "${BIN_NAMES[@]}"; do
    local ref="$REFERENCE_DIR/$name"
    {
      printf '#!/bin/sh\n'
      printf '# cks-lab stand-in de "%s" (NO es un binario real de Kubernetes)\n' "$name"
      printf '# relleno para que el archivo tenga contenido no trivial:\n'
      printf '# %s\n' "$(head -c 256 /dev/urandom | base64 | tr -d '\n')"
      printf 'echo "cks-lab: %s (stand-in) ejecutado correctamente"\n' "$name"
    } > "$ref"
    chmod +x "$ref"
    sha256sum "$ref" | awk '{print $1}' > "$ref.sha256"
    cp "$ref" "$INCOMING_DIR/$name"
    cp "$ref.sha256" "$INCOMING_DIR/$name.sha256"
  done
}

tamper_one_binary() {
  local victim_index=$(( RANDOM % ${#BIN_NAMES[@]} ))
  local victim="${BIN_NAMES[$victim_index]}"
  # Simula corrupcion en transito / manipulacion por un mirror comprometido:
  # el archivo cambia pero el .sha256 que lo acompaña sigue siendo el original.
  printf '\n# corrupted-in-transit-%s\n' "$RANDOM" >> "$INCOMING_DIR/$victim"
}

print_break_banner() {
  cat <<EOF

=== LAB CKS 1.5 - Verify platform binaries before deploying ===

Escenario:
  Sos el operador de un cluster y acabas de "descargar" tres binarios de
  la plataforma (kubeadm, kubelet, kubectl) para actualizar un nodo. La
  politica de tu organizacion exige verificar su integridad contra los
  checksums SHA-256 oficiales ANTES de instalarlos.

Donde esta todo:
  $INCOMING_DIR/      -> lo que "descargaste" (kubeadm, kubelet, kubectl
                          + un archivo <nombre>.sha256 por cada uno)
  $REFERENCE_DIR/     -> representa la fuente oficial (equivalente a
                          dl.k8s.io) - no la copies a ciegas, es solo
                          para que en este lab exista un "origen" al que
                          volver si necesitas re-descargar algo.

Sintoma:
  Uno de los tres binarios en incoming/ fue corrompido o manipulado en
  transito. No sabes cual hasta que lo verifiques: puede arrancar sin
  errores visibles, el problema NO es obvio a simple vista.

Objetivo (que tenes que lograr):
  1. Verificar los tres binarios de incoming/ contra su .sha256
     correspondiente (mismo mecanismo que documenta upstream para
     kubectl: sha256sum --check).
  2. Identificar cual de los tres fallo la verificacion.
  3. Conseguir una copia integra de ese binario (en este lab, restaurala
     desde $REFERENCE_DIR/) y volver a verificar TODO.
  4. Recien cuando los tres pasen la verificacion, "desplegarlos"
     copiandolos a:
       $INSTALLED_DIR/
  5. Correr: $0 grade

Regla de oro: nunca copies un binario a installed/ sin haberlo verificado
primero contra su checksum oficial.
EOF
}

break_scenario() {
  require_confirmation
  rm -rf -- "$LAB_ROOT"
  setup_release
  tamper_one_binary
  print_break_banner
}

status() {
  echo "== $INCOMING_DIR =="
  ls -la "$INCOMING_DIR" 2>/dev/null || echo "  (vacio; corre primero: break)"
  echo
  echo "== $INSTALLED_DIR =="
  ls -la "$INSTALLED_DIR" 2>/dev/null || echo "  (vacio; todavia no desplegaste nada)"
}

grade() {
  local all_ok=1
  for name in "${BIN_NAMES[@]}"; do
    local installed="$INSTALLED_DIR/$name"
    local expected=""
    [[ -f "$REFERENCE_DIR/$name.sha256" ]] && expected="$(cat "$REFERENCE_DIR/$name.sha256")"

    if [[ ! -f "$installed" ]]; then
      echo "[FALTA] $name no fue desplegado en $INSTALLED_DIR"
      all_ok=0
      continue
    fi

    local actual
    actual="$(sha256sum "$installed" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      echo "[OK]   $name verificado e instalado correctamente"
    else
      echo "[FAIL] $name instalado NO coincide con el checksum oficial"
      all_ok=0
    fi
  done

  echo
  if [[ "$all_ok" -eq 1 ]]; then
    echo "PASS: los tres binarios fueron verificados antes de desplegarlos."
  else
    echo "FAIL: todavia hay binarios sin verificar o mal instalados."
    echo "Revisa $INCOMING_DIR/*.sha256 con sha256sum --check antes de copiar a $INSTALLED_DIR."
    exit 1
  fi
}

reset_lab() {
  [[ -n "$LAB_ROOT" ]] || { echo "LAB_ROOT vacio, aborto por seguridad."; exit 1; }
  rm -rf -- "$LAB_ROOT"
  echo "Lab reseteado: $LAB_ROOT"
}

usage() {
  cat <<EOF
Uso: $0 {break|status|grade|reset}

  break   Genera el escenario y corrompe un binario (requiere CKS_LAB_CONFIRM=si)
  status  Muestra el estado actual de incoming/ e installed/
  grade   Verifica si resolviste el lab correctamente
  reset   Borra todo el estado del lab ($LAB_ROOT)
EOF
}

case "${1:-}" in
  break)  break_scenario ;;
  status) status ;;
  grade)  grade ;;
  reset)  reset_lab ;;
  *)      usage ;;
esac

# ============================================================
# SOLUCION PASO A PASO (referencia para autocorregirte; no hace falta
# ejecutar esto para que el lab funcione, es la guia si quedaste trabado)
# ============================================================
#
# 1) Verificar los tres binarios descargados contra su SHA-256, con el
#    mismo mecanismo que documenta upstream para kubectl/kubeadm/kubelet:
#    https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#verify-kubectl-binary
#
#      cd ~/cks-lab/1.5-verify-binaries/incoming
#      for f in kubeadm kubelet kubectl; do
#        echo "== $f =="
#        echo "$(cat "$f.sha256")  $f" | sha256sum --check
#      done
#
#    Vas a ver algo como:
#      kubeadm: OK
#      kubelet: FAILED
#      kubectl: OK
#    (cual de los tres falla varia entre corridas del lab, es aleatorio)
#
# 2) El binario que dio FAILED esta corrompido/manipulado: NO se instala
#    tal como esta. En este lab, la "fuente oficial" esta simulada en
#    reference/; en un cluster real volverias a descargarlo desde
#    dl.k8s.io/release/<version>/bin/linux/amd64/<binario> junto con su
#    <binario>.sha256 publicado ahi mismo, y jamas confiarias en el mismo
#    mirror sin volver a verificar la nueva copia.
#
#      cp ../reference/kubelet ./kubelet   # sustituir <binario> segun cual haya fallado
#
# 3) Volver a verificar TODO antes de instalar (no asumir que porque uno
#    se arreglo, el resto sigue bien):
#
#      for f in kubeadm kubelet kubectl; do
#        echo "$(cat "$f.sha256")  $f" | sha256sum --check
#      done
#
# 4) Recien ahi "desplegar" (copiar) los tres binarios ya verificados:
#
#      mkdir -p ../installed
#      cp kubeadm kubelet kubectl ../installed/
#
# 5) Confirmar la resolucion:
#
#      cd ~/cks-lab/1.5-verify-binaries
#      ./break-fix-1.5-verify-binaries.sh grade
#
# Nota de examen: la misma logica aplica a los tarballs completos de
# release (checksums SHA-512 publicados en CHANGELOG-<version>.md del
# repo kubernetes/kubernetes) y, desde Kubernetes 1.24+, los artefactos
# de release tambien tienen firmas cosign/sigstore ademas de los
# checksums SHA-256/512.
# Fuente: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf