# CKA 1.35 — Tema 1.2: Configure volume types, access modes and reclaim policies

**Dominio del curriculum:** Storage
**Peso en el examen:** 3.33%

## Introducción

En Kubernetes, los contenedores son efímeros por diseño: cuando un Pod se reinicia, el filesystem del contenedor se descarta. El objeto **Volume** resuelve dos problemas distintos:

1. **Compartir datos entre contenedores** de un mismo Pod (comparten el mismo `network namespace`, pero no el filesystem por defecto).
2. **Persistir datos** más allá del ciclo de vida de un Pod individual.

Este tema cubre tres piezas que suelen confundirse entre sí: el **tipo de volumen** (de dónde viene el storage), el **access mode** (cómo se puede montar) y la **reclaim policy** (qué pasa con los datos cuando el claim se libera).

## Volume types

Un volumen se declara en `spec.volumes` del Pod y se monta en uno o más contenedores vía `volumeMounts`. El campo que define el tipo (`emptyDir`, `hostPath`, `persistentVolumeClaim`, etc.) determina el backend real.

### emptyDir

Se crea vacío cuando el Pod es asignado a un Node, y vive mientras el Pod exista en ese Node. Se borra si el Pod es eliminado (no sobrevive un reinicio del Pod, aunque sí sobrevive el reinicio de un contenedor individual dentro del Pod).

Uso típico: scratch space compartido entre contenedores de un mismo Pod (ej. un sidecar que procesa logs generados por el contenedor principal).

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
    - name: cache-vol
      mountPath: /cache
  volumes:
  - name: cache-vol
    emptyDir:
      sizeLimit: 500Mi
```

`emptyDir.medium: Memory` monta un `tmpfs` (RAM) en vez de disco — útil para datos sensibles que no querés persistir en disco, o para I/O de baja latencia.

### hostPath

Monta un archivo o directorio del filesystem del Node dentro del Pod. Rompe la portabilidad (el Pod queda atado a lo que exista en ese Node específico) y es un riesgo de seguridad si se usa sin restricciones (permite acceso al filesystem del host). Se usa principalmente para daemons de sistema (ej. Pods de `kube-proxy` o CNI que necesitan leer `/etc/cni` o sockets del host).

```yaml
volumes:
- name: host-logs
  hostPath:
    path: /var/log
    type: Directory
```

El campo `type` (`Directory`, `DirectoryOrCreate`, `File`, `FileOrCreate`, `Socket`, etc.) valida qué debe existir ya en el host antes de montar.

### configMap y secret

Exponen datos de configuración o credenciales como archivos dentro del Pod. Son de solo lectura desde el Pod y se actualizan automáticamente (con cierto delay) si el `ConfigMap`/`Secret` cambia — excepto cuando se montan como `subPath`, en cuyo caso no reciben actualizaciones.

```yaml
volumes:
- name: app-config
  configMap:
    name: my-config
```

### persistentVolumeClaim (PVC)

Es el mecanismo estándar para storage persistente y desacoplado del ciclo de vida del Pod. El Pod referencia un `PersistentVolumeClaim`, que a su vez se vincula (bind) a un `PersistentVolume` — ya sea provisionado manualmente o dinámicamente vía `StorageClass`.

```yaml
volumes:
- name: data
  persistentVolumeClaim:
    claimName: mysql-pvc
```

### Otros tipos relevantes

- **`nfs`**: monta un export NFS directamente (sin pasar por PV/PVC), soporta `ReadWriteMany` de forma nativa.
- **`csi`**: integración con drivers de Container Storage Interface — es el mecanismo moderno para storage de proveedores externos (EBS, Azure Disk, Ceph, Longhorn, etc.). La mayoría del storage "in-tree" (`awsElasticBlockStore`, `gcePersistentDisk`) está deprecado en favor de sus equivalentes CSI.
- **`projected`**: combina múltiples fuentes (`secret`, `configMap`, `downwardAPI`, `serviceAccountToken`) en un único volumen.
- **`downwardAPI`**: expone metadata del propio Pod (labels, annotations, resource limits) como archivos.

## Access modes

El `PersistentVolume` (y el `PersistentVolumeClaim` que lo solicita) declaran cómo puede montarse el volumen simultáneamente desde distintos Nodes:

| Access mode | Abreviatura | Descripción |
|---|---|---|
| `ReadWriteOnce` | RWO | Montado read-write por un único Node (puede tener múltiples Pods en ese mismo Node montándolo). |
| `ReadOnlyMany` | ROX | Montado read-only por múltiples Nodes simultáneamente. |
| `ReadWriteMany` | RWX | Montado read-write por múltiples Nodes simultáneamente. |
| `ReadWriteOncePod` | RWOP | Montado read-write por un único **Pod** en todo el cluster (más estricto que RWO, que permite varios Pods en el mismo Node). Requiere CSI drivers que lo soporten. |

No todos los backends soportan todos los modos. Por ejemplo, la mayoría de los block storage de cloud (EBS, Azure Disk, GCE PD) solo soportan `ReadWriteOnce`; para `ReadWriteMany` normalmente se necesita un filesystem de red (NFS, CephFS, EFS, Azure Files).

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
```

