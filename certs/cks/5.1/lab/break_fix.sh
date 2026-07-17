#!/usr/bin/env bash
#
# CKS v1.34 - Break & Fix Lab
# Dominio: System Hardening
# Tema 5.1: Minimize host OS footprint (reduce attack surface)
# Peso en el examen: 2.5
#
# Fuente de referencia (curriculum oficial):
#   https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# USO (correr como root o con sudo, en una VM de laboratorio DESCARTABLE):
#   sudo ./cks-5.1-break-fix.sh break     -> rompe el escenario y muestra el enunciado
#   sudo ./cks-5.1-break-fix.sh verify    -> chequea si ya resolviste el laboratorio
#
# Este script NO incluye un comando "fix" automático a propósito: la resolución
# es parte del ejercicio. La solución paso a paso está comentada al final del
# archivo para que la leas después de intentarlo.

set -euo pipefail

LAB_TAG="cks-5.1"
UNIT_FTP="cks-legacy-ftpd.service"
UNIT_TELNET="cks-legacy-telnetd.service"
LIB_DIR="/usr/local/lib/${LAB_TAG}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.${LAB_TAG}.bak"

# --- Guardas de seguridad ---------------------------------------------------

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: corré este script como root (sudo)." >&2
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: este script asume una distro con systemd (ej. Ubuntu)." >&2
    exit 1
  fi
}

require_disposable_vm_confirmation() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-}" == "yes" ]]; then
    return 0
  fi
  cat <<'EOF'
ATENCION: este script modifica sshd_config y crea servicios de red falsos
que quedan escuchando en puertos 21 y 23. Corré esto SOLO en una VM de
laboratorio descartable, nunca en un host real o compartido.

Si estás seguro, volvé a ejecutar con:
  I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes sudo -E ./cks-5.1-break-fix.sh break
EOF
  exit 1
}

find_python3() {
  command -v python3 2>/dev/null || {
    echo "ERROR: se necesita python3 para simular los servicios legacy." >&2
    exit 1
  }
}

find_ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
  else
    echo "ERROR: no se encontró el servicio de sshd (ni ssh.service ni sshd.service)." >&2
    exit 1
  fi
}

# --- Acción: break -----------------------------------------------------------

do_break() {
  require_root
  require_systemd
  require_disposable_vm_confirmation
  local py
  py="$(find_python3)"
  local ssh_svc
  ssh_svc="$(find_ssh_service_name)"

  mkdir -p "${LIB_DIR}"

  cat > "${LIB_DIR}/fake-ftpd.py" <<'PYEOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 21))
s.listen(5)
while True:
    conn, _ = s.accept()
    try:
        conn.sendall(b"220 (vsFTPd 3.0.3)\r\n")
    finally:
        conn.close()
PYEOF

  cat > "${LIB_DIR}/fake-telnetd.py" <<'PYEOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 23))
s.listen(5)
while True:
    conn, _ = s.accept()
    try:
        conn.sendall(b"Debian GNU/Linux 12\r\nlogin: ")
    finally:
        conn.close()
PYEOF

  cat > "/etc/systemd/system/${UNIT_FTP}" <<EOF
[Unit]
Description=Legacy FTP daemon (lab-injected, CKS 5.1)

[Service]
ExecStart=${py} ${LIB_DIR}/fake-ftpd.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${UNIT_TELNET}" <<EOF
[Unit]
Description=Legacy Telnet daemon (lab-injected, CKS 5.1)

[Service]
ExecStart=${py} ${LIB_DIR}/fake-telnetd.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${UNIT_FTP}" "${UNIT_TELNET}"

  if [[ ! -f "${SSHD_BACKUP}" ]]; then
    cp "${SSHD_CONFIG}" "${SSHD_BACKUP}"
  fi

  if grep -qi '^PermitRootLogin' "${SSHD_CONFIG}"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/I' "${SSHD_CONFIG}"
  else
    echo "PermitRootLogin yes" >> "${SSHD_CONFIG}"
  fi

  if grep -qi '^PasswordAuthentication' "${SSHD_CONFIG}"; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/I' "${SSHD_CONFIG}"
  else
    echo "PasswordAuthentication yes" >> "${SSHD_CONFIG}"
  fi

  systemctl restart "${ssh_svc}"

  cat <<EOF

============================================================
LAB ROTO: CKS 5.1 - Minimize host OS footprint
============================================================

SINTOMA:
Te pidieron auditar este nodo antes de sumarlo a un cluster de
Kubernetes productivo. Al escanear la máquina con herramientas
como 'ss', 'nmap' o 'systemctl', vas a notar:

  - Puertos TCP escuchando que no deberían estar ahí.
  - Unidades systemd corriendo que no forman parte de un nodo
    de Kubernetes estándar (kubelet, containerd, sshd, etc.).
  - La configuración de sshd permite un método de acceso remoto
    que amplía innecesariamente la superficie de ataque del host.

OBJETIVO (qué tenés que lograr):
  1. Que no queden puertos ni servicios de red innecesarios
     escuchando en el host (footprint mínimo).
  2. Que las unidades systemd inyectadas por este lab queden
     detenidas, deshabilitadas y sin poder reactivarse por accidente.
  3. Que sshd esté configurado de forma más restrictiva respecto
     al acceso remoto (login y autenticación).
  4. Que sshd siga funcionando (no te dejes afuera de la VM).

Corré:
  sudo ./cks-5.1-break-fix.sh verify
para autoevaluarte sin ver la solución.
EOF
}

# --- Acción: verify ------------------------------------------------------

do_verify() {
  require_root
  require_systemd
  local ssh_svc
  ssh_svc="$(find_ssh_service_name)"
  local ok=1

  echo "Verificando objetivos del lab CKS 5.1..."
  echo

  if ss -H -tulpn 2>/dev/null | grep -qE ':21\s'; then
    echo "[FAIL] Sigue habiendo algo escuchando en el puerto 21."
    ok=0
  else
    echo "[PASS] Puerto 21 cerrado."
  fi

  if ss -H -tulpn 2>/dev/null | grep -qE ':23\s'; then
    echo "[FAIL] Sigue habiendo algo escuchando en el puerto 23."
    ok=0
  else
    echo "[PASS] Puerto 23 cerrado."
  fi

  for unit in "${UNIT_FTP}" "${UNIT_TELNET}"; do
    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
      echo "[FAIL] ${unit} sigue activo."
      ok=0
    else
      echo "[PASS] ${unit} no está activo."
    fi
  done

  if command -v sshd >/dev/null 2>&1; then
    if sshd -T 2>/dev/null | grep -qi '^permitrootlogin no'; then
      echo "[PASS] PermitRootLogin está en 'no'."
    else
      echo "[FAIL] PermitRootLogin no está en 'no'."
      ok=0
    fi
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
      echo "[PASS] PasswordAuthentication está en 'no'."
    else
      echo "[FAIL] PasswordAuthentication no está en 'no'."
      ok=0
    fi
  else
    echo "[WARN] no se encontró el binario 'sshd' para validar la config."
  fi

  if systemctl is-active --quiet "${ssh_svc}"; then
    echo "[PASS] El servicio ${ssh_svc} sigue activo (no te dejaste afuera)."
  else
    echo "[FAIL] El servicio ${ssh_svc} no está activo."
    ok=0
  fi

  echo
  if [[ "${ok}" -eq 1 ]]; then
    echo "RESULTADO: todos los objetivos cumplidos."
  else
    echo "RESULTADO: todavía hay objetivos pendientes."
  fi
}

# --- Main --------------------------------------------------------------

case "${1:-}" in
  break)
    do_break
    ;;
  verify)
    do_verify
    ;;
  *)
    echo "Uso: $0 {break|verify}" >&2
    exit 1
    ;;
esac

# =============================================================================
# SOLUCION PASO A PASO (leer solo después de intentar resolverlo)
# =============================================================================
#
# 1. Relevar qué está escuchando en la red y qué servicios corren de más:
#      sudo ss -tulpn
#      sudo systemctl list-units --type=service --state=running | grep -i cks-legacy
#
# 2. Detener, deshabilitar y bloquear los servicios legacy inyectados por el lab:
#      sudo systemctl stop cks-legacy-ftpd.service cks-legacy-telnetd.service
#      sudo systemctl disable cks-legacy-ftpd.service cks-legacy-telnetd.service
#      sudo systemctl mask cks-legacy-ftpd.service cks-legacy-telnetd.service
#
# 3. (Opcional, para dejar el filesystem limpio) borrar las unidades y el
#    código que las respalda:
#      sudo rm -f /etc/systemd/system/cks-legacy-ftpd.service
#      sudo rm -f /etc/systemd/system/cks-legacy-telnetd.service
#      sudo rm -rf /usr/local/lib/cks-5.1
#      sudo systemctl daemon-reload
#
# 4. Restringir el acceso remoto en sshd_config
#    (/etc/ssh/sshd_config o un archivo en /etc/ssh/sshd_config.d/):
#      sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
#      sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
#      sudo sshd -t                # valida sintaxis antes de reiniciar
#      sudo systemctl restart ssh  # en Ubuntu/Debian el unit se llama "ssh"
#
# 5. Confirmar que el footprint quedó minimizado:
#      sudo ss -tulpn | grep -E ':21|:23'      # sin salida
#      sudo sshd -T | grep -i permitrootlogin  # "permitrootlogin no"
#      sudo sshd -T | grep -i passwordauthentication  # "passwordauthentication no"
#
# Nota conceptual (CKS 5.1): un host de Kubernetes debe correr únicamente
# los servicios que necesita (kubelet, container runtime, sshd si aplica) y
# nada más. Cada demonio, puerto abierto o protocolo inseguro adicional
# (FTP, Telnet, root por SSH con password) es superficie de ataque extra
# que no aporta valor al cluster y que un atacante puede explotar para
# moverse lateralmente desde el nodo comprometido.