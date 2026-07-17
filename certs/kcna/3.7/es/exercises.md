# Storage en Kubernetes — Ejercicios guiados (KCNA 3.7)

> Fuente de referencia: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

Requisitos: un cluster de Kubernetes accesible con `kubectl` (sirve `minikube`, `kind` o `Docker Desktop`, ya que necesitás un `StorageClass` por defecto para los ejercicios de aprovisionamiento dinámico).

---

## Ejercicio 1 — `emptyDir`: storage efímero compartido entre containers

1. Creá el archivo `pod-emptydir.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-emptydir
spec:
  containers:
  - name: writer
    image: busybox
    command: ["sh", "-c", "echo 'hola desde writer' > /data/mensaje.txt && sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  - name: reader
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  volumes:
  - name: shared-data
    emptyDir: {}
```

2. Aplicá el manifiesto:

```
kubectl apply -f pod-emptydir.yaml
```

3. Esperá a que el Pod esté `Running`:

```
kubectl get pod demo-emptydir -w
```

4. Leé el archivo desde el container `reader` (que nunca lo escribió):

```
kubectl exec demo-emptydir -c reader -- cat /data/mensaje.txt
```

5. Eliminá el Pod y confirmá que el volumen desaparece con él:

```
kubectl delete pod demo-emptydir
```

**Preguntas de comprensión:**

1. ¿Por qué el container `reader` pudo leer un archivo que nunca escribió?
2. ¿Qué pasa con los datos de un `emptyDir` si el Pod es eliminado o reprogramado (rescheduled) a otro Node? ¿Y si solo se reinicia un container dentro del mismo Pod?

---

## Ejercicio 2 — `hostPath`: montar un path del Node

1. Creá un archivo de prueba en el Node (si usás `minikube`, entrá con `minikube ssh`; si usás `kind`, con `docker exec -it <nombre-nodo> sh`):

```
mkdir -p /tmp/kcna-hostpath
echo "dato del host" > /tmp/kcna-hostpath/archivo.txt
exit
```

2. Creá `pod-hostpath.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-hostpath
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: host-vol
      mountPath: /host-data
  volumes:
  - name: host-vol
    hostPath:
      path: /tmp/kcna-hostpath
      type: Directory
```

3. Aplicá y verificá el contenido montado:

```
kubectl apply -f pod-hostpath.yaml
kubectl exec demo-hostpath -- cat /host-data/archivo.txt
```

4. Limpiá el recurso:

```
kubectl delete pod demo-hostpath
```

**Preguntas de comprensión:**

1. ¿Qué ocurre con este Pod si Kubernetes lo reprograma en un Node distinto al que tiene el archivo en `/tmp/kcna-hostpath`?
2. Nombrá un riesgo de seguridad de usar `hostPath` en un cluster multi-tenant.

---

## Ejercicio 3 — PersistentVolume (PV) estático

1. Creá `pv-demo.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-demo
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/kcna-pv-data
```

2. Aplicá el manifiesto y revisá su estado:

```
kubectl apply -f pv-demo.yaml
kubectl get pv pv-demo
```

3. Observá la columna `STATUS`: debería figurar `Available`.

4. Inspeccioná el objeto completo:

```
kubectl describe pv pv-demo
```

**Preguntas de comprensión:**

1. Un PV es un recurso a nivel de cluster (cluster-scoped), no de un Namespace. ¿Qué implicancia práctica tiene esto al listar PVs con `kubectl get pv -n <namespace>`?
2. ¿Qué significa el `accessMode` `ReadWriteOnce` (RWO)?

---

## Ejercicio 4 — PersistentVolumeClaim (PVC) y binding

1. Creá `pvc-demo.yaml`, pidiendo menos storage del que ofrece el PV para forzar el binding sobre `pv-demo`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
  storageClassName: ""
```

2. Aplicá el PVC y verificá que quedó `Bound` contra `pv-demo`:

```
kubectl apply -f pvc-demo.yaml
kubectl get pvc pvc-demo
kubectl get pv pv-demo
```

3. Montá el PVC en un Pod (`pod-pvc.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pvc-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'via PVC' > /data/out.txt && sleep 3600"]
    volumeMounts:
    - name: pv-storage
      mountPath: /data
  volumes:
  - name: pv-storage
    persistentVolumeClaim:
      claimName: pvc-demo
```

4. Aplicá y verificá que el archivo se escribió:

```
kubectl apply -f pod-pvc.yaml
kubectl exec demo-pvc-pod -- cat /data/out.txt
```

**Preguntas de comprensión:**

1. ¿Por qué fue necesario setear `storageClassName: ""` en el PVC para que se bindeara contra `pv-demo`?
2. Si existieran dos PVs disponibles que cumplen los requisitos del PVC (capacidad y `accessMode`), ¿el usuario elige a cuál se bindea?

---

## Ejercicio 5 — Aprovisionamiento dinámico con `StorageClass`

1. Listá los `StorageClass` disponibles en el cluster y identificá cuál tiene el annotation de default:

```
kubectl get storageclass
```

2. Creá un PVC **sin** especificar un PV manualmente, dejando que el `StorageClass` default aprovisione el volumen (`pvc-dynamic.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

3. Aplicá el manifiesto y observá cómo pasa de `Pending` a `Bound` sin que hayas creado un PV vos mismo:

```
kubectl apply -f pvc-dynamic.yaml
kubectl get pvc pvc-dynamic -w
```

4. Confirmá que se creó un PV nuevo automáticamente:

```
kubectl get pv
```

**Preguntas de comprensión:**

1. ¿Qué componente es responsable de crear el PV automáticamente cuando el PVC referencia un `StorageClass`? (pensá en el rol del **provisioner** / CSI driver)
2. ¿Qué diferencia hay, en el flujo de trabajo del usuario, entre el binding del Ejercicio 4 (estático) y el de este ejercicio (dinámico)?

---

## Ejercicio 6 — Reclaim Policy: `Retain` vs `Delete`

1. Revisá la `reclaimPolicy` del PV creado dinámicamente en el Ejercicio 5:

```
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

2. Eliminá el PVC dinámico y observá qué pasa con su PV asociado:

```
kubectl delete pvc pvc-dynamic
kubectl get pv
```

3. Ahora eliminá el PVC estático del Ejercicio 4 (bindeado a `pv-demo`, que tiene `persistentVolumeReclaimPolicy: Retain`) y observá la diferencia:

```
kubectl delete pvc pvc-demo
kubectl get pv pv-demo
```

4. Limpiá los recursos restantes:

```
kubectl delete pod demo-pvc-pod
kubectl delete pv pv-demo
```

**Preguntas de comprensión:**

1. ¿Qué `STATUS` mostró `pv-demo` después de eliminar `pvc-demo`, y por qué no se borró el PV automáticamente?
2. Si `pv-demo` hubiera tenido `persistentVolumeReclaimPolicy: Delete`, ¿qué habría pasado con el PV (y con los datos subyacentes en `hostPath`) al eliminar el PVC?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**

1. Porque ambos containers del mismo Pod comparten el mismo volumen `emptyDir`, montado en ambos como `/data`. El volumen es compartido a nivel de Pod, no aislado por container.
2. Si el Pod es eliminado o reprogramado a otro Node, el `emptyDir` se borra definitivamente (su ciclo de vida está atado al del Pod, no al Node). Si solo se reinicia un container individual dentro del mismo Pod (por ejemplo por un crash), el `emptyDir` sobrevive porque el Pod en sí sigue existiendo.

**Ejercicio 2**

1. El Pod fallaría al iniciar (o se quedaría sin poder leer el archivo esperado), porque `hostPath` referencia un path en el filesystem del Node donde corre el Pod. El scheduler no garantiza que el Pod caiga siempre en el mismo Node, así que el contenido de `hostPath` no viaja con el Pod.
2. Un container con acceso a `hostPath` puede leer/escribir directamente en el filesystem del Node subyacente, lo que puede exponer archivos sensibles del host o incluso permitir escapar del aislamiento del container si se monta un path crítico (por ejemplo `/`, `/etc` o el socket de Docker).

**Ejercicio 3**

1. Que un PV no pertenece a ningún Namespace: aparece en `kubectl get pv` sin importar el flag `-n`, y cualquier PVC de cualquier Namespace (sujeto a `accessModes` y `storageClassName`) puede potencialmente bindearse a él.
2. `ReadWriteOnce` significa que el volumen puede montarse en modo lectura-escritura por los Pods de un único Node a la vez (desde Kubernetes 1.22+, técnicamente permite múltiples Pods en ese mismo Node). No implica que solo un Pod pueda usarlo, sino que está limitado a un solo Node.

**Ejercicio 4**

1. Porque el PV `pv-demo` no tiene `storageClassName` definido (queda como `""` por defecto). Si el PVC no especifica también `storageClassName: ""`, Kubernetes usaría el `StorageClass` default del cluster (si existe) y dispararía aprovisionamiento dinámico en lugar de bindear contra el PV estático existente.
2. No. El binding lo resuelve el control plane de Kubernetes (el PersistentVolume controller), no el usuario. Se bindea automáticamente al PV disponible que mejor cumpla los criterios (capacidad mínima suficiente, `accessModes` compatibles, `storageClassName` coincidente), no necesariamente al de menor tamaño.

**Ejercicio 5**

1. El **provisioner** asociado al `StorageClass` (por ejemplo, un driver **CSI — Container Storage Interface**) es quien crea el volumen de storage real y el objeto PV correspondiente. El `StorageClass` solo define *qué* provisioner usar y con qué parámetros.
2. En el flujo estático, un administrador de cluster crea el PV manualmente por adelantado; el PVC solo se bindea a un PV ya existente. En el flujo dinámico, el usuario únicamente crea el PVC, y el PV se crea automáticamente "on demand" en el momento en que el PVC lo requiere — no hace falta que un PV preexista.

**Ejercicio 6**

1. El PV pasó a `STATUS: Released` (no `Available` ni se eliminó). No se borra automáticamente porque su `persistentVolumeReclaimPolicy` es `Retain`, política diseñada para preservar los datos y requerir intervención manual del administrador antes de reutilizar o liberar el volumen.
2. Con `Delete`, al eliminar el PVC, Kubernetes habría eliminado automáticamente tanto el objeto PV como el storage subyacente (en este caso, el directorio de `hostPath`), sin necesidad de limpieza manual. `Delete` es la política default para muchos provisioners dinámicos, mientras que `Retain` prioriza no perder datos por accidente.

</details>