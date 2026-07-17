# Ejercicios guiados: Manage persistent volumes and persistent volume claims (CKA 1.3)

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

## Ejercicio 1 — Crear un PersistentVolume estático con `hostPath`

1. Creá un namespace de trabajo para los ejercicios:
   ```bash
   kubectl create namespace storage-lab
   ```
2. En el nodo donde va a correr el Pod (o dentro de una VM/minikube de un solo nodo), creá el directorio que va a respaldar el volumen:
   ```bash
   mkdir -p /mnt/data-lab
   echo "Hola desde el PersistentVolume" > /mnt/data-lab/index.html
   ```
3. Creá el archivo `pv-hostpath.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: pv-lab-01
   spec:
     capacity:
       storage: 1Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     storageClassName: manual
     hostPath:
       path: /mnt/data-lab
   ```
4. Aplicá el manifiesto y verificá el estado del PV:
   ```bash
   kubectl apply -f pv-hostpath.yaml
   kubectl get pv pv-lab-01
   ```

**Preguntas de comprensión**

1. ¿En qué `STATUS` debería aparecer `pv-lab-01` inmediatamente después de crearlo, y por qué?
2. ¿Qué diferencia práctica hay entre `persistentVolumeReclaimPolicy: Retain` y `Delete` para un PV con backend `hostPath`?

---

## Ejercicio 2 — Crear el PersistentVolumeClaim y verificar el binding

1. Creá el archivo `pvc-lab.yaml` en el namespace `storage-lab`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-lab-01
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: manual
     resources:
       requests:
         storage: 500Mi
   ```
2. Aplicá el PVC:
   ```bash
   kubectl apply -f pvc-lab.yaml
   ```
3. Observá el binding entre el PVC y el PV:
   ```bash
   kubectl get pvc pvc-lab-01 -n storage-lab
   kubectl get pv pv-lab-01
   ```
4. Inspeccioná el campo `spec.volumeName` del PVC y el campo `spec.claimRef` del PV para confirmar la relación uno a uno:
   ```bash
   kubectl get pvc pvc-lab-01 -n storage-lab -o jsonpath='{.spec.volumeName}{"\n"}'
   kubectl get pv pv-lab-01 -o jsonpath='{.spec.claimRef.name}{"\n"}'
   ```

**Preguntas de comprensión**

1. El PVC pide `500Mi` pero el PV ofrece `1Gi`. ¿Por qué igual se produce el binding, y qué capacidad queda efectivamente "reservada" para otros PVC?
2. ¿Qué hubiera pasado si el PVC pedía `storageClassName: manual` pero el `accessModes` fuera `ReadWriteMany`?

---

## Ejercicio 3 — Montar el PVC en un Pod y comprobar persistencia

1. Creá el archivo `pod-consumer.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-lab-01
     namespace: storage-lab
   spec:
     containers:
       - name: web
         image: nginx:1.27
         volumeMounts:
           - name: data
             mountPath: /usr/share/nginx/html
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: pvc-lab-01
   ```
2. Aplicá el Pod y esperá a que esté `Running`:
   ```bash
   kubectl apply -f pod-consumer.yaml
   kubectl wait --for=condition=Ready pod/pod-lab-01 -n storage-lab --timeout=60s
   ```
3. Verificá que el contenido del `hostPath` es visible dentro del contenedor:
   ```bash
   kubectl exec -n storage-lab pod-lab-01 -- cat /usr/share/nginx/html/index.html
   ```
4. Borrá el Pod y volvé a crearlo, y confirmá que el archivo sigue existiendo (la data sobrevive al ciclo de vida del Pod):
   ```bash
   kubectl delete pod pod-lab-01 -n storage-lab
   kubectl apply -f pod-consumer.yaml
   kubectl exec -n storage-lab pod-lab-01 -- cat /usr/share/nginx/html/index.html
   ```

**Preguntas de comprensión**

1. Si en lugar de borrar el Pod hubieras borrado el PVC mientras el Pod seguía corriendo, ¿qué comportamiento esperarías?
2. ¿Por qué el dato persiste aunque el Pod se recree, pero no persistiría si en vez de un volumen `persistentVolumeClaim` hubieras usado `emptyDir`?

---

## Ejercicio 4 — Reclaim policy: liberar y reciclar un PV

1. Borrá el PVC (dejando el PV intacto por la reclaim policy `Retain`):
   ```bash
   kubectl delete pod pod-lab-01 -n storage-lab
   kubectl delete pvc pvc-lab-01 -n storage-lab
   ```
2. Verificá el estado del PV:
   ```bash
   kubectl get pv pv-lab-01
   ```
3. Un PV en `Released` no se puede volver a enlazar automáticamente. Limpiá el `claimRef` para liberarlo manualmente:
   ```bash
   kubectl patch pv pv-lab-01 -p '{"spec":{"claimRef": null}}'
   kubectl get pv pv-lab-01
   ```
4. Volvé a crear el PVC del Ejercicio 2 y confirmá que se reutiliza el mismo PV:
   ```bash
   kubectl apply -f pvc-lab.yaml
   kubectl get pvc pvc-lab-01 -n storage-lab
   ```

**Preguntas de comprensión**

1. ¿Qué estado (`STATUS`) tiene un PV entre que se borra su PVC y que se limpia manualmente su `claimRef`?
2. En un clúster productivo con backend `hostPath` o `local`, ¿qué riesgo tiene reutilizar un PV "liberado" sin borrar antes los datos que dejó el consumidor anterior?

---

## Ejercicio 5 — Dynamic provisioning con StorageClass

1. Listá las StorageClass disponibles en el clúster y detectá cuál es la default:
   ```bash
   kubectl get storageclass
   ```
2. Creá una StorageClass propia (ajustá el `provisioner` al que exista en tu clúster, por ejemplo `rancher.io/local-path` o el CSI driver disponible):
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: sc-lab-fast
   provisioner: rancher.io/local-path
   reclaimPolicy: Delete
   volumeBindingMode: WaitForFirstConsumer
   allowVolumeExpansion: true
   ```
   ```bash
   kubectl apply -f sc-lab-fast.yaml
   ```
3. Creá un PVC que use esta StorageClass, sin crear un PV manualmente:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-dynamic
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: sc-lab-fast
     resources:
       requests:
         storage: 1Gi
   ```
   ```bash
   kubectl apply -f pvc-dynamic.yaml
   kubectl get pvc pvc-dynamic -n storage-lab
   ```
4. Si el `volumeBindingMode` es `WaitForFirstConsumer`, el PVC queda en `Pending` hasta que un Pod lo consuma. Creá un Pod que lo use y volvé a chequear:
   ```bash
   kubectl run pod-dynamic --image=nginx:1.27 -n storage-lab \
     --overrides='{"spec":{"containers":[{"name":"pod-dynamic","image":"nginx:1.27","volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"pvc-dynamic"}}]}}'
   kubectl get pvc pvc-dynamic -n storage-lab
   kubectl get pv
   ```

**Preguntas de comprensión**

1. ¿Qué diferencia de comportamiento hay entre `volumeBindingMode: Immediate` y `WaitForFirstConsumer` respecto al momento en que se aprovisiona el volumen físico?
2. Con `reclaimPolicy: Delete` en la StorageClass, ¿qué pasa con el PV y con los datos subyacentes cuando se borra `pvc-dynamic`?

---

## Ejercicio 6 — Expandir un PVC (volume expansion)

1. Confirmá que la StorageClass usada permite expansión:
   ```bash
   kubectl get storageclass sc-lab-fast -o jsonpath='{.allowVolumeExpansion}{"\n"}'
   ```
2. Editá el PVC para pedir más capacidad (el campo `resources.requests.storage` es el único editable en un PVC existente):
   ```bash
   kubectl patch pvc pvc-dynamic -n storage-lab -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   ```
3. Verificá el progreso de la expansión:
   ```bash
   kubectl get pvc pvc-dynamic -n storage-lab
   kubectl describe pvc pvc-dynamic -n storage-lab
   ```
4. Si el volumen requiere expansión a nivel de filesystem dentro del nodo, confirmá que el Pod que lo consume sigue corriendo (algunos CSI drivers necesitan que el Pod exista para completar el resize del filesystem):
   ```bash
   kubectl get pod pod-dynamic -n storage-lab
   ```

**Preguntas de comprensión**

1. ¿Por qué `allowVolumeExpansion: false` en la StorageClass hace que el `patch` del paso 2 falle o quede sin efecto?
2. ¿Es posible reducir (`shrink`) el tamaño de un PVC editando `resources.requests.storage` a un valor menor? Justificá.

---

## Ejercicio 7 — StatefulSet con `volumeClaimTemplates`

1. Creá el archivo `statefulset-lab.yaml`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: svc-lab
     namespace: storage-lab
   spec:
     clusterIP: None
     selector:
       app: sts-lab
     ports:
       - port: 80
   ---
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: sts-lab
     namespace: storage-lab
   spec:
     serviceName: svc-lab
     replicas: 3
     selector:
       matchLabels:
         app: sts-lab
     template:
       metadata:
         labels:
           app: sts-lab
       spec:
         containers:
           - name: web
             image: nginx:1.27
             volumeMounts:
               - name: www
                 mountPath: /usr/share/nginx/html
     volumeClaimTemplates:
       - metadata:
           name: www
         spec:
           accessModes: ["ReadWriteOnce"]
           storageClassName: sc-lab-fast
           resources:
             requests:
               storage: 500Mi
   ```
2. Aplicá el manifiesto y observá cómo se crean réplicas y PVC en paralelo:
   ```bash
   kubectl apply -f statefulset-lab.yaml
   kubectl get pods -n storage-lab -l app=sts-lab
   kubectl get pvc -n storage-lab
   ```
3. Identificá el patrón de nombres de los PVC generados:
   ```bash
   kubectl get pvc -n storage-lab -o custom-columns=NAME:.metadata.name,POD:.metadata.labels
   ```
4. Borrá el StatefulSet y confirmá que los PVC generados por `volumeClaimTemplates` **no** se borran automáticamente:
   ```bash
   kubectl delete statefulset sts-lab -n storage-lab
   kubectl get pvc -n storage-lab
   ```

**Preguntas de comprensión**

1. ¿Por qué cada réplica de un StatefulSet obtiene su propio PVC en lugar de compartir uno solo, a diferencia de lo que ocurriría con un Deployment?
2. Si escalás `sts-lab` de 3 a 1 réplicas y después otra vez a 3, ¿el Pod `sts-lab-2` vuelve a montar el mismo PVC que tenía antes o uno nuevo?

---

## Ejercicio 8 — Troubleshooting: PVC atascado en `Pending`

1. Creá intencionalmente un PVC con una StorageClass inexistente:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-broken
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: sc-no-existe
     resources:
       requests:
         storage: 1Gi
   ```
   ```bash
   kubectl apply -f pvc-broken.yaml
   kubectl get pvc pvc-broken -n storage-lab
   ```
2. Diagnosticá la causa raíz con `describe` (revisá la sección `Events`):
   ```bash
   kubectl describe pvc pvc-broken -n storage-lab
   ```
3. Corregí el problema apuntando a una StorageClass válida:
   ```bash
   kubectl patch pvc pvc-broken -n storage-lab -p '{"spec":{"storageClassName":"sc-lab-fast"}}'
   ```
4. Si el patch falla porque `storageClassName` es inmutable una vez creado el PVC, borrá y recreá el PVC con el valor correcto, y confirmá el binding:
   ```bash
   kubectl delete pvc pvc-broken -n storage-lab
   kubectl apply -f pvc-broken.yaml   # con storageClassName: sc-lab-fast ya corregido en el YAML
   kubectl get pvc pvc-broken -n storage-lab
   ```

**Preguntas de comprensión**

1. Además de una StorageClass inexistente, mencioná otras dos causas comunes por las que un PVC queda en `Pending` en el examen.
2. ¿Qué comando usarías para ver, en un solo lugar, los `Events` recientes de todo el namespace `storage-lab` y así detectar errores de provisioning sin describir objeto por objeto?

---

## Limpieza

```bash
kubectl delete namespace storage-lab
kubectl delete pv pv-lab-01
kubectl delete storageclass sc-lab-fast
```

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
1. Aparece en `Available`, porque todavía no existe ningún PVC que lo reclame (`claimRef` vacío).
2. Con `Retain`, al borrar el PVC el PV pasa a `Released` y los datos en `/mnt/data-lab` quedan intactos hasta que un admin los limpie y libere el PV manualmente. Con `Delete`, al borrarse el PVC el PV (y en muchos provisioners el storage subyacente) se elimina automáticamente; en `hostPath` estático esta policy es riesgosa porque el kubelet la implementa de forma limitada y no siempre borra el contenido del path.

**Ejercicio 2**
1. El binding se produce porque `1Gi >= 500Mi` solicitado y coinciden `accessModes` y `storageClassName`; el binding es 1 a 1 así que toda la capacidad del PV (1Gi) queda comprometida con ese PVC, no solo los 500Mi pedidos — no se puede "fraccionar" un PV entre varios PVC.
2. No se hubiera enlazado: el binding requiere que el `accessModes` solicitado por el PVC esté entre los que ofrece el PV. Un PV con solo `ReadWriteOnce` no satisface un PVC que pide `ReadWriteMany`, y el PVC quedaría en `Pending`.

**Ejercicio 3**
1. El Pod quedaría bloqueado en estado `Terminating` para el volumen o el `kubectl delete pvc` quedaría colgado (el PVC obtiene el finalizer `kubernetes.io/pvc-protection`) hasta que el Pod que lo monta deje de existir; recién ahí se completa el borrado del PVC.
2. Un PV respaldado por `hostPath` (vía PVC) apunta a un path fijo en el filesystem del nodo que sobrevive al ciclo de vida del Pod; `emptyDir` se crea y se destruye junto con el Pod (vive en el nodo solo mientras el Pod existe), así que al recrear el Pod el directorio se recrea vacío.

**Ejercicio 4**
1. `Released`: el PV ya no está `Bound` pero tampoco es reutilizable automáticamente porque conserva el `claimRef` apuntando al PVC borrado.
2. El nuevo consumidor puede leer datos residuales del consumidor anterior (fuga de información entre workloads/namespaces) si nadie limpia el contenido del path o del disco antes de reutilizar el PV.

**Ejercicio 5**
1. Con `Immediate`, el volumen se aprovisiona apenas se crea el PVC, sin saber en qué nodo terminará el Pod. Con `WaitForFirstConsumer`, el scheduler primero decide en qué nodo va el Pod y recién ahí se aprovisiona el volumen, lo cual es clave para provisioners con afinidad de zona/nodo (como discos locales).
2. El PV y, según el CSI driver, el volumen físico/disco se eliminan automáticamente junto con los datos; no queda rastro recuperable salvo que exista un snapshot previo.

**Ejercicio 6**
1. `allowVolumeExpansion: false` (o el campo ausente, que por defecto es `false`) hace que el API server rechace o ignore el aumento de `requests.storage`; el `kubectl describe pvc` muestra un evento indicando que el resize no está permitido por la StorageClass.
2. No. El campo `resources.requests.storage` de un PVC solo admite incrementos; Kubernetes no soporta shrink de PVC de forma nativa — reducirlo requiere crear un PVC nuevo más chico y migrar los datos manualmente.

**Ejercicio 7**
1. Cada réplica de un StatefulSet tiene identidad estable (`sts-lab-0`, `sts-lab-1`, `sts-lab-2`) y normalmente representa una instancia de datos independiente (por ejemplo, un nodo de una base de datos distribuida), por lo que necesita su propio storage aislado; un Deployment no da identidad estable a sus réplicas y por eso no soporta `volumeClaimTemplates`.
2. Vuelve a montar el mismo PVC (`www-sts-lab-2`), porque el StatefulSet no borra los PVC generados por `volumeClaimTemplates` al reducir réplicas; el nombre del PVC es determinístico según el nombre del Pod, así que al reescalar hacia arriba se reutiliza el que ya existía con sus datos.

**Ejercicio 8**
1. (a) La StorageClass no tiene provisioner activo o el pod del provisioner/CSI driver no está corriendo; (b) no hay suficiente capacidad disponible en el backend, o ningún PV estático libre coincide en `accessModes`/`storageClassName`/tamaño con lo pedido; también es común (c) un PVC con `WaitForFirstConsumer` que queda en `Pending` simplemente porque todavía no hay ningún Pod que lo use.
2. `kubectl get events -n storage-lab --sort-by=.lastTimestamp`

</details>