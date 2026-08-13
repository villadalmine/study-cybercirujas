# Tema 2.5 — High Availability Installations

**Certificación:** KCA · **Dominio 2 (Instalación & Configuración)** · **Peso: 3.0**

---

## 1. Motivación y el problema arquitectónico

Un cluster de Kubernetes con un solo nodo de control plane es una demostración, no un sistema de producción. El control plane es el punto donde converge **todo el estado deseado del cluster**: el `kube-apiserver` es la única puerta de entrada a `etcd`, el `kube-controller-manager` reconcilia el estado, y el `kube-scheduler` decide colocación. Si ese único nodo cae, ocurren dos cosas de gravedad muy distinta:

1. **El data plane sigue corriendo.** Los `Pods` ya programados en los workers siguen sirviendo tráfico: el `kubelet` no necesita al apiserver para mantener vivos los contenedores existentes. Esto es una propiedad de diseño clave — Kubernetes degrada, no se apaga.
2. **El cluster deja de reconciliar.** No hay `kubectl`, no hay self-healing, no hay rescheduling si un worker muere, no hay escalado (HPA), no hay renovación de leases, no hay respuesta a un `Deployment` nuevo. El cluster queda **congelado en su último estado conocido** y ciego a cualquier fallo nuevo.

El objetivo de una instalación HA es eliminar el control plane como **Single Point of Failure (SPOF)** y garantizar la disponibilidad tanto del **plano de API** (frontend sin estado, fácil de replicar) como de **`etcd`** (backend con estado, que impone las restricciones más severas).

### El problema del estado: `etcd` y el quórum

`etcd` es un almacén clave-valor distribuido que usa el algoritmo de consenso **Raft**. Raft exige **quórum** — mayoría estricta de los miembros — para confirmar cualquier escritura. Esto define matemáticamente cuántos nodos necesitás:

$$\text{quórum} = \left\lfloor \frac{n}{2} \right\rfloor + 1 \qquad \text{tolerancia a fallos} = \left\lfloor \frac{n-1}{2} \right\rfloor$$

| Miembros `etcd` (n) | Quórum requerido | Fallos tolerados | ¿Vale la pena? |
|---|---|---|---|
| 1 | 1 | 0 | Solo dev/lab |
| 2 | 2 | 0 | **Nunca** — peor que 1: cualquier caída rompe quórum |
| 3 | 2 | 1 | **Estándar de producción** |
| 4 | 3 | 1 | No — mismo fallo tolerado que 3, mayor superficie |
| 5 | 3 | 2 | Clusters grandes / multi-rack |
| 7 | 4 | 3 | Raro; latencia de consenso empieza a doler |

**Regla de oro:** siempre un número **impar** de miembros. Un número par nunca mejora la tolerancia a fallos respecto al impar inferior, pero **aumenta** la probabilidad de perder quórum (más miembros que pueden fallar para el mismo umbral) y el costo de la latencia de consenso (más *fsyncs* que confirmar). Con 3 miembros tolerás la pérdida de 1; perder 2 significa **pérdida de quórum**: `etcd` pasa a modo solo-lectura y el cluster no acepta ninguna mutación hasta recuperar la mayoría.

> **Latencia y consenso:** cada escritura confirmada en `etcd` requiere un *fsync* a disco en la mayoría de los miembros. Por eso `etcd` es extremadamente sensible a la latencia de disco (se recomienda SSD/NVMe, WAL en disco dedicado) y a la latencia de red entre miembros. **No estirés un cluster `etcd` entre regiones**: el RTT inter-región destruye el throughput de consenso. Para multi-región se usan clusters independientes, no un `etcd` estirado.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Topología: `etcd` apilado (stacked) vs. externo

Kubernetes ofrece dos topologías HA soportadas por `kubeadm`.

**Stacked etcd** — cada nodo de control plane corre además un miembro local de `etcd`:

```
┌─ CP1 ─────────┐  ┌─ CP2 ─────────┐  ┌─ CP3 ─────────┐
│ apiserver     │  │ apiserver     │  │ apiserver     │
│ controller-mgr│  │ controller-mgr│  │ controller-mgr│
│ scheduler     │  │ scheduler     │  │ scheduler     │
│ etcd (local)  │◄─┤ etcd (local)  │◄─┤ etcd (local)  │
└───────────────┘  └───────────────┘  └───────────────┘
```

**External etcd** — `etcd` corre en un cluster dedicado, separado del control plane:

```
┌─ CP1 ────┐ ┌─ CP2 ────┐ ┌─ CP3 ────┐      ┌─ etcd1 ┐ ┌─ etcd2 ┐ ┌─ etcd3 ┐
│apiserver │ │apiserver │ │apiserver │  ───► │ etcd   │ │ etcd   │ │ etcd   │
│ctrl-mgr  │ │ctrl-mgr  │ │ctrl-mgr  │      └────────┘ └────────┘ └────────┘
│scheduler │ │scheduler │ │scheduler │
└──────────┘ └──────────┘ └──────────┘
```

| Criterio | Stacked etcd | External etcd |
|---|---|---|
| Nº mínimo de hosts | 3 | 6 (3 CP + 3 etcd) |
| Acoplamiento de fallos | **Alto** — perder un nodo pierde un apiserver *y* un miembro etcd | **Bajo** — fallo de un CP no afecta el quórum de etcd |
| Blast radius | Un nodo caído consume tolerancia de etcd *y* de CP a la vez | Dominios de fallo independientes |
| Complejidad operativa | Menor (kubeadm lo gestiona todo) | Mayor (etcd se instala/upgradea aparte) |
| Costo de infraestructura | Menor | Mayor (2× máquinas) |
| Aislamiento de recursos | apiserver y etcd compiten por CPU/IO/disco | etcd tiene disco e IO dedicados (mejor p99) |
| Uso recomendado | Default; mayoría de producción | Clusters grandes, alta carga de escritura, compliance |

**Recomendación:** empezá con **stacked** salvo que tengas una razón concreta (carga de escritura alta que satura el disco compartido, requisitos de aislamiento, o querés poder escalar/upgradear `etcd` sin tocar el control plane). El acoplamiento de fallos del stacked es real: si CP1 se muere, perdés simultáneamente un apiserver y un miembro de etcd — con solo 3 nodos, ya estás en el borde del quórum.

### 2.2 Balanceo del `kube-apiserver`

El apiserver es **stateless**: cualquier cliente (`kubelet`, `kubectl`, controllers) puede hablar con cualquier instancia. Necesitás un **endpoint estable único** (`controlPlaneEndpoint`) delante de las N réplicas. Opciones:

| Solución | Modelo | HA del propio LB | Pros | Contras |
|---|---|---|---|---|
| **HAProxy + keepalived** | LB software L4 + VIP (VRRP) | Sí (VIP failover) | Portable, on-prem, sin dependencia de cloud | Hay que operar 2 daemons; failover ~ segundos |
| **kube-vip** | VIP en el propio cluster (ARP/L2 o BGP) | Sí (leader election) | Corre como static pod, sin nodos LB extra | ARP/L2 limitado a misma subred; BGP requiere fabric compatible |
| **Cloud LB** (NLB/GLB) | LB gestionado L4 | Sí (gestionado) | Cero operación, health checks nativos | Atado al proveedor; costo; latencia extra |
| **DNS round-robin** | — | **No** | Trivial | **No es HA**: no saca de rotación a un backend caído |

> **Advertencia crítica:** DNS round-robin **no** es una solución HA. No detecta un apiserver caído y sigue entregando su IP, produciendo timeouts intermitentes. Necesitás health-checking real (L4 con `tcp-check` o L7 sobre `/healthz`).

El `controlPlaneEndpoint` **debe definirse en el `kubeadm init` original**. Añadirlo después obliga a reemitir certificados y reconfigurar todos los componentes — mucho más doloroso que planificarlo desde el día cero. Aunque arranques con un solo control plane, definí el endpoint desde el principio si prevés crecer a HA.

---

## 3. Manifiestos e infraestructura completos

Topología de referencia usada en toda esta sección (stacked etcd, 3 control planes, HAProxy+keepalived):

```
VIP (endpoint):  10.0.0.10   → k8s-api.example.com:6443
LB1 (haproxy):   10.0.0.4    (keepalived MASTER, priority 101)
LB2 (haproxy):   10.0.0.5    (keepalived BACKUP,  priority 100)
cp1:             10.0.0.11
cp2:             10.0.0.12
cp3:             10.0.0.13
worker1:         10.0.0.21
worker2:         10.0.0.22
```

### 3.1 HAProxy — `/etc/haproxy/haproxy.cfg`

```haproxy
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 20000

defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
    retries 3

# Estadísticas del LB (opcional pero muy útil para diagnóstico)
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

frontend kubernetes-apiserver
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-apiserver

backend kubernetes-apiserver
    mode tcp
    option tcp-check
    balance roundrobin
    # 'check' activa el health-check L4; los apiservers caídos salen de rotación
    server cp1 10.0.0.11:6443 check fall 3 rise 2
    server cp2 10.0.0.12:6443 check fall 3 rise 2
    server cp3 10.0.0.13:6443 check fall 3 rise 2
```

> **Nota de precisión:** un `tcp-check` solo verifica que el puerto 6443 acepta conexiones TCP, no que el apiserver esté *sano*. Para un chequeo más fuerte usá modo HTTP contra `/readyz` (o `/healthz`) con `option httpchk GET /readyz` y `check-ssl verify none`, aceptando el overhead de TLS por chequeo. En L4 puro, `tcp-check` es lo estándar y suficiente en la mayoría de los casos.

### 3.2 keepalived — `/etc/keepalived/keepalived.conf` (nodo MASTER)

```conf
vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 3     # ejecutar cada 3 s
    weight -2      # restar 2 a la prioridad si falla
    fall 3         # 3 fallos consecutivos = DOWN
    rise 2         # 2 éxitos consecutivos = UP
}

vrrp_instance VI_APISERVER {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101              # BACKUP usa 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass 7k3s_ha_vip
    }
    virtual_ipaddress {
        10.0.0.10/24
    }
    track_script {
        check_haproxy
    }
}
```

Script de salud del VIP — `/etc/keepalived/check_haproxy.sh`:

```bash
#!/usr/bin/env bash
# Baja el VIP si HAProxy no está corriendo en este nodo,
# forzando el failover VRRP hacia el BACKUP.
errorExit() { echo "*** $*" 1>&2; exit 1; }

# ¿HAProxy vivo?
if ! killall -0 haproxy 2>/dev/null; then
    exit 1
fi
# ¿El apiserver responde a través del VIP local?
curl --silent --max-time 2 --insecure https://localhost:6443/healthz -o /dev/null \
    || errorExit "apiserver /healthz no responde vía HAProxy local"
exit 0
```

```bash
$ sudo chmod +x /etc/keepalived/check_haproxy.sh
```

### 3.3 Alternativa: kube-vip como static pod (sin nodos LB extra)

Si preferís no operar HAProxy/keepalived, `kube-vip` provee el VIP desde el propio control plane vía leader election. Generá el manifiesto y colocalo en `/etc/kubernetes/manifests/` **antes** del `kubeadm init` en cp1:

```bash
$ export VIP=10.0.0.10
$ export INTERFACE=eth0
$ export KVVERSION=v0.8.0
$ sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
$ sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip \
    /kube-vip manifest pod \
      --interface $INTERFACE \
      --address $VIP \
      --controlplane \
      --arp \
      --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

`/etc/kubernetes/manifests/kube-vip.yaml` resultante (recortado a lo esencial):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:v0.8.0
      args: ["manager"]
      env:
        - name: vip_arp
          value: "true"
        - name: address
          value: "10.0.0.10"
        - name: vip_interface
          value: "eth0"
        - name: cp_enable
          value: "true"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "15"
        - name: vip_renewdeadline
          value: "10"
        - name: vip_retryperiod
          value: "2"
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
      volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
  hostNetwork: true
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/admin.conf
```

> **Bootstrap chicken-and-egg:** kube-vip con leader election necesita el apiserver para elegir líder, pero el apiserver aún no existe durante el primer `init`. Por eso durante el bootstrap kube-vip levanta el VIP en modo ARP sin líder; una vez que cp1 arranca, la elección de líder toma el control. En despliegues nuevos con kube-vip ≥ 0.8, se recomienda el modo `super-admin.conf` para el bootstrap. Consultá la doc oficial de kube-vip para tu versión exacta.

### 3.4 `kubeadm` — configuración del cluster (stacked etcd)

`kubeadm-config.yaml`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.0.0.11"   # IP real de cp1
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.31.0"
# CLAVE: el endpoint estable (VIP/LB), NO la IP de un nodo concreto
controlPlaneEndpoint: "k8s-api.example.com:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
etcd:
  local:
    dataDir: /var/lib/etcd
apiServer:
  # SANs extra para que el cert del apiserver sea válido en el VIP y el DNS
  certSANs:
    - "k8s-api.example.com"
    - "10.0.0.10"
    - "10.0.0.11"
    - "10.0.0.12"
    - "10.0.0.13"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

### 3.5 Variante: `kubeadm` con `etcd` **externo**

Si vas por la topología externa, primero levantás el cluster `etcd` de 3 miembros con TLS mutuo (fuera del alcance de kubeadm; se hace con `etcdadm`, `static pods` o systemd + certificados propios), y luego apuntás el control plane a él. La sección `etcd` cambia de `local` a `external`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.31.0"
controlPlaneEndpoint: "k8s-api.example.com:6443"
networking:
  podSubnet: "10.244.0.0/16"
etcd:
  external:
    endpoints:
      - https://10.0.0.31:2379
      - https://10.0.0.32:2379
      - https://10.0.0.33:2379
    caFile:   /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
    keyFile:  /etc/kubernetes/pki/apiserver-etcd-client.key
```

> Con `etcd` externo, `kubeadm` **no** gestiona el ciclo de vida de `etcd`: los backups, upgrades y monitoreo de `etcd` son responsabilidad tuya, y los certs de cliente (`apiserver-etcd-client.*`) deben estar presentes en cada control plane antes del `init`.

---

## 4. Comandos CLI y salidas reales

### 4.1 Inicializar el primer control plane (cp1)

`--upload-certs` guarda los certificados del control plane cifrados en un `Secret` temporal del namespace `kube-system`, para que los otros CP los descarguen al unirse (evita copiarlos a mano).

```bash
$ sudo kubeadm init --config=kubeadm-config.yaml --upload-certs
```

```text
[init] Using Kubernetes version: v1.31.0
[preflight] Running pre-flight checks
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [cp1 kubernetes ...
        k8s-api.example.com] and IPs [10.96.0.1 10.0.0.11 10.0.0.10]
[control-plane] Creating static Pod manifest for "kube-apiserver"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[upload-certs] Storing the certificates in Secret "kubeadm-certs" in "kube-system"
[upload-certs] Using certificate key:
9063a1ccc9c5e926e02f245c06b8d9f0f7272cd3a2b0e5d8f3d7c4a1b6e8f2c1
[mark-control-plane] Marking the node cp1 as control-plane
...

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes by copying certificate
authorities and service account keys on each node and then running the
following as root:

  kubeadm join k8s-api.example.com:6443 --token 7gx1z9.abcd1234efgh5678 \
    --discovery-token-ca-cert-hash sha256:2f9d...c7a1 \
    --control-plane --certificate-key 9063a1ccc9c5e926e02f245c06b8d9f0f7272cd3a2b0e5d8f3d7c4a1b6e8f2c1

Then you can join any number of worker nodes by running the following on each:

  kubeadm join k8s-api.example.com:6443 --token 7gx1z9.abcd1234efgh5678 \
    --discovery-token-ca-cert-hash sha256:2f9d...c7a1
```

Configurar `kubectl` e instalar el CNI (sin red de Pods, los nodos quedan `NotReady`):

```bash
$ mkdir -p $HOME/.kube
$ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
$ kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

### 4.2 Unir cp2 y cp3 (control planes)

En cada nodo adicional, correr el comando `--control-plane` que imprimió el `init`:

```bash
$ sudo kubeadm join k8s-api.example.com:6443 --token 7gx1z9.abcd1234efgh5678 \
    --discovery-token-ca-cert-hash sha256:2f9d...c7a1 \
    --control-plane --certificate-key 9063a1ccc9c5e926e02f245c06b8d9f0f7272cd3a2b0e5d8f3d7c4a1b6e8f2c1
```

```text
[preflight] Running pre-flight checks
[download-certs] Downloading the certificates in Secret "kubeadm-certs"
[certs] Generating "apiserver" certificate and key
[etcd] Announced new etcd member joining to the existing etcd cluster
[etcd] Creating static Pod manifest for "etcd"
[etcd] Waiting for the new etcd member to join the cluster. This can take up to 40s
[mark-control-plane] Marking the node cp2 as control-plane

This node has joined the cluster and a new control plane instance was created.
```

> **Ventana de la certificate-key:** el `Secret` `kubeadm-certs` y su clave **expiran a las 2 horas** por defecto. Si pasó ese tiempo, regenerá la clave antes de unir un CP nuevo:
> ```bash
> $ sudo kubeadm init phase upload-certs --upload-certs
> $ sudo kubeadm token create --print-join-command   # nuevo token + hash
> ```

### 4.3 Unir workers

```bash
$ sudo kubeadm join k8s-api.example.com:6443 --token 7gx1z9.abcd1234efgh5678 \
    --discovery-token-ca-cert-hash sha256:2f9d...c7a1
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Estado del cluster y control plane

```bash
$ kubectl get nodes -o wide
NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP
cp1       Ready    control-plane   22m   v1.31.0   10.0.0.11
cp2       Ready    control-plane   15m   v1.31.0   10.0.0.12
cp3       Ready    control-plane   12m   v1.31.0   10.0.0.13
worker1   Ready    <none>          8m    v1.31.0   10.0.0.21
worker2   Ready    <none>          8m    v1.31.0   10.0.0.22
```

```bash
$ kubectl -n kube-system get pods -l tier=control-plane -o wide
NAME                    READY   STATUS    NODE
etcd-cp1                1/1     Running   cp1
etcd-cp2                1/1     Running   cp2
etcd-cp3                1/1     Running   cp3
kube-apiserver-cp1      1/1     Running   cp1
kube-apiserver-cp2      1/1     Running   cp2
kube-apiserver-cp3      1/1     Running   cp3
kube-controller-manager-cp1  1/1  Running   cp1
kube-scheduler-cp1           1/1  Running   cp1
```

**Nota sobre controller-manager y scheduler:** aunque corren en los 3 CP, solo **uno de cada uno está activo** a la vez. Usan **leader election** vía un `Lease` en `kube-system`; los demás quedan en standby. Verificá quién es el líder:

```bash
$ kubectl -n kube-system get lease kube-scheduler \
    -o jsonpath='{.spec.holderIdentity}{"\n"}'
cp1_a1b2c3d4-...

$ kubectl -n kube-system get lease kube-controller-manager \
    -o jsonpath='{.spec.holderIdentity}{"\n"}'
cp2_e5f6g7h8-...
```

### 5.2 Salud del cluster `etcd` (el chequeo más importante)

En un CP con etcd stacked, usar el propio pod de etcd o el binario con los certs de kubeadm:

```bash
$ export ETCDCTL_API=3
$ export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
$ export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
$ export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

$ sudo -E etcdctl --endpoints=https://10.0.0.11:2379 member list -w table
+------------------+---------+------+--------------------------+--------------------------+
|        ID        | STATUS  | NAME |        PEER ADDRS         |       CLIENT ADDRS       |
+------------------+---------+------+--------------------------+--------------------------+
| 8e9e05c52164694d | started | cp1  | https://10.0.0.11:2380   | https://10.0.0.11:2379   |
| a5f3b7c8d9e01234 | started | cp2  | https://10.0.0.12:2380   | https://10.0.0.12:2379   |
| f1e2d3c4b5a67890 | started | cp3  | https://10.0.0.13:2380   | https://10.0.0.13:2379   |
+------------------+---------+------+--------------------------+--------------------------+
```

**El comando de diagnóstico definitivo** — estado por endpoint, incluyendo quién es el líder y si algún miembro tiene *alarms*:

```bash
$ sudo -E etcdctl \
    --endpoints=https://10.0.0.11:2379,https://10.0.0.12:2379,https://10.0.0.13:2379 \
    endpoint status --cluster -w table
+-------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT         |        ID        | VERSION | DB SIZE | IS LEADER | RAFT INDEX |
+-------------------------+------------------+---------+---------+-----------+------------+
| https://10.0.0.11:2379  | 8e9e05c52164694d |  3.5.15 |   25 MB |     false |      98234 |
| https://10.0.0.12:2379  | a5f3b7c8d9e01234 |  3.5.15 |   25 MB |      true |      98234 |
| https://10.0.0.13:2379  | f1e2d3c4b5a67890 |  3.5.15 |   25 MB |     false |      98234 |
+-------------------------+------------------+---------+---------+-----------+------------+

$ sudo -E etcdctl \
    --endpoints=https://10.0.0.11:2379,https://10.0.0.12:2379,https://10.0.0.13:2379 \
    endpoint health --cluster
https://10.0.0.12:2379 is healthy: successfully committed proposal: took = 8.1ms
https://10.0.0.11:2379 is healthy: successfully committed proposal: took = 9.4ms
https://10.0.0.13:2379 is healthy: successfully committed proposal: took = 7.8ms
```

**Qué mirar:**
- **Exactamente un `IS LEADER=true`.** Cero líderes = no hay quórum. Dos líderes = ojo, indica partición de red o lecturas contra estados stale.
- **`RAFT INDEX` cercano entre miembros.** Un miembro muy atrasado está lento o particionado.
- **`DB SIZE` divergente** entre miembros sugiere un problema de compactación/defrag en uno de ellos.

### 5.3 Simulación de fallo: perder un control plane

```bash
# Apagamos cp3 para simular un fallo de nodo
$ sudo systemctl stop kubelet && sudo crictl stop $(sudo crictl ps -q)

# El cluster sigue funcionando: quórum 2 de 3 intacto
$ kubectl get nodes
NAME      STATUS     ROLES           AGE   VERSION
cp1       Ready      control-plane   30m   v1.31.0
cp2       Ready      control-plane   23m   v1.31.0
cp3       NotReady   control-plane   20m   v1.31.0    # <── caído, sin impacto
worker1   Ready      <none>          16m   v1.31.0

# El apiserver de cp3 sale de rotación en HAProxy (estado DOWN)
$ echo "show servers state" | sudo socat stdio /run/haproxy/admin.sock | grep cp3
# cp3 aparece con srv_op_state=0 (DOWN)

$ sudo -E etcdctl --endpoints=https://10.0.0.13:2379 endpoint health
{"level":"warn","msg":"unhealthy cluster","endpoint":"https://10.0.0.13:2379"}
Error: unhealthy cluster    # ese endpoint concreto está caído, pero el cluster tiene quórum
```

### 5.4 Recuperación: quitar un miembro `etcd` muerto

Si un CP se pierde permanentemente, **primero** hay que sacar su miembro de `etcd` (si no, sigue contando para el quórum) y luego resetear el nodo:

```bash
# Encontrar el ID del miembro muerto (cp3)
$ sudo -E etcdctl member list -w table
# ... f1e2d3c4b5a67890 | cp3 ...

# Removerlo del cluster etcd
$ sudo -E etcdctl member remove f1e2d3c4b5a67890
Member f1e2d3c4b5a67890 removed from cluster ...

# Limpiar el nodo caído desde el apiserver
$ kubectl delete node cp3

# En cp3 (si vuelve), resetear antes de re-unir
$ sudo kubeadm reset -f
$ sudo rm -rf /etc/kubernetes /var/lib/etcd
```

Luego re-unir cp3 con un `join --control-plane` nuevo (regenerando token y certificate-key como en §4.2).

### 5.5 Matriz de diagnóstico rápido

| Síntoma | Causa probable | Verificación |
|---|---|---|
| `kubectl` da timeout intermitente | LB entrega un apiserver caído | `show stat` en HAProxy `/stats`; revisar `check` en backend |
| `kubectl` totalmente colgado | Pérdida de quórum en `etcd` | `etcdctl endpoint status --cluster`; contar miembros vivos |
| `etcdserver: request timed out` | Latencia de disco / IO saturado | `etcd_disk_wal_fsync_duration_seconds` (p99 > 10 ms es señal roja) |
| CP nuevo no se une | Token o certificate-key expirados (2 h) | `kubeadm token list`; regenerar con `upload-certs` |
| VIP no responde | keepalived caído o script de health falla | `systemctl status keepalived`; `ip addr show eth0` (¿tiene el VIP?) |
| Dos nodos reclaman el VIP | Split-brain VRRP (firewall bloquea multicast 224.0.0.18) | Verificar tráfico VRRP entre LBs |
| Cambios no se aplican pero `kubectl` responde | controller-manager/scheduler sin líder | `kubectl -n kube-system get lease` |

---

## 6. Referencias

- **CNCF Curriculum (KCA):** https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- **Options for Highly Available Topology (stacked vs. external etcd):** https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- **Creating Highly Available Clusters with kubeadm:** https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- **Set up a High Availability etcd Cluster with kubeadm:** https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/setup-ha-etcd-with-kubeadm/
- **Operating etcd clusters for Kubernetes:** https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- **etcd — FAQ (quórum, tamaño de cluster, tolerancia a fallos):** https://etcd.io/docs/latest/faq/
- **etcd — Disaster recovery (snapshot, restore):** https://etcd.io/docs/latest/op-guide/recovery/
- **etcd — Runtime reconfiguration (member add/remove):** https://etcd.io/docs/latest/op-guide/runtime-configuration/
- **kubeadm reference — `kubeadm init` / `join` / phases:** https://kubernetes.io/docs/reference/setup-tools/kubeadm/
- **kubeadm ClusterConfiguration v1beta4 API:** https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- **kube-vip — Kubernetes Control Plane (ARP/BGP, static pod):** https://kube-vip.io/docs/usage/kubernetes-control-plane/
- **HAProxy Configuration Manual:** https://docs.haproxy.org/2.8/configuration.html
- **keepalived — User Guide (VRRP):** https://www.keepalived.org/manpage.html