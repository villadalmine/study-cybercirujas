#!/usr/bin/env bash
#
# break-fix: CKS 1.34 - Dominio 3.4 "Upgrade Kubernetes to avoid vulnerabilities" (peso: 3.75%)
# Fuente: CKS Curriculum v1.34 - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
# Referencias: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
#              https://kubernetes.io/docs/setup/release/version-skew-policy/
#
# ADVERTENCIA: este script modifica paquetes del sistema (kubeadm, kubelet, kubectl)
# y los deja "held" (bloqueados) en una version anterior. Ejecutalo SOLO en una VM
# de laboratorio descartable con un cluster kubeadm (Debian/Ubuntu + repo pkgs.k8s.io)
# que no te importe romper.
#
# Uso:
#   sudo ./break-3.4-upgrade.sh break   # rompe el lab (pide confirmacion)
#   sudo ./break-3.4-upgrade.sh check   # autoevalua si ya lo arreglaste
#
set -euo pipefail

LAB_MARKER="/var/tmp/cks-3.4-lab.state"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Este script necesita privilegios de root (sudo)." >&2
    exit 1
  fi
}

require_tools() {
  for bin in kubeadm kubelet kubectl apt-cache apt-get apt-mark dpkg dpkg-query systemctl; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      echo "Falta el binario requerido: ${bin}. Este script asume un nodo kubeadm sobre Debian/Ubuntu con el repo pkgs.k8s.io configurado." >&2
      exit 1
    fi
  done
}

confirm() {
  if [[ "${CKS_LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  echo "Este script va a downgradear y bloquear (apt-mark hold) kubeadm/kubelet/kubectl en este equipo."
  read -r -p "Escribi 'romper' para continuar: " ans
  [[ "${ans}" == "romper" ]] || { echo "Cancelado."; exit 1; }
}

pkg_installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

available_versions() {
  # Lista versiones candidatas del repo apt configurado, mas vieja primero
  apt-cache madison "$1" | awk '{print $3}' | sort -V | uniq
}

semver_of() {
  # extrae "X.Y.Z" de un string tipo "1.34.1-1.1" (version de paquete apt)
  printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

do_break() {
  require_root
  require_tools
  confirm

  if [[ -f "${LAB_MARKER}" ]]; then
    echo "Aviso: hay un lab roto previo sin resolver (${LAB_MARKER}). Se sobreescribe el estado."
  fi

  local cur_kubeadm cur_kubelet cur_kubectl
  cur_kubeadm="$(pkg_installed_version kubeadm)"
  cur_kubelet="$(pkg_installed_version kubelet)"
  cur_kubectl="$(pkg_installed_version kubectl)"

  if [[ -z "${cur_kubeadm}" ]]; then
    echo "kubeadm no esta instalado via apt en este nodo. Este lab requiere un nodo kubeadm existente." >&2
    exit 1
  fi

  mapfile -t versions < <(available_versions kubeadm)
  if [[ "${#versions[@]}" -lt 2 ]]; then
    echo "El repo apt configurado solo expone una version de kubeadm (${versions[*]:-ninguna})." >&2
    echo "No hay una version anterior disponible para simular el atraso. Agrega un canal pkgs.k8s.io con al menos 2 patch releases y reintenta." >&2
    exit 1
  fi

  local target="${versions[0]}"   # la mas vieja disponible en el repo
  echo ">> Version actual: kubeadm=${cur_kubeadm} kubelet=${cur_kubelet} kubectl=${cur_kubectl}"
  echo ">> Version objetivo (vulnerable, la mas vieja del repo): ${target}"

  apt-mark unhold kubeadm kubelet kubectl >/dev/null 2>&1 || true

  apt-get install -y --allow-downgrades --allow-change-held-packages \
    "kubeadm=${target}" "kubelet=${target}" "kubectl=${target}"

  apt-mark hold kubeadm kubelet kubectl >/dev/null

  systemctl daemon-reload
  systemctl restart kubelet

  {
    echo "role=$( [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] && echo control-plane || echo worker )"
    echo "node_name=$(hostname)"
    echo "broken_at=$(date -Is)"
  } > "${LAB_MARKER}"

  cat <<'EOF'

================================================================
 LAB ROTO: CKS 3.4 - Upgrade Kubernetes to avoid vulnerabilities
================================================================

SINTOMA que vas a observar:

  1) kubeadm/kubelet/kubectl estan "held" en una version vieja:
       apt-mark showhold
     (no se actualizan aunque corras "apt upgrade")

  2) kubeadm avisa que hay una version mas nueva disponible:
       kubeadm upgrade plan
     Vas a ver algo como:
       "Cluster version: vX.Y.z (actual)"
       "Latest stable version: vX.Y.Z (mas nueva)"

  3) "kubectl get nodes -o wide" muestra la version vieja en la
     columna KUBELET-VERSION.

Este escenario simula una practica de operacion real y riesgosa:
alguien bloqueo los paquetes de Kubernetes con apt-mark hold para
evitar un upgrade "inesperado" y se olvido de destrabarlos. El
cluster queda corriendo con un patch viejo que puede tener CVEs
ya resueltos en versiones posteriores, sin que "apt upgrade" lo
detecte ni lo avise.

TU OBJETIVO:

  Dejar el cluster corriendo en la version mas nueva disponible en
  el repo apt configurado, siguiendo el procedimiento oficial de
  kubeadm (destrabar y apt-get install a los ponchazos no alcanza:
  la idea es que practiques el flujo completo de upgrade).

  Se considera resuelto cuando:
    - kubeadm, kubelet y kubectl quedan en la version mas nueva
      del repo (la que veias como "Latest stable version").
    - kubectl get nodes muestra esa version nueva.
    - Ningun paquete de Kubernetes queda con "hold" pendiente que
      impida futuros upgrades (a menos que lo dejes held vos a
      proposito, entendiendo el trade-off).

  Para autoevaluarte:
       sudo ./break-3.4-upgrade.sh check

================================================================
EOF
}

do_check() {
  require_root
  require_tools

  if [[ ! -f "${LAB_MARKER}" ]]; then
    echo "No hay lab roto registrado (o ya fue verificado y limpiado). Corre 'break' primero."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${LAB_MARKER}"

  mapfile -t versions < <(available_versions kubeadm)
  local newest="${versions[-1]}"
  local newest_semver
  newest_semver="$(semver_of "${newest}")"

  local cur_kubeadm cur_kubelet cur_kubectl
  cur_kubeadm="$(pkg_installed_version kubeadm)"
  cur_kubelet="$(pkg_installed_version kubelet)"
  cur_kubectl="$(pkg_installed_version kubectl)"

  local held
  held="$(apt-mark showhold | grep -E '^(kubeadm|kubelet|kubectl)$' || true)"

  local ok=1
  echo ">> Version mas nueva disponible en el repo: ${newest} (v${newest_semver})"
  echo ">> Instalado: kubeadm=${cur_kubeadm}  kubelet=${cur_kubelet}  kubectl=${cur_kubectl}"

  if [[ "${cur_kubeadm}" != "${newest}" || "${cur_kubelet}" != "${newest}" || "${cur_kubectl}" != "${newest}" ]]; then
    echo "FALTA: no todos los paquetes estan en la version mas nueva (${newest})."
    ok=0
  fi

  if [[ -n "${held}" ]]; then
    echo "AVISO: siguen 'held' estos paquetes -> ${held}"
    echo "       (si fue una decision intencional esta bien; si no, corre: apt-mark unhold ${held})"
  fi

  if kubectl get nodes "${node_name:-}" -o wide 2>/dev/null | grep -q "v${newest_semver}"; then
    echo "OK: kubectl get nodes ya refleja la version nueva."
  else
    echo "FALTA: kubectl get nodes todavia no refleja v${newest_semver}."
    ok=0
  fi

  if [[ "${ok}" -eq 1 ]]; then
    echo
    echo "RESUELTO. Buen upgrade."
    rm -f "${LAB_MARKER}"
  else
    echo
    echo "Todavia no. Segui el procedimiento de kubeadm upgrade (ver la solucion comentada al final del script)."
    exit 1
  fi
}

main() {
  case "${1:-break}" in
    break) do_break ;;
    check) do_check ;;
    *) echo "Uso: $0 [break|check]" >&2; exit 1 ;;
  esac
}

main "$@"

# ================================================================
# SOLUCION (referencia - no se ejecuta como parte del script)
# ================================================================
#
# Procedimiento oficial de kubeadm para upgrade de un nodo, aplicado
# a este lab (ver https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/):
#
# 1) Destrabar los paquetes que estan "held":
#      sudo apt-mark unhold kubeadm kubelet kubectl
#      apt-mark showhold        # confirmar que ya no aparecen
#
# 2) Actualizar el indice de apt y ver que version de kubeadm hay
#    disponible en el repo:
#      sudo apt update
#      apt-cache madison kubeadm
#
# 3) Instalar la version nueva de kubeadm PRIMERO (fijando la version
#    exacta, no un "apt upgrade" a ciegas):
#      sudo apt-get install -y --allow-change-held-packages \
#        kubeadm=<VERSION-NUEVA>
#      kubeadm version
#
# 4) Verificar el plan de upgrade (kubeadm valida version skew y el
#    estado de los componentes del control plane):
#      sudo kubeadm upgrade plan
#
# 5a) Si este nodo es control-plane (existe
#     /etc/kubernetes/manifests/kube-apiserver.yaml):
#      sudo kubeadm upgrade apply <VERSION-NUEVA>
#     Esto reescribe los manifests estaticos (etcd, kube-apiserver,
#     kube-controller-manager, kube-scheduler) con las imagenes
#     nuevas y espera a que el control plane vuelva a estar Ready.
#
# 5b) Si es un nodo worker (o un control-plane adicional, despues
#     del primero):
#      sudo kubeadm upgrade node
#
# 6) Drenar el nodo antes de tocar el kubelet (evita downtime de
#    los pods que corren ahi):
#      kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data
#
# 7) Instalar kubelet y kubectl en la misma version nueva:
#      sudo apt-get install -y --allow-change-held-packages \
#        kubelet=<VERSION-NUEVA> kubectl=<VERSION-NUEVA>
#      sudo systemctl daemon-reload
#      sudo systemctl restart kubelet
#
# 8) Volver a habilitar el scheduling en el nodo:
#      kubectl uncordon $(hostname)
#
# 9) Verificar el resultado:
#      kubectl get nodes -o wide     # columna KUBELET-VERSION
#      kubeadm version
#      kubectl version
#
# 10) (Opcional, discutible) Volver a hacer hold de los paquetes
#     como politica intencional de control de cambios, documentando
#     el proceso para destrabarlos ante el proximo CVE:
#      sudo apt-mark hold kubeadm kubelet kubectl
#
# Puntos clave que evalua el examen en este dominio:
#  - kubeadm upgrade plan / apply / node es el camino soportado;
#    nunca se "fuerza" un downgrade en un cluster productivo.
#  - El kubelet nunca debe quedar en una version mas nueva que el
#    kube-apiserver, y la politica de version skew de Kubernetes
#    limita cuantas versiones menores de atraso se toleran
#    (ver https://kubernetes.io/docs/setup/release/version-skew-policy/).
#  - Un paquete "held" no aparece en "apt upgrade" ni en escaneos
#    que solo miran actualizaciones pendientes de apt: hay que
#    revisar explicitamente "apt-mark showhold" como parte de una
#    auditoria de vulnerabilidades.
#  - drain/uncordon evita que el upgrade del kubelet tire pods en
#    caliente.
# ================================================================