# 1.1 Implement storage classes and dynamic volume provisioning

## Introducción

En Kubernetes, el almacenamiento persistente se gestiona a través de tres objetos principales: `PersistentVolume` (PV), `PersistentVolumeClaim` (PVC) y `StorageClass` (SC). Mientras que un PV representa una porción de almacenamiento físico o en la nube ya aprovisionada, el objetivo de una `StorageClass` es automatizar ese aprovisionamiento: en lugar de que un administrador cree PVs manualmente ("static provisioning"), el cluster crea el volumen bajo demanda cuando un usuario pide un PVC ("dynamic provisioning").

Este tema tiene un peso relativamente bajo en el examen CKA (3.33%), pero es transversal: aparece combinado con preguntas de workloads con estado (StatefulSets), backup/restore y troubleshooting de Pods que quedan en `Pending` por problemas de storage.

## StorageClass: qué es y para qué sirve

Una `StorageClass` es un objeto a nivel de cluster (no namespaced) que define una "clase" o "perfil" de almacenamiento disponible. Le dice a Kubernetes **qué provisioner usar** y **con qué parámetros** crear el volumen quien lo solicite.

Estructura básica de una `StorageClass`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Campos clave:

- **`provisioner`**: identifica el plugin que crea el volumen físico. Hoy en día casi siempre es un driver **CSI** (Container Storage Interface), por ejemplo `ebs.csi.aws.com`, `pd.csi.storage.gke.io`, `disk.csi.azure.com`, `rook-ceph.rbd.csi.ceph.com`. Los "in-tree provisioners" (`kubernetes.io/aws-ebs`, etc.) están deprecados desde 1.25+ a favor de CSI.
- **`parameters`**: pares clave-valor específicos del provisioner (tipo de disco, filesystem, IOPS, replicación, etc.). Varían según el driver CSI usado.
- **`reclaimPolicy`**: qué pasa con el volumen subyacente cuando se borra el PVC. `Delete` (default en la mayoría de provisioners dinámicos) borra el volumen físico; `Retain` lo deja existir (queda en estado `Released`, requiere limpieza manual).
- **`allowVolumeExpansion`**: si es `true`, permite agrandar el PVC editando `spec.resources.requests.storage` sin recrear el volumen (siempre que el driver CSI lo soporte).
- **`volumeBindingMode`**:
  - `Immediate` (default): el volumen se aprovisiona apenas se crea el PVC, sin esperar a que exista un Pod que lo use. Puede causar problemas de scheduling si el volumen queda en una zona distinta al nodo donde termina el Pod.
  - `WaitForFirstConsumer`: retrasa el binding/aprovisionamiento hasta que un Pod que usa el PVC es programado. El scheduler elige el nodo considerando restricciones del Pod, y luego el volumen se crea en la zona/topología correcta. Es el modo recomendado para storage con afinidad de zona (ej. EBS, PD).

## Flujo de dynamic provisioning

1. El usuario crea un `PersistentVolumeClaim` indicando `storageClassName`.
2. El controlador de la `StorageClass` (vía CSI external-provisioner) detecta el PVC pendiente.
3. Si `volumeBindingMode: WaitForFirstConsumer`, espera a que el scheduler asigne un Pod a un nodo.
4. El provisioner crea el volumen real en el backend (EBS, PD, Ceph, NFS, etc.) y genera automáticamente un objeto `PersistentVolume` que referencia ese storage.
5. El PV se enlaza (bind) 1:1 con el PVC.
6. El Pod monta el PVC como volumen.

```
PVC (Pending) --> StorageClass --> CSI provisioner --> PV (creado automáticamente) --> Bound
```

## Ejemplo completo

### 1. Ver las StorageClasses disponibles

```bash
kubectl get storageclass
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   kubernetes.io/gce-pd    Delete          Immediate              true                   40d
fast-ssd              ebs.csi.aws.com        Delete          WaitForFirstConsumer   true                   2h
```

`kubectl get sc` es el alias corto. La columna `(default)` indica cuál se usa cuando un PVC no especifica `storageClassName`.

### 2. Crear una StorageClass

```bash
kubectl apply -f - <<EOF
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
EOF
```

### 3. Marcar una StorageClass como default

Kubernetes usa la annotation `storageclass.kubernetes.io/is-default-class`. Solo puede haber una SC default por cluster; si hay más de una, el comportamiento es indefinido.

```bash
kubectl patch storageclass standard \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 4. Crear un PVC que dispare el aprovisionamiento dinámico

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f pvc.yaml
kubectl get pvc data-pvc
```

Si `volumeBindingMode: WaitForFirstConsumer`, el PVC queda `Pending` hasta que un Pod lo consuma:

```
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Pending                                      fast-ssd       5s
```

Al crear un Pod que referencia el PVC, el volumen se aprovisiona y hace bind:

```bash
kubectl get pvc data-pvc
```

```
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Bound    pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab    10Gi       RWO            fast-ssd       12s
```

```bash
kubectl get pv pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab
```

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM               STORAGECLASS   AGE
pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab   10Gi       RWO            Delete           Bound    default/data-pvc    fast-ssd       10s
```

Nótese que el nombre del PV se genera automáticamente con el prefijo `pvc-` seguido de un UID — esa es la señal visual de que fue creado por dynamic provisioning, a diferencia de un PV creado manualmente (static provisioning).

### 5. Expandir un volumen (volume expansion)

Si la SC tiene `allowVolumeExpansion: true`, se puede editar el PVC para pedir más espacio:

```bash
kubectl patch pvc data-pvc -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

Kubernetes marca la condición `FileSystemResizePending` hasta que el kubelet complete el resize del filesystem en el nodo (puede requerir que el Pod siga corriendo, según el driver CSI). El estado final se ve con:

```bash
kubectl get pvc data-pvc -o jsonpath='{.status.capacity.storage}'
```

## Puntos de troubleshooting frecuentes en el examen

- **PVC queda en `Pending` indefinidamente**: revisar `kubectl describe pvc <nombre>` — eventos típicos: `storageclass.storage.k8s.io "x" not found` (SC inexistente), falta de default SC cuando el PVC no especifica `storageClassName`, o el CSI driver/controller no está corriendo (`kubectl get pods -n kube-system` o el namespace del driver).
- **Pod queda en `Pending` con volumen `Bound`**: puede ser un problema de topología/zona si `volumeBindingMode: Immediate` creó el volumen en una zona sin nodos disponibles para el Pod — otra razón para preferir `WaitForFirstConsumer`.
- **`accessModes` incompatibles**: el PVC pide `ReadWriteMany` pero el provisioner solo soporta `ReadWriteOnce` (común en EBS/PD de bloque, no en NFS/EFS).
- **Reclaim policy `Retain`**: al borrar el PVC, el PV queda en estado `Released` y no se reutiliza automáticamente; hay que borrar manualmente el PV y limpiar el volumen backend, o editarlo para volverlo `Available` reseteando `claimRef`.
- **Verificar drivers CSI instalados**: `kubectl get csidrivers` y `kubectl get pods -n kube-system -l app=csi-...` (el namespace/label varía según el driver).

## Referencias

- Storage Classes — documentación oficial: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Volume Expansion: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims
- Container Storage Interface (CSI): https://kubernetes-csi.github.io/docs/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf