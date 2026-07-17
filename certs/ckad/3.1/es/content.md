# 3.1 — Implement probes and health checks

## ¿Por qué existen las probes?

Kubernetes necesita saber dos cosas sobre cada contenedor: si está **vivo** (¿hay que reiniciarlo?) y si está **listo** (¿puede recibir tráfico?). Un proceso puede estar corriendo y aun así estar roto: un deadlock, una conexión a base de datos perdida, un warm-up de caché que tarda minutos. Las **probes** son chequeos periódicos que ejecuta el **kubelet** contra cada contenedor para tomar esas decisiones de forma automática.

Existen tres tipos de probe, y entender la diferencia entre ellas es uno de los puntos más evaluados del examen:

| Probe | Pregunta que responde | Acción si falla |
|---|---|---|
| `livenessProbe` | ¿El contenedor sigue funcionando? | El kubelet **reinicia** el contenedor (según `restartPolicy`) |
| `readinessProbe` | ¿Puede recibir tráfico ahora? | El Pod se **quita de los Endpoints** del Service (no se reinicia) |
| `startupProbe` | ¿Terminó de arrancar? | Reinicia el contenedor; mientras corre, **desactiva** liveness y readiness |

Punto clave: una `readinessProbe` que falla **nunca reinicia** el contenedor, solo deja de enviarle tráfico. Una `livenessProbe` que falla **sí lo reinicia**. Confundir esto lleva a configuraciones peligrosas (por ejemplo, usar liveness para chequear una dependencia externa: si la base de datos se cae, todos los Pods entran en un loop de reinicios sin arreglar nada).

## Mecanismos de chequeo

Cada probe (del tipo que sea) usa uno de estos cuatro mecanismos:

### 1. `httpGet`

El kubelet hace una request HTTP GET al contenedor. Cualquier código de respuesta **entre 200 y 399** cuenta como éxito.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
    - name: Custom-Header
      value: Awesome
```

El `port` puede ser un número o el **nombre de un puerto** declarado en `containerPort` (por ejemplo `port: http`), algo que aparece con frecuencia en YAMLs del examen.

### 2. `exec`

El kubelet ejecuta un comando dentro del contenedor. **Exit code 0 = éxito**, cualquier otro valor = fallo.

```yaml
livenessProbe:
  exec:
    command:
    - cat
    - /tmp/healthy
```

### 3. `tcpSocket`

El kubelet intenta abrir una conexión TCP al puerto indicado. Si la conexión se establece, la probe pasa. Útil para servicios que no hablan HTTP (bases de datos, brokers).

```yaml
readinessProbe:
  tcpSocket:
    port: 3306
```

### 4. `grpc`

Para aplicaciones que implementan el [gRPC Health Checking Protocol](https://grpc.io/docs/guides/health-checking/). Estable desde Kubernetes 1.27.

```yaml
livenessProbe:
  grpc:
    port: 2379
```

## Parámetros de configuración

Todos los tipos de probe comparten estos campos, que controlan el timing y la tolerancia a fallos:

| Campo | Default | Significado |
|---|---|---|
| `initialDelaySeconds` | 0 | Segundos de espera tras arrancar el contenedor antes de la primera probe |
| `periodSeconds` | 10 | Cada cuántos segundos se ejecuta la probe |
| `timeoutSeconds` | 1 | Segundos antes de considerar que la probe expiró |
| `failureThreshold` | 3 | Fallos consecutivos necesarios para declarar el fallo |
| `successThreshold` | 1 | Éxitos consecutivos para volver a considerar la probe exitosa (debe ser 1 en liveness y startup) |

Ejemplo completo con timing explícito:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - name: http
      containerPort: 80
    readinessProbe:
      httpGet:
        path: /
        port: http
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 2
    livenessProbe:
      httpGet:
        path: /
        port: http
      initialDelaySeconds: 15
      periodSeconds: 10
      timeoutSeconds: 2
```

Con esta configuración, el contenedor será marcado como no-listo tras `2 × 5 = 10` segundos de fallos, y será reiniciado tras `3 × 10 = 30` segundos de fallos de liveness (los defaults de `failureThreshold: 3` aplican donde no se sobrescriben).

## `startupProbe`: aplicaciones que arrancan lento

El problema clásico: una aplicación legacy tarda hasta 5 minutos en arrancar. Si la `livenessProbe` empieza a chequear antes de que termine el arranque, la mata y el Pod entra en un loop infinito de reinicios. La solución ingenua (`initialDelaySeconds: 300`) penaliza también los arranques rápidos.

