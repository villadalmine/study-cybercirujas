# 1.3 Understand multi-container Pod design patterns (sidecar, init y otros)

## Por qué un Pod puede tener varios containers

Un Pod es la unidad mínima de scheduling en Kubernetes, y todos los containers dentro de un mismo Pod comparten:

- **Network namespace**: mismo `localhost`, mismos puertos (no puede haber dos containers escuchando el mismo puerto dentro del Pod).
- **Volúmenes**: si se define un `volume` a nivel Pod, todos los containers que lo montan comparten el mismo storage.
- **Ciclo de vida**: se programan juntos en el mismo Node, y comparten el `Pod IP`.

Esto habilita patrones de diseño donde un container "principal" delega responsabilidades secundarias (logging, proxy, sincronización de datos) a containers auxiliares, sin acoplar ese código al container principal. El CKAD curriculum (v1.35) agrupa estos patrones bajo el dominio *Application Design and Build*, con foco en reconocer **cuándo** usar cada patrón y **cómo** implementarlo con manifiestos YAML.

Los tres patrones "clásicos" (documentados originalmente por Brendan Burns en el paper de Google sobre multi-container patterns) son:

1. **Sidecar**: container auxiliar que extiende o mejora la funcionalidad del container principal.
2. **Ambassador**: proxy que simplifica la conexión del container principal hacia el mundo exterior.
3. **Adapter**: normaliza la salida/entrada del container principal hacia un formato estándar.

A esto se suma el mecanismo nativo de Kubernetes para secuenciar arranque: **init containers**.

---

## Init containers

Un `initContainer` corre **antes** que los containers de la sección `containers`, en orden secuencial, y debe **terminar exitosamente** (`exit 0`) para que el siguiente arranque. Si un init container falla, Kubernetes lo reintenta según la `restartPolicy` del Pod.

Usos típicos:

- Esperar a que un servicio dependiente esté disponible (DB, API).
- Clonar un repo Git o descargar configuración antes de que arranque la app.
- Setear permisos o preparar datos en un volumen compartido (`chown`, generar archivos).
- Registrar el Pod en un servicio externo antes de que reciba tráfico.

Diferencias clave respecto a un container normal:

| Característica | Init container | Container normal |
|---|---|---|
| Orden de ejecución | Secuencial, uno a la vez | Todos en paralelo |
| Debe terminar | Sí, antes de continuar | No (corre indefinidamente) |
| `readinessProbe` | No aplica | Sí |
| Reinicio en fallo | Reinicia el init container | Depende de `restartPolicy` |

### Ejemplo: init container que espera a un Service

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-app
  labels:
    app: web-app
spec:
  initContainers:
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nslookup db-service; do echo esperando db-service; sleep 2; done']
  containers:
  - name: web-app
    image: nginx:1.27
    ports:
    - containerPort: 80
```

Al describir el Pod mientras el init container corre:

```bash
$ kubectl get pod web-app
NAME      READY   STATUS     RESTARTS   AGE
web-app   0/1     Init:0/1   0          5s
```

Una vez que `db-service` resuelve, el init container termina y el container principal arranca:

```bash
$ kubectl get pod web-app
NAME      READY   STATUS    RESTARTS   AGE
web-app   1/1     Running   0          12s

$ kubectl logs web-app -c wait-for-db
esperando db-service
esperando db-service
Server:    10.96.0.10
Address:   10.96.0.10:53
Name:      db-service.default.svc.cluster.local
Address:   10.96.20.55
```

Notar el uso de `-c` para especificar el container cuando el Pod tiene más de uno (obligatorio también para `kubectl exec` y `kubectl logs` en Pods multi-container).

---

## Patrón Sidecar

El container sidecar corre **en paralelo** con el container principal durante toda la vida del Pod, y típicamente comparte un volumen o el network namespace para complementarlo sin modificar su código.

Caso de uso clásico: un container de aplicación que escribe logs a un archivo local, y un sidecar que los envía (tail + forward) a un sistema centralizado.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-sidecar
spec:
  volumes:
  - name: shared-logs
    emptyDir: {}
  containers:
  - name: app
    image: myregistry/app:1.4
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
  - name: log-shipper
    image: busybox:1.36
    command: ['sh', '-c', 'tail -F /var/log/app/app.log']
    volumeMounts:
    - name: shared-logs
      mountPath: /var/log/app
```