Verificación con `kubectl`:

```bash
$ kubectl get pv
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM               STORAGECLASS   AGE
pv-mysql   10Gi       RWO            Retain           Bound    default/mysql-pvc   standard       2m

$ kubectl get pvc
NAME        STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
mysql-pvc   Bound    pv-mysql   10Gi       RWO            standard       2m
```

Un PVC solo hace bind a un PV si el PV tiene **al menos** los access modes solicitados (y capacidad suficiente, y coincide la `StorageClass` si aplica).

## Reclaim policies

La `persistentVolumeReclaimPolicy` de un `PersistentVolume` define qué pasa con el volumen (y sus datos subyacentes) cuando el `PersistentVolumeClaim` que lo estaba usando se elimina:

- **`Retain`**: el PV y sus datos se conservan. El PV queda en estado `Released` (no `Available`) y no puede volver a hacer bind automáticamente a un nuevo PVC — requiere intervención manual del admin (limpiar los datos y borrar la referencia `claimRef`, o borrar y recrear el PV). Es la opción segura por defecto para storage provisionado manualmente.
- **`Delete`**: el PV y el storage backend asociado (ej. el disco EBS) se eliminan automáticamente al borrarse el PVC. Es el default para volúmenes provisionados dinámicamente vía `StorageClass`.
- **`Recycle`** *(deprecado)*: ejecutaba un `rm -rf` básico sobre el volumen y lo dejaba disponible de nuevo. Reemplazado por dynamic provisioning; no debería usarse en clusters modernos.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mysql
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: standard
  hostPath:
    path: /mnt/data/mysql
```

Cambiar la reclaim policy de un PV existente sin recrearlo:

```bash
$ kubectl patch pv pv-mysql -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
persistentvolume/pv-mysql patched
```

Esto es útil cuando un PV fue creado dinámicamente con policy `Delete` (heredada de la `StorageClass`) y se quiere proteger sus datos antes de borrar el PVC.

### StorageClass y provisioning dinámico

Una `StorageClass` define un `provisioner` (ej. `kubernetes.io/aws-ebs`, o un driver CSI) y parámetros por defecto, incluyendo `reclaimPolicy` y `volumeBindingMode`:

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
allowVolumeExpansion: true
```

`volumeBindingMode: WaitForFirstConsumer` retrasa el binding/provisioning hasta que un Pod que usa el PVC sea scheduleado — evita crear un volumen en una zona donde después no hay Nodes disponibles (relevante en clusters multi-zona).

Ver la StorageClass por defecto del cluster:

```bash
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   10d
fast-ssd              ebs.csi.aws.com         Delete          WaitForFirstConsumer   2m
```

## Ciclo de vida completo (resumen)

1. Admin crea una `StorageClass` (o se usa la default) — o crea PVs manualmente para provisioning estático.
2. Usuario crea un `PersistentVolumeClaim` solicitando tamaño y `accessModes`.
3. El `PersistentVolumeController` bindea el PVC a un PV existente compatible, o dispara provisioning dinámico si hay `StorageClass`.
4. El Pod referencia el PVC en `spec.volumes`; el `kubelet` monta el volumen real en el Node donde corre el Pod.
5. Al borrar el PVC, la `reclaimPolicy` del PV determina si los datos se retienen o se destruyen.

## Referencias

- Kubernetes docs — Volumes: https://kubernetes.io/docs/concepts/storage/volumes/
- Kubernetes docs — Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes docs — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes docs — Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Kubernetes docs — Configure a Pod to Use a PersistentVolume for Storage: https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
- CKA Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
