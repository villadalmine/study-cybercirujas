#!/usr/bin/env bash
#
# CKS v1.34 - Dominio: Cluster Hardening
# Tema 1.4: Protect node metadata and endpoints (peso examen: 3)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# BREAK & FIX
# -----------
# Rompe: la Kubelet API queda accesible SIN autenticacion ni autorizacion
# (anonymous-auth habilitado + authorization-mode AlwaysAllow) y se abre
# el puerto read-only 10255, que sirve datos del nodo/pods en texto plano
# y sin ningun control de acceso.
#
# Esto reproduce una violacion directa de los checks CIS Kubernetes Benchmark:
#   4.2.1 Ensure --anonymous-auth is set to false
#   4.2.2 Ensure --authorization-mode is not set to AlwaysAllow
#   4.2.4 Ensure --read-only-port is set to 0
#
# ADVERTENCIA: ejecutar SOLO como root en una VM de laboratorio descartable
# (nodo de un cluster kubeadm de practica). Este script modifica la
# configuracion de kubelet y reinicia el servicio. No usar en un cluster real.
#
# Uso:
#   sudo ./break-fix-1.4-node-endpoints.sh break --yes
#   sudo ./break-fix-1.4-node-endpoints.sh restore
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
BACKUP_ROOT="/root/cks-1.4-lab-backups"
LATEST_BACKUP_LINK="${BACKUP_ROOT}/latest"

usage() {
  cat <<EOF
Uso: ${SCRIPT_NAME} <break|restore> [--yes]

  break    Rompe la Kubelet API del nodo (anonymous-auth + AlwaysAllow + puerto 10255).
  restore  Restaura la configuracion original de kubelet desde el ultimo backup.

  --yes    Omite la confirmacion interactiva (solo para VMs de laboratorio descartables).
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Este script debe ejecutarse como root." >&2
    exit 1
  fi
}

confirm_lab_vm() {
  local auto_yes="$1"
  if [[ "${auto_yes}" == "yes" ]]; then
    return 0
  fi
  echo "Este script modifica la configuracion de kubelet y reinicia el servicio."
  echo "Debe correrse UNICAMENTE en una VM de laboratorio descartable."
  read -r -p "Confirmas que esta VM es descartable y no es un cluster real? [escribi 'si']: " ans
  if [[ "${ans}" != "si" ]]; then
    echo "Cancelado."
    exit 1
  fi
}

find_kubelet_config() {
  local cfg
  cfg="$(ps -ef | grep '[k]ubelet' | grep -oP '(?<=--config=)\S+' | head -n1 || true)"
  if [[ -z "${cfg}" ]]; then
    cfg="/var/lib/kubelet/config.yaml"
  fi
  if [[ ! -f "${cfg}" ]]; then
    echo "No se encontro el archivo de configuracion de kubelet (probado: ${cfg})." >&2
    echo "Ajusta la variable KUBELET_CONFIG en el script para tu distro/instalacion." >&2
    exit 1
  fi
  echo "${cfg}"
}

backup_config() {
  local cfg="$1"
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  local dir="${BACKUP_ROOT}/${ts}"
  mkdir -p "${dir}"
  cp -a "${cfg}" "${dir}/config.yaml.orig"
  ln -sfn "${dir}" "${LATEST_BACKUP_LINK}"
  echo "Backup guardado en: ${dir}/config.yaml.orig"
}

break_kubelet() {
  local cfg="$1"

  echo "Aplicando configuracion insegura en ${cfg} ..."
  python3 - "${cfg}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

out = []
changed = {"anon": False, "authz": False, "roport": False}
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    out.append(line)

    if re.match(r'^\s*anonymous:\s*$', line) and i + 1 < n:
        nxt = lines[i + 1]
        if re.search(r'enabled:\s*false', nxt):
            indent = re.match(r'^(\s*)', nxt).group(1)
            out.append(f"{indent}enabled: true\n")
            i += 1
            changed["anon"] = True
    elif re.match(r'^\s*mode:\s*Webhook\s*$', line):
        indent = re.match(r'^(\s*)', line).group(1)
        out[-1] = f"{indent}mode: AlwaysAllow\n"
        changed["authz"] = True
    elif re.match(r'^\s*readOnlyPort:\s*0\s*$', line):
        indent = re.match(r'^(\s*)', line).group(1)
        out[-1] = f"{indent}readOnlyPort: 10255\n"
        changed["roport"] = True

    i += 1

if not changed["roport"]:
    out.append("readOnlyPort: 10255\n")
    changed["roport"] = True

with open(path, "w") as f:
    f.writelines(out)

if not (changed["anon"] and changed["authz"]):
    print("ADVERTENCIA: no se pudieron localizar las claves esperadas "
          "(anonymous/enabled o authorization/mode) en el formato usual "
          "de kubeadm. Revisa el archivo manualmente.", file=sys.stderr)
PY

  echo "Reiniciando kubelet ..."
  systemctl daemon-reload
  systemctl restart kubelet
  sleep 5

  if ! systemctl is-active --quiet kubelet; then
    echo "kubelet no arranco. Revisa: journalctl -u kubelet -n 100" >&2
    exit 1
  fi
}