Ambos containers ven el mismo directorio `/var/log/app` gracias al `emptyDir` compartido. El sidecar no necesita saber nada de la lógica de negocio de `app`; solo lee el archivo.

Desde Kubernetes v1.28+, existe además el concepto de **native sidecar containers**: un `initContainer` con `restartPolicy: Always`, que arranca antes que los containers principales pero se mantiene corriendo durante todo el ciclo de vida del Pod (y se apaga después que los containers principales al terminar el Pod). Esto resuelve el problema histórico de que un sidecar tradicional (definido en `containers`) no garantizaba estar listo antes que la app principal.

```yaml
spec:
  initContainers:
  - name: sidecar-proxy
    image: envoyproxy/envoy:v1.29
    restartPolicy: Always   # lo convierte en "native sidecar"
    ports:
    - containerPort: 9901
  containers:
  - name: app
    image: myregistry/app:1.4
```

---

## Patrón Ambassador

El container ambassador actúa como **proxy local** entre el container principal y el mundo exterior, simplificando su lógica de conexión (por ejemplo, la app solo conoce `localhost:6379` y el ambassador decide a qué instancia real de Redis conectarse, aplicando retries, TLS o sharding).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-ambassador
spec:
  containers:
  - name: app
    image: myregistry/app:2.0
    env:
    - name: REDIS_HOST
      value: "localhost"   # la app siempre habla con localhost
    - name: REDIS_PORT
      value: "6379"
  - name: redis-ambassador
    image: myregistry/redis-proxy:1.0
    ports:
    - containerPort: 6379
```

La app nunca necesita saber la dirección real del clúster Redis; si cambia (failover, migración), solo se actualiza el ambassador.

---

## Patrón Adapter

El container adapter **transforma la salida** del container principal a un formato estándar consumido por sistemas externos (por ejemplo, monitoring). Es común cuando distintas apps del clúster generan métricas o logs en formatos heterogéneos, y se necesita normalizarlos antes de exponerlos.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-adapter
spec:
  volumes:
  - name: metrics
    emptyDir: {}
  containers:
  - name: legacy-app
    image: myregistry/legacy-app:3.1
    volumeMounts:
    - name: metrics
      mountPath: /var/metrics
  - name: metrics-adapter
    image: myregistry/prometheus-adapter:1.0
    volumeMounts:
    - name: metrics
      mountPath: /var/metrics
    ports:
    - containerPort: 9090   # expone /metrics en formato Prometheus
```

`legacy-app` escribe métricas en su formato propietario a `/var/metrics`; `metrics-adapter` las lee, las convierte a formato Prometheus y las expone en `:9090/metrics` para que un scraper las consuma sin que `legacy-app` cambie una línea de código.

---

## Verificación y troubleshooting en Pods multi-container

Comandos que aplican específicamente cuando hay más de un container por Pod:

```bash
# Ver estado de READY (n/m containers listos)
$ kubectl get pod app-with-sidecar
NAME               READY   STATUS    RESTARTS   AGE
app-with-sidecar   2/2     Running   0          40s

# Logs de un container específico
$ kubectl logs app-with-sidecar -c log-shipper

# Ejecutar comando en un container específico
$ kubectl exec -it app-with-sidecar -c app -- sh

# Describe muestra el detalle de cada container y sus eventos
$ kubectl describe pod app-with-sidecar
```

Si se omite `-c` en un Pod multi-container, `kubectl logs` y `kubectl exec` fallan pidiendo que se especifique el container:

```bash
$ kubectl logs app-with-sidecar
error: a container name must be specified for pod app-with-sidecar, choose one of: [app log-shipper]
```

---

## Resumen: cuándo usar cada patrón

| Patrón | Objetivo | Ejemplo típico |
|---|---|---|
| Init container | Preparar/bloquear antes del arranque | Esperar dependencia, migrar schema |
| Sidecar | Extender funcionalidad en paralelo | Log shipping, service mesh proxy |
| Ambassador | Simplificar conexión saliente | Proxy a DB/cache con lógica de red |
| Adapter | Normalizar salida hacia estándar | Convertir métricas/logs a formato común |

---

## Referencias

- Kubernetes Documentation — Init Containers: https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Kubernetes Documentation — Sidecar Containers: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Kubernetes Documentation — Pods (containers compartiendo recursos): https://kubernetes.io/docs/concepts/workloads/pods/
- CNCF CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf