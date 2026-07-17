# 1.4 Utilize persistent and ephemeral volumes

## Introducción

En Kubernetes, un **Volume** es un directorio (con datos, potencialmente) accesible por los containers de un Pod. A diferencia del filesystem de un container —que se destruye cuando el container se reinicia—, un volume tiene un ciclo de vida ligado al Pod (o, en el caso de volúmenes persistentes, independiente de él).

Hay dos grandes categorías que el examen CKAD evalúa en este tema:

- **Ephemeral volumes**: su ciclo de vida está atado al Pod. Cuando el Pod muere, el volumen y sus datos desaparecen. Ejemplos: `emptyDir`, `configMap`, `secret`, `downwardAPI`, `generic ephemeral volumes`.
- **Persistent volumes**: los datos sobreviven a la vida del Pod e incluso pueden sobrevivir a la eliminación del Pod que los usó. Se implementan con el par **PersistentVolume (PV)** / **PersistentVolumeClaim (PVC)**.

## Volúmenes ephemeral

### emptyDir

Es el volumen ephemeral más usado. Se crea vacío cuando el Pod es asignado a un Node, y se borra permanentemente cuando el Pod se elimina de ese Node (no sobrevive a reinicios del Node ni a la eliminación del Pod). Es útil para:

- Compartir archivos entre containers del mismo Pod (patrón sidecar).
- Scratch space temporal (por ejemplo, un merge sort que necesita disco).
- Cache local no crítico.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
spec:
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - name: cache-volume
      mountPath: /cache
  volumes:
  - name: cache-volume
    emptyDir:
      sizeLimit: 500Mi
```

Por defecto `emptyDir` usa el disco del Node. Se puede forzar a que resida en memoria (tmpfs) con `medium: Memory`, lo cual es más rápido pero cuenta contra el límite de memoria del container y se pierde al reiniciar el Node:

```yaml
  volumes:
  - name: cache-volume
    emptyDir:
      medium: Memory
      sizeLimit: 100Mi
```

### hostPath

Monta un archivo o directorio del filesystem del Node dentro del Pod. Es riesgoso en producción (acopla el Pod a un Node específico y puede exponer el filesystem del host), pero aparece en el examen para casos como acceder a `/var/run/docker.sock` o herramientas de monitoreo a nivel de Node (DaemonSets).

```yaml
  volumes:
  - name: host-logs
    hostPath:
      path: /var/log
      type: Directory
```

Valores comunes de `type`: `Directory`, `DirectoryOrCreate`, `File`, `FileOrCreate`, `Socket`.

### configMap y secret como volumen

Aunque `ConfigMap` y `Secret` se cubren en otros temas del curriculum, técnicamente se montan como volúmenes ephemeral: se generan al iniciar el Pod y se actualizan (con cierto delay, vía kubelet sync) si el objeto cambia, pero no persisten datos escritos por la app.

```yaml
  volumes:
  - name: config-vol
    configMap:
      name: app-config
```

### Generic ephemeral volumes

Permiten pedir almacenamiento con las mismas características que un PVC (incluyendo dynamic provisioning vía StorageClass), pero con ciclo de vida atado al Pod: se crean y eliminan junto con él. Se declaran dentro de `volumes` con la clave `ephemeral`:

```yaml
  volumes:
  - name: scratch-data
    ephemeral:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: standard
          resources:
            requests:
              storage: 1Gi
```

Internamente Kubernetes crea un PVC con nombre `<pod-name>-<volume-name>` que se borra automáticamente al borrar el Pod.

## Volúmenes persistentes

### PersistentVolume (PV)

Es un recurso a nivel de cluster (cluster-scoped, no vive dentro de un Namespace) que representa una porción de storage real: puede ser un disco de un proveedor cloud (EBS, PD, Azure Disk), NFS, iSCSI, o un backend CSI. El PV existe independientemente de cualquier Pod que lo use.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data
```

Campos clave:

- **capacity**: tamaño del volumen.
- **accessModes**: cómo puede montarse.
  - `ReadWriteOnce` (RWO): un solo Node puede montarlo en modo read-write.
  - `ReadOnlyMany` (ROX): múltiples Nodes en modo read-only.
  - `ReadWriteMany` (RWX): múltiples Nodes en modo read-write (requiere backend que lo soporte, ej. NFS).
  - `ReadWriteOncePod` (RWOP): solo un Pod en todo el cluster puede montarlo read-write (más estricto que RWO, que permite varios Pods en el mismo Node).
