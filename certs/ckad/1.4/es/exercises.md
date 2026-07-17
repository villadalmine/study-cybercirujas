# CKAD 1.4 — Ejercicios guiados: Utilize persistent and ephemeral volumes

> Requisitos: acceso a un cluster de Kubernetes (`minikube`, `kind` o similar) con `kubectl` configurado y, al menos, una `StorageClass` por default disponible (`kubectl get storageclass` debe devolver al menos una fila).
>
> Referencia curricular: [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

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
     name: shared-vol-pod
     namespace: vol-lab
   spec:
     volumes:
       - name: cache-vol
         emptyDir: {}
     containers:
       - name: writer
         image: busybox:1.36
         command: ["sh", "-c", "echo hola-desde-writer > /data/mensaje.txt && sleep 3600"]
         volumeMounts:
           - name: cache-vol
             mountPath: /data
       - name: reader
         image: busybox:1.36
         command: ["sh", "-c", "sleep 5 && cat /shared/mensaje.txt && sleep 3600"]
         volumeMounts:
           - name: cache-vol
             mountPath: /shared
   ```

3. Aplicá el manifiesto y esperá a que el Pod quede `Running`:

   ```bash
   kubectl apply -f emptydir-pod.yaml
   kubectl wait --for=condition=Ready pod/shared-vol-pod -n vol-lab --timeout=60s
   ```

4. Verificá los logs del container `reader`:

   ```bash
   kubectl logs shared-vol-pod -c reader -n vol-lab
   ```

5. Borrá el Pod y confirmá que no queda rastro del volumen:

   ```bash
   kubectl delete pod shared-vol-pod -n vol-lab
   ```

<details>
<summary>Preguntas de comprensión — Ejercicio 1</summary>

1. ¿Por qué el container `reader` pudo leer el archivo escrito por `writer` si son dos containers distintos dentro del mismo Pod?
2. ¿Qué ocurre con los datos de un `emptyDir` si el Pod se reinicia por un crash de un container vs. si el Pod entero es eliminado?
3. ¿En qué se diferencia un `emptyDir` de un volumen `hostPath` en términos de dónde vive físicamente el dato?

</details>

---

## Ejercicio 2 — `hostPath`: montar un path del nodo

1. Creá `hostpath-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hostpath-pod
     namespace: vol-lab
   spec:
     volumes:
       - name: node-logs
         hostPath:
           path: /tmp/vol-lab-hostpath
           type: DirectoryOrCreate
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "echo dato-persistido-en-nodo >> /host-data/log.txt && sleep 3600"]
         volumeMounts:
           - name: node-logs
             mountPath: /host-data
   ```

2. Aplicá y esperá a que esté `Running`:

   ```bash
   kubectl apply -f hostpath-pod.yaml
   kubectl wait --for=condition=Ready pod/hostpath-pod -n vol-lab --timeout=60s
   ```

3. Borrá el Pod y volvé a crearlo con el mismo manifiesto:

   ```bash
   kubectl delete pod hostpath-pod -n vol-lab
   kubectl apply -f hostpath-pod.yaml
   kubectl wait --for=condition=Ready pod/hostpath-pod -n vol-lab --timeout=60s
   kubectl exec hostpath-pod -n vol-lab -- cat /host-data/log.txt
   ```

<details>
<summary>Preguntas de comprensión — Ejercicio 2</summary>

1. Al recrear el Pod, ¿el archivo `log.txt` tenía una o dos líneas? ¿Qué te dice eso sobre la persistencia de `hostPath` frente a la de `emptyDir`?
2. Si este Pod pudiera ser reprogramado (rescheduled) en otro nodo del cluster, ¿seguiría viendo el mismo archivo? ¿Por qué es esto una limitación seria de `hostPath` en producción?
3. ¿Qué riesgo de seguridad implica dar acceso `hostPath` de escritura a un Pod?

</details>

---

## Ejercicio 3 — `PersistentVolume` y `PersistentVolumeClaim` (provisioning estático)

1. Verificá qué `StorageClass` tenés disponible por default:

   ```bash
   kubectl get storageclass
   ```

2. Creá `pvc-basic.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: data-pvc
     namespace: vol-lab
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   ```

3. Aplicá el PVC y observá su estado hasta que quede `Bound`:

   ```bash
   kubectl apply -f pvc-basic.yaml
   kubectl get pvc data-pvc -n vol-lab -w
   ```

   (`Ctrl+C` cuando veas `STATUS: Bound`)

4. Inspeccioná qué `PersistentVolume` se creó/asoció automáticamente:

   ```bash
   kubectl get pv
   kubectl describe pvc data-pvc -n vol-lab
   ```

5. Montá el PVC en un Pod, `pvc-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-pod
     namespace: vol-lab
   spec:
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: data-pvc
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "echo dato-en-pvc > /data/persist.txt && sleep 3600"]
         volumeMounts:
           - name: data
             mountPath: /data
   ```

6. Aplicá, esperá `Running`, borrá el Pod, volvé a crearlo y confirmá que el archivo sigue existiendo:

   ```bash
   kubectl apply -f pvc-pod.yaml
   kubectl wait --for=condition=Ready pod/pvc-pod -n vol-lab --timeout=60s
   kubectl delete pod pvc-pod -n vol-lab
   kubectl apply -f pvc-pod.yaml
   kubectl wait --for=condition=Ready pod/pvc-pod -n vol-lab --timeout=60s
   kubectl exec pvc-pod -n vol-lab -- cat /data/persist.txt
   ```

<details>
<summary>Preguntas de comprensión — Ejercicio 3</summary>

1. ¿Qué componente del cluster fue responsable de crear el `PersistentVolume` cuando aplicaste el PVC, dado que no lo creaste vos manualmente?
2. ¿Cuál es la relación de cardinalidad entre un PVC y un PV una vez que el binding ocurrió?
3. Si borrás el Pod `pvc-pod` pero dejás el PVC intacto, ¿el dato sobrevive? ¿Y si además borrás el PVC? (pista: revisá el `reclaimPolicy` del PV con `kubectl get pv -o yaml`)

</details>

---

## Ejercicio 4 — Access modes y `reclaimPolicy`

1. Mirá el `accessModes` y el `persistentVolumeReclaimPolicy` del PV asociado a `data-pvc`:

   ```bash
   PV_NAME=$(kubectl get pvc data-pvc -n vol-lab -o jsonpath='{.spec.volumeName}')
   kubectl get pv "$PV_NAME" -o jsonpath='{.spec.accessModes}{"\n"}{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

2. Intentá crear un segundo Pod que use la misma `data-pvc` en paralelo al primero, `pvc-pod-2.yaml` (mismo contenido que `pvc-pod.yaml` pero `metadata.name: pvc-pod-2`), y aplicalo sin borrar `pvc-pod`:

   ```bash
   kubectl apply -f pvc-pod-2.yaml
   kubectl get pods -n vol-lab -o wide
   ```

3. Borrá el PVC `data-pvc` (vas a necesitar borrar antes ambos Pods si tu cluster bloquea el delete por Pods activos):

   ```bash
   kubectl delete pod pvc-pod pvc-pod-2 -n vol-lab --ignore-not-found
   kubectl delete pvc data-pvc -n vol-lab
   kubectl get pv
   ```

<details>
<summary>Preguntas de comprensión — Ejercicio 4</summary>

1. Con `accessModes: [ReadWriteOnce]`, ¿en cuántos nodos simultáneamente puede montarse el volumen en modo escritura? ¿Qué diferencia hay con `ReadWriteOncePod`?
2. Si el `reclaimPolicy` era `Delete`, ¿qué pasó con el `PersistentVolume` después de borrar el PVC? ¿Y si hubiese sido `Retain`?
3. ¿Qué `accessMode` elegirías para un volumen que debe ser leído simultáneamente por múltiples réplicas de un Deployment, pero nunca escrito por ellas?

</details>

---

## Ejercicio 5 — `subPath` y expansión de un PVC

1. Creá `pvc-subpath-pod.yaml`, montando dos subdirectorios distintos del mismo PVC en dos paths diferentes usando `subPath`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: shared-storage
     namespace: vol-lab
   spec:
     accessModes: ["ReadWriteOnce"]
     resources:
       requests:
         storage: 1Gi
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: subpath-pod
     namespace: vol-lab
   spec:
     volumes:
       - name: storage
         persistentVolumeClaim:
           claimName: shared-storage
     containers:
       - name: app-logs
         image: busybox:1.36
         command: ["sh", "-c", "echo linea-de-log >> /var/log/app/out.log && sleep 3600"]
         volumeMounts:
           - name: storage
             mountPath: /var/log/app
             subPath: logs
       - name: app-config
         image: busybox:1.36
         command: ["sh", "-c", "echo clave=valor >> /etc/app/config.ini && sleep 3600"]
         volumeMounts:
           - name: storage
             mountPath: /etc/app
             subPath: config
   ```

2. Aplicá y verificá que ambos containers escriben en rutas separadas del mismo volumen físico:

   ```bash
   kubectl apply -f pvc-subpath-pod.yaml
   kubectl wait --for=condition=Ready pod/subpath-pod -n vol-lab --timeout=60s
   kubectl exec subpath-pod -n vol-lab -c app-logs -- ls /var/log/app
   kubectl exec subpath-pod -n vol-lab -c app-config -- ls /etc/app
   ```

3. Comprobá si tu `StorageClass` permite expansión de volumen:

   ```bash
   SC_NAME=$(kubectl get pvc shared-storage -n vol-lab -o jsonpath='{.spec.storageClassName}')
   kubectl get storageclass "$SC_NAME" -o jsonpath='{.allowVolumeExpansion}{"\n"}'
   ```

4. Si el resultado fue `true`, intentá agrandar el PVC editando el campo `resources.requests.storage`:

   ```bash
   kubectl patch pvc shared-storage -n vol-lab -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   kubectl get pvc shared-storage -n vol-lab -w
   ```

<details>
<summary>Preguntas de comprensión — Ejercicio 5</summary>

1. ¿Qué ventaja tiene usar `subPath` frente a montar dos `PersistentVolumeClaim` distintos si ambos containers solo necesitan compartir el mismo volumen físico dividido en carpetas?
2. Si `allowVolumeExpansion` es `false` en tu `StorageClass`, ¿qué alternativas tenés para aumentar la capacidad disponible de una aplicación sin downtime?
3. Un volumen montado con `subPath: logs` en `/var/log/app`: ¿el container `app-config` puede ver los archivos de `logs`? Justificá según lo observado en el paso 2.

</details>

---

## Limpieza final

```bash
kubectl delete namespace vol-lab
```

---

<details>
<summary><strong>Respuestas — Ejercicio 1</strong></summary>

1. Ambos containers pertenecen al mismo Pod y comparten el mismo `emptyDir`, aunque cada uno lo monta en un `mountPath` distinto (`/data` y `/shared`). El volumen es único a nivel Pod, no a nivel container.
2. Un `emptyDir` sobrevive a un restart de container individual (el kubelet no lo borra al reiniciar solo un container), pero se elimina definitivamente cuando el Pod completo es removido del nodo (borrado, evicted, o rescheduled a otro nodo).
3. `emptyDir` vive en el filesystem del nodo (o en memoria si se configura `medium: Memory`) pero está atado al ciclo de vida del Pod; `hostPath` también vive en el filesystem del nodo, pero su ciclo de vida es independiente del Pod y persiste incluso después de que el Pod se borre — el dato queda "pegado" a ese nodo específico.

</details>

<details>
<summary><strong>Respuestas — Ejercicio 2</strong></summary>

1. Tenía dos líneas: la segunda ejecución del Pod encontró el archivo ya creado por la primera y le agregó (`>>`) una línea nueva. Esto confirma que `hostPath` persiste más allá del ciclo de vida del Pod, a diferencia de `emptyDir`.
2. No vería el mismo archivo, porque `hostPath` referencia un path en el filesystem del nodo local donde corre el Pod; si el scheduler ubica el Pod en otro nodo, ese path no existe ahí (o existe con contenido distinto). Por eso `hostPath` no es apto para cargas que requieren portabilidad entre nodos.
3. Da acceso directo al filesystem del nodo, lo que puede permitir escapar del aislamiento del container (por ejemplo, escribiendo binarios o modificando archivos del sistema si se monta un path sensible), y es una superficie de ataque típica para escalamiento de privilegios en clusters mal configurados.

</details>

<details>
<summary><strong>Respuestas — Ejercicio 3</strong></summary>

1. El **provisioner dinámico** de la `StorageClass` default (por ejemplo `local-path-provisioner`, el CSI driver de la nube, etc.), invocado automáticamente porque el PVC no especificó un PV existente y sí tiene (implícita o explícitamente) una `storageClassName` con provisioner configurado.
2. Es una relación **uno a uno**: una vez bound, ese PV queda exclusivamente reservado para ese PVC y no puede ser reclamado por ningún otro PVC hasta que se libere.
3. Con el PVC intacto y solo el Pod borrado, el dato sobrevive (el PVC retiene el binding al PV). Si además se borra el PVC, el resultado depende del `reclaimPolicy` del PV: con `Delete` el PV (y típicamente el storage subyacente) se elimina junto con el dato; con `Retain` el PV queda en estado `Released`, conservando el dato pero sin poder ser reusado automáticamente por un nuevo PVC.

</details>

<details>
<summary><strong>Respuestas — Ejercicio 4</strong></summary>

1. Con `ReadWriteOnce`, el volumen puede montarse en modo lectura-escritura en **un solo nodo** a la vez — pero, según versión de Kubernetes y CSI driver, eso históricamente podía permitir múltiples Pods del mismo nodo montándolo simultáneamente. `ReadWriteOncePod` es más estricto: garantiza que el volumen sea montado por **un único Pod** en todo el cluster, cerrando esa ambigüedad.
2. Con `reclaimPolicy: Delete`, el `PersistentVolume` se eliminó automáticamente (y el backend de storage liberó/borró los datos) apenas se borró el PVC. Con `Retain`, el PV hubiese quedado en estado `Released`, sin borrarse, requiriendo intervención manual del administrador para reutilizarlo o limpiarlo.
3. `ReadOnlyMany` — permite que múltiples nodos monten el volumen simultáneamente pero solo en modo lectura, que es exactamente lo que necesitan réplicas que consumen un dataset compartido sin modificarlo.

</details>

<details>
<summary><strong>Respuestas — Ejercicio 5</strong></summary>

1. `subPath` permite reutilizar un único volumen (y por lo tanto una única reserva de storage) dividiéndolo lógicamente en subdirectorios, evitando tener que aprovisionar y gestionar múltiples PVCs (con sus propios ciclos de vida y costos) cuando en realidad todos los datos pertenecen a la misma unidad lógica de la aplicación.
2. Alternativas: crear un nuevo PVC más grande y migrar los datos manualmente (por ejemplo con un Job que copie de un volumen viejo a uno nuevo), usar una `StorageClass` distinta que sí soporte expansión, o diseñar la aplicación para particionar datos en múltiples PVCs desde el inicio.
3. No — cada `subPath` aísla la vista del container a esa subcarpeta específica dentro del volumen. `app-config` con `subPath: config` solo ve el contenido de la carpeta `config/`, no `logs/`, aunque ambas convivan en el mismo `PersistentVolume` físico.

</details>