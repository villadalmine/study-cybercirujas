# 3.6 Troubleshooting

En KCNA el troubleshooting se evalúa a nivel conceptual: qué comando usar, qué información buscar y cómo interpretar el estado de los objetos de Kubernetes cuando algo falla. Estos ejercicios asumen un clúster local (`kind`, `minikube` o similar) con `kubectl` configurado y apuntando al contexto correcto.

---

## Ejercicio 1: Pod en estado `Pending`

1. Creá un manifiesto `pending-pod.yaml` que pida más CPU de la que tiene cualquier nodo del clúster:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-imposible
   spec:
     containers:
       - name: app
         image: nginx
         resources:
           requests:
             cpu: "100"
   ```

2. Aplicá el manifiesto:

   ```bash
   kubectl apply -f pending-pod.yaml
   ```

3. Revisá el estado del Pod:

   ```bash
   kubectl get pod pod-imposible
   ```

4. Investigá la causa con `describe`, prestando atención a la sección `Events` al final de la salida:

   ```bash
   kubectl describe pod pod-imposible
   ```

5. Borrá el recurso una vez terminado el ejercicio:

   ```bash
   kubectl delete -f pending-pod.yaml
   ```

**Preguntas**
- ¿Qué fase (`Phase`) muestra `kubectl get pod` mientras el scheduler no puede ubicar el Pod?
- ¿Qué `Reason` aparece en la sección `Events` de `describe` y qué componente de Kubernetes lo genera?
- Nombrá otras dos causas (además de recursos insuficientes) que pueden dejar un Pod en `Pending`.

---

## Ejercicio 2: `CrashLoopBackOff`

1. Creá `crash-pod.yaml` con un contenedor que termina inmediatamente con error:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-crash
   spec:
     containers:
       - name: app
         image: busybox
         command: ["sh", "-c", "echo 'fallo simulado'; exit 1"]
   ```

2. Aplicá el manifiesto y observá cómo cambia el estado a lo largo de ~1 minuto:

   ```bash
   kubectl apply -f crash-pod.yaml
   kubectl get pod pod-crash --watch
   ```

3. Cortá el `watch` con `Ctrl+C` y revisá los logs del contenedor:

   ```bash
   kubectl logs pod-crash
   ```

4. Consultá el código de salida y el estado anterior del contenedor:

   ```bash
   kubectl describe pod pod-crash
   ```

5. Limpiá el recurso:

   ```bash
   kubectl delete -f crash-pod.yaml
   ```

**Preguntas**
- ¿Por qué Kubernetes sigue reiniciando el contenedor en lugar de dejarlo detenido, y qué campo del `PodSpec` controla ese comportamiento?
- En la salida de `describe`, ¿en qué campos se ve el `Exit Code` y el `Reason` de la última terminación?
- Si el `Exit Code` fuera `137` en lugar de `1`, ¿qué señal del sistema operativo sugiere y qué causa típica está asociada (pista: memoria)?

---

## Ejercicio 3: `ImagePullBackOff`

1. Creá `bad-image-pod.yaml` con un tag de imagen inexistente:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-mala-imagen
   spec:
     containers:
       - name: app
         image: nginx:tag-que-no-existe-123
   ```

2. Aplicá y observá el estado:

   ```bash
   kubectl apply -f bad-image-pod.yaml
   kubectl get pod pod-mala-imagen
   ```

3. Repetí el comando un par de veces con unos segundos de diferencia y notá cómo cambia el `STATUS`:

   ```bash
   kubectl get pod pod-mala-imagen
   ```

4. Confirmá la causa exacta en `Events`:

   ```bash
   kubectl describe pod pod-mala-imagen
   ```

5. Limpiá el recurso:

   ```bash
   kubectl delete -f bad-image-pod.yaml
   ```

**Preguntas**
- ¿Cuál es la diferencia entre los estados `ErrImagePull` y `ImagePullBackOff` en cuanto a orden de aparición y significado?
- Si la imagen fuera privada y faltara autenticación, ¿qué recurso de Kubernetes se usa para proveer las credenciales del registry y en qué campo del Pod/ServiceAccount se referencia?

---

## Ejercicio 4: Service sin `Endpoints`

1. Creá un Deployment y un Service con un selector mal escrito (`app: web` en el Deployment pero `app: webapp` en el Service):

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx
             ports:
               - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web-svc
   spec:
     selector:
       app: webapp
     ports:
       - port: 80
         targetPort: 80
   ```

2. Aplicá ambos objetos:

   ```bash
   kubectl apply -f web-service.yaml
   ```

3. Confirmá que los Pods están `Running`:

   ```bash
   kubectl get pods -l app=web
   ```

4. Revisá si el Service tiene destinos activos:

   ```bash
   kubectl get endpoints web-svc
   ```

5. Corregí el selector del Service (cambiá `app: webapp` por `app: web`), reaplicá y confirmá que aparecen `Endpoints`:

   ```bash
   kubectl apply -f web-service.yaml
   kubectl get endpoints web-svc
   ```

6. Limpiá los recursos:

   ```bash
   kubectl delete -f web-service.yaml
   ```

**Preguntas**
- ¿Qué objeto intermedio conecta un Service con los Pods reales, y qué comando lo muestra?
- Además de un selector incorrecto, ¿qué otra condición de los Pods hace que queden excluidos de los `Endpoints` de un Service aunque el selector coincida?

---

## Ejercicio 5: Nodo `NotReady`

1. Listá el estado de los nodos del clúster:

   ```bash
   kubectl get nodes
   ```

2. Elegí un nodo y examiná sus `Conditions`:

   ```bash
   kubectl describe node <nombre-del-nodo>
   ```

3. Ubicá en la salida las condiciones `Ready`, `MemoryPressure`, `DiskPressure` y `PIDPressure`, y su valor (`True`/`False`/`Unknown`).

4. Revisá qué Pods está corriendo ese nodo y si alguno está afectado:

   ```bash
   kubectl get pods --all-namespaces --field-selector spec.nodeName=<nombre-del-nodo>
   ```

**Preguntas**
- ¿Qué componente corre en cada nodo y es responsable de reportar su estado al control plane?
- Si `Ready` pasa a `Unknown` (no `False`), ¿qué suele indicar eso sobre la comunicación entre el nodo y el control plane?
- ¿Qué le pasa a los Pods de un nodo que queda `NotReady` por más del tiempo de tolerancia configurado (`node.kubernetes.io/not-ready`)?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- El Pod queda en `Phase: Pending` porque el scheduler no logra asignarlo a ningún nodo.
- El evento muestra `Reason: FailedScheduling`, generado por el `kube-scheduler`, con un mensaje como `Insufficient cpu`.
- Otras causas comunes: un `nodeSelector`/`affinity` que no coincide con ningún nodo, o un `taint` en los nodos sin la `toleration` correspondiente en el Pod; también un `PersistentVolumeClaim` que no puede quedar `Bound`.

**Ejercicio 2**
- El campo `restartPolicy` del `PodSpec` (por defecto `Always` en Pods creados directamente o vía Deployment) hace que el kubelet reinicie el contenedor cada vez que termina; Kubernetes aplica un backoff exponencial entre reintentos, de ahí el nombre `CrashLoopBackOff`.
- En `describe pod`, dentro de `Containers > app > Last State: Terminated` aparecen `Reason` y `Exit Code`.
- El código `137` = 128 + 9 (SIGKILL). La causa típica es que el contenedor fue matado por el kernel por exceder su límite de memoria (`OOMKilled`), visible también como `Reason: OOMKilled` en `describe`.

**Ejercicio 3**
- `ErrImagePull` es el primer intento fallido de descarga (imagen inexistente, tag inválido, registry inalcanzable); si el fallo persiste, Kubernetes pasa a `ImagePullBackOff`, que indica que está esperando con backoff exponencial antes de reintentar.
- Se usa un `Secret` de tipo `kubernetes.io/dockerconfigjson`, referenciado en el campo `imagePullSecrets` del `PodSpec` (o configurado por defecto en el `ServiceAccount` del namespace).

**Ejercicio 4**
- El objeto `Endpoints` (o `EndpointSlice` en versiones más recientes) conecta el Service con las IPs de los Pods que coinciden con su selector; se ve con `kubectl get endpoints <service>`.
- Un Pod con un `readinessProbe` que falla se marca como `Not Ready` y Kubernetes lo excluye de los `Endpoints` del Service aunque sus labels coincidan con el selector.

**Ejercicio 5**
- El `kubelet` corre en cada nodo y es el responsable de reportar periódicamente su estado (heartbeat) al control plane (`kube-apiserver`/`kube-controller-manager`).
- `Ready: Unknown` indica que el control plane dejó de recibir heartbeats del nodo dentro del tiempo esperado (problema de red o kubelet caído), a diferencia de `False`, que indica que el kubelet respondió mal explícitamente.
- Pasado el `tolerationSeconds` del taint automático `node.kubernetes.io/not-ready` (5 minutos por defecto), el control plane expulsa (evict) los Pods de ese nodo y, si pertenecen a un controlador como un Deployment, se reprograman en otro nodo disponible.

</details>

---

**Fuente:** CNCF KCNA Curriculum — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf