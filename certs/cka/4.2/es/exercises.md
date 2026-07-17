# 4.2 — Crear y gestionar clusters de Kubernetes usando kubeadm

Ejercicios guiados para practicar el ciclo de vida completo de un cluster gestionado con `kubeadm`: preparación de nodos, `init`, instalación de CNI, `join` de workers, gestión de tokens y certificados, y remoción de nodos.

**Entorno asumido:** tres máquinas Linux (Ubuntu/Debian) con conectividad entre sí — `cp-01` (control plane), `worker-01` y `worker-02`. Container runtime: `containerd`. Usuario con privilegios `sudo`.

## Ejercicio 1 — Preparar los nodos para kubeadm

Repetí estos pasos en **las tres máquinas** (`cp-01`, `worker-01`, `worker-02`).

1. Deshabilitá el swap, requisito estricto del kubelet:
   ```bash
   sudo swapoff -a
   sudo sed -i '/ swap /s/^/#/' /etc/fstab
   ```

2. Cargá los módulos de kernel que necesitan el container runtime y la red de pods:
   ```bash
   cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF
   sudo modprobe overlay
   sudo modprobe br_netfilter
   ```

3. Configurá los parámetros de `sysctl` para que el tráfico de bridge pase por las reglas de iptables:
   ```bash
   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables  = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward                 = 1
   EOF
   sudo sysctl --system
   ```

4. Instalá `containerd` y activá `SystemdCgroup`, requerido por kubeadm:
   ```bash
   sudo apt-get update && sudo apt-get install -y containerd
   sudo mkdir -p /etc/containerd
   containerd config default | sudo tee /etc/containerd/config.toml
   sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
   sudo systemctl restart containerd
   ```

5. Agregá el repositorio de paquetes de Kubernetes e instalá `kubeadm`, `kubelet` y `kubectl`, fijando la versión con `apt-mark hold`:
   ```bash
   KUBE_VERSION=v1.34
   sudo mkdir -m 755 -p /etc/apt/keyrings
   curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/Release.key | \
     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/ /" | \
     sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   sudo apt-get install -y kubelet kubeadm kubectl
   sudo apt-mark hold kubelet kubeadm kubectl
   ```

6. Verificá que las tres herramientas quedaron instaladas con la misma versión:
   ```bash
   kubeadm version -o short
   kubelet --version
   kubectl version --client
   ```

**Preguntas**

1. ¿Por qué kubeadm exige deshabilitar el swap antes de inicializar un nodo?
2. ¿Qué rol cumple el módulo de kernel `br_netfilter` en un cluster de Kubernetes?
3. ¿Qué problema evitás al usar `apt-mark hold` sobre los paquetes de kubeadm/kubelet/kubectl?

## Ejercicio 2 — Inicializar el control plane

Ejecutá estos pasos **solo en `cp-01`**.

1. Inicializá el cluster indicando el CIDR de la red de pods (debe coincidir con el que espera el CNI que vas a instalar) y el endpoint que usarán los demás nodos para contactar al control plane:
   ```bash
   sudo kubeadm init \
     --pod-network-cidr=10.244.0.0/16 \
     --control-plane-endpoint=cp-01 \
     --upload-certs
   ```

2. Guardá el bloque final del output: contiene el comando `kubeadm join` para workers y la variante con `--control-plane` para agregar más control planes en una topología HA. Lo vas a necesitar en el Ejercicio 4.

3. Configurá `kubectl` para tu usuario copiando el kubeconfig administrativo que generó kubeadm:
   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```

4. Verificá el estado del control plane:
   ```bash
   kubectl get nodes
   kubectl get pods -n kube-system
   ```
   El nodo `cp-01` va a figurar en estado `NotReady` — es esperado, todavía falta instalar el CNI.

**Preguntas**

1. ¿Qué componentes del control plane corren como static pods gestionados directamente por el kubelet local, sin pasar por el scheduler?
2. ¿Por qué el nodo queda en `NotReady` inmediatamente después de `kubeadm init`?
3. ¿Qué garantiza el flag `--upload-certs` y en qué escenario es imprescindible?

## Ejercicio 3 — Instalar el CNI plugin

1. Instalá Flannel como plugin de red de pods (coincide con el CIDR `10.244.0.0/16` usado en el `init`):
   ```bash
   kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
   ```

2. Esperá a que los pods de `kube-flannel` queden `Running`:
   ```bash
   kubectl get pods -n kube-flannel -w
   ```

3. Confirmá que el control plane pasó a `Ready`:
   ```bash
   kubectl get nodes
   ```

**Preguntas**

1. ¿Por qué `kubeadm init` no instala un CNI plugin por defecto?
2. Si hubieras elegido un CIDR distinto al que asume el manifest de Flannel, ¿qué síntoma verías en los pods?

## Ejercicio 4 — Unir workers al cluster

Ejecutá en `worker-01` y `worker-02`.

1. Pegá el comando `kubeadm join` que guardaste en el Ejercicio 2. Tiene esta forma:
   ```bash
   sudo kubeadm join cp-01:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```

2. Volviendo a `cp-01`, confirmá que ambos workers aparecen en el cluster:
   ```bash
   kubectl get nodes -o wide
   ```

3. Etiquetá los workers con su rol (kubeadm no lo hace automáticamente):
   ```bash
   kubectl label node worker-01 node-role.kubernetes.io/worker=
   kubectl label node worker-02 node-role.kubernetes.io/worker=
   ```

**Preguntas**

1. ¿Qué verifica el `--discovery-token-ca-cert-hash` durante el proceso de join?
2. ¿Qué componentes corren en cada worker node después del join, y cuáles NO corren ahí a diferencia del control plane?

## Ejercicio 5 — Gestión de tokens de bootstrap

El token del `kubeadm init` original expira a las 24 horas por defecto. Practicá crear uno nuevo.

1. Listá los tokens activos:
   ```bash
   kubeadm token list
   ```

2. Generá un token nuevo con TTL corto y el comando de join listo para copiar:
   ```bash
   kubeadm token create --ttl 10m --print-join-command
   ```

3. Si necesitás el hash del certificado CA por separado, para armar el join manualmente:
   ```bash
   openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
     openssl rsa -pubin -outform der 2>/dev/null | \
     openssl dgst -sha256 -hex | sed 's/^.* //'
   ```

4. Borrá un token que ya no necesitás:
   ```bash
   kubeadm token delete <token>
   ```

**Preguntas**

1. ¿Por qué kubeadm hace expirar los tokens de bootstrap en vez de dejarlos válidos indefinidamente?
2. ¿Qué comando usarías para agregar un worker nuevo a un cluster que ya lleva varios días corriendo, sin reiniciar nada en el control plane?

## Ejercicio 6 — Certificados del cluster

Los certificados que genera `kubeadm init` tienen un año de validez por defecto.

1. Revisá cuándo vencen los certificados del control plane:
   ```bash
   sudo kubeadm certs check-expiration
   ```

2. Renová todos los certificados manualmente:
   ```bash
   sudo kubeadm certs renew all
   ```

3. Los procesos del control plane ya cargaron los certificados viejos en memoria: renovar el archivo en disco no alcanza. Forzá que el kubelet recree los static pods moviendo temporalmente sus manifests fuera del directorio que vigila:
   ```bash
   sudo mkdir -p /tmp/manifests-backup
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml \
           /etc/kubernetes/manifests/kube-controller-manager.yaml \
           /etc/kubernetes/manifests/kube-scheduler.yaml \
           /tmp/manifests-backup/
   sleep 20
   sudo mv /tmp/manifests-backup/*.yaml /etc/kubernetes/manifests/
   ```

4. Confirmá las nuevas fechas de expiración:
   ```bash
   sudo kubeadm certs check-expiration
   ```

**Preguntas**

1. ¿Por qué renovar los certificados no alcanza por sí solo, y hace falta mover los manifests estáticos (o reiniciar los componentes)?
2. ¿Qué comando de kubeadm automatiza la renovación de certificados como parte de un upgrade de versión?

## Ejercicio 7 — Remover un nodo del cluster

Vas a dar de baja `worker-02` de forma prolija.

1. Desde `cp-01`, marcá el nodo como no programable y movele los pods:
   ```bash
   kubectl cordon worker-02
   kubectl drain worker-02 --ignore-daemonsets --delete-emptydir-data
   ```

2. Eliminá el objeto Node del API server:
   ```bash
   kubectl delete node worker-02
   ```

3. En `worker-02`, revertí los cambios que hizo kubeadm (certificados, `kubelet.conf`, reglas de iptables/IPVS):
   ```bash
   sudo kubeadm reset
   sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
   ```

4. (Opcional) Limpiá también el estado de la CNI en `worker-02`:
   ```bash
   sudo rm -rf /etc/cni/net.d
   ```

**Preguntas**

1. ¿Por qué hay que hacer `drain` antes de `delete node`, y qué pasaría si borraras el Node directamente sin drenarlo?
2. ¿Qué hace exactamente `kubeadm reset`, y qué NO revierte (pista: pensá en el objeto Node del lado del API server)?

## Fuentes

- CNCF, *Certified Kubernetes Administrator (CKA) Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

1. El kubelet no soporta swap habilitado de forma confiable: afecta el cálculo de límites de memoria y el comportamiento del eviction manager. Por eso `kubeadm init`/`join` fallan por un preflight check si detectan swap activo, salvo que se use `--ignore-preflight-errors=Swap` (no recomendado).
2. `br_netfilter` hace que el tráfico que atraviesa un bridge Linux (como el que crean los plugins de red de pods) pase por las reglas de iptables del host, algo necesario para que funcionen los Services y las Network Policies.
3. Evitás que un `apt-get upgrade` de rutina suba el kubelet o kubeadm a una versión no soportada por el control plane actual y rompa el cluster — las actualizaciones de Kubernetes deben hacerse de forma controlada, un minor a la vez, con `kubeadm upgrade`.

### Ejercicio 2

1. `etcd`, `kube-apiserver`, `kube-controller-manager` y `kube-scheduler` corren como static pods, definidos por manifests en `/etc/kubernetes/manifests/` que el kubelet local vigila y aplica directamente, sin pasar por el scheduler ni el API server.
2. Porque todavía no hay CNI plugin instalado: sin él, el nodo no tiene la red de pods configurada y el kubelet reporta la condición `NetworkNotReady` hasta que un plugin de red la resuelve.
3. `--upload-certs` sube los certificados del control plane (cifrados) como un Secret en el cluster para que otros nodos control-plane los descarguen automáticamente durante su propio `kubeadm join --control-plane`. Es imprescindible en clusters HA multi-control-plane; sin él habría que copiar los certificados a mano a cada nodo adicional.

### Ejercicio 3

1. Kubernetes define la interfaz (CNI) pero deliberadamente no impone una implementación: la elección del plugin (Flannel, Calico, Cilium, etc.) depende de necesidades específicas como Network Policies, encriptación o modo de encapsulamiento, y queda a criterio del administrador.
2. Los pods quedarían en `Pending` o `ContainerCreating` indefinidamente, y en los logs del CNI o del kubelet aparecerían errores de asignación de IP fuera del rango esperado, porque el plugin fue configurado para un CIDR distinto al que efectivamente usan los nodos.

### Ejercicio 4

1. Verifica que el worker se está conectando al API server correcto, protegiendo contra un ataque man-in-the-middle: el hash se calcula sobre la clave pública del certificado CA del cluster, y el kubelet del worker lo compara antes de confiar en la conexión TLS.
2. En cada worker corren el kubelet y el kube-proxy, además del container runtime. NO corren ahí el kube-apiserver, kube-scheduler, kube-controller-manager ni etcd, exclusivos de los nodos control-plane (salvo un cluster de un solo nodo).

### Ejercicio 5

1. Un token indefinido sería un secreto de larga vida que, si se filtra, permitiría a cualquiera unir un nodo arbitrario al cluster. Los TTL cortos (24h por defecto) limitan la ventana de exposición.
2. `kubeadm token create --print-join-command`, ejecutado en un nodo control-plane existente, sin necesidad de reiniciar ni tocar ningún componente ya corriendo.

### Ejercicio 6

1. Los procesos del control plane cargan sus certificados una sola vez al arrancar y los mantienen en memoria; `kubeadm certs renew` solo reescribe los archivos en disco. Como el kubelet reconcilia el estado del static pod contra un manifest que no cambió, no fuerza la recreación del contenedor por sí solo — hay que mover el manifest fuera y adentro del directorio vigilado (o reiniciar el proceso a mano) para que relea el certificado nuevo.
2. `kubeadm upgrade apply` (y `kubeadm upgrade node` en los demás nodos) renueva automáticamente todos los certificados del control plane como parte del proceso de upgrade, salvo que se lo desactive explícitamente con `--certificate-renewal=false`.

### Ejercicio 7

1. `drain` evacúa de forma controlada los pods administrados (Deployments, StatefulSets, etc.) hacia otros nodos antes de la baja, respetando PodDisruptionBudgets. Si borraras el Node directamente, el API server eliminaría el objeto pero los pods que corrían ahí quedarían huérfanos hasta que el garbage collector los detecte, provocando una interrupción no controlada del servicio.
2. `kubeadm reset` revierte los cambios locales hechos por `kubeadm init`/`join` en esa máquina: detiene el kubelet, borra `/etc/kubernetes/`, limpia el directorio de datos de etcd si aplica, y deja pendiente la limpieza manual de iptables/IPVS. NO elimina el objeto Node del API server del cluster — eso requiere `kubectl delete node`, como se hizo en el paso 2.

</details>