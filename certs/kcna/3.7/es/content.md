# Tema 3.7: Storage

## Introducción

Kubernetes desacopla el ciclo de vida de los datos persistentes del ciclo de vida de los Pods. Un Pod es efímero: puede ser reprogramado, reiniciado o eliminado en cualquier momento, y todo lo escrito en su filesystem local se pierde en ese proceso. El subsistema de storage de Kubernetes resuelve esto mediante un modelo de abstracciones que separa **qué necesita un Pod** (una reclamación de almacenamiento) de **cómo se provee ese almacenamiento** (el backend físico o en la nube).

Las piezas centrales de este modelo son:

- **Volumes**: la abstracción básica que adjunta almacenamiento al ciclo de vida de un Pod.
- **PersistentVolume (PV)**: una pieza de almacenamiento en el cluster, provista por un administrador o dinámicamente por un `StorageClass`.
- **PersistentVolumeClaim (PVC)**: una solicitud de almacenamiento hecha por un usuario/aplicación, que se enlaza (`bind`) a un PV.
- **StorageClass (SC)**: define "clases" de storage y permite el aprovisionamiento dinámico de PVs.
- **CSI (Container Storage Interface)**: el estándar que permite a Kubernetes hablar con cualquier backend de storage (cloud, on-prem, distribuido) sin acoplar ese código al core de Kubernetes.

## Volumes

Un `Volume` en Kubernetes es un directorio (posiblemente con datos) accesible por los containers de un Pod, cuyo ciclo de vida está atado al del **Pod** (no al del container individual). Esto ya resuelve un problema básico: si un container dentro de un Pod crashea y se reinicia, los datos en un volume sobreviven, porque el volume vive a nivel Pod.

Tipos de volumes más relevantes para el examen:

- **`emptyDir`**: se crea vacío cuando el Pod se asigna a un nodo y existe mientras el Pod esté corriendo en ese nodo. Se usa para compartir archivos entre containers del mismo Pod o como scratch space. Se borra cuando el Pod se elimina.
- **`hostPath`**: monta un archivo o directorio del filesystem del nodo directamente en el Pod. Útil para casos como acceso a Docker internals o logs del nodo, pero riesgoso en producción (rompe la portabilidad y tiene implicaciones de seguridad).
- **`configMap` / `secret`**: exponen datos de configuración o información sensible como archivos dentro del Pod.
- **`persistentVolumeClaim`**: el tipo de volume que referencia un PVC, y es la forma estándar de dar almacenamiento persistente y duradero (que sobrevive al Pod) a una aplicación.

Ejemplo de un Pod usando `emptyDir`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: cache-volume
      mountPath: /cache
  volumes:
  - name: cache-volume
    emptyDir: {}
```

## PersistentVolume (PV) y PersistentVolumeClaim (PVC)

Este es el par de objetos central del modelo de storage persistente de Kubernetes, y sigue una analogía similar a la de compute (`Node` vs `Pod`):

- **PV**: recurso de storage a nivel cluster, con su propio ciclo de vida independiente de cualquier Pod. Es creado por un administrador (aprovisionamiento estático) o dinámicamente por Kubernetes vía un `StorageClass`. Define detalles como capacidad, `accessModes` y el backend real (NFS, disco cloud, CSI driver, etc.).
- **PVC**: solicitud de storage hecha por un usuario. Especifica tamaño y `accessModes` deseados, sin conocer los detalles de infraestructura subyacente. Kubernetes busca un PV que satisfaga la claim y los enlaza (`Bound`).

Este desacople permite que developers pidan storage ("necesito 10Gi con acceso `ReadWriteOnce`") sin saber si por debajo hay un EBS volume, un disco de Azure, o un array NFS on-prem.

**Access Modes** (modos de acceso) definen cómo puede ser montado el volumen:

- `ReadWriteOnce` (RWO): lectura/escritura por un único nodo.
- `ReadOnlyMany` (ROX): solo lectura por múltiples nodos.
- `ReadWriteMany` (RWX): lectura/escritura por múltiples nodos.
- `ReadWriteOncePod` (RWOP): lectura/escritura restringida a un único Pod (no solo un nodo) — modo más reciente, útil para garantizar exclusividad estricta.

**Ciclo de vida de un PV**: `Available` → `Bound` → `Released` → (`Deleted` o `Retained` según la `reclaimPolicy`).

Ejemplo de PV estático (backend NFS):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    path: /exports/data
    server: nfs-server.example.com
```

Ejemplo de PVC que solicita ese storage:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-app-data
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
```

Y su uso dentro de un Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-storage
spec:
  containers:
  - name: app
    image: my-app:1.0
    volumeMounts:
    - name: data
      mountPath: /var/lib/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-app-data
```

Comandos comunes de inspección:

```console
$ kubectl get pv
NAME     CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS
pv-nfs   5Gi        RWX            Retain           Bound    default/pvc-app-data     manual

$ kubectl get pvc
NAME            STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
pvc-app-data    Bound    pv-nfs   5Gi        RWX            manual
```

## StorageClass y aprovisionamiento dinámico

Crear PVs manualmente no escala. La abstracción **`StorageClass`** permite definir "clases" o "perfiles" de storage (por ejemplo, `fast-ssd`, `standard-hdd`) que un `provisioner` sabe cómo crear bajo demanda. Cuando un usuario crea un PVC referenciando una `StorageClass`, Kubernetes provisiona el PV automáticamente (aprovisionamiento dinámico), sin intervención de un administrador.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

Un PVC que use esta clase dispara la creación automática del PV correspondiente:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic
spec:
  storageClassName: fast-ssd
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
```

Dos parámetros clave de `StorageClass`:

- **`reclaimPolicy`**: qué pasa con el PV cuando su PVC se borra — `Delete` (borra también el storage subyacente) o `Retain` (conserva los datos para recuperación manual).
- **`volumeBindingMode`**: `Immediate` (provisiona apenas se crea el PVC) o `WaitForFirstConsumer` (espera a que un Pod use el PVC, para provisionar en la zona/nodo correcto — importante en clouds con storage zonal).

Si ningún `storageClassName` se especifica y existe una `StorageClass` marcada como default, esa se usa automáticamente.

## Container Storage Interface (CSI)

Antes de CSI, los drivers de storage estaban compilados dentro del código core de Kubernetes ("in-tree"), lo que obligaba a que cada nuevo backend de storage requiriera cambios en el propio Kubernetes. **CSI** es un estándar de la industria (no exclusivo de Kubernetes) que define una interfaz común para que cualquier proveedor de storage escriba un driver ("out-of-tree") que orqueste sus propios volúmenes sin tocar el core del proyecto.

Beneficios clave que evalúa el examen:

- Los vendors desarrollan y publican sus drivers de forma independiente del ciclo de release de Kubernetes.
- Kubernetes ya no necesita mantener código específico de cada backend (AWS EBS, GCE PD, Azure Disk, Ceph, Portworx, etc.).
- Es el mecanismo estándar recomendado hoy para cualquier integración de storage nueva; el soporte "in-tree" está en proceso de deprecación.

Un `StorageClass` con `provisioner: ebs.csi.aws.com` (como en el ejemplo anterior) es justamente un ejemplo de uso de un driver CSI.

## Referencias

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs — Volumes: https://kubernetes.io/docs/concepts/storage/volumes/
- Kubernetes docs — Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes docs — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes docs — Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Kubernetes docs — Container Storage Interface (CSI): https://kubernetes.io/docs/concepts/storage/volumes/#csi
- Container Storage Interface (spec oficial): https://github.com/container-storage-interface/spec