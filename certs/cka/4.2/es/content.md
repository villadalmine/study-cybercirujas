# 4.2 Create and manage Kubernetes clusters using kubeadm

## ¿Qué es kubeadm?

`kubeadm` es la herramienta oficial de Kubernetes para hacer bootstrap de un cluster siguiendo las best practices del proyecto. No instala ni gestiona el container runtime, no configura el networking de bajo nivel (eso lo hace el CNI plugin) ni provisiona la infraestructura (VMs, load balancers). Su responsabilidad termina en dejar un control plane mínimamente funcional y en unir (`join`) nodos worker a ese cluster.

`kubeadm` resuelve dos comandos centrales:

- `kubeadm init` — bootstrapea el primer control-plane node.
- `kubeadm join` — une un nodo (worker o control-plane adicional) a un cluster existente.

Y comandos de mantenimiento del ciclo de vida:

- `kubeadm upgrade` — actualiza la versión del cluster.
- `kubeadm certs` — gestiona certificados (rotación, expiración).
- `kubeadm token` — gestiona bootstrap tokens.
- `kubeadm reset` — revierte los cambios hechos por `init`/`join`.
- `kubeadm config` — inspecciona y migra la configuración usada para bootstrapear el cluster.

## Prerrequisitos antes de `kubeadm init`

En **todos** los nodos (control plane y workers):

```bash
# Deshabilitar swap (kubelet no arranca con swap activo, salvo NodeSwap feature gate)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Habilitar módulos de kernel necesarios para networking
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Parámetros sysctl requeridos por el CNI
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```

Además hace falta un **container runtime compatible con CRI** (containerd, CRI-O) ya instalado y corriendo, y los paquetes `kubeadm`, `kubelet` y `kubectl` en la misma minor version (o con el skew soportado). Instalación típica desde el repo apt de Kubernetes:

```bash
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
```

> Nota de examen: en el CKA no se suele pedir instalar el container runtime desde cero, pero sí puede aparecer un cluster ya provisionado donde falta correr `kubeadm init`/`join`, o donde hay que diagnosticar por qué el kubelet no arranca (swap activo, cgroup driver desalineado entre containerd y kubelet, etc.).

## `kubeadm init`: bootstrap del control plane

```bash
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.10 \
  --kubernetes-version=v1.35.0
```

`--pod-network-cidr` es obligatorio si el CNI que vas a instalar lo requiere (por ejemplo Flannel usa `10.244.0.0/16` por convención; Calico suele usar `192.168.0.0/16`). Si el CIDR no coincide con lo que espera el manifest del CNI, los pods quedan en `ContainerCreating` indefinidamente.

Salida relevante (abreviada):

```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.1.10:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...
```

Después de `init` **el cluster no tiene networking entre pods** hasta instalar un CNI:

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

Los nodos quedan en estado `NotReady` hasta que el CNI esté funcionando:

```bash
kubectl get nodes
# NAME     STATUS     ROLES           AGE   VERSION
# master   NotReady   control-plane   2m    v1.35.0
```

### Qué produce `kubeadm init`

- Certificados en `/etc/kubernetes/pki/` (CA, etcd, apiserver, etc.).
- Kubeconfigs en `/etc/kubernetes/` (`admin.conf`, `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`).
- Static pod manifests en `/etc/kubernetes/manifests/` para `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` y `etcd` (local, si no se usa etcd externo). El kubelet los levanta automáticamente por ser static pods.
- Un `ConfigMap` `kubeadm-config` en el namespace `kube-system` con la configuración usada.

## `kubeadm join`: incorporar nodos

### Workers

El comando exacto lo imprime `kubeadm init` al final. Si se perdió o el token expiró:

```bash
kubeadm join 192.168.1.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234567890abcdef...
```

### Control-plane adicionales (HA)

Para agregar un control-plane node hace falta subir los certificados con `--upload-certs` en el `init` original (o `kubeadm init phase upload-certs --upload-certs` después) y luego:

```bash
kubeadm join 192.168.1.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234... \
  --control-plane \
  --certificate-key f8902e...
```

Sin `--control-plane`, `join` siempre agrega el nodo como worker.

## `kubeadm token`: gestión de tokens de bootstrap

El token por defecto expira a las 24 horas. Comandos típicos:

```bash
kubeadm token list
# TOKEN                     TTL  USAGES           DESCRIPTION
# abcdef.0123456789abcdef   23h  authentication,   ...
#                                signing

kubeadm token create                      # crea uno nuevo con TTL default
kubeadm token create --ttl 0              # token que no expira
kubeadm token delete abcdef.0123456789abcdef
```

Si el token expiró y se necesita también recalcular el `--discovery-token-ca-cert-hash`:

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

O de forma más directa, generar el comando de `join` completo de nuevo:

```bash
kubeadm token create --print-join-command
```

## `kubeadm certs`: expiración y renovación

Los certificados generados por `kubeadm init` expiran al año por defecto (excepto la CA, a 10 años).

```bash
kubeadm certs check-expiration
```

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME
admin.conf                 Jul 15, 2027 10:00 UTC   364d
apiserver                  Jul 15, 2027 10:00 UTC   364d
apiserver-etcd-client      Jul 15, 2027 10:00 UTC   364d
...
```

Renovación de todos los certificados:

```bash
kubeadm certs renew all
```

Esto no reinicia automáticamente los componentes; hay que reiniciar los static pods (moviendo el manifest fuera de `/etc/kubernetes/manifests/` y de vuelta, o reiniciando el kubelet) para que tomen los certificados nuevos. `kubeadm upgrade apply`/`node` renueva certificados como parte del proceso salvo que se pase `--certificate-renewal=false`.

## `kubeadm upgrade`: actualizar la versión del cluster

El flujo estándar por nodo, empezando siempre por **un solo control-plane node**:

```bash
# 1. Actualizar el paquete kubeadm primero
apt-mark unhold kubeadm
apt-get install -y kubeadm=1.35.1-1.1
apt-mark hold kubeadm

# 2. Ver el plan de upgrade
kubeadm upgrade plan
```

```
Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT   TARGET
kubelet     1x v1.35.0   1x v1.35.1

Upgrade to the latest version in the v1.35 series:
COMPONENT                 CURRENT   TARGET
kube-apiserver             v1.35.0   v1.35.1
kube-controller-manager    v1.35.0   v1.35.1
kube-scheduler             v1.35.0   v1.35.1
kube-proxy                 v1.35.0   v1.35.1

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.35.1
```

```bash
# 3. Aplicar (solo en el primer control-plane node)
kubeadm upgrade apply v1.35.1
```

Para control-plane nodes adicionales o workers, **no** se usa `upgrade apply` sino `upgrade node`:

```bash
kubeadm upgrade node
```

### Secuencia completa por nodo (aplica a cada nodo, incluido el primero)

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.35.1-1.1 kubectl=1.35.1-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet

kubectl uncordon <node>
```

Reglas de version skew relevantes para el examen:

- `kubeadm` **no puede saltar más de una minor version** por upgrade (ej: no se puede ir de 1.33 a 1.35 directo; hay que pasar por 1.34).
- El `kube-apiserver` debe ser la versión más nueva del cluster; los demás componentes del control plane no pueden ser más nuevos que el `apiserver`.
- `kubelet` puede estar hasta 2 minor versions por detrás del `kube-apiserver`.
- Siempre actualizar `kubeadm` antes que `kubelet`/`kubectl` en cada nodo.

## `kubeadm config`

Útil para inspeccionar qué configuración generó (o generaría) `kubeadm init`, y para clusters bootstrapeados con flags que ahora hace falta auditar:

```bash
kubeadm config print init-defaults      # config por defecto que usaría init
kubeadm config print join-defaults      # config por defecto que usaría join
kubeadm config images list              # imágenes que se van a pullear
kubeadm config images pull              # pre-pull antes de init (útil sin conectividad en el momento)
```

Para instalaciones avanzadas (más allá de los flags de línea de comandos) se usa un `ClusterConfiguration` en YAML:

```bash
kubeadm init --config kubeadm-config.yaml
```

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.0
networking:
  podSubnet: 10.244.0.0/16
apiServer:
  certSANs:
  - "k8s-api.example.com"
```

## `kubeadm reset`: revertir un nodo

```bash
kubeadm reset
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
rm -rf /etc/cni/net.d
```

`reset` limpia `/etc/kubernetes/` y detiene el kubelet, pero **no** limpia reglas de iptables/CNI ni desinstala los paquetes; eso queda a cargo del operador si se quiere dejar el nodo completamente limpio antes de reincorporarlo con `join`.

## Errores frecuentes en el examen

- Nodo queda `NotReady` tras `init`: falta instalar el CNI, o el `podSubnet` no coincide con el que espera el manifest del CNI.
- `join` falla con error de token expirado o hash inválido: regenerar con `kubeadm token create --print-join-command`.
- kubelet no arranca tras `join`: revisar `journalctl -u kubelet`, causas típicas son swap activo o mismatch de cgroup driver entre containerd (`SystemdCgroup`) y kubelet.
- `kubeadm upgrade apply` falla por preflight checks: se puede forzar con `--ignore-preflight-errors=<lista>`, aunque no es la práctica recomendada fuera de troubleshooting puntual.
- Confundir `upgrade apply` (solo primer control-plane) con `upgrade node` (resto de los nodos) es el error más común de secuencia.

## Referencias

- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [kubeadm init reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- [kubeadm join reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Certificate management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [kubeadm token reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/)
- [High Availability considerations](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [CNCF CKA Curriculum v1.35 (PDF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)