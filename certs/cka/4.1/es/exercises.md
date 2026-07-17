# Ejercicios guiados — 4.1 Prepare underlying infrastructure for installing a Kubernetes cluster

**Certificación:** CKA v1.35 · **Peso en el examen:** 3.57%

**Fuentes de referencia:**
- CNCF, *CKA Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs, *Installing kubeadm* — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes docs, *Container runtimes* — https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes docs, *Ports and Protocols* — https://kubernetes.io/docs/reference/networking/ports-and-protocols/

**Requisitos previos:** al menos dos VMs Linux (Ubuntu 22.04/24.04 se usa en este ejercicio) con acceso `sudo`, una destinada a control-plane y otra a worker node. Conectividad de red entre ambas. Ejecutá cada paso en **todos los nodos** salvo que se indique lo contrario.

---

## Paso 1: Verificar unicidad de hostname, MAC address y product_uuid

kubeadm requiere que cada nodo del cluster sea identificable de forma única. Un cluster con hostnames duplicados, o con VMs clonadas que comparten MAC address o `product_uuid` (típico al clonar templates sin regenerar estos valores), va a fallar de forma silenciosa o intermitente al registrar nodos.

1. En cada nodo, revisá el hostname:
   ```bash
   hostnamectl status | grep hostname
   ```
2. Revisá la MAC address de la interfaz principal:
   ```bash
   ip link show
   ```
3. Revisá el `product_uuid`:
   ```bash
   sudo cat /sys/class/dmi/id/product_uuid
   ```
4. Comparé los tres valores entre control-plane y worker node. Si algún valor coincide entre nodos, corregilo (para hostname: `sudo hostnamectl set-hostname <nuevo-nombre>`; para MAC/product_uuid en VMs clonadas, regenerá la interfaz de red o recreá la VM desde el hipervisor).

**Preguntas de verificación:**
1. ¿Por qué kubeadm no puede garantizar el comportamiento del cluster si dos nodos comparten el mismo `product_uuid`?
2. ¿Qué componente de Kubernetes usa estos identificadores para diferenciar nodos dentro del cluster?

---

## Paso 2: Verificar puertos requeridos entre nodos

Cada rol de nodo expone un conjunto de puertos que deben estar accesibles desde otros nodos del cluster (no necesariamente desde Internet).

1. En el nodo control-plane, verificá qué puertos están en `LISTEN`:
   ```bash
   sudo ss -tulpn | grep LISTEN
   ```
2. Confirmá conceptualmente los puertos mínimos de un control-plane node: `6443` (API server), `2379-2380` (etcd, solo si es stacked), `10250` (kubelet API), `10251` (kube-scheduler, si no usa `--bind-address` restringido), `10252` (kube-controller-manager).
3. Confirmá los puertos mínimos de un worker node: `10250` (kubelet API), `30000-32767` (NodePort Services).
4. Desde el worker node, probá alcanzar el puerto del API server del control-plane:
   ```bash
   nc -zv <IP-control-plane> 6443
   ```
5. Si tenés un firewall activo (`ufw`, `firewalld`), abrí explícitamente los puertos correspondientes al rol de cada nodo en lugar de deshabilitar el firewall por completo.

**Preguntas de verificación:**
1. ¿Por qué el rango `30000-32767` debe estar accesible en los worker nodes pero no es un puerto único como `6443`?
2. Si `nc -zv` falla contra el puerto `6443` del control-plane, ¿qué dos causas típicas investigarías primero?

---

## Paso 3: Deshabilitar swap de forma permanente

El kubelet, por defecto, no arranca (o degrada el scheduling de QoS) si detecta swap habilitado, porque el manejo de memoria de Kubernetes asume que los límites de memoria de los Pods son deterministas.

1. Deshabilitá el swap para la sesión actual:
   ```bash
   sudo swapoff -a
   ```
2. Verificá que no quede activo:
   ```bash
   free -h
   ```
3. Comentá cualquier entrada de swap en `/etc/fstab` para que no se reactive en el próximo reboot:
   ```bash
   sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
   ```
4. (Alternativa soportada desde kubelet reciente) si tu escenario requiere mantener swap habilitado, documentá que se necesita configurar `failSwapOn: false` y `memorySwap.swapBehavior` en la configuración del kubelet — pero para este ejercicio, y para el enfoque por defecto del examen, deshabilitalo.

**Preguntas de verificación:**
1. ¿Qué pasa con el kubelet si arranca con swap activo y no se configuró explícitamente para tolerarlo?
2. ¿Por qué el paso de `/etc/fstab` es necesario además de `swapoff -a`?

---

## Paso 4: Cargar los kernel modules requeridos

El networking de Kubernetes (Services, forwarding entre Pods) depende de `overlay` (usado por containerd para el filesystem de las imágenes) y `br_netfilter` (permite que iptables vea el tráfico que atraviesa un bridge de Linux).

1. Configurá la carga de los módulos en cada boot:
   ```bash
   cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF
   ```
2. Cargalos inmediatamente sin reiniciar:
   ```bash
   sudo modprobe overlay
   sudo modprobe br_netfilter
   ```
3. Confirmá que estén cargados:
   ```bash
   lsmod | grep -E 'overlay|br_netfilter'
   ```

**Preguntas de verificación:**
1. ¿Qué problema de networking observarías en los Pods si `br_netfilter` no estuviera cargado?
2. ¿Por qué `overlay` es relevante para el container runtime y no directamente para el kube-proxy?

---

## Paso 5: Configurar parámetros de sysctl para networking

Con `br_netfilter` cargado, además hay que decirle explícitamente al kernel que aplique reglas de iptables al tráfico que atraviesa bridges, y habilitar IP forwarding para que el nodo pueda rutear tráfico entre Pods.

1. Definí los parámetros persistentes:
   ```bash
   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables  = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward                 = 1
   EOF
   ```
2. Aplicalos sin reiniciar:
   ```bash
   sudo sysctl --system
   ```
3. Verificá los tres valores:
   ```bash
   sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
   ```

**Preguntas de verificación:**
1. Si `net.ipv4.ip_forward` queda en `0`, ¿qué tipo de comunicación entre Pods de distintos nodos se rompe?
2. ¿Qué relación tiene este paso con el Paso 4?

---

## Paso 6: Instalar y configurar un container runtime (containerd)

kubeadm necesita un container runtime compatible con CRI (Container Runtime Interface). Vamos a instalar `containerd`.

1. Instalá containerd desde los repos de Ubuntu (o desde el repo oficial de Docker si necesitás una versión más reciente):
   ```bash
   sudo apt update
   sudo apt install -y containerd
   ```
2. Generá la configuración por defecto:
   ```bash
   sudo mkdir -p /etc/containerd
   containerd config default | sudo tee /etc/containerd/config.toml
   ```
3. Editá `/etc/containerd/config.toml` y habilitá `SystemdCgroup` dentro de la sección `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]`:
   ```bash
   sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
   ```
4. Reiniciá y habilitá el servicio:
   ```bash
   sudo systemctl restart containerd
   sudo systemctl enable containerd
   ```
5. Verificá que esté activo:
   ```bash
   sudo systemctl status containerd --no-pager
   ```

**Preguntas de verificación:**
1. ¿Por qué es necesario que el cgroup driver de containerd coincida con el del kubelet?
2. ¿Qué componente de Kubernetes se comunica directamente con containerd a través de CRI?

---

## Paso 7: Configurar el cgroup driver del sistema como `systemd`

Tanto el container runtime como el kubelet deben usar el mismo cgroup driver. En distribuciones modernas basadas en systemd, el driver recomendado es `systemd` (no `cgroupfs`), ya definido en el Paso 6 para containerd.

1. Confirmá que el sistema use `systemd` como init system:
   ```bash
   ps -p 1 -o comm=
   ```
2. Confirmá que quedó seteado en containerd:
   ```bash
   grep SystemdCgroup /etc/containerd/config.toml
   ```
3. (Este valor se usará también en el Paso 8 al inicializar kubeadm; el kubelet toma `SystemdCgroup` como default automáticamente en versiones recientes, pero es buena práctica verificarlo explícitamente después de `kubeadm init`.)

**Preguntas de verificación:**
1. ¿Qué síntoma observarías en el kubelet si su cgroup driver no coincide con el de containerd?
2. ¿Por qué `cgroupfs` es desaconsejado en distribuciones que ya usan `systemd` para el resto de los servicios del sistema?

---

## Paso 8: Instalar `kubeadm`, `kubelet` y `kubectl`

Usamos el repositorio oficial de paquetes de Kubernetes (`pkgs.k8s.io`), versionado por minor release.

1. Instalá dependencias y agregá la GPG key del repo (ejemplo para la serie v1.35):
   ```bash
   sudo apt update
   sudo apt install -y apt-transport-https ca-certificates curl gpg
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | \
     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   ```
2. Agregá el repo:
   ```bash
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | \
     sudo tee /etc/apt/sources.list.d/kubernetes.list
   ```
3. Instalá los paquetes:
   ```bash
   sudo apt update
   sudo apt install -y kubelet kubeadm kubectl
   ```
4. Fijá las versiones para que no se actualicen accidentalmente con `apt upgrade`:
   ```bash
   sudo apt-mark hold kubelet kubeadm kubectl
   ```
5. Verificá las versiones instaladas:
   ```bash
   kubeadm version
   kubelet --version
   kubectl version --client
   ```

**Preguntas de verificación:**
1. ¿Por qué el repositorio está versionado por minor release (`v1.35`) en lugar de tener un único repo para todas las versiones?
2. ¿Qué riesgo mitiga `apt-mark hold` en un cluster ya inicializado?
3. ¿`kubectl` es un requisito para que el nodo funcione como parte del cluster, o es solo una herramienta de administración?

---

## Paso 9: Validar que la infraestructura está lista con preflight checks

kubeadm incluye validaciones automáticas antes de inicializar el cluster; correrlas manualmente permite detectar problemas de infraestructura antes de comprometerse con `kubeadm init`.

1. En el nodo control-plane, corré solo la fase de preflight:
   ```bash
   sudo kubeadm init phase preflight
   ```
2. Revisá que no haya errores relacionados a swap, módulos de kernel, puertos ocupados o el container runtime.
3. (Opcional) descargá por adelantado las imágenes de los componentes del control plane, para evitar demoras o fallos de red durante `kubeadm init`:
   ```bash
   sudo kubeadm config images pull --kubernetes-version v1.35.0
   ```

**Preguntas de verificación:**
1. ¿Qué ventaja tiene correr `kubeadm init phase preflight` por separado en vez de ir directo a `kubeadm init` completo?
2. Si `kubeadm config images pull` falla por timeout, ¿qué paso previo de este ejercicio revisarías primero?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Paso 1**
1. Porque componentes internos (como la asignación de identidad de nodo y el manejo de certificados) pueden asumir unicidad de estos valores; con duplicados, el comportamiento del scheduler y del kubelet frente a ese nodo queda indefinido.
2. El kubelet, al registrarse contra el API server, usa el hostname (o el `--node-name` configurado) como identidad del nodo dentro del cluster.

**Paso 2**
1. Porque `30000-32767` es un rango reservado para NodePort Services: cada Service tipo NodePort ocupa dinámicamente un puerto dentro de ese rango en todos los worker nodes, no es un puerto fijo de un componente del control plane.
2. Un firewall bloqueando el puerto en el control-plane, o el kube-apiserver no estando activo/escuchando en esa interfaz todavía.

**Paso 3**
1. El kubelet falla al iniciar (o entra en un estado degradado) porque no puede garantizar los límites de memoria de QoS de los Pods con swap activo, salvo que se configure explícitamente `failSwapOn: false`.
2. Porque `swapoff -a` solo afecta la sesión en curso; sin editar `/etc/fstab`, el swap se reactiva en el próximo reboot del nodo.

**Paso 4**
1. El tráfico entre Pods que atraviesa el bridge de red del nodo no sería visible para iptables, rompiendo el forwarding y las reglas de Services/NetworkPolicy.
2. `overlay` es el filesystem driver que usa containerd para construir las capas de las imágenes de contenedor; no está relacionado con el path de red del kube-proxy.

**Paso 5**
1. Se rompe el ruteo de tráfico entre Pods ubicados en distintos nodos, ya que el nodo dejaría de reenviar paquetes IP que no son para sí mismo.
2. `br_netfilter` habilita que el tráfico de bridge sea visible para iptables; los sysctl del Paso 5 son los que efectivamente activan que iptables procese ese tráfico y que el nodo haga IP forwarding.

**Paso 6**
1. Porque si el kubelet y el container runtime usan cgroup drivers distintos, ambos administran cgroups de forma inconsistente, lo que puede causar inestabilidad del nodo bajo presión de recursos.
2. El kubelet, a través de la interfaz CRI (Container Runtime Interface).

**Paso 7**
1. El kubelet puede fallar al iniciar, o los Pods pueden quedar en estados inestables por conflictos en la jerarquía de cgroups entre el runtime y el kubelet.
2. Porque mezclar `cgroupfs` (gestionado por el runtime/kubelet) con `systemd` (que ya gestiona cgroups para el resto de los servicios) genera dos manejadores de cgroups compitiendo por los mismos recursos en el nodo.

**Paso 8**
1. Porque distintas minor releases de Kubernetes pueden requerir versiones distintas de `kubeadm`/`kubelet`/`kubectl`, y fijar el repo por versión evita instalar accidentalmente una release incompatible con el resto del cluster.
2. Mitiga que un `apt upgrade` de rutina actualice `kubelet`/`kubeadm`/`kubectl` a una minor version distinta de la que corre el resto del cluster, lo cual puede romper la compatibilidad de versiones soportada por Kubernetes (skew policy).
3. Es una herramienta de administración (cliente que habla con el API server); el nodo puede funcionar como parte del cluster sin `kubectl` instalado, ya que lo que se comunica con el control plane es el kubelet.

**Paso 9**
1. Permite aislar y corregir errores de infraestructura (swap, módulos, puertos, runtime) sin dejar el cluster a medio inicializar ni tener que hacer `kubeadm reset` si algo falla a mitad de camino.
2. La conectividad de red de salida del nodo control-plane (Paso 2 y accesibilidad general a internet/registry), ya que las imágenes se descargan desde un container registry externo.

</details>
