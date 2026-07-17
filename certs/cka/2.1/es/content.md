# Troubleshoot clusters and nodes

## Introducción

El troubleshooting de clusters y nodos es una de las competencias centrales del examen CKA: exige diagnosticar por qué un nodo no está `Ready`, por qué un componente del control plane no arranca, o por qué el cluster completo deja de responder, usando únicamente las herramientas disponibles en el nodo (systemd, journalctl, crictl) y `kubectl`. A diferencia del troubleshooting de aplicaciones (workloads), acá el foco está en la infraestructura del cluster: kubelet, container runtime, componentes del control plane (como static pods) y etcd.

## Diagnóstico general del cluster

El primer paso siempre es obtener una vista general del estado del cluster:

```bash
kubectl get nodes -o wide
kubectl cluster-info
kubectl get pods -n kube-system -o wide
kubectl get events -A --sort-by=.metadata.creationTimestamp
```

Salida típica de un nodo con problemas:

```
NAME       STATUS     ROLES           AGE   VERSION
master1    Ready      control-plane   40d   v1.35.0
worker1    NotReady   <none>          40d   v1.35.0
worker2    Ready      <none>          40d   v1.35.0
```

`kubectl describe node <node>` es el comando más importante para entender *por qué* un nodo está en un estado dado: muestra `Conditions`, `Taints`, `Allocatable`, `Events` y la versión de kubelet/container runtime.

```bash
kubectl describe node worker1
```

```
Conditions:
  Type             Status  Reason
  ----             ------  ------
  MemoryPressure   False   KubeletHasSufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  PIDPressure      False   KubeletHasSufficientPID
  Ready            False   KubeletNotReady
Taints:            node.kubernetes.io/not-ready:NoSchedule
```

## Node conditions y taints automáticos

Kubernetes expone cuatro condiciones estándar por nodo: `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure` y `NetworkUnavailable`. Cuando una condición pasa a `True` (o `Ready` pasa a `False`/`Unknown`), el node controller aplica automáticamente un taint (`node.kubernetes.io/not-ready`, `node.kubernetes.io/memory-pressure`, `node.kubernetes.io/disk-pressure`, etc.), lo que impide que se sigan schedulando pods ahí salvo que tengan la toleration correspondiente.

Si el nodo pasa a `Unknown` (kubelet dejó de reportar heartbeats), después de `--node-monitor-grace-period` (default 40s) el controller-manager lo marca como no saludable, y luego de `pod-eviction-timeout` (default 5m) empieza a evictuar los pods.

## Troubleshooting del kubelet

El kubelet corre como servicio systemd en cada nodo (no como pod). Es el punto de partida cuando un nodo aparece `NotReady`:

```bash
systemctl status kubelet
journalctl -u kubelet -f
journalctl -u kubelet --since "10 min ago" | grep -i error
```

Causas frecuentes de fallo:

- **Certificados expirados** del kubelet (`/var/lib/kubelet/pki/kubelet-client-current.pem`).
- **Container runtime caído** o mal configurado (`/var/lib/kubelet/config.yaml`, campo `containerRuntimeEndpoint`).
- **cgroup driver mismatch** entre kubelet y el container runtime (`cgroupfs` vs `systemd`), típico error en logs: `misconfiguration: kubelet cgroup driver ... is different from docker cgroup driver`.
- **Swap habilitado** sin `failSwapOn: false` en la configuración del kubelet.
- **Disco lleno** (`DiskPressure`), revisable con `df -h` y `du -sh /var/lib/kubelet`.

Verificar y corregir la configuración del kubelet:

```bash
cat /var/lib/kubelet/config.yaml
systemctl daemon-reload
systemctl restart kubelet
```

## Troubleshooting del container runtime con crictl

`crictl` es la CLI estándar (CRI-compatible) para inspeccionar contenedores a bajo nivel, independiente de si el runtime es containerd o CRI-O. Se configura en `/etc/crictl.yaml`:

```yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
```

Comandos útiles:

```bash
crictl ps -a
crictl pods
crictl logs <container-id>
crictl inspect <container-id>
systemctl status containerd
```

## Troubleshooting del control plane (static pods)

Los componentes del control plane instalados con `kubeadm` corren como **static pods**, definidos en manifiestos YAML que el kubelet observa directamente en `/etc/kubernetes/manifests/` (sin pasar por el API server). Esto es clave: si `kube-apiserver` está caído, `kubectl` no funciona, así que hay que diagnosticar directamente en el nodo del control plane.

```bash
ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

Si el pod correspondiente no aparece, el kubelet no pudo levantarlo; se revisa con `crictl` y `journalctl`:

```bash
crictl ps -a | grep kube-apiserver
crictl logs <container-id>
journalctl -u kubelet | grep apiserver
```

Errores comunes en manifiestos de static pods:

- Flags mal escritos o rutas de certificados inexistentes (`--etcd-certfile`, `--tls-cert-file`).
- YAML mal indentado (el kubelet simplemente ignora el archivo silenciosamente).
- Puertos ya en uso.

Una vez que el API server está arriba, se puede inspeccionar como cualquier pod:

```bash
kubectl get pods -n kube-system
kubectl logs -n kube-system kube-apiserver-master1
kubectl logs -n kube-system kube-scheduler-master1
kubectl logs -n kube-system kube-controller-manager-master1
```

## Troubleshooting de etcd

`etcd` es el almacén de estado del cluster; si falla, el cluster completo deja de responder aunque el resto de los componentes estén sanos. Se verifica su salud con `etcdctl`, apuntando a los certificados usados por el propio etcd:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

ETCDCTL_API=3 etcdctl ... member list
ETCDCTL_API=3 etcdctl ... endpoint status --write-out=table
```

Salida esperada de un endpoint sano:

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 12.345ms
```

Si etcd está degradado en un cluster de múltiples miembros (por quorum perdido), revisar `journalctl` del static pod de etcd y el estado de red entre los miembros (`member list` debe mostrar todos con `started`).

## Troubleshooting de red y DNS

Fallas de red en el cluster suelen manifestarse como pods `Pending`/`ContainerCreating` colgados, o pods `Running` pero sin conectividad entre sí.

**CNI plugin:**

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|flannel|cilium'
cat /etc/cni/net.d/*.conf
journalctl -u kubelet | grep -i cni
```

Un error típico es `NetworkPlugin cni failed to set up pod ... network: open /etc/cni/net.d: no such file or directory`, que indica que el CNI plugin no se instaló o su DaemonSet no llegó a correr en ese nodo.

**kube-proxy:**

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system kube-proxy-xxxxx
iptables -L -t nat | grep KUBE-SVC   # modo iptables
ipvsadm -Ln                          # modo ipvs
```

**CoreDNS:**

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --rm -it -- \
  nslookup kubernetes.default
```

Si la resolución DNS falla desde los pods pero el resto del cluster funciona, verificar `kube-system/kube-dns` Service, el ConfigMap `coredns` y que `/etc/resolv.conf` dentro del pod apunte al `clusterDNS` configurado en el kubelet.

## Certificados del cluster

Los certificados de un cluster `kubeadm` expiran a 1 año por default. Su vencimiento es una causa común (y muy evaluada en el examen) de que el control plane deje de responder de golpe.

```bash
kubeadm certs check-expiration
kubeadm certs renew all
systemctl restart kubelet
```

Tras renovar, hay que reiniciar los static pods afectados (el kubelet los recrea automáticamente al detectar cambios en los certificados montados) y, si cambió el certificado del API server, actualizar `~/.kube/config` o `/etc/kubernetes/admin.conf`.

## Drenar y aislar nodos para mantenimiento

Antes de intervenir un nodo con problemas (o para mantenimiento planificado), se lo aísla del scheduler:

```bash
kubectl cordon worker1
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
# ... tareas de mantenimiento / reinicio ...
kubectl uncordon worker1
```

`cordon` marca el nodo como `SchedulingDisabled` sin tocar los pods existentes; `drain` además evictúa los pods (respetando PodDisruptionBudgets) y bloquea nuevos schedulings.

## kubectl debug para inspección in-situ

Cuando no se tiene acceso SSH directo al nodo (o para no instalar herramientas extra), `kubectl debug` permite lanzar un contenedor con acceso al namespace del nodo:

```bash
kubectl debug node/worker1 -it --image=busybox:1.36
# dentro del contenedor de debug, el filesystem del nodo queda montado en /host
chroot /host
```

## Escenario práctico: nodo NotReady por certificado kubelet vencido

```bash
$ kubectl get nodes
NAME      STATUS     ROLES    AGE   VERSION
worker1   NotReady   <none>   400d  v1.35.0

$ journalctl -u kubelet --since "5 min ago" | tail
... "Failed to connect to apiserver" err="x509: certificate has expired or is not yet valid"

$ ls -la /var/lib/kubelet/pki/
-rw------- 1 root root 1273 ene 10  2025 kubelet-client-2025-01-10.pem

$ kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME
kubelet.conf                Jan 10, 2026 10:00 UTC   EXPIRED

# Solución: renovar certificados y reiniciar el servicio
$ kubeadm certs renew all
$ systemctl restart kubelet
$ kubectl get nodes
NAME      STATUS   ROLES    AGE   VERSION
worker1   Ready    <none>   400d  v1.35.0
```

## Referencias

- Troubleshooting Clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Troubleshooting kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/
- Debug Pods and ReplicationControllers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods-replication-controller/
- Node conditions: https://kubernetes.io/docs/concepts/architecture/nodes/#condition
- Static Pods: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- etcd operations guide: https://etcd.io/docs/v3.5/op-guide/
- crictl reference: https://kubernetes.io/docs/reference/tools/map-crictl-dockercli/
- kubectl debug reference: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Certificate Management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf