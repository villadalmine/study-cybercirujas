#!/usr/bin/env bash
# CKS 2.2 - Manage Kubernetes Secrets
# Break & Fix: encryption at rest de Secrets mal configurado en el control plane.
# Uso: SOLO en una VM de laboratorio descartable (kubeadm, single control-plane node).

set -euo pipefail

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
ENC_DIR="/etc/kubernetes/enc"
ENC_CONFIG="$ENC_DIR/encryption-config.yaml"
STATE_FILE="/root/.cks-2.2-lab-state"

usage() {
  cat <<EOF
Uso: $0 {break|restore|status}

  break    Rompe el escenario de forma controlada (requiere LAB_CONFIRM=yes).
  restore  Revierte los cambios usando el backup del ultimo 'break'.
  status   Muestra el estado del contenedor de kube-apiserver en este nodo.
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script necesita correr como root en el nodo control-plane." >&2
    exit 1
  fi
}

require_kubeadm_controlplane() {
  if [[ ! -f "$MANIFEST" ]]; then
    echo "No se encontro $MANIFEST. Este script espera un control-plane node armado con kubeadm." >&2
    exit 1
  fi
}

confirm_disposable() {
  if [[ "${LAB_CONFIRM:-}" == "yes" ]]; then
    return 0
  fi
  cat <<'EOF'
Este script rompe intencionalmente el control plane (kube-apiserver
deja de arrancar). Ejecutalo SOLO en una VM de laboratorio
descartable, nunca en un cluster real o compartido.

Para confirmar, volve a ejecutar con:
  LAB_CONFIRM=yes ./cks-2.2-break-fix.sh break
EOF
  exit 1
}

ensure_pyyaml() {
  if python3 -c "import yaml" >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] python3-yaml no esta instalado, instalando..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq python3-yaml
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3-pyyaml
  else
    echo "No pude instalar PyYAML automaticamente. Instalalo manualmente y reintenta." >&2
    exit 1
  fi
}

date_stamp() { date +%Y%m%d-%H%M%S; }

do_status() {
  echo "Buscando el contenedor de kube-apiserver en este nodo..."
  if command -v crictl >/dev/null 2>&1; then
    crictl ps -a | grep kube-apiserver || echo "No se encontraron contenedores kube-apiserver (crictl)."
  elif command -v docker >/dev/null 2>&1; then
    docker ps -a | grep kube-apiserver || echo "No se encontraron contenedores kube-apiserver (docker)."
  else
    echo "No se encontro crictl ni docker en este nodo." >&2
  fi
}

do_break() {
  require_root
  require_kubeadm_controlplane
  confirm_disposable

  local backup_dir="/root/cks-lab-backups/$(date_stamp)"
  mkdir -p "$backup_dir"
  cp -a "$MANIFEST" "$backup_dir/kube-apiserver.yaml.orig"
  if [[ -d "$ENC_DIR" ]]; then
    cp -a "$ENC_DIR" "$backup_dir/enc.orig"
  fi
  echo "$backup_dir" > "$STATE_FILE"

  ensure_pyyaml

  mkdir -p "$ENC_DIR"
  cat > "$ENC_CONFIG" <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c2hvcnQ=
      - identity: {}
EOF

  python3 - <<'PYEOF'
import yaml

path = "/etc/kubernetes/manifests/kube-apiserver.yaml"
with open(path) as f:
    manifest = yaml.safe_load(f)

container = manifest["spec"]["containers"][0]
flag = "--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml"
if flag not in container["command"]:
    container["command"].append(flag)

volume_mounts = container.setdefault("volumeMounts", [])
if not any(v.get("name") == "enc-config" for v in volume_mounts):
    volume_mounts.append({"name": "enc-config", "mountPath": "/etc/kubernetes/enc", "readOnly": True})

volumes = manifest["spec"].setdefault("volumes", [])
if not any(v.get("name") == "enc-config" for v in volumes):
    volumes.append({"name": "enc-config", "hostPath": {"path": "/etc/kubernetes/enc", "type": "DirectoryOrCreate"}})

with open(path, "w") as f:
    yaml.safe_dump(manifest, f, default_flow_style=False)
PYEOF

  cat <<EOF
==============================================================
 CKS 2.2 - Manage Kubernetes Secrets: encryption at rest roto
==============================================================
SINTOMA:
  A partir de ahora, kubectl (y cualquier otro cliente del API
  server) va a fallar con timeouts o "connection refused". El
  control plane dejo de responder.

QUE SE TOCO (para orientarte, sin revelarte la solucion):
  Se modifico el manifest estatico de kube-apiserver para que
  arranque con --encryption-provider-config apuntando a un
  archivo de EncryptionConfiguration en /etc/kubernetes/enc/.
  Ese archivo existe, pero kube-apiserver no logra iniciar con
  la configuracion tal como esta.

TU OBJETIVO:
  1. Diagnosticar, en el propio nodo (sin depender de kubectl),
     por que kube-apiserver no arranca.
  2. Corregir la EncryptionConfiguration para que sea VALIDA,
     de forma que kube-apiserver vuelva a levantar.
  3. No te conformes con sacar la flag agregada: el objetivo
     real es terminar con encryption at rest para Secrets
     FUNCIONANDO, no con el cluster vuelto al estado anterior
     sin cifrar.
  4. Confirmar que los Secrets nuevos quedan realmente cifrados
     en etcd (no solo en base64) antes de dar la tarea por
     resuelta.

Backup del manifest original y del directorio de encryption
config: $backup_dir
Podes ejecutar '$0 restore' en cualquier momento para volver
al estado previo a este script.
EOF
}

do_restore() {
  require_root
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No hay ningun backup registrado ($STATE_FILE no existe)." >&2
    exit 1
  fi

  local backup_dir
  backup_dir=$(cat "$STATE_FILE")
  if [[ ! -f "$backup_dir/kube-apiserver.yaml.orig" ]]; then
    echo "Backup no encontrado en $backup_dir" >&2
    exit 1
  fi

  cp -a "$backup_dir/kube-apiserver.yaml.orig" "$MANIFEST"
  rm -rf "$ENC_DIR"
  if [[ -d "$backup_dir/enc.orig" ]]; then
    cp -a "$backup_dir/enc.orig" "$ENC_DIR"
  fi
  rm -f "$STATE_FILE"

  echo "Manifest y encryption config restaurados desde $backup_dir"
  echo "kubelet va a reconciliar kube-apiserver en los proximos segundos."
}

case "${1:-}" in
  break) do_break ;;
  restore) do_restore ;;
  status) do_status ;;
  *) usage; exit 1 ;;
esac

# ==============================================================
# SOLUCION paso a paso (comentada, no se ejecuta)
# ==============================================================
#
# 1) Confirmar el sintoma sin depender de kubectl (el API server
#    esta caido), trabajando directo en el nodo:
#      crictl ps -a | grep kube-apiserver
#    Vas a ver el contenedor en estado Exited, reiniciando en loop.
#
# 2) Ver por que falla al arrancar:
#      crictl logs $(crictl ps -a --name kube-apiserver -q | head -1)
#    o, si el runtime todavia no llego a crear el contenedor:
#      journalctl -u kubelet -f --since "5 min ago"
#    El mensaje de error indica algo como:
#      "error while parsing file: ... invalid key size N for aescbc provider"
#    (la key configurada, c2hvcnQ=, decodifica a solo 5 bytes; aescbc
#    requiere keys de 16, 24 o 32 bytes).
#
# 3) Ubicar la configuracion de encryption at rest que se agrego:
#      grep encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml
#      cat /etc/kubernetes/enc/encryption-config.yaml
#
# 4) Generar una key valida de 32 bytes (AES-256) en base64:
#      head -c 32 /dev/urandom | base64
#
# 5) Reemplazar el valor de "secret:" en
#    /etc/kubernetes/enc/encryption-config.yaml por la key generada,
#    manteniendo el resto de la estructura (providers: aescbc + identity).
#    No hace falta tocar el manifest del kube-apiserver: al ser un
#    static pod, kubelet ya lo esta reintentando solo; en el proximo
#    reintento va a leer la config corregida y arrancar bien.
#
# 6) Esperar a que kube-apiserver vuelva a responder:
#      watch crictl ps
#      # o, desde una maquina con kubeconfig admin:
#      kubectl get nodes
#
# 7) Verificar que el objetivo real (encryption at rest para Secrets)
#    quedo funcionando, no solo que el cluster volvio a responder:
#      kubectl create secret generic cks-2-2-test \
#        --from-literal=clave=valor-secreto
#
#      ETCDCTL_API=3 etcdctl \
#        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#        --cert=/etc/kubernetes/pki/etcd/server.crt \
#        --key=/etc/kubernetes/pki/etcd/server.key \
#        get /registry/secrets/default/cks-2-2-test | hexdump -C
#
#    El valor almacenado en etcd debe empezar con el prefijo
#      k8s:enc:aescbc:v1:key1:
#    en lugar de mostrar el valor en texto plano/base64. Eso confirma
#    que los Secrets nuevos se cifran antes de persistir en etcd.
#
# 8) (Opcional, buena practica) Los Secrets que ya existian ANTES de
#    habilitar encryption siguen sin cifrar en etcd. Para reescribirlos
#    ahora que el provider funciona:
#      kubectl get secrets --all-namespaces -o json | kubectl replace -f -
#
# Referencias:
#   - CKS Curriculum v1.34:
#     https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - Encrypting Confidential Data at Rest:
#     https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# ==============================================================