La `startupProbe` resuelve esto: mientras no pase, **liveness y readiness quedan deshabilitadas**. Una vez que pasa por primera vez, no vuelve a ejecutarse y las otras probes toman el control.

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10
```

Aquí la aplicación tiene hasta `30 × 10 = 300` segundos para arrancar. Si en ese tiempo no responde, se reinicia. Una vez arrancada, la liveness la vigila con un ciclo agresivo de 10 segundos.

## Ejemplo guiado: ver una liveness probe fallar

Este manifiesto (adaptado del ejemplo de la documentación oficial) crea un archivo, lo borra a los 30 segundos, y deja que la probe falle:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: liveness-exec
spec:
  containers:
  - name: liveness
    image: registry.k8s.io/busybox
    args:
    - /bin/sh
    - -c
    - touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 5
      periodSeconds: 5
```

Aplicarlo y observar los eventos:

```bash
kubectl apply -f liveness-exec.yaml
kubectl describe pod liveness-exec
```

Pasados ~35 segundos, en la sección `Events` aparece algo como:

```
Events:
  Type     Reason     Age    From     Message
  ----     ------     ----   ----     -------
  Normal   Started    50s    kubelet  Started container liveness
  Warning  Unhealthy  15s    kubelet  Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
  Normal   Killing    15s    kubelet  Container liveness failed liveness probe, will be restarted
```

Y el contador de reinicios crece:

```bash
kubectl get pod liveness-exec
NAME            READY   STATUS    RESTARTS      AGE
liveness-exec   1/1     Running   1 (10s ago)   80s
```

## Readiness y Services: el efecto práctico

Cuando la `readinessProbe` de un Pod falla, su IP se retira de los `EndpointSlices` del Service que lo selecciona. Se puede verificar así:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                AGE
web-abc12   IPv4          80      10.244.1.5,10.244.2.8    5m
```

Si un Pod deja de estar listo, desaparece de `ENDPOINTS` y en `kubectl get pods` se ve como `READY 0/1` con `STATUS Running` — corriendo pero sin recibir tráfico. Este es el diagnóstico típico del examen: *"el Service no responde pero los Pods están Running"* → revisar readiness.

Además, en un `Deployment` con `RollingUpdate`, los Pods nuevos no cuentan como disponibles hasta que su readiness pase, así que una readiness mal configurada puede **bloquear un rollout** (visible con `kubectl rollout status deployment/web`).

## Cómo trabajar rápido en el examen

No hay flag de `kubectl` que genere probes directamente; el flujo eficiente es generar el YAML base y editarlo:

```bash
kubectl run web --image=nginx --dry-run=client -o yaml > pod.yaml
# editar pod.yaml y agregar el bloque livenessProbe/readinessProbe
kubectl apply -f pod.yaml
```

Para no escribir el bloque de memoria, la documentación embebida ayuda:

```bash
kubectl explain pod.spec.containers.livenessProbe
kubectl explain pod.spec.containers.readinessProbe.httpGet
```

Checklist de errores frecuentes:

- **Puerto equivocado**: la probe apunta al puerto del Service en lugar del `containerPort`. La probe se ejecuta **contra el contenedor**, no contra el Service.
- **Path inexistente**: `/health` vs `/healthz` — verificar con `kubectl describe pod` el mensaje exacto del fallo (incluye el código HTTP recibido).
- **Liveness que chequea dependencias externas**: provoca reinicios en cascada. Liveness debe chequear solo el estado interno del proceso.
- **`successThreshold` distinto de 1** en liveness o startup: el API server lo rechaza.
- **Timing demasiado agresivo**: `timeoutSeconds: 1` (el default) es corto para aplicaciones bajo carga; un pico de latencia puede disparar reinicios.

## Resumen

- **Liveness** → reinicia; **readiness** → saca del Service; **startup** → protege el arranque desactivando las otras dos.
- Cuatro mecanismos: `httpGet` (200–399), `exec` (exit 0), `tcpSocket` (conexión abierta), `grpc`.
- El timing efectivo para declarar un fallo es `periodSeconds × failureThreshold` (más `initialDelaySeconds` al inicio).
- Diagnóstico: `kubectl describe pod` (sección Events), `kubectl get pods` (columnas READY/RESTARTS), `kubectl get endpointslices`.

## Referencias

- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Pod Lifecycle (container probes) — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
- API reference: Probe (v1 core) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#Probe
- gRPC Health Checking Protocol — https://grpc.io/docs/guides/health-checking/
- CKAD Curriculum v1.35 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf