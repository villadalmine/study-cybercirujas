# Manage persistent volumes and persistent volume claims

## 1. El problema que resuelve el storage persistente

Los contenedores son efímeros: si un Pod muere, su filesystem se pierde. Para datos que deben sobrevivir a reinicios, rescheduling o incluso a la eliminación del Pod, Kubernetes desacopla el **almacenamiento** del **ciclo de vida del Pod** mediante tres objetos:

- **PersistentVolume (PV)**: representa una pieza de storage en el cluster (disco de un cloud provider, NFS, iSCSI, storage local, etc.), provisionada por un administrador o dinámicamente por un `provisioner`.
- **PersistentVolumeClaim (PVC)**: una solicitud de storage hecha por un usuario/Pod, especificando tamaño y `accessModes`. Es análogo a cómo un Pod solicita recursos de cómputo (CPU/memoria) y un Node los provee.
- **StorageClass (SC)**: define "clases" de storage (tipos de disco, provisioner, parámetros) y habilita el **provisioning dinámico** de PVs, evitando que el admin tenga que crear PVs a mano.

El flujo típico es: `Pod` → usa → `PVC` → se enlaza (`bind`) con → `PV` → respaldado por el storage real (CSI driver, NFS, etc.).

## 2. PersistentVolume (PV)

Un PV es un recurso a nivel de cluster (no namespaced). Ejemplo estático con `hostPath` (solo para pruebas/lab, no producción):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data
```

Campos clave:

- `capacity.storage`: tamaño ofrecido.
- `accessModes`: cómo puede montarse (ver sección 4).
- `persistentVolumeReclaimPolicy`: qué pasa con el volumen cuando el PVC se borra (`Retain`, `Delete`, `Recycle` — este último deprecado).
- `storageClassName`: vincula el PV a una clase; si se omite, solo hace match con PVCs que tampoco especifiquen clase.
- `volumeMode`: `Filesystem` (default) o `Block` (para block devices raw).

```bash
kubectl get pv
```
```
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   AGE
pv-data    5Gi        RWO            Retain           Available           manual         10s
```

## 3. PersistentVolumeClaim (PVC)

Es namespaced. El usuario pide storage sin conocer los detalles de infraestructura:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 3Gi
  storageClassName: manual
```

Kubernetes busca un PV `Available` que cumpla `accessModes`, capacidad mínima y `storageClassName`, y los enlaza 1:1.

```bash
kubectl get pvc
```
```
NAME       STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Bound    pv-data    5Gi        RWO            manual         5s
```

Notar que el PVC quedó `Bound` a un PV de 5Gi aunque pidió 3Gi: el binding es por el volumen completo, no por la cantidad exacta.

## 4. Access Modes

| Modo | Abreviatura | Descripción |
|---|---|---|
| ReadWriteOnce | RWO | Un solo Node puede montar el volumen para read/write |
| ReadOnlyMany | ROX | Múltiples Nodes pueden montar en read-only |
| ReadWriteMany | RWX | Múltiples Nodes pueden montar para read/write (ej. NFS, CephFS) |
| ReadWriteOncePod | RWOP | Un solo **Pod** (no Node) puede montar para read/write — introducido para casos donde RWO no era suficientemente estricto |

No todos los tipos de volumen soportan todos los modos (ej. la mayoría de los discos de bloque de cloud providers solo soportan RWO).

## 5. Reclaim Policy

Determina qué ocurre con el PV cuando su PVC se elimina:

- **Retain**: el PV se preserva con sus datos, queda en estado `Released` y debe limpiarse/reciclarse manualmente antes de reutilizarse.
- **Delete** (default en la mayoría de provisioners dinámicos): el PV y el storage subyacente se eliminan automáticamente.
- **Recycle**: deprecado, hacía un `rm -rf` básico; reemplazado por dynamic provisioning.

```bash
kubectl patch pv pv-data -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

## 6. StorageClass y provisioning dinámico

En clusters reales casi nunca se crean PVs a mano: se define una `StorageClass` y los PVCs disparan la creación automática del PV vía un **CSI driver**.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Campos importantes:

- `provisioner`: el driver CSI (ej. `ebs.csi.aws.com`, `pd.csi.storage.gke.io`, `disk.csi.azure.com`, `rancher.io/local-path`).
- `allowVolumeExpansion: true`: permite crecer el PVC editando `spec.resources.requests.storage` sin recrear el volumen.
- `volumeBindingMode`:
  - `Immediate`: el PV se provisiona apenas se crea el PVC.
  - `WaitForFirstConsumer`: el provisioning se retrasa hasta que un Pod que use el PVC sea scheduled, para que el volumen se cree en la zona/Node correctos (crítico en clusters multi-zona).

Si un PVC no especifica `storageClassName`, usa la StorageClass marcada como default:

```bash
kubectl get storageclass
```
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      DEFAULT
fast-ssd (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true
standard             rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

Se marca default con la annotation `storageclass.kubernetes.io/is-default-class: "true"`.

## 7. Uso del PVC en un Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - name: storage
          mountPath: /usr/share/nginx/html
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: pvc-data
```

En Deployments/StatefulSets el patrón es idéntico, salvo que StatefulSet permite `volumeClaimTemplates` para generar un PVC por réplica automáticamente:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
```

## 8. Resize de un PVC

Si la StorageClass tiene `allowVolumeExpansion: true`:

```bash
kubectl patch pvc pvc-data -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
kubectl get pvc pvc-data
```
```
NAME       STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Bound    pv-data    10Gi       RWO            fast-ssd       2m
```

El filesystem dentro del Pod puede tardar unos segundos en reflejar el nuevo tamaño (file system expansion online).

## 9. Troubleshooting típico en el examen

**PVC queda en `Pending`:**

```bash
kubectl describe pvc pvc-data
```
Causas comunes:
- Ningún PV disponible con `accessModes`/capacidad/`storageClassName` compatibles.
- `storageClassName` mal escrito o inexistente.
- `volumeBindingMode: WaitForFirstConsumer` y todavía no hay Pod consumidor scheduled (comportamiento normal, no error).
- El provisioner CSI no está corriendo (`kubectl get pods -n kube-system` o el namespace del driver).

**Pod queda en `Pending` por volumen:**

```bash
kubectl describe pod app-pod
```
Revisar events al final: `FailedMount`, `FailedAttachVolume`, o `node(s) had volume node affinity conflict` (típico cuando el PV fue creado en una zona distinta a la del Node donde se schedulea el Pod).

**PV queda en `Released` y no se reutiliza:**
Con `reclaimPolicy: Retain`, hay que limpiar manualmente `spec.claimRef` del PV para que vuelva a `Available`:

```bash
kubectl patch pv pv-data -p '{"spec":{"claimRef": null}}'
```

## Referencias

- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Volume Snapshots (referencia relacionada): https://kubernetes.io/docs/concepts/storage/volume-snapshots/
- Configure a Pod to Use a PersistentVolume for Storage (tutorial): https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
- Expanding Persistent Volumes Claims: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf