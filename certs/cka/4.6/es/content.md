# 4.6 Understand extension interfaces (CNI, CSI, CRI, etc.)

## Introducción

Kubernetes no implementa directamente el runtime de contenedores, el networking ni el storage: define **interfaces estables** (contratos gRPC o de plugin) que terceros implementan. Esto permite que el mismo Kubernetes funcione con distintos runtimes (`containerd`, `CRI-O`), distintos proveedores de red (`Calico`, `Cilium`, `Flannel`) y distintos backends de almacenamiento (`EBS`, `Ceph`, `Portworx`) sin cambiar el core del proyecto.

Las tres interfaces principales son:

| Interfaz | Qué abstrae | Componente que la consume |
|---|---|---|
| **CRI** (Container Runtime Interface) | Cómo se crean y gestionan contenedores | `kubelet` |
| **CNI** (Container Network Interface) | Cómo se les asigna red a los Pods | `kubelet` (invoca al binario CNI) |
| **CSI** (Container Storage Interface) | Cómo se provisiona y monta storage | `kube-controller-manager`, `kubelet` |

También existe el **Device Plugin API**, para exponer hardware especializado (GPUs, NICs, FPGAs) a los Pods.

---

## CRI (Container Runtime Interface)

CRI es una API gRPC definida por Kubernetes que el `kubelet` usa para comunicarse con el runtime de contenedores, sin necesitar código específico por cada runtime (antes de CRI, Docker estaba hardcodeado en el kubelet).

CRI define dos servicios gRPC:

- **RuntimeService**: operaciones sobre Pods y contenedores (crear, iniciar, detener, listar).
- **ImageService**: pull, listado y remoción de imágenes.

### Runtimes compatibles con CRI

- **containerd**: el más usado en producción, mantenido por CNCF.
- **CRI-O**: creado específicamente para Kubernetes, ligero, sin funcionalidades fuera de lo que Kubernetes necesita.
- Docker Engine ya no es soportado nativamente (`dockershim` fue removido en Kubernetes 1.24); para usar Docker hace falta `cri-dockerd` como adaptador.

### Configuración

El `kubelet` recibe el socket del runtime vía el flag `--container-runtime-endpoint`:

```bash
# En un nodo con containerd
cat /var/lib/kubelet/kubeadm-flags.env
# --container-runtime-endpoint=unix:///run/containerd/containerd.sock
```

### Diagnóstico con crictl

`crictl` es la CLI estándar para hablar con cualquier runtime CRI, útil cuando `docker` no está disponible (por ejemplo con CRI-O o containerd puro):

```bash
# Configurar el endpoint (o usar /etc/crictl.yaml)
crictl config runtime-endpoint unix:///run/containerd/containerd.sock

# Listar Pods (sandboxes) gestionados por el runtime
crictl pods

# Listar contenedores
crictl ps -a

# Ver logs de un contenedor por su ID de containerd (no el nombre del Pod)
crictl logs <container-id>

# Inspeccionar imágenes descargadas
crictl images
```

Ejemplo de salida:

```
POD ID              CREATED             STATE               NAME                NAMESPACE
a1b2c3d4e5f6        10 minutes ago      Ready               nginx-7d9f8c        default
```

### Verificar el runtime en un nodo

```bash
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           VERSION   CONTAINER-RUNTIME
node-01    Ready    control-plane   v1.35.0   containerd://1.7.13
node-02    Ready    <none>          v1.35.0   containerd://1.7.13
```

---

## CNI (Container Network Interface)

CNI no es específico de Kubernetes: es un estándar de CNCF para configurar interfaces de red en contenedores Linux. El `kubelet` invoca al binario del plugin CNI cada vez que crea o destruye un Pod.

### Cómo funciona

1. El `kubelet` crea el **pause container** (contenedor "infra") que sostiene el network namespace del Pod.
2. El `kubelet` llama al binario CNI configurado, pasándole el network namespace y parámetros vía JSON (stdin) y variables de entorno.
3. El plugin CNI crea la interfaz de red (veth pair, bridge, etc.), asigna IP (a menudo delegando en un plugin IPAM) y devuelve el resultado en JSON.

### Archivos de configuración

```bash
ls /etc/cni/net.d/
# 10-calico.conflist

cat /etc/cni/net.d/10-calico.conflist
```

```json
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "ipam": { "type": "calico-ipam" }
    },
    { "type": "portmap", "capabilities": {"portMappings": true} }
  ]
}
```

Los binarios de los plugins viven típicamente en `/opt/cni/bin/`.

### Plugins CNI populares

- **Calico**: BGP o overlay (VXLAN/IPIP), soporta `NetworkPolicy` con reglas avanzadas.
- **Cilium**: basado en eBPF, alto rendimiento, observabilidad avanzada (Hubble).
- **Flannel**: simple, overlay VXLAN, sin soporte nativo de `NetworkPolicy`.
- **Weave Net**: mesh de red simple, cifrado opcional.

> Kubernetes exige un requisito de modelo de red: cada Pod debe tener su propia IP, sin NAT entre Pods, y todos los Pods deben poder comunicarse entre nodos directamente. El plugin CNI es responsable de cumplir ese contrato.

### Diagnóstico

```bash
# Un Pod en estado Pending eternamente por falta de CNI instalado
kubectl get pods -n kube-system
kubectl describe pod coredns-xxxx -n kube-system
# Warning  FailedCreatePodSandBox  ... network plugin is not ready: cni config uninitialized

# Ver los Pods del plugin de red (ejemplo Calico)
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
```

Un síntoma clásico en el examen: nodos en `NotReady` o Pods atascados en `ContainerCreating` porque no se instaló ningún CNI tras `kubeadm init`.

---

## CSI (Container Storage Interface)

CSI es otro estándar CNCF (no exclusivo de Kubernetes) que permite a proveedores de storage escribir plugins fuera del árbol de código de Kubernetes ("out-of-tree"), reemplazando los plugins in-tree legados.

### Componentes de un driver CSI

Un driver CSI típico se despliega con:

- **Controller plugin** (`Deployment` o `StatefulSet`): gestiona operaciones a nivel de clúster — `CreateVolume`, `DeleteVolume`, `ControllerPublishVolume` (attach/detach).
- **Node plugin** (`DaemonSet`, uno por nodo): monta el volumen en el nodo donde corre el Pod — `NodeStageVolume`, `NodePublishVolume`.

Ambos se comunican con Kubernetes vía **sidecars** estándar que traducen los recursos de Kubernetes a llamadas gRPC CSI:

- `external-provisioner`: observa `PersistentVolumeClaim` y llama `CreateVolume`.
- `external-attacher`: gestiona el attach/detach del volumen al nodo.
- `node-driver-registrar`: registra el driver ante el `kubelet` vía el socket en `/var/lib/kubelet/plugins_registry/`.
- `external-resizer`: soporta expansión de volúmenes.
- `external-snapshotter`: soporta `VolumeSnapshot`.

### Ejemplo: StorageClass usando un driver CSI

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ebs-gp3
  resources:
    requests:
      storage: 10Gi
```

### Diagnóstico

```bash
# Ver drivers CSI registrados en el clúster
kubectl get csidrivers

NAME                NAME              ATTACHREQUIRED   PODINFOONMOUNT
ebs.csi.aws.com     ebs.csi.aws.com   true             true

# Ver nodos donde cada driver está disponible
kubectl get csinodes

# Ver el estado del PVC
kubectl get pvc data-pvc
kubectl describe pvc data-pvc
# Events: Warning ProvisioningFailed ... rpc error: code = Internal desc = ...

# Pods del driver (ejemplo AWS EBS CSI)
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n kube-system -l app=ebs-csi-node
```

Diferencia clave respecto a CNI/CRI: CSI se ve mayormente como objetos de la API de Kubernetes (`StorageClass`, `PersistentVolume`, `CSIDriver`, `CSINode`, `VolumeAttachment`), no solo como binarios en el nodo.

```bash
kubectl get volumeattachments
```

---

## Device Plugins (mención breve)

El **Device Plugin Framework** permite exponer recursos de hardware (GPUs, `hugepages`, NICs SR-IOV) como recursos schedulables (`nvidia.com/gpu: 1`). Se despliega como `DaemonSet` que se registra ante el `kubelet` vía gRPC, de forma análoga a CSI.

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

```bash
kubectl describe node node-01 | grep -A5 Capacity
# nvidia.com/gpu: 4
```

---

## Resumen para el examen

- **CRI** = cómo el `kubelet` habla con el runtime de contenedores (`crictl`, `containerd`, `CRI-O`).
- **CNI** = cómo se le da red a un Pod (`/etc/cni/net.d/`, `/opt/cni/bin/`, Calico/Cilium/Flannel).
- **CSI** = cómo se provisiona/monta storage (`CSIDriver`, `CSINode`, sidecars `provisioner`/`attacher`).
- Todas son interfaces gRPC estandarizadas por CNCF que desacoplan a Kubernetes de implementaciones específicas.
- Ante fallas, revisar primero: ¿el componente correspondiente está corriendo? (`kubectl get pods -n kube-system`), y luego `kubectl describe` / `kubectl logs` sobre el recurso o Pod afectado.

---

## Referencias

- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Container Network Interface (CNI) spec: https://github.com/containernetworking/cni
- Kubernetes Network Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Container Storage Interface (CSI): https://kubernetes.io/docs/concepts/storage/volumes/#csi
- CSI Developer Documentation: https://kubernetes-csi.github.io/docs/
- Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- `crictl` reference: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/