# 4.4 Implement and configure a highly-available control plane

## ¿Qué significa "alta disponibilidad" en el control plane?

Un cluster de Kubernetes es altamente disponible (HA) cuando la pérdida de un nodo del control plane no interrumpe el funcionamiento del API server ni la capacidad de administrar el cluster. Esto se logra corriendo **múltiples nodos de control plane** (típicamente un número impar: 3, 5, 7) con sus componentes replicados:

- **kube-apiserver**: stateless, se replica libremente. Todas las réplicas atienden requests simultáneamente detrás de un load balancer.
- **etcd**: stateful, forma un cluster propio que usa el protocolo Raft para consenso. Requiere quorum (mayoría) para aceptar escrituras.
- **kube-scheduler** y **kube-controller-manager**: se ejecutan en todos los nodos de control plane pero usan **leader election** (vía `Lease` objects en el namespace `kube-system`) para que solo una instancia esté activa a la vez, evitando decisiones duplicadas o conflictivas.

## Topologías de etcd

### Stacked etcd (topología por defecto de kubeadm)

etcd corre como un miembro más en cada nodo de control plane, colocalizado con kube-apiserver.

```
[CP1: apiserver+etcd] [CP2: apiserver+etcd] [CP3: apiserver+etcd]
```

Ventajas: menos infraestructura (menos nodos), setup más simple con `kubeadm`.
Riesgo: si se pierde un nodo, se pierde tanto una réplica de apiserver como un miembro de etcd al mismo tiempo, afectando el quorum más rápido que en la topología externa.

### External etcd

etcd corre en nodos dedicados, separados de los nodos que ejecutan kube-apiserver.

```
[CP1: apiserver] [CP2: apiserver] [CP3: apiserver]
[etcd1]           [etcd2]          [etcd3]
```

Ventajas: falla independiente de control plane y etcd; más resiliente pero requiere más nodos (mínimo 6 en un setup 3+3).

## Load balancing del API server

Los nodos worker, y también `kubectl`, deben apuntar a un único endpoint estable (`--control-plane-endpoint`) que balancee entre todas las instancias de kube-apiserver. Opciones típicas:

- Load balancer de la nube (ej. AWS NLB, GCP LB).
- HAProxy + keepalived con una VIP (Virtual IP) on-prem.
- DNS round-robin (menos recomendado, sin health checks).

Ejemplo mínimo de configuración HAProxy apuntando a 3 control plane nodes:

```
frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server cp1 10.0.0.11:6443 check
    server cp2 10.0.0.12:6443 check
    server cp3 10.0.0.13:6443 check
```

## Quorum en etcd

Con N miembros de etcd, el cluster tolera `floor(N/2)` caídas manteniendo escritura:

| Miembros | Tolera caídas |
|---|---|
| 1 | 0 |
| 3 | 1 |
| 5 | 2 |
| 7 | 3 |

Por esto se usan números impares: agregar un miembro par (ej. pasar de 3 a 4) no mejora la tolerancia a fallos, solo agrega latencia de consenso.

## Bootstrapping de un control plane HA con kubeadm

### 1. Inicializar el primer nodo de control plane

```bash
kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16
```

- `--control-plane-endpoint`: apunta al load balancer/VIP, no a la IP de este nodo.
- `--upload-certs`: sube los certificados compartidos del control plane (CA, etc.) cifrados a un Secret en el cluster, para que los demás nodos de control plane los descarguen automáticamente al hacer join (evita copiarlos a mano por scp).

Salida relevante:

```
Your Kubernetes control-plane has initialized successfully!
...
You can now join any number of control-plane nodes by copying certificate authorities
and service account keys on each node and then running the following as root:

  kubeadm join k8s-api.internal:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234... \
    --control-plane --certificate-key f8902e...

Then you can join any number of worker nodes by running the following on each as root:

  kubeadm join k8s-api.internal:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...
```

> Nota: el `--certificate-key` expira a las 2 horas. Si vence, se regenera con:
> ```bash
> kubeadm init phase upload-certs --upload-certs
> ```

### 2. Unir los otros nodos de control plane

En CP2 y CP3:

```bash
kubeadm join k8s-api.internal:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234... \
  --control-plane \
  --certificate-key f8902e...
```

El flag `--control-plane` es lo que distingue un join de control plane de un join de worker: hace que kubeadm descargue los certificados compartidos, agregue este nodo al cluster de etcd (topología stacked) y levante kube-apiserver, kube-scheduler y kube-controller-manager locales.

### 3. Unir los worker nodes

```bash
kubeadm join k8s-api.internal:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234...
```

## Verificación del cluster HA

```bash
kubectl get nodes
```

```
NAME   STATUS   ROLES           AGE   VERSION
cp1    Ready    control-plane   10m   v1.35.0
cp2    Ready    control-plane   7m    v1.35.0
cp3    Ready    control-plane   5m    v1.35.0
worker1  Ready  <none>          3m    v1.35.0
```

Verificar salud del cluster de etcd (desde un pod con acceso a etcdctl, o `crictl exec` en el contenedor de etcd):

```bash
kubectl exec -n kube-system etcd-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

```
+------------------+---------+-------+------------------------+------------------------+
|        ID        | STATUS  | NAME  |       PEER ADDRS       |      CLIENT ADDRS      |
+------------------+---------+-------+------------------------+------------------------+
| 4f5a3c2d1e0b1234  | started |  cp1  | https://10.0.0.11:2380 | https://10.0.0.11:2379 |
| 8b9c0d1e2f3a5678  | started |  cp2  | https://10.0.0.12:2380 | https://10.0.0.12:2379 |
| c1d2e3f4a5b69012  | started |  cp3  | https://10.0.0.13:2380 | https://10.0.0.13:2379 |
+------------------+---------+-------+------------------------+------------------------+
```

Verificar quién es el leader actual de scheduler y controller-manager (leader election vía Lease):

```bash
kubectl get lease -n kube-system kube-scheduler kube-controller-manager -o yaml | grep holderIdentity
```

## Consideraciones prácticas para el examen

- Si `--upload-certs` no se usó (o el certificate-key expiró), hay que copiar manualmente `/etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*,etcd/ca.*}` a los demás nodos de control plane antes de hacer el join.
- El `--control-plane-endpoint` debe definirse desde el `kubeadm init` inicial: no se puede agregar un load balancer "después" sin reconfigurar el cluster.
- Escalar de single control plane a HA no es soportado de forma directa por kubeadm; hay que planificar la topología HA desde el inicio.
- En clusters gestionados (EKS, GKE, AKS), el control plane HA es responsabilidad del proveedor cloud — el examen CKA se enfoca en clusters self-managed (kubeadm).

## Referencias

- [Options for Highly Available Topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/)
- [Creating Highly Available Clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [kubeadm init reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- [kubeadm join reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [etcd: Optimal etcd cluster size](https://etcd.io/docs/latest/faq/#what-is-failure-tolerance)
- [Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)