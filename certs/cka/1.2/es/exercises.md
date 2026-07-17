# Ejercicios guiados — CKA 1.2: Configure volume types, access modes and reclaim policies

> Peso en el examen: 3.33%
> Fuente de referencia: [CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)
> Requisitos: un cluster con al menos 1 nodo worker (kind, minikube o similar) y `kubectl` configurado contra ese contexto.

---

## Ejercicio 1 — `emptyDir`: volumen efímero compartido entre containers

1. Creá un namespace de trabajo:

   ```bash
   kubectl create namespace vol-lab
   ```

2. Creá el archivo `emptydir-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: emptydir-demo
     namespace: vol-lab
   spec:
     containers:
     - name: writer
       image: busybox
       command: ["sh", "-c", "echo hola desde writer > /data/msg.txt && sleep 3600"]
       volumeMounts:
       - name: shared
         mountPath: /data
     - name: reader
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: shared
         mountPath: /data
     volumes:
     - name: shared
       emptyDir: {}
   ```

3. Aplicá el manifiesto y esperá a que el Pod esté `Running`:

   ```bash
   kubectl apply -f emptydir-pod.yaml
   kubectl wait --for=condition=Ready pod/emptydir-demo -n vol-lab --timeout=60s
   ```

4. Verificá que el container `reader` puede leer el archivo escrito por `writer`:

   ```bash
   kubectl exec -n vol-lab emptydir-demo -c reader -- cat /data/msg.txt
   ```

5. Borrá el Pod y confirmá que el volumen desaparece con él:

   ```bash
   kubectl delete pod emptydir-demo -n vol-lab
   ```

**Preguntas de comprensión**

- ¿Qué pasa con los datos de un `emptyDir` si un container dentro del Pod se reinicia (crash) en lugar de que se borre el Pod entero?
- ¿En qué campo de `spec.volumes[].emptyDir` configurarías el volumen para que use memoria RAM (`tmpfs`) en vez de disco, y qué implicancia tiene eso sobre la persistencia?

---

## Ejercicio 2 — `hostPath`: acceso directo al filesystem del nodo

1. Identificá en qué nodo vas a programar el Pod (en un cluster de un solo nodo esto es automático):

   ```bash
   kubectl get nodes
   ```

2. Creá `hostpath-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hostpath-demo
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: host-data
         mountPath: /hostdata
     volumes:
     - name: host-data
       hostPath:
         path: /tmp/vol-lab-data
         type: DirectoryOrCreate
   ```

3. Aplicá y verificá que el Pod está corriendo:

   ```bash
   kubectl apply -f hostpath-pod.yaml
   kubectl wait --for=condition=Ready pod/hostpath-demo -n vol-lab --timeout=60s
   ```

4. Escribí un archivo desde dentro del container y confirmá que existe en el filesystem del nodo (si usás kind, entrá con `docker exec` al container del nodo; si usás minikube, `minikube ssh`):

   ```bash
   kubectl exec -n vol-lab hostpath-demo -- sh -c "echo prueba > /hostdata/archivo.txt"
   ```

5. Inspeccioná el `type` que usaste y probá cambiarlo mentalmente a `Directory` (sin crear el directorio antes) para el siguiente punto de comprensión.

**Preguntas de comprensión**

- Si el Pod con `hostPath` es reprogramado (rescheduled) a otro nodo, ¿qué pasa con los datos que escribiste en el punto 4?
- ¿Qué diferencia práctica hay entre `type: Directory` y `type: DirectoryOrCreate` si el path no existe todavía en el nodo?

---

## Ejercicio 3 — PersistentVolume y PersistentVolumeClaim estáticos, access modes

1. Creá un `PersistentVolume` respaldado por `hostPath` con `accessModes: ReadWriteOnce`, en `pv-demo.yaml`:

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
     storageClassName: manual
     hostPath:
       path: /tmp/pv-demo-data
   ```

2. Creá el `PersistentVolumeClaim` que va a reclamar ese PV, en `pvc-demo.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-demo
     namespace: vol-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: manual
     resources:
       requests:
         storage: 500Mi
   ```

3. Aplicá ambos manifiestos en orden y verificá el estado (`STATUS`) de cada objeto:

   ```bash
   kubectl apply -f pv-demo.yaml
   kubectl apply -f pvc-demo.yaml
   kubectl get pv pv-demo
   kubectl get pvc pvc-demo -n vol-lab
   ```

4. Confirmá el binding 1:1 entre PV y PVC inspeccionando el campo `spec.claimRef` del PV:

   ```bash
   kubectl get pv pv-demo -o jsonpath='{.spec.claimRef.name}{"\n"}'
   ```

5. Montá el PVC en un Pod, en `pvc-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-consumer
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-demo
   ```

   ```bash
   kubectl apply -f pvc-pod.yaml
   kubectl wait --for=condition=Ready pod/pvc-consumer -n vol-lab --timeout=60s
   ```

**Preguntas de comprensión**

- Si pedís un `storage: 500Mi` en el PVC pero el único PV disponible con ese `storageClassName` tiene `capacity: 1Gi`, ¿el PVC hace binding igual? ¿Por qué el PVC no queda limitado a los 500Mi que pidió?
- ¿Por qué un segundo Pod en otro namespace no puede reclamar el mismo `pv-demo` aunque el PV tenga `accessModes: ReadWriteOnce` y todavía tenga capacidad "libre" en teoría?
- ¿Qué modo de acceso elegirías si necesitás que varios Pods en distintos nodos escriban al mismo volumen simultáneamente, y qué tipo de backend (`hostPath` no sirve) lo soporta típicamente?

---

## Ejercicio 4 — Reclaim policies: `Retain` vs `Delete`

1. Con el PV/PVC del ejercicio 3 todavía en pie, confirmá la reclaim policy actual:

   ```bash
   kubectl get pv pv-demo -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

2. Borrá el Pod consumidor y luego el PVC:

   ```bash
   kubectl delete pod pvc-consumer -n vol-lab
   kubectl delete pvc pvc-demo -n vol-lab
   ```

3. Observá qué le pasa al PV después de borrar el PVC:

   ```bash
   kubectl get pv pv-demo
   ```

4. Notá el nuevo `STATUS` (`Released`) y que los datos en `/tmp/pv-demo-data` en el nodo **siguen existiendo**. Para volver a usar ese PV hace falta limpiar manualmente el `claimRef`:

   ```bash
   kubectl patch pv pv-demo --type=json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
   kubectl get pv pv-demo
   ```

5. Ahora creá un segundo PV idéntico pero con `persistentVolumeReclaimPolicy: Delete`, en `pv-delete.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: pv-delete-demo
   spec:
     capacity:
       storage: 1Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Delete
     storageClassName: manual-delete
     hostPath:
       path: /tmp/pv-delete-demo-data
   ```

   Aplicalo, creá un PVC que lo reclame, y luego borrá el PVC. Verificá qué pasa con el PV esta vez:

   ```bash
   kubectl apply -f pv-delete.yaml
   # (creá y aplicá un PVC análogo al del ejercicio 3, apuntando a storageClassName: manual-delete)
   kubectl delete pvc <nombre-del-pvc>
   kubectl get pv pv-delete-demo
   ```

**Preguntas de comprensión**

- Con `persistentVolumeReclaimPolicy: Retain`, ¿en qué estado queda el PV después de borrar el PVC, y qué pasos manuales son necesarios para que otro PVC pueda reclamarlo?
- ¿Por qué en un PV respaldado por `hostPath` la policy `Delete` puede no eliminar realmente los datos del disco del nodo, a diferencia de un volumen provisto dinámicamente por un backend CSI en la nube?
- La reclaim policy `Recycle` está deprecada. ¿Qué hacía originalmente, y qué mecanismo la reemplaza hoy para "limpiar" un volumen antes de reutilizarlo?

---

## Ejercicio 5 — Aprovisionamiento dinámico con `StorageClass`

1. Listá las `StorageClass` disponibles en el cluster (en kind/minikube suele haber una por defecto):

   ```bash
   kubectl get storageclass
   ```

2. Inspeccioná su reclaim policy y su `provisioner`:

   ```bash
   kubectl get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIMPOLICY:.reclaimPolicy,BINDINGMODE:.volumeBindingMode
   ```

3. Creá un PVC que **no** especifique `storageClassName` fijo a `manual`, sino que use la StorageClass por defecto, en `pvc-dynamic.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-dynamic
     namespace: vol-lab
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   ```

4. Aplicá y observá cómo se crea automáticamente un PV nuevo (sin que vos lo hayas definido):

   ```bash
   kubectl apply -f pvc-dynamic.yaml
   kubectl get pvc pvc-dynamic -n vol-lab
   kubectl get pv
   ```

5. Identificá qué PV fue provisto dinámicamente para este PVC y confirmá que su `persistentVolumeReclaimPolicy` heredó el valor definido en la StorageClass:

   ```bash
   PV_NAME=$(kubectl get pvc pvc-dynamic -n vol-lab -o jsonpath='{.spec.volumeName}')
   kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

**Preguntas de comprensión**

- ¿Qué campo del recurso `StorageClass` determina si el binding del PV ocurre inmediatamente (`Immediate`) o recién cuando un Pod que usa el PVC es programado (`WaitForFirstConsumer`), y por qué esto último es relevante en clusters multi-zona?
- Si borrás el PVC `pvc-dynamic` y la StorageClass usada tiene `reclaimPolicy: Delete`, ¿qué diferencia de comportamiento observás respecto al PV manual `Retain` del ejercicio 4?
- ¿Cómo marcarías una StorageClass como la default del cluster usando una annotation, y qué pasa si dos StorageClass tienen esa annotation en `true` al mismo tiempo?

---

## Ejercicio 6 — Access modes: `ReadWriteOnce` vs `ReadWriteOncePod`

1. Revisá la documentación embebida del recurso PVC para ver los access modes soportados:

   ```bash
   kubectl explain pvc.spec.accessModes
   ```

2. Tomá el PVC `pvc-dynamic` del ejercicio 5 y montalo simultáneamente desde dos Pods distintos en el mismo namespace, en `two-consumers.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer-a
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-dynamic
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer-b
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-dynamic
   ```

3. Aplicá y observá el estado de ambos Pods:

   ```bash
   kubectl apply -f two-consumers.yaml
   kubectl get pods -n vol-lab -o wide
   ```

4. Si ambos Pods terminan en el mismo nodo, vas a ver que ambos llegan a `Running` (porque `ReadWriteOnce` permite múltiples Pods **en el mismo nodo**). Confirmá el nodo de cada uno:

   ```bash
   kubectl get pod consumer-a consumer-b -n vol-lab -o jsonpath='{.items[*].spec.nodeName}{"\n"}'
   ```

5. Limpiá todos los recursos del namespace al terminar:

   ```bash
   kubectl delete namespace vol-lab
   ```

**Preguntas de comprensión**

- ¿Cuál es la diferencia exacta entre `ReadWriteOnce` (RWO) y `ReadWriteOncePod` (RWOP) respecto a cuántos Pods pueden montar el volumen simultáneamente?
- En un cluster con varios nodos, si dos Pods con el mismo PVC `ReadWriteOnce` son programados en nodos distintos, ¿qué pasa con el segundo Pod?
- ¿Qué access mode elegirías para un PVC consumido por múltiples réplicas de un Deployment que necesitan lectura concurrente pero nunca escriben (por ejemplo, assets estáticos)?

---

<details>
<summary>Ver respuestas</summary>

### Ejercicio 1 — `emptyDir`

- Si un container crashea y Kubernetes lo reinicia dentro del mismo Pod, el `emptyDir` **sobrevive** — el volumen está atado al ciclo de vida del Pod, no al de un container individual. Solo se pierde cuando el Pod completo es eliminado (o reprogramado a otro nodo).
- Se configura con `spec.volumes[].emptyDir.medium: Memory`. Esto hace que el volumen use `tmpfs` respaldado por RAM en vez de disco, lo que lo hace más rápido pero también hace que cuente contra el límite de memoria del Pod y que los datos se pierdan si el nodo se reinicia (la RAM no persiste al reboot).

### Ejercicio 2 — `hostPath`

- Los datos quedan en el nodo original y **no viajan con el Pod**. El Pod reprogramado en el nuevo nodo va a ver el path `/hostdata` vacío (o con el contenido que ya existiera en ese otro nodo), porque `hostPath` monta un directorio del filesystem local del nodo donde corre el Pod en ese momento, no un volumen de red compartido.
- `type: Directory` requiere que el path **ya exista** en el nodo; si no existe, el Pod falla al arrancar. `type: DirectoryOrCreate` crea el directorio (con permisos `0755`) si no existe todavía, evitando ese error.

### Ejercicio 3 — PV/PVC estáticos y access modes

- Sí, el binding ocurre igual: Kubernetes hace el binding de un PVC al **primer PV disponible que cumpla o exceda** la capacidad solicitada y coincida en `accessModes`/`storageClassName` — no busca el PV de tamaño más ajustado. El PVC queda vinculado a la capacidad total del PV (1Gi en este caso), no limitado a los 500Mi pedidos; ese campo solo es un mínimo, no un tope.
- El binding entre un PV y un PVC es exclusivo y 1:1 a nivel de todo el cluster (no por namespace): una vez que `pv-demo` tiene un `claimRef` apuntando a `vol-lab/pvc-demo`, ningún otro PVC —esté en el namespace que esté— puede reclamarlo hasta que ese PVC se borre y el PV vuelva a `Available`. El `accessModes: ReadWriteOnce` describe cuántos **nodos** pueden montar el volumen simultáneamente, no cuántos PVCs pueden reclamarlo.
- `ReadWriteMany` (RWX) es el modo adecuado para escritura concurrente multi-nodo. Backends típicos que lo soportan son NFS, CephFS, o servicios de archivos compartidos en la nube (Azure Files, Filestore de GCP, EFS de AWS vía su driver CSI); `hostPath` y la mayoría de los discos de bloque en la nube (EBS, PD) solo soportan `ReadWriteOnce`.

### Ejercicio 4 — Reclaim policies

- Con `Retain`, al borrar el PVC el PV pasa a estado `Released`: los datos permanecen intactos en el backend, pero el PV no puede ser reclamado automáticamente por un nuevo PVC. Un administrador debe limpiar manualmente el campo `spec.claimRef` del PV (y opcionalmente los datos) antes de que vuelva a `Available` y pueda ser reutilizado.
- Con `hostPath`, el "delete" que ejecuta Kubernetes es una operación lógica sobre el objeto PV — no hay un plugin CSI de `hostPath` en producción que sepa ir a borrar archivos en el disco del nodo de forma segura, por lo que el comportamiento real de limpieza depende del provisioner. En cambio, un backend CSI en la nube (EBS, PD, etc.) sí ejecuta la llamada de borrado real contra la API del proveedor cuando la reclaim policy es `Delete`, eliminando el volumen físico.
- `Recycle` (deprecada) hacía un `rm -rf` básico del contenido del volumen para dejarlo limpio y disponible para un nuevo PVC. Fue reemplazada por el **aprovisionamiento dinámico** vía `StorageClass`: en vez de reciclar un PV existente, se crea y destruye un volumen nuevo por cada PVC, lo cual es más seguro y flexible.

### Ejercicio 5 — StorageClass y aprovisionamiento dinámico

- El campo es `volumeBindingMode`. Con `WaitForFirstConsumer`, el scheduler retrasa el binding (y con eso la creación real del volumen) hasta que sabe en qué nodo va a correr el Pod que consume el PVC. Esto es clave en clusters multi-zona porque evita crear un volumen en una zona distinta a la del nodo donde termina programado el Pod, lo cual causaría que el Pod quede en `Pending` para siempre por no poder montar un volumen de otra zona.
- Con la StorageClass en `Delete` (comportamiento default de la mayoría de provisioners dinámicos), al borrar el PVC el PV asociado se borra automáticamente **y** el provisioner elimina el recurso de almacenamiento subyacente. Esto contrasta con el PV manual en `Retain` del ejercicio 4, donde el PV queda huérfano en `Released` y requiere limpieza manual — con `Delete` dinámico no queda rastro que limpiar a mano.
- Se marca agregando la annotation `storageclass.kubernetes.io/is-default-class: "true"` en los metadata de la StorageClass. Si dos StorageClass tienen esa annotation en `true` simultáneamente, Kubernetes no falla pero el comportamiento queda ambiguo: los PVC sin `storageClassName` explícito terminan usando la StorageClass default creada más recientemente (la que tiene el timestamp de creación más nuevo), y Kubernetes emite un warning al respecto.

### Ejercicio 6 — Access modes

- `ReadWriteOnce` permite que el volumen sea montado en lectura-escritura por **múltiples Pods, siempre que todos corran en el mismo nodo**. `ReadWriteOncePod` es más estricto: garantiza que **un único Pod en todo el cluster** puede montar el volumen en lectura-escritura a la vez, sin importar el nodo — útil para bases de datos u otras cargas que requieren garantía estricta de exclusividad.
- El segundo Pod queda en estado `Pending`: el scheduler no puede programarlo porque el volumen `ReadWriteOnce` ya está montado en otro nodo, y ese access mode no permite acceso concurrente entre nodos distintos (a diferencia de dentro de un mismo nodo).
- `ReadOnlyMany` (ROX) es la elección correcta: permite que múltiples Pods, en cualquier nodo, monten el mismo volumen en modo solo lectura simultáneamente, lo cual encaja con réplicas de un Deployment que sirven contenido estático sin necesidad de escribir.

</details>
