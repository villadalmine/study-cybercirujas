# 4.1 Prepare underlying infrastructure for installing a Kubernetes cluster

**Peso en el examen: 3.57%**

## Qué cubre este objetivo

Antes de correr `kubeadm init` (o cualquier instalador) hay un trabajo de *infrastructure readiness* que es responsabilidad del administrador: asegurarse de que cada máquina (bare-metal, VM o instancia cloud) cumple los requisitos mínimos de hardware, tiene conectividad de red completa entre nodos, corre un container runtime compatible con CRI, y tiene el kernel configurado para permitir el forwarding de tráfico entre pods. Si esta etapa se hace mal, el cluster puede levantar "a medias" (kubelet en `NotReady`, CNI que no asigna IPs, pods en `CrashLoopBackOff` por errores de red) y el diagnóstico es mucho más costoso que prevenirlo.

Este tema es la base sobre la que se apoya 4.2 (bootstrapping con kubeadm): acá no se instala Kubernetes todavía, se prepara el terreno.

## 1. Requisitos de hardware y sistema operativo

Mínimos recomendados por nodo (documentados en el proyecto kubeadm):

| Recurso | Control plane | Worker |
|---|---|---|
| CPU | 2 vCPU | 1 vCPU |
| RAM | 2 GiB | 1 GiB |
| Disco | 20 GiB libres | 20 GiB libres |
| Swap | deshabilitado | deshabilitado |

En producción real estos mínimos se quedan cortos casi siempre; son el piso para que `kubeadm init` no falle en el preflight check, no un dimensionamiento serio de capacidad.

Sistema operativo: cualquier distribución Linux compatible con systemd (Ubuntu, Debian, RHEL/CentOS/Rocky, Flatcar, etc.). Windows Server es soportado solo para *worker nodes* en escenarios híbridos, nunca para control plane.

## 2. Requisitos de red entre nodos

Cada nodo necesita:

- **Hostname único** dentro del cluster.
- **MAC address único** por interfaz de red.
- **`product_uuid` único** (relevante en VMs clonadas de una misma imagen/template, donde puede repetirse).
- **Conectividad full mesh**: todos los nodos deben poder alcanzarse entre sí (y el control plane debe poder llegar a todos los workers) en los puertos que usa Kubernetes.

Verificación típica antes de instalar nada:

```bash
# Hostname
hostnamectl status | grep "Static hostname"

# MAC address de la interfaz principal
ip link show eth0 | awk '/ether/ {print $2}'

# product_uuid (clave en VMs clonadas)
sudo cat /sys/class/dmi/id/product_uuid
```

Si dos nodos devuelven el mismo `product_uuid` (típico al clonar una VM sin regenerar la identidad), `kubeadm join` puede fallar de forma confusa más adelante. Conviene chequearlo *antes* de instalar nada.

## 3. Puertos requeridos

Kubernetes necesita puertos específicos abiertos entre nodos. Si hay un firewall (`ufw`, `firewalld`, security groups de la nube, NSGs) hay que permitirlos explícitamente.

**Control plane:**

| Puerto | Componente |
|---|---|
| 6443 | kube-apiserver |
| 2379-2380 | etcd (client/peer) |
| 10250 | kubelet API |
| 10259 | kube-scheduler |
| 10257 | kube-controller-manager |

**Worker nodes:**

| Puerto | Componente |
|---|---|
| 10250 | kubelet API |
| 30000-32767 | NodePort Services |

Ejemplo con `ufw` en Ubuntu para un nodo de control plane:

```bash
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 10259/tcp
sudo ufw allow 10257/tcp
sudo ufw status
```

Salida esperada:

```
Status: active

To                         Action      From
--                         ------      ----
6443/tcp                   ALLOW       Anywhere
2379:2380/tcp               ALLOW       Anywhere
10250/tcp                  ALLOW       Anywhere
10259/tcp                  ALLOW       Anywhere
10257/tcp                  ALLOW       Anywhere
```

En muchos labs y hasta en algunos clusters de producción simples se opta directamente por deshabilitar el firewall local del host y delegar el filtrado al security group / NSG de la nube, para evitar que reglas locales interfieran con las que gestiona la CNI (iptables/nftables).

## 4. Deshabilitar swap

kubelet se niega a arrancar con swap activo salvo que se lo habilite explícitamente (`NodeSwap` feature gate + `failSwapOn: false` en la config de kubelet), y esa no es la configuración por defecto que se evalúa en el examen. Lo esperable es deshabilitarlo:

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

Verificación:

```bash
free -h
```

```
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       412Mi       2.9Gi        1.0Mi       498Mi       3.2Gi
Swap:             0B          0B          0B
```

`Swap: 0B` en todas las columnas confirma que quedó desactivado también tras un reboot (por el cambio en `/etc/fstab`).

## 5. Módulos de kernel y parámetros sysctl

Kubernetes necesita que el tráfico que pasa por los bridges de red de los pods sea visible para `iptables`, y que el forwarding de IP esté habilitado.

Módulos requeridos:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

- `overlay`: filesystem que usan containerd/CRI-O para las capas de las imágenes.
- `br_netfilter`: permite que el tráfico L2 en bridges sea procesado por reglas de iptables (necesario para que las políticas de red y el kube-proxy funcionen correctamente).

Parámetros sysctl:

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

Verificación:

```bash
sudo sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```

```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

Sin `ip_forward = 1`, el nodo no reenvía paquetes entre interfaces y los pods pierden conectividad cruzada (por ejemplo, pod-to-pod entre nodos distintos vía la CNI).

## 6. Container runtime (CRI)

Desde que Kubernetes eliminó `dockershim` (1.24+), el nodo necesita un runtime que implemente **Container Runtime Interface (CRI)** directamente: `containerd`, `CRI-O` o similares. `containerd` es la opción más usada en el examen y en la práctica.

Instalación típica en Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

Punto crítico que suele fallar en labs: el **cgroup driver**. Kubelet espera que el runtime use `systemd` como cgroup driver (coincidiendo con el driver del propio sistema operativo). Hay que editarlo explícitamente en `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd --no-pager
```

```
● containerd.service - containerd container runtime
     Loaded: loaded (/lib/systemd/system/containerd.service; enabled; vendor preset: enabled)
     Active: active (running) since ...
```

Si `SystemdCgroup` queda en `false` (o inconsistente con el driver de kubelet), típicamente se ve `kubelet` reportando errores de cgroup driver mismatch en `journalctl -u kubelet` una vez que se corre `kubeadm init`.

## 7. Checklist de verificación previa a la instalación

Antes de pasar a 4.2 (bootstrapping con kubeadm), conviene validar en cada nodo:

```bash
# hostname y uuid únicos
hostnamectl status
sudo cat /sys/class/dmi/id/product_uuid

# swap apagado
free -h

# módulos cargados
lsmod | grep -E 'overlay|br_netfilter'

# sysctl aplicado
sysctl net.ipv4.ip_forward

# runtime corriendo y con socket CRI disponible
sudo systemctl is-active containerd
sudo crictl info 2>/dev/null | head -n 5

# conectividad entre nodos en el puerto del API server
nc -zv <ip-control-plane> 6443
```

## Referencias

- [Installing kubeadm — Before you begin](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Ports and Protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- [kubeadm init — Preflight checks](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#preflight-checks)
- [Swap memory management in Kubernetes](https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory)
- [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)