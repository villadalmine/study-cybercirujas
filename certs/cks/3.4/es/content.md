# 3.4 Upgrade Kubernetes to avoid vulnerabilities

## Por qué importa

Cada release de Kubernetes recibe *patch releases* que corrigen bugs y vulnerabilidades (CVEs) durante una ventana de soporte de aproximadamente 14 meses desde el GA de esa minor version. Cuando una minor version sale de soporte, deja de recibir backports de seguridad. Mantener el cluster en una versión soportada, y aplicar patch releases apenas salen, es una de las medidas de hardening más simples y con mayor impacto: gran parte de los CVEs de Kubernetes (kube-apiserver, kubelet, etc.) se corrigen justamente así, sin cambios de configuración adicionales.

Kubernetes sostiene ("supports") las últimas 3 minor releases (la política se conoce informalmente como *N-2*). Como CKS candidate, se espera que sepas ejecutar un upgrade de forma segura, en el orden correcto y sin downtime evitable, usando `kubeadm` (el mecanismo que usa el exam environment).

## Versionado y version skew policy

Kubernetes usa `MAJOR.MINOR.PATCH` (ej. `v1.34.2`). Un upgrade de seguridad rutinario es normalmente un *patch bump* (`v1.34.1 → v1.34.2`); un *minor bump* (`v1.33 → v1.34`) puede traer deprecaciones y remociones de API.

Los componentes no necesitan estar todos en la misma versión, pero hay límites estrictos (*version skew policy*):

| Componente | Skew permitido respecto a kube-apiserver |
|---|---|
| `kube-apiserver` (HA) | máx. 1 minor version entre instancias |
| `kube-controller-manager` / `kube-scheduler` / `cloud-controller-manager` | ≤ 1 minor version más vieja |
| `kubelet` | ≤ 3 minor versions más vieja (desde v1.28; antes era 2) |
| `kubectl` | ±1 minor version |
| `kubeadm` | debe coincidir con la minor version del cluster que gestiona |

Esto implica una regla clave para el upgrade: **`kubeadm` no permite saltar minor versions**. Para ir de `v1.32` a `v1.34` hay que pasar por `v1.33`; no se puede aplicar `kubeadm upgrade apply v1.34.x` directo desde `v1.32.x`.

## Antes de actualizar: revisar deprecaciones y release notes

Un upgrade de minor version puede remover APIs deprecadas (ej. `batch/v1beta1 CronJob` removida en 1.25). Antes de actualizar:

1. Leer el *CHANGELOG* / release notes de la minor version destino.
2. Revisar la [Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/).
3. Detectar manifests que usan APIs deprecadas/removidas, con herramientas como `kubectl convert` (subcomando del plugin `kubectl-convert`) o escaneando manifests versionados en git contra la lista de deprecaciones.

```bash
# Ejemplo: detectar uso de una apiVersion removida antes de actualizar a v1.25+
grep -r "batch/v1beta1" manifests/
```

Saltear este paso es la causa más común de que un `kubeadm upgrade apply` funcione pero luego workloads existentes fallen al ser reconciliados contra la nueva versión del API server.

## Proceso con `kubeadm`: nodo de control plane primario

**1. Backup de etcd antes de tocar nada** (rollback rápido si algo sale mal):

```bash
ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-snapshot-pre-upgrade.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

**2. Actualizar el paquete `kubeadm` primero** (sin tocar `kubelet`/`kubectl` todavía):

```bash
apt-mark unhold kubeadm
apt-get update && apt-get install -y kubeadm='1.34.1-*'
apt-mark hold kubeadm
kubeadm version
```

**3. Verificar el plan de upgrade:**

```bash
kubeadm upgrade plan
```

```
[upgrade/versions] Cluster version: v1.34.0
[upgrade/versions] kubeadm version: v1.34.1
[upgrade/versions] Target version: v1.34.1
[upgrade/versions] Latest version in the v1.34 series: v1.34.1

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT       TARGET
kubelet     3 x v1.34.0   v1.34.1

Upgrade to the latest version in the v1.34 series:
COMPONENT                 CURRENT   TARGET
kube-apiserver             v1.34.0   v1.34.1
kube-controller-manager    v1.34.0   v1.34.1
kube-scheduler             v1.34.0   v1.34.1
kube-proxy                 v1.34.0   v1.34.1
CoreDNS                    v1.11.3   v1.11.3
etcd                       3.5.16-0  3.5.16-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.34.1
```

Opcionalmente, `kubeadm upgrade diff` muestra el diff exacto que se aplicará a los manifests estáticos (`kube-apiserver.yaml`, etc.) sin ejecutarlo, útil para revisar cambios antes de aplicar.

**4. Aplicar el upgrade** (solo en el primer control plane node; recrea los static pods del control plane uno por uno):

```bash
kubeadm upgrade apply v1.34.1
```

**5. Drenar el nodo** antes de tocar `kubelet`/`kubectl` locales:

```bash
kubectl drain <control-plane-node> --ignore-daemonsets --delete-emptydir-data
```

**6. Actualizar `kubelet` y `kubectl`, reiniciar el servicio:**

```bash
apt-mark unhold kubelet kubectl
apt-get install -y kubelet='1.34.1-*' kubectl='1.34.1-*'
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
```

**7. Uncordon:**

```bash
kubectl uncordon <control-plane-node>
```

## Nodos de control plane adicionales (HA)

En cada control plane node adicional se corre `kubeadm upgrade node` (no `upgrade apply`, que solo va en el primero):

```bash
apt-get install -y kubeadm='1.34.1-*'
kubeadm upgrade node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
apt-get install -y kubelet='1.34.1-*' kubectl='1.34.1-*'
systemctl daemon-reload && systemctl restart kubelet
kubectl uncordon <node>
```

## Nodos worker

Mismo patrón, un worker por vez para no tirar abajo capacidad del cluster de golpe:

```bash
# En el worker
apt-mark unhold kubeadm && apt-get install -y kubeadm='1.34.1-*' && apt-mark hold kubeadm
kubeadm upgrade node

# Desde una máquina con acceso al API server
kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data

# De nuevo en el worker
apt-mark unhold kubelet kubectl
apt-get install -y kubelet='1.34.1-*' kubectl='1.34.1-*'
apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet

# Desde la máquina de control
kubectl uncordon <worker-node>
```

## Verificación post-upgrade

```bash
kubectl get nodes -o wide
```

```
NAME           STATUS   ROLES           AGE   VERSION
controlplane   Ready    control-plane   90d   v1.34.1
node01         Ready    <none>          90d   v1.34.1
```

Confirmar además que los static pods del control plane volvieron a `Running` (`kubectl get pods -n kube-system`) y que no quedaron manifests apuntando a la versión vieja del binario en `/etc/kubernetes/manifests/`.

## Errores comunes (relevantes para el examen)

- Intentar `kubeadm upgrade apply` saltando una minor version → falla con error de skew.
- Olvidar `apt-mark hold`/`unhold` (o el equivalente en el package manager) → un `apt upgrade` posterior no relacionado puede romper el cluster al actualizar `kubelet` fuera de banda.
- Actualizar `kubelet` antes de drenar el nodo → reinicio del servicio interrumpe pods en ejecución sin resched controlado.
- No correr `kubeadm upgrade node` en control plane nodes adicionales o en workers (solo el primer control plane node usa `upgrade apply`).
- No hacer backup de etcd antes de un upgrade de minor version, dejando sin rollback rápido ante una falla del `kube-apiserver`.

## Referencias

- Documentación oficial — Upgrading kubeadm clusters: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Version Skew Policy: https://kubernetes.io/releases/version-skew-policy/
- Kubernetes release cycle y soporte de versiones: https://kubernetes.io/releases/
- Deprecated API Migration Guide: https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- `kubectl drain` / `cordon` / `uncordon`: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- etcd disaster recovery (snapshot/backup): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster
- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf