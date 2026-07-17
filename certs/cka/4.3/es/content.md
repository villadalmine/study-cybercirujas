# 4.3 Manage the lifecycle of Kubernetes clusters

## Alcance del tema

Este tema cubre las tareas operativas necesarias para mantener un cluster de Kubernetes actualizado y saludable a lo largo del tiempo: entender la **version skew policy**, ejecutar **upgrades** de control plane y worker nodes con `kubeadm`, hacer **backup/restore de etcd**, y realizar mantenimiento de nodos (drain/cordon/uncordon) para aplicar cambios de OS o hardware sin downtime del workload. Es un tema de peso moderado (3.57%) pero muy práctico: en el examen suele aparecer como una tarea end-to-end de upgrade de un cluster kubeadm de una minor version a la siguiente.

## Version Skew Policy

Kubernetes soporta un desfasaje limitado de versiones entre componentes. Reglas clave (aplican a v1.35, confirmar siempre contra la versión específica del examen):

- **kube-apiserver**: es la versión "de referencia". No debe haber ningún componente más nuevo que el apiserver.
- **kube-controller-manager, kube-scheduler, cloud-controller-manager**: pueden estar hasta **1 minor version** por debajo del apiserver.
- **kubelet**: puede estar hasta **3 minor versions** por debajo del apiserver (soporte extendido desde v1.28).
- **kube-proxy**: misma versión que kubelet en ese nodo, no debe superar al apiserver.
- **kubectl**: puede estar 1 minor version por arriba o por debajo del apiserver.
- Los **upgrades deben hacerse de a una minor version por vez** (ej: 1.33 → 1.34 → 1.35), nunca saltar minors.

Esto implica el orden estándar de upgrade de un cluster:

1. Upgrade del **control plane** (primero el nodo primario, luego los demás control plane nodes si hay HA).
2. Upgrade de los **worker nodes**, típicamente de a uno o en batches, para no perder capacidad.

## Upgrade de un cluster con kubeadm

### 1. Verificar versiones disponibles

```bash
# En el nodo control-plane
apt update
apt-cache madison kubeadm
```

```
kubeadm | 1.35.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.35/deb  Packages
kubeadm | 1.35.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.35/deb  Packages
```

### 2. Upgrade del primer control plane node

```bash
# Fijar/instalar la versión exacta de kubeadm
apt-mark unhold kubeadm
apt install -y kubeadm='1.35.1-1.1'
apt-mark hold kubeadm

# Verificar el plan de upgrade
kubeadm upgrade plan
```

Salida típica (resumida):

```
[upgrade/versions] Cluster version: v1.34.1
[upgrade/versions] kubeadm version: v1.35.1
Upgrade to the latest stable version:

COMPONENT                 CURRENT   TARGET
kube-apiserver             v1.34.1   v1.35.1
kube-controller-manager    v1.34.1   v1.35.1
kube-scheduler             v1.34.1   v1.35.1
kube-proxy                 v1.34.1   v1.35.1
CoreDNS                    v1.11.3   v1.11.3
etcd                       3.5.15-0  3.5.16-0

You can now apply the upgrade by executing the following command:
        kubeadm upgrade apply v1.35.1
```

```bash
kubeadm upgrade apply v1.35.1
```

Esto actualiza los manifiestos estáticos del control plane (`/etc/kubernetes/manifests/`), certificados (con renovación automática salvo que se pase `--certificate-renewal=false`), y componentes de addon (CoreDNS, kube-proxy).

Para control plane nodes **adicionales** (HA) se usa en cambio:

```bash
kubeadm upgrade node
```

### 3. Drenar el nodo antes de tocar el kubelet

```bash
kubectl drain <control-plane-node> --ignore-daemonsets
```

Esto marca el nodo como **unschedulable** (`cordon`) y expulsa los pods que corren en él (excepto DaemonSets y, salvo `--delete-emptydir-data`, pods con emptyDir local que bloquean el drain). Es el mismo mecanismo que se usa antes de mantenimiento de OS/hardware.

### 4. Upgrade de kubelet y kubectl en ese nodo

```bash
apt-mark unhold kubelet kubectl
apt install -y kubelet='1.35.1-1.1' kubectl='1.35.1-1.1'
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
```

### 5. Descordonar el nodo

```bash
kubectl uncordon <control-plane-node>
```

### 6. Repetir para cada worker node

En cada worker, el flujo es más simple (no hay `kubeadm upgrade apply`, solo `node`):

```bash
# En el control plane, drenar el worker
kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data

# En el worker
apt-mark unhold kubeadm
apt install -y kubeadm='1.35.1-1.1'
apt-mark hold kubeadm

kubeadm upgrade node

apt-mark unhold kubelet kubectl
apt install -y kubelet='1.35.1-1.1' kubectl='1.35.1-1.1'
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet

# En el control plane, verificar y descordonar
kubectl get nodes
kubectl uncordon <worker-node>
```

### Verificación final

```bash
kubectl get nodes -o wide
```

```
NAME           STATUS   ROLES           AGE   VERSION
cp-01          Ready    control-plane   90d   v1.35.1
worker-01      Ready    <none>          90d   v1.35.1
worker-02      Ready    <none>          90d   v1.35.1
```

## Backup y restore de etcd

etcd es la fuente de verdad del cluster; su backup/restore es una tarea clásica del examen dentro de este dominio.

### Backup

```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/backups/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

```
{"level":"info","msg":"created temporary db file","path":"/opt/backups/etcd-snapshot.db.part"}
{"level":"info","msg":"saved","path":"/opt/backups/etcd-snapshot.db"}
Snapshot saved at /opt/backups/etcd-snapshot.db
```

Verificar el snapshot:

```bash
ETCDCTL_API=3 etcdctl snapshot status /opt/backups/etcd-snapshot.db --write-out=table
```

### Restore

El restore crea un **nuevo data directory**; no sobrescribe in-place.

```bash
ETCDCTL_API=3 etcdctl snapshot restore /opt/backups/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restore
```

Luego hay que apuntar el manifiesto estático de etcd (`/etc/kubernetes/manifests/etcd.yaml`) al nuevo `data-dir` (cambiar el `hostPath` del volumen `etcd-data`) y reiniciar el kubelet o esperar a que el static pod controller lo detecte:

```bash
systemctl restart kubelet
```

```bash
kubectl get pods -n kube-system | grep etcd
```

```
etcd-cp-01   1/1   Running   0   45s
```

Puntos clave para el examen:
- El backup se hace **desde el nodo donde corre etcd**, usando los certs de `/etc/kubernetes/pki/etcd/`.
- En clusters con etcd externo, los endpoints y certs cambian pero el flujo es análogo.
- Siempre hacer backup **antes** de un upgrade de cluster o de una operación destructiva.

## Mantenimiento de nodos (fuera de upgrades)

`cordon` / `drain` / `uncordon` también se usan para mantenimiento de OS, reemplazo de hardware, o escalado down manual:

```bash
kubectl cordon <node>     # marca unschedulable, no mueve pods existentes
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... mantenimiento del nodo (reboot, patch de OS, etc.) ...
kubectl uncordon <node>   # vuelve a ser schedulable
```

Flags relevantes de `drain`:
- `--ignore-daemonsets`: necesario porque los pods de DaemonSet no se pueden evacuar (se recrean en el mismo nodo).
- `--delete-emptydir-data`: requerido si hay pods con volúmenes `emptyDir`, ya que esos datos se pierden.
- `--force`: permite drenar pods no gestionados por un controlador (bare pods).

## Referencias

- kubeadm upgrade: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Version Skew Policy: https://kubernetes.io/releases/version-skew-policy/
- Safely Drain a Node: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Operating etcd clusters for Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcdctl snapshot: https://etcd.io/docs/latest/op-guide/recovery/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf