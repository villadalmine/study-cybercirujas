# 2.2 Debugging

## Ejercicio 1: Pod atascado en `ImagePullBackOff`

1. Creá un archivo `bad-pod.yaml` con el siguiente contenido:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: broken-image
   spec:
     containers:
       - name: app
         image: nginx:this-tag-no-existe
   ```
2. Aplicá el manifest: `kubectl apply -f bad-pod.yaml`
3. Listá los Pods: `kubectl get pods`. Vas a ver un `STATUS` que va cambiando entre `ErrImagePull` y `ImagePullBackOff`.
4. Ejecutá `kubectl describe pod broken-image` y prestá atención a la sección `Events` al final del output.
5. Corregí el manifest cambiando el `image` a `nginx:latest`, aplicá de nuevo con `kubectl apply -f bad-pod.yaml` y confirmá que el Pod pasa a `Running`.

**Preguntas de comprensión:**
- ¿Por qué `kubectl get pods` no alcanza para saber la causa raíz del problema, y qué comando sí la muestra?
- ¿Qué diferencia hay entre `ErrImagePull` y `ImagePullBackOff` en términos de qué está haciendo el kubelet en ese momento?

## Ejercicio 2: `CrashLoopBackOff` y revisión de logs

1. Creá `crash-pod.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: crash-demo
   spec:
     containers:
       - name: app
         image: busybox
         command: ["sh", "-c", "echo 'fallo simulado' && exit 1"]
   ```
2. Aplicá el manifest y observá el `STATUS` con `kubectl get pods -w` (el flag `-w` hace watch de los cambios).
3. Una vez que aparezca `CrashLoopBackOff`, revisá los logs del último intento: `kubectl logs crash-demo`.
4. Si el contenedor ya se reinició más de una vez, compará con los logs del intento anterior: `kubectl logs crash-demo --previous`.
5. Revisá el conteo de reinicios y el backoff exponencial en `kubectl describe pod crash-demo` (campo `Restart Count` y los eventos `BackOff`).

**Preguntas de comprensión:**
- ¿Qué significa el estado `CrashLoopBackOff` y por qué el intervalo entre reintentos crece con el tiempo?
- ¿Cuándo es indispensable usar `--previous` en `kubectl logs` en vez del comando simple?

## Ejercicio 3: Inspeccionar un contenedor en ejecución con `kubectl exec`

1. Desplegá un Pod sano: `kubectl run debug-target --image=nginx`
2. Esperá a que esté `Running`: `kubectl get pod debug-target`
3. Abrí una shell interactiva dentro del contenedor: `kubectl exec -it debug-target -- sh`
4. Dentro de la shell, verificá conectividad y variables de entorno relevantes (por ejemplo `env` y `cat /etc/resolv.conf`), y salí con `exit`.
5. Ejecutá un comando puntual sin entrar a una shell interactiva: `kubectl exec debug-target -- ls /usr/share/nginx/html`

**Preguntas de comprensión:**
- ¿Qué limitación tiene `kubectl exec` cuando la imagen del contenedor no incluye una shell ni herramientas de diagnóstico?
- ¿Qué alternativa ofrece Kubernetes para depurar un contenedor "distroless" sin shell, sin modificar la imagen original?

## Ejercicio 4: Fallas de `readiness` y `liveness probes`

1. Creá `probe-pod.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe-demo
   spec:
     containers:
       - name: app
         image: nginx
         readinessProbe:
           httpGet:
             path: /no-existe
             port: 80
           periodSeconds: 5
   ```
2. Aplicá el manifest y ejecutá `kubectl get pod probe-demo`. Notá que el Pod queda `Running` pero con `READY 0/1`.
3. Ejecutá `kubectl describe pod probe-demo` y buscá los eventos `Unhealthy` generados por la probe.
4. Corregí el `path` a `/` y volvé a aplicar el manifest.
5. Confirmá que `READY` pasa a `1/1` con `kubectl get pod probe-demo -w`.

**Preguntas de comprensión:**
- ¿Por qué un Pod puede figurar como `Running` y al mismo tiempo no recibir tráfico de un Service?
- ¿Qué diferencia práctica hay entre una `readinessProbe` fallida y una `livenessProbe` fallida en cuanto a la acción que toma Kubernetes?

## Ejercicio 5: `OOMKilled` y límites de recursos

1. Creá `oom-pod.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: oom-demo
   spec:
     containers:
       - name: app
         image: polinux/stress
         resources:
           limits:
             memory: "20Mi"
         command: ["stress"]
         args: ["--vm", "1", "--vm-bytes", "50M", "--vm-hang", "1"]
   ```
2. Aplicá el manifest y esperá unos segundos.
3. Ejecutá `kubectl get pod oom-demo` y observá el `STATUS` (`OOMKilled` dentro del último estado del contenedor).
4. Confirmá la causa con `kubectl describe pod oom-demo`, revisando `Last State: Terminated, Reason: OOMKilled`.
5. Aumentá el `limits.memory` a `"100Mi"`, reaplicá y verificá que el Pod se mantiene `Running`.

**Preguntas de comprensión:**
- ¿Qué componente mata al contenedor cuando excede su `memory limit`, y por qué esto no depende de la `CPU limit`?
- ¿Cómo se distingue en `kubectl describe pod` un `OOMKilled` de un `CrashLoopBackOff` causado por un error de aplicación?

## Ejercicio 6: Eventos del clúster y uso de recursos con `kubectl top`

1. Listá todos los eventos recientes del namespace actual, ordenados por timestamp: `kubectl get events --sort-by=.lastTimestamp`
2. Filtrá eventos de tipo `Warning` únicamente: `kubectl get events --field-selector type=Warning`
3. Si tenés `metrics-server` instalado, revisá el consumo de recursos de los Pods: `kubectl top pods`
4. Revisá también el consumo por Node: `kubectl top nodes`
5. Cruzá esta información con `kubectl describe node <nombre-del-node>` para ver si el Node está bajo presión de recursos (`Conditions` como `MemoryPressure` o `DiskPressure`).

**Preguntas de comprensión:**
- ¿Por qué `kubectl get events` es útil para debugging incluso cuando el Pod problemático ya fue eliminado o recreado?
- ¿Qué requisito de infraestructura necesita el clúster para que `kubectl top` funcione?

---

**Fuente de referencia:** [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- `kubectl get pods` solo muestra el estado resumido (`STATUS`), no la razón detrás de él. `kubectl describe pod` expone la sección `Events`, donde el kubelet registra el motivo exacto del fallo (por ejemplo, "manifest unknown" al intentar pull de una tag inexistente).
- `ErrImagePull` es el primer intento fallido de traer la imagen; `ImagePullBackOff` es el estado posterior, donde Kubernetes espera un intervalo creciente (backoff) antes de reintentar, para no saturar al registry con pulls fallidos consecutivos.

**Ejercicio 2**
- `CrashLoopBackOff` indica que el contenedor arrancó, terminó (en este caso con `exit 1`) y Kubernetes lo reinicia según la `restartPolicy`, pero espera cada vez más tiempo entre reintentos (backoff exponencial) para evitar reinicios infinitos inmediatos que consuman recursos del Node.
- `--previous` es necesario cuando el contenedor ya se reinició y los logs del proceso actual no contienen la información del fallo original, porque cada reinicio arranca un proceso nuevo cuyos logs se muestran por separado del anterior.

**Ejercicio 3**
- Si la imagen no tiene una shell (`sh`, `bash`) ni utilidades como `ls` o `cat`, `kubectl exec -it ... -- sh` falla porque no hay binario que ejecutar dentro del contenedor.
- Kubernetes ofrece los `ephemeral containers` (`kubectl debug`), que inyectan temporalmente un contenedor con herramientas de diagnóstico dentro del Pod (o comparten su namespace de proceso), sin necesidad de modificar o reconstruir la imagen original.

**Ejercicio 4**
- Un Pod puede estar `Running` (el proceso del contenedor sigue vivo) pero no `Ready` si su `readinessProbe` falla; en ese caso el Endpoint controller lo excluye de la lista de endpoints del Service, por lo que no recibe tráfico aunque el contenedor esté activo.
- Una `readinessProbe` fallida solo saca al Pod de los Endpoints del Service (no se reinicia el contenedor); una `livenessProbe` fallida hace que el kubelet mate y reinicie el contenedor, porque se interpreta como que el proceso quedó en un estado no recuperable.

**Ejercicio 5**
- El `OOM killer` del kernel de Linux es quien termina al contenedor cuando supera su `memory limit`, porque la memoria no es un recurso "comprimible": al agotarse, el proceso debe morir. La CPU, en cambio, es comprimible (se puede limitar mediante *throttling* sin matar el proceso), por eso exceder un `CPU limit` no termina al contenedor.
- En `kubectl describe pod`, un `OOMKilled` se identifica en `Last State: Terminated` con `Reason: OOMKilled` y `Exit Code: 137`; un `CrashLoopBackOff` por error de aplicación muestra `Reason: Error` con un exit code distinto (normalmente definido por la propia aplicación) y sin mención a memoria.

**Ejercicio 6**
- Los eventos del clúster tienen un `Reason` y `Message` ligados al objeto que los generó, y persisten un tiempo (por defecto una hora) en `etcd` incluso si el Pod que los originó ya no existe, permitiendo reconstruir qué pasó después del hecho.
- `kubectl top` requiere que el clúster tenga desplegado `metrics-server` (u otro proveedor de la Metrics API), ya que `kubectl` no calcula el uso de CPU/memoria por sí mismo sino que consulta esa API.

</details>