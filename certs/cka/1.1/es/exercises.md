# CKA 1.35 — Tema 1.1: Implement storage classes and dynamic volume provisioning

**Peso en el examen:** 3.33%
**Fuente de referencia:** [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

> Requisitos previos: un cluster con `kubectl` configurado y al menos un provisioner dinámico disponible (por ejemplo `rancher.io/local-path` en `kind`, `k8s.io/minikube-hostpath` en `minikube`, o el provisioner de tu cloud provider). Si tu cluster no trae ninguno, los Ejercicios 2 a 6 igual funcionan usando el mismo provisioner que ya tengas configurado como `StorageClass` por defecto — solo reemplazá el valor de `provisioner` que se indica.

---

## Ejercicio 1 — Inspeccionar los StorageClass existentes

1. Listá los `StorageClass` disponibles en el cluster:
   ```bash
   kubectl get storageclass
   ```
2. Fijate cuál tiene la anotación `(default)` al lado del nombre. Si ninguno la tiene, no hay `StorageClass` por defecto configurado.
3. Describí el objeto en detalle, incluyendo el provisioner y los parámetros:
   ```bash
   kubectl describe storageclass <nombre>
   ```
4. Mostrá el manifest completo en YAML para ver todos los campos, incluyendo los que `describe` no siempre expone (`volumeBindingMode`, `allowVolumeExpansion`):
   ```bash
   kubectl get storageclass <nombre> -o yaml
   ```

**Preguntas de comprensión — Ejercicio 1**
- P1.1: ¿Qué campo del manifest determina qué componente del cluster (in-tree o CSI driver) va a aprovisionar el volumen físico?
- P1.2: ¿Qué anotación identifica a un `StorageClass` como el default del cluster, y qué pasa si dos `StorageClass` la tienen en `"true"` al mismo tiempo?

---

## Ejercicio 2 — Crear un StorageClass propio

1. Creá un archivo `sc-wffc.yaml` con el siguiente contenido (ajustá `provisioner` al que corresponda a tu cluster):
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast-retain
   provisioner: rancher.io/local-path
   reclaimPolicy: Retain
   volumeBindingMode: WaitForFirstConsumer
   allowVolumeExpansion: true
   ```
2. Aplicalo:
   ```bash
   kubectl apply -f sc-wffc.yaml
   ```
3. Confirmá que se creó y revisá su estado:
   ```bash
   kubectl get storageclass fast-retain
   ```

**Preguntas de comprensión — Ejercicio 2**
- P2.1: ¿Qué diferencia de comportamiento produce `volumeBindingMode: WaitForFirstConsumer` frente al valor por defecto `Immediate` a la hora de crear el `PersistentVolume`?
- P2.2: ¿Se puede editar el `provisioner` de un `StorageClass` ya creado con `kubectl edit`? ¿Por qué sí o por qué no conviene hacerlo?

---

## Ejercicio 3 — Provisioning dinámico vía PVC

1. Creá un `PersistentVolumeClaim` que use el `StorageClass` `fast-retain` del ejercicio anterior, en un archivo `pvc-app.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-app
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: fast-retain
     resources:
       requests:
         storage: 1Gi
   ```
2. Aplicalo y observá el estado inmediatamente después:
   ```bash
   kubectl apply -f pvc-app.yaml
   kubectl get pvc pvc-app
   ```
3. Verificá si ya existe un `PersistentVolume` asociado:
   ```bash
   kubectl get pv
   ```
4. Creá un Pod que use ese PVC, en `pod-app.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app
   spec:
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
         volumeMounts:
           - name: data
             mountPath: /data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: pvc-app
   ```
5. Aplicalo y volvé a chequear el estado del PVC y del PV recién creado:
   ```bash
   kubectl apply -f pod-app.yaml
   kubectl get pvc pvc-app
   kubectl get pv
   kubectl get pod pod-app
   ```

**Preguntas de comprensión — Ejercicio 3**
- P3.1: Justo después del paso 2, ¿en qué estado (`STATUS`) esperás encontrar el PVC, y por qué no está `Bound` todavía?
- P3.2: ¿En qué momento exacto se dispara el provisioning dinámico del `PersistentVolume` dado `volumeBindingMode: WaitForFirstConsumer`?

---

## Ejercicio 4 — Reclaim policy: Retain vs Delete

1. Anotá el nombre del `PersistentVolume` que quedó `Bound` a `pvc-app`:
   ```bash
   kubectl get pvc pvc-app -o jsonpath='{.spec.volumeName}'
   ```
2. Borrá el Pod y el PVC:
   ```bash
   kubectl delete pod pod-app
   kubectl delete pvc pvc-app
   ```
3. Revisá el estado del `PersistentVolume` que anotaste en el paso 1:
   ```bash
   kubectl get pv
   ```
4. Compará: creá un segundo `StorageClass` idéntico pero con `reclaimPolicy: Delete`, llamado `fast-delete`, repetí los pasos 1 a 3 de este ejercicio usando un nuevo PVC (`pvc-app2`) que apunte a `fast-delete`, y observá la diferencia en el resultado final.

**Preguntas de comprensión — Ejercicio 4**
- P4.1: Con `reclaimPolicy: Retain`, ¿en qué `STATUS` queda el `PersistentVolume` después de borrar el PVC, y qué pasos manuales hacen falta para poder reutilizar ese almacenamiento en un PVC nuevo?
- P4.2: ¿El campo `reclaimPolicy` de un `StorageClass` afecta a los `PersistentVolume` ya provisionados si lo cambiás después con `kubectl edit storageclass`?

---

## Ejercicio 5 — Volume expansion (allowVolumeExpansion)

1. Con el PVC `pvc-app` todavía existente (o recreándolo si lo borraste en el ejercicio anterior) y usando el `StorageClass` `fast-retain` (que tiene `allowVolumeExpansion: true`), editá el PVC para pedir más espacio:
   ```bash
   kubectl patch pvc pvc-app -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   ```
2. Observá el proceso de expansión:
   ```bash
   kubectl get pvc pvc-app -o jsonpath='{.status.capacity.storage}{"\n"}'
   kubectl describe pvc pvc-app
   ```
3. Intentá el mismo `patch` pero contra un PVC que use un `StorageClass` con `allowVolumeExpansion: false` (o sin el campo, que por defecto es `false`), y observá qué mensaje de error o condición aparece.

**Preguntas de comprensión — Ejercicio 5**
- P5.1: ¿Es posible reducir (`shrink`) el tamaño de un PVC vía `allowVolumeExpansion`?
- P5.2: ¿Qué condición aparece en `kubectl describe pvc` cuando el volumen requiere una expansión del filesystem en el nodo (`FileSystemResizePending`), y cuándo se dispara ese paso adicional?

---

## Ejercicio 6 — Cambiar el StorageClass por defecto

1. Listá nuevamente los `StorageClass` y anotá cuál es el default actual:
   ```bash
   kubectl get storageclass
   ```
2. Sacá la anotación de default del `StorageClass` actual (reemplazá `<default-actual>`):
   ```bash
   kubectl patch storageclass <default-actual> -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
   ```
3. Marcá `fast-retain` como el nuevo default:
   ```bash
   kubectl patch storageclass fast-retain -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
   ```
4. Confirmá el cambio:
   ```bash
   kubectl get storageclass
   ```
5. Creá un PVC **sin** especificar `storageClassName` y verificá a cuál `StorageClass` quedó asociado:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-default-test
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   EOF
   kubectl get pvc pvc-default-test -o jsonpath='{.spec.storageClassName}{"\n"}'
   ```

**Preguntas de comprensión — Ejercicio 6**
- P6.1: Si un PVC no especifica `storageClassName` y no existe ningún `StorageClass` marcado como default, ¿qué pasa con ese PVC?
- P6.2: ¿Qué diferencia hay entre dejar `storageClassName` sin especificar y ponerlo explícitamente como cadena vacía (`storageClassName: ""`)?

---

<details>
<summary><strong>Respuestas</strong></summary>

**P1.1:** El campo `provisioner`. Indica qué plugin se encarga de crear el volumen físico dinámicamente: puede ser un provisioner in-tree (legado, con prefijo `kubernetes.io/...`) o, lo más común hoy, un CSI driver externo identificado por su nombre de driver (por ejemplo `ebs.csi.aws.com`, `rancher.io/local-path`).

**P1.2:** La anotación `storageclass.kubernetes.io/is-default-class: "true"`. Si dos `StorageClass` la tienen en `"true"` simultáneamente, Kubernetes no falla pero el comportamiento queda indefinido/ambiguo: al crear un PVC sin `storageClassName`, el admission controller `DefaultStorageClass` termina eligiendo el que fue creado más recientemente (por timestamp), lo cual no es confiable — la buena práctica es tener un único default a la vez.

**P2.1:** Con `Immediate` (el default), el `PersistentVolume` se provisiona apenas se crea el PVC, sin considerar en qué nodo va a correr el Pod que lo va a usar — esto puede generar problemas si el volumen queda ligado a una zona/nodo distinto del que finalmente scheduló el Pod. Con `WaitForFirstConsumer`, el binding y el provisioning dinámico se posponen hasta que exista un Pod que reclame ese PVC y el scheduler haya decidido en qué nodo va a correr, garantizando que el volumen se cree en la topología correcta (zona, nodo local, etc.).

**P2.2:** El campo `provisioner` (como la mayoría de los campos de un `StorageClass`) es inmutable una vez creado el objeto — `kubectl edit` te va a dejar editar el YAML pero el API server rechaza el cambio en ese campo. Si necesitás otro provisioner, hay que crear un `StorageClass` nuevo con otro nombre.

**P3.1:** El PVC queda en `STATUS Pending`. No pasa a `Bound` inmediatamente porque `fast-retain` tiene `volumeBindingMode: WaitForFirstConsumer`, así que el binding (y el provisioning dinámico del PV) se retrasa hasta que exista un Pod que use ese PVC y el scheduler elija un nodo.

**P3.2:** Se dispara cuando el scheduler asigna (`bind`) el Pod que consume el PVC a un nodo específico. En ese momento el volume controller dispara el provisioning dinámico del PV en la topología correspondiente a ese nodo, y recién ahí el PVC pasa a `Bound`.

**P4.1:** Queda en `STATUS Released` (no `Available`), porque el PV conserva los datos y ya no puede ser reclamado automáticamente por otro PVC mientras tenga la referencia (`claimRef`) al PVC anterior. Para reutilizarlo hay que: (1) editar el PV y eliminar el bloque `claimRef` manualmente, y (2) opcionalmente limpiar los datos remanentes en el volumen físico antes de que un nuevo PVC lo reclame — recién ahí vuelve a `Available` y puede ser reclamado (típicamente creando el nuevo PVC con `spec.volumeName` apuntando a ese PV, o dejando que el binding lo encuentre si coinciden tamaño/accessModes).

**P4.2:** No. `reclaimPolicy` en el `StorageClass` solo se usa como valor por defecto al momento en que se provisiona un nuevo `PersistentVolume`; ese valor se copia al campo `persistentVolumeReclaimPolicy` del PV en el momento de su creación. Cambiar el `StorageClass` después no altera los PV ya existentes — para eso hay que editar `reclaimPolicy` directamente en cada PV con `kubectl patch pv <nombre> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`.

**P5.1:** No. `allowVolumeExpansion` solo permite crecer el tamaño solicitado en `spec.resources.requests.storage`; un intento de poner un valor menor al actual es rechazado por el API server con un error de validación.

**P5.2:** Aparece la condición `FileSystemResizePending` en `status.conditions` del PVC cuando el volumen ya fue expandido a nivel del backend de almacenamiento pero todavía falta que el filesystem dentro del volumen se expanda para aprovechar el nuevo tamaño. Ese paso final lo ejecuta el kubelet del nodo donde está montado el volumen, típicamente en el próximo montaje/remontaje del Pod (para muchos CSI drivers esto ocurre automáticamente sin necesidad de reiniciar el Pod, dependiendo del driver).

**P6.1:** El PVC queda en `STATUS Pending` indefinidamente (a menos que algún controlador externo lo reclame manualmente contra un PV preexistente). Sin `storageClassName` explícito y sin default configurado, no hay ningún provisioner dinámico asociado, así que el PVC solo puede satisfacerse mediante binding manual a un `PersistentVolume` estático ya existente.

**P6.2:** Dejar `storageClassName` sin especificar (campo ausente) hace que el admission controller `DefaultStorageClass` complete automáticamente el campo con el nombre del `StorageClass` marcado como default, si existe uno. En cambio, poner explícitamente `storageClassName: ""` desactiva ese comportamiento: el PVC queda asociado a "sin StorageClass" a propósito, y solo puede bindearse a un `PersistentVolume` estático que tampoco tenga `storageClassName` (o que tenga `storageClassName: ""`), nunca a provisioning dinámico.

</details>