show_symptom() {
  echo
  echo "=== SINTOMA ==="
  local code_10250 code_10255
  code_10250="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:10250/pods || echo '000')"
  code_10255="$(curl -s  -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:10255/pods  || echo '000')"

  echo "curl -sk https://127.0.0.1:10250/pods  -> HTTP ${code_10250}  (deberia dar 401 Unauthorized; hoy responde con datos)"
  echo "curl -s  http://127.0.0.1:10255/pods   -> HTTP ${code_10255}  (puerto read-only; deberia estar cerrado/000)"
  echo
  echo "Cualquier proceso en la red del nodo (incluido un Pod comprometido"
  echo "con hostNetwork o acceso a la IP del nodo) puede leer /pods, /stats,"
  echo "/exec, /run, etc. sin presentar ninguna credencial."
  echo
  echo "=== TU TAREA ==="
  echo "Sin ejecutar 'restore', dejar la Kubelet API del nodo endurecida:"
  echo "  1. La API en :10250 debe volver a exigir autenticacion y autorizacion"
  echo "     (una request sin credenciales debe devolver 401, no datos)."
  echo "  2. El puerto read-only :10255 debe quedar deshabilitado."
  echo "  3. kubelet debe seguir activo despues del cambio."
  echo "Pista: la configuracion vive en ${KUBELET_CONFIG_PATH}."
  echo "Verifica repitiendo los dos curl de arriba: 10250 debe dar 401 y"
  echo "10255 debe fallar la conexion."
  echo
}

restore_config() {
  if [[ ! -e "${LATEST_BACKUP_LINK}/config.yaml.orig" ]]; then
    echo "No hay backup disponible en ${LATEST_BACKUP_LINK}." >&2
    exit 1
  fi
  local cfg
  cfg="$(find_kubelet_config)"
  cp -a "${LATEST_BACKUP_LINK}/config.yaml.orig" "${cfg}"
  systemctl daemon-reload
  systemctl restart kubelet
  sleep 5
  echo "Configuracion original restaurada desde ${LATEST_BACKUP_LINK}/config.yaml.orig"
}

main() {
  local action="${1:-}"
  local auto_yes="no"
  [[ "${2:-}" == "--yes" ]] && auto_yes="yes"

  case "${action}" in
    break)
      require_root
      confirm_lab_vm "${auto_yes}"
      KUBELET_CONFIG_PATH="$(find_kubelet_config)"
      backup_config "${KUBELET_CONFIG_PATH}"
      break_kubelet "${KUBELET_CONFIG_PATH}"
      show_symptom
      ;;
    restore)
      require_root
      restore_config
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

# ============================================================================
# SOLUCION PASO A PASO (no se ejecuta; guia para el instructor/estudiante)
# ============================================================================
#
# 1. Ubicar el archivo de configuracion de kubelet (kubeadm por defecto):
#      /var/lib/kubelet/config.yaml
#    (si kubelet corre con --config=<ruta>, usar esa ruta)
#
# 2. Editarlo y corregir las tres claves comprometidas:
#
#      authentication:
#        anonymous:
#          enabled: false        # antes: true
#        webhook:
#          enabled: true
#      authorization:
#        mode: Webhook            # antes: AlwaysAllow
#      readOnlyPort: 0             # antes: 10255
#
# 3. Aplicar el cambio reiniciando el servicio:
#      sudo systemctl daemon-reload
#      sudo systemctl restart kubelet
#      systemctl status kubelet   # debe quedar "active (running)"
#
# 4. Verificar que la API vuelve a exigir credenciales:
#      curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:10250/pods
#        -> 401 (Unauthorized)
#      curl -s  -o /dev/null -w '%{http_code}\n' http://127.0.0.1:10255/pods
#        -> conexion rechazada / timeout (puerto cerrado)
#
# 5. (Si el cluster fue inicializado con kubeadm y se quiere que el fix
#    persista tras un `kubeadm upgrade` o reinicio del control plane,
#    corregir tambien el ConfigMap `kubelet-config` en el namespace
#    `kube-system` con las mismas claves, y volver a aplicar la config
#    en los nodos con `kubeadm upgrade node phase kubelet-config`.)
#
# Contexto adicional del tema (no cubierto por este break, pero parte del
# 1.4 del curriculum): restringir el acceso de los Pods al endpoint de
# metadata del cloud provider (ej. 169.254.169.254) con una NetworkPolicy
# que bloquee esa IP de destino, evitando que un Pod comprometido robe
# credenciales de instancia (IAM role, service account tokens del cloud, etc).
# ============================================================================