- **persistentVolumeReclaimPolicy**: qué pasa con el volumen cuando se borra el PVC que lo reclamaba.
  - `Retain`: el PV y los datos quedan, pero el PV pasa a estado `Released` y no puede reusarse hasta intervención manual.
  - `Delete`: el storage subyacente se borra (comportamiento típico con dynamic provisioning).
  - `Recycle`: deprecado, no usar.

### PersistentVolumeClaim (PVC)

Es la forma en que un usuario/aplicación **solicita** storage, sin conocer los detalles del backend. Es un recurso namespaced. Kubernetes busca un PV que satisfaga la claim (capacity, accessModes, storageClassName) y los "bindea" en una relación 1:1.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: manual
  resources:
    requests:
      storage: 3Gi
```

```console
$ kubectl apply -f pv-data.yaml
persistentvolume/pv-data created

$ kubectl apply -f pvc-data.yaml
persistentvolumeclaim/pvc-data created

$ kubectl get pv
NAME      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM              STORAGECLASS   AGE
pv-data   5Gi        RWO            Retain           Bound    default/pvc-data   manual         12s

$ kubectl get pvc
NAME       STATUS   VOLUME    CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Bound    pv-data   5Gi        RWO            manual         12s
```

Notar que la claim pide 3Gi pero el PV disponible es de 5Gi: el binding es válido porque el PV cumple o excede lo solicitado (no hay binding parcial, el Pod consumidor ve la capacity real del PV).

### Consumir el PVC desde un Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: db-pod
spec:
  containers:
  - name: postgres
    image: postgres:16
    env:
    - name: POSTGRES_PASSWORD
      value: examplepass
    volumeMounts:
    - name: db-storage
      mountPath: /var/lib/postgresql/data
      subPath: pgdata
  volumes:
  - name: db-storage
    persistentVolumeClaim:
      claimName: pvc-data
```

`subPath` monta un subdirectorio dentro del volumen en vez de la raíz, útil cuando un mismo PVC se comparte entre containers que necesitan paths distintos, o para evitar que el volumen sobrescriba archivos ya existentes en el mountPath (por ejemplo `/var/lib/postgresql/data` que Postgres espera vacío o con estructura propia).

### StorageClass y dynamic provisioning

En clusters reales casi nunca se crean PVs a mano: una **StorageClass** define un `provisioner` (el driver CSI del backend) que crea el PV automáticamente cuando se crea un PVC que la referencia.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

- `volumeBindingMode: WaitForFirstConsumer` retrasa el binding (y el provisioning) hasta que un Pod que usa el PVC es scheduleado, para que el volumen se cree en la zona correcta.
- `allowVolumeExpansion: true` permite crecer un PVC ya existente editando `spec.resources.requests.storage` (no todos los backends lo soportan).

Si un PVC no especifica `storageClassName`, usa la StorageClass marcada como `default` (annotation `storageclass.kubernetes.io/is-default-class: "true"`). Si se especifica `storageClassName: ""`, el PVC solo hace match contra PVs sin StorageClass (pre-provisionados).

```console
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
fast-ssd (default)   kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   true                   3d
```

### Diagnóstico: por qué un PVC queda en Pending

```console
$ kubectl get pvc pvc-data
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Pending                                      fast-ssd       45s

$ kubectl describe pvc pvc-data
...
Events:
  Type     Reason              Age   From                         Message
  ----     ------              ----  ----                         -------
  Warning  ProvisioningFailed  10s   persistentvolume-controller  storageclass.storage.k8s.io "fast-ssd" not found
```

Causas típicas de un PVC en `Pending`: la StorageClass no existe, no hay ningún PV que matchee `accessModes`/`capacity` (en provisioning estático), o el provisioner dinámico no puede crear el volumen (permisos, cuota, zona).

## Referencias

- [Volumes — Kubernetes Documentation](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Ephemeral Volumes — Kubernetes Documentation](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)
- [Persistent Volumes — Kubernetes Documentation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes — Kubernetes Documentation](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Configure a Pod to Use a PersistentVolume for Storage — Kubernetes Tasks](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
- [CKAD Curriculum v1.35 — CNCF](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)