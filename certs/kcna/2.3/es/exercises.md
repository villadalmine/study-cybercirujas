# Ejercicios guiados: Observability

Estos ejercicios requieren acceso a un clúster de Kubernetes vía `kubectl` (por ejemplo, uno creado con `minikube start` o `kind create cluster`) y, para los ejercicios 4 y 5, `helm` instalado.

## Ejercicio 1: Liveness y readiness probes

Los health checks son el mecanismo más básico de observability a nivel de Pod: le dicen al kubelet si un container está vivo y si está listo para recibir tráfico.

**Pasos:**

1. Creá un archivo `liveness-demo.yaml` con el siguiente contenido:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: liveness-demo
spec:
  containers:
  - name: demo
    image: busybox
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

2. Aplicá el manifiesto:

```bash
kubectl apply -f liveness-demo.yaml
```

3. Observá el estado del Pod durante el primer minuto:

```bash
kubectl get pod liveness-demo -w
```

4. Después de que el container borre `/tmp/healthy` (a los 30 segundos), inspeccioná los eventos:

```bash
kubectl describe pod liveness-demo
```

Vas a ver un evento `Unhealthy` seguido de un `Killing` y un reinicio del container.

5. Confirmá el conteo de reinicios:

```bash
kubectl get pod liveness-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'
```

**Preguntas de comprensión:**

- ¿Qué acción toma el kubelet cuando una liveness probe falla repetidamente, y en qué se diferencia de la acción que toma cuando falla una readiness probe?
- ¿Por qué `initialDelaySeconds` es importante en aplicaciones con tiempo de arranque largo?

---

## Ejercicio 2: Logs en Pods multi-container

Un patrón común (sidecar) tiene más de un container por Pod, cada uno con su propio stream de logs.

**Pasos:**

1. Creá un archivo `multi-container.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi-log
spec:
  containers:
  - name: app
    image: busybox
    args: ["/bin/sh", "-c", "while true; do echo app-$(date +%s); sleep 5; done"]
  - name: sidecar
    image: busybox
    args: ["/bin/sh", "-c", "while true; do echo sidecar-$(date +%s); sleep 5; done"]
```

2. Aplicá el manifiesto y esperá a que el Pod esté `Running`:

```bash
kubectl apply -f multi-container.yaml
kubectl get pod multi-log
```

3. Intentá ver los logs sin especificar container:

```bash
kubectl logs multi-log
```

4. Ahora especificá cada container:

```bash
kubectl logs multi-log -c app
kubectl logs multi-log -c sidecar
```

5. Seguí los logs en tiempo real de uno de los dos containers:

```bash
kubectl logs multi-log -c app -f
```

Cortá con `Ctrl+C` cuando quieras terminar.

**Preguntas de comprensión:**

- ¿Qué pasa cuando ejecutás `kubectl logs` sobre un Pod con más de un container sin usar `-c`?
- ¿Qué comando usarías para ver los logs de un container que se reinició, correspondientes a su ejecución anterior?

---

## Ejercicio 3: Métricas de recursos con `kubectl top`

`kubectl top` depende de metrics-server, un componente que agrega métricas de CPU/memoria desde cAdvisor (vía kubelet) y las expone a través de la Metrics API.

**Pasos:**

1. Si usás minikube, habilitá el addon:

```bash
minikube addons enable metrics-server
```

2. Verificá que el Pod de metrics-server esté corriendo en `kube-system`:

```bash
kubectl get pods -n kube-system | grep metrics-server
```

3. Esperá alrededor de un minuto (metrics-server necesita tiempo para recolectar la primera muestra) y consultá el uso a nivel nodo:

```bash
kubectl top nodes
```

4. Consultá el uso a nivel Pod en el namespace `default`:

```bash
kubectl top pods
```

5. Si el comando falla con un error de "metrics not available yet", esperá unos segundos más y reintentá.

**Preguntas de comprensión:**

- ¿Qué componente necesita estar corriendo en el clúster para que `kubectl top` funcione?
- ¿Por qué `kubectl top` no sirve para ver el histórico de uso de CPU de las últimas 24 horas?

---

## Ejercicio 4: Prometheus y PromQL

Prometheus es el sistema de monitoring de referencia en el ecosistema cloud native, con un modelo de recolección pull (scraping de endpoints `/metrics`).

**Pasos:**

1. Agregá el repo de Helm de la comunidad de Prometheus:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

2. Instalá el stack (incluye Prometheus, Alertmanager y exporters):

```bash
helm install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

3. Esperá a que los Pods estén listos:

```bash
kubectl get pods -n monitoring -w
```

4. Hacé port-forward al servidor de Prometheus:

```bash
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-stack-prometheus 9090:9090
```

5. Abrí `http://localhost:9090` en el navegador y ejecutá esta query en la pestaña "Graph":

```
up
```

Esto devuelve `1` para cada target que Prometheus scrapeó exitosamente, `0` si no.

6. Probá una segunda query que agregue uso de CPU por Pod:

```
sum(rate(container_cpu_usage_seconds_total[5m])) by (pod)
```

**Preguntas de comprensión:**

- ¿Qué significa que Prometheus use un modelo pull en lugar de push, y qué implica eso para cómo las aplicaciones exponen sus métricas?
- En la query `rate(container_cpu_usage_seconds_total[5m])`, ¿qué representa el `[5m]`?

---

## Ejercicio 5: Grafana como capa de visualización

Grafana no recolecta datos por sí mismo: consulta datasources (como Prometheus) y renderiza los resultados como dashboards.

**Pasos:**

1. Si instalaste `kube-prometheus-stack` en el ejercicio anterior, Grafana ya viene incluido. Obtené la contraseña admin generada:

```bash
kubectl get secret -n monitoring kube-prom-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

2. Hacé port-forward al servicio de Grafana:

```bash
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80
```

3. Abrí `http://localhost:3000` y logueate con usuario `admin` y la contraseña obtenida en el paso 1.

4. Andá a Connections → Data sources y confirmá que Prometheus ya está configurado como datasource (el chart lo agrega automáticamente).

5. Importá un dashboard público de monitoreo de clúster: en Dashboards → New → Import, ingresá el ID `315` (Kubernetes cluster monitoring) y seleccioná el datasource de Prometheus.

6. Explorá el dashboard importado y ubicá el panel de uso de CPU por nodo.

**Preguntas de comprensión:**

- ¿Qué responsabilidad tiene Prometheus y cuál tiene Grafana en este stack? ¿Por qué separarlas en lugar de tener un solo componente que haga ambas cosas?
- Si el panel de Grafana muestra "No data", ¿qué componente revisarías primero: el datasource de Prometheus o la configuración del dashboard?

---

**Fuente de referencia:** [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- Cuando una liveness probe falla repetidamente, el kubelet mata el container y lo reinicia según la `restartPolicy` del Pod. Cuando falla una readiness probe, el Pod no se reinicia: simplemente se lo saca de los Endpoints del Service, así deja de recibir tráfico hasta que vuelva a pasar la probe.
- `initialDelaySeconds` evita que Kubernetes empiece a evaluar la probe antes de que la aplicación termine de arrancar. Sin ese delay, una app con arranque lento podría ser marcada como fallida (y reiniciada en loop) antes de tener chance de levantar.

**Ejercicio 2**
- Si el Pod tiene más de un container y no usás `-c`, `kubectl logs` devuelve un error pidiendo que especifiques el nombre del container (a menos que el Pod tenga un único container, en cuyo caso no hace falta).
- `kubectl logs <pod> -c <container> --previous` muestra los logs de la instancia anterior del container, útil para diagnosticar por qué se reinició (crash, OOMKilled, etc.).

**Ejercicio 3**
- Necesita estar corriendo metrics-server en el clúster (normalmente en `kube-system`), que agrega datos de uso desde cAdvisor/kubelet y los expone vía la Metrics API.
- Porque metrics-server solo guarda datos en memoria, en una ventana muy corta (los últimos segundos/minutos), sin persistencia histórica. Para eso se necesita un sistema con almacenamiento de series temporales, como Prometheus.

**Ejercicio 4**
- En el modelo pull, Prometheus es quien inicia las conexiones, scrapeando periódicamente los endpoints `/metrics` que exponen las aplicaciones. Esto implica que cada app (o un exporter que actúe en su nombre) debe exponer un endpoint HTTP con las métricas en formato Prometheus, en vez de enviarlas activamente a un servidor central.
- El `[5m]` define un range vector: le dice a `rate()` que calcule la tasa de cambio del contador usando los valores de los últimos 5 minutos, en vez de comparar solo dos puntos consecutivos.

**Ejercicio 5**
- Prometheus se encarga de scrapear, almacenar y consultar (vía PromQL) las series temporales de métricas. Grafana no almacena métricas: consulta datasources como Prometheus y las renderiza como paneles y dashboards. Separar ambas responsabilidades permite, por ejemplo, cambiar la herramienta de visualización sin tocar la recolección, o tener múltiples datasources (Prometheus, Loki, etc.) alimentando los mismos dashboards.
- Primero revisarías el datasource de Prometheus (que esté bien configurado y que Prometheus tenga datos para esa query), ya que un panel mal configurado normalmente muestra un error distinto a "No data", mientras que "No data" suele indicar que la query no devolvió resultados desde el datasource.

</details>