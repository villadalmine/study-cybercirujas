# Ejercicios guiados — 3.2 Use built-in CLI tools to monitor Kubernetes applications

> **Requisitos previos:** un cluster de Kubernetes funcionando (minikube, kind o similar), `kubectl` configurado, y permisos para crear recursos. Para los ejercicios de `kubectl top` necesitás **metrics-server** instalado; el Ejercicio 1 te muestra cómo verificarlo e instalarlo.

Trabajá en un namespace propio para poder limpiar todo al final:

```bash
kubectl create namespace monitor-lab
kubectl config set-context --current --namespace=monitor-lab
```

---

## Ejercicio 1 — Verificar el pipeline de métricas (metrics-server)

Las métricas de CPU y memoria que muestra `kubectl top` no salen de la nada: las provee **metrics-server**, un componente que agrega datos de los **kubelet** y los expone a través de la **Metrics API** (`metrics.k8s.io`).

1. Verificá si metrics-server está desplegado:

   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```

2. Si no existe, instalalo. En **minikube**:

   ```bash
   minikube addons enable metrics-server
   ```

   En otros clusters:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

3. Confirmá que la Metrics API responde (puede tardar 1–2 minutos en juntar datos):

   ```bash
   kubectl get apiservices | grep metrics
   kubectl top nodes
   ```

4. Mirá los datos crudos que expone la API:

   ```bash
   kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 500
   ```

**Preguntas:**

- **1.a** ¿Qué componente recolecta las métricas en cada nodo y se las entrega a metrics-server?
- **1.b** Si `kubectl top nodes` devuelve `error: Metrics API not available`, ¿cuál es la causa más probable?
- **1.c** ¿metrics-server guarda un histórico de métricas que puedas consultar más tarde?

---

## Ejercicio 2 — `kubectl top`: uso real de CPU y memoria

1. Desplegá un workload que consuma CPU de forma sostenida:

   ```bash
   kubectl create deployment cpu-burner --image=busybox --replicas=2 \
     -- /bin/sh -c "while true; do :; done"
   ```

2. Desplegá otro que esté prácticamente ocioso:

   ```bash
   kubectl create deployment idler --image=busybox --replicas=1 \
     -- /bin/sh -c "sleep 3600"
   ```

3. Esperá ~1 minuto y mirá el consumo por pod:

   ```bash
   kubectl top pods
   ```

4. Ordená por consumo de CPU y después por memoria:

   ```bash
   kubectl top pods --sort-by=cpu
   kubectl top pods --sort-by=memory
   ```

5. Mirá el desglose **por container** dentro de cada pod:

   ```bash
   kubectl top pods --containers
   ```

6. Mirá el consumo agregado por nodo y compará con la capacidad:

   ```bash
   kubectl top nodes
   kubectl describe node <nombre-del-nodo> | grep -A 8 "Allocated resources"
   ```

**Preguntas:**

- **2.a** ¿Qué diferencia hay entre lo que muestra `kubectl top pods` y los **requests** que ves en `kubectl describe node`?
- **2.b** En el examen te piden encontrar el pod que más CPU consume en un namespace y guardar su nombre en un archivo. ¿Qué comando usarías?
- **2.c** ¿Qué significa la unidad `m` en la columna `CPU(cores)` (por ejemplo, `250m`)?

---

## Ejercicio 3 — `kubectl logs`: leer lo que la aplicación cuenta

1. Creá un pod con **dos containers** que escriben en stdout:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: dual-logger
   spec:
     containers:
     - name: app
       image: busybox
       command: ["/bin/sh", "-c", "while true; do echo \"[app] procesando pedido $RANDOM\"; sleep 2; done"]
     - name: sidecar
       image: busybox
       command: ["/bin/sh", "-c", "while true; do echo \"[sidecar] heartbeat ok\"; sleep 5; done"]
   EOF
   ```

2. Intentá pedir los logs sin especificar container y observá el error:

   ```bash
   kubectl logs dual-logger
   ```

3. Pedí los logs del container correcto:

   ```bash
   kubectl logs dual-logger -c app
   kubectl logs dual-logger --all-containers=true
   ```

4. Seguí los logs en vivo y cortá con `Ctrl+C`:

   ```bash
   kubectl logs dual-logger -c app -f
   ```

5. Limitá la salida: solo las últimas 5 líneas, y solo lo del último minuto:

   ```bash
   kubectl logs dual-logger -c app --tail=5
   kubectl logs dual-logger -c app --since=1m
   ```

6. Pedí logs de **varios pods a la vez** usando un label selector:

   ```bash
   kubectl logs -l app=cpu-burner --prefix=true --tail=3
   ```

7. Ahora simulá un container que crashea y reinicia:

   ```bash
   kubectl run crasher --image=busybox -- /bin/sh -c "echo 'arranco...'; sleep 5; echo 'ERROR FATAL: sin conexion a la DB'; exit 1"
   ```

   Esperá a que reinicie un par de veces (`kubectl get pod crasher`) y recuperá los logs de la **ejecución anterior**:

   ```bash
   kubectl logs crasher --previous
   ```

**Preguntas:**

- **3.a** ¿Por qué falló el paso 2 y qué flag lo resuelve?
- **3.b** Un pod está en `CrashLoopBackOff` y `kubectl logs <pod>` no muestra nada útil porque el container acaba de reiniciar. ¿Qué flag te deja ver por qué murió la ejecución anterior?
- **3.c** ¿Qué requisito debe cumplir una aplicación para que sus logs aparezcan con `kubectl logs`?

---

## Ejercicio 4 — `kubectl describe` y `kubectl get events`: cuando el pod ni siquiera arranca

`kubectl logs` sirve cuando la aplicación corre. Cuando el pod **no llega a arrancar** (imagen inexistente, falta de recursos, volúmenes que no montan), la información está en los **events**.

1. Creá un pod con una imagen que no existe:

   ```bash
   kubectl run broken --image=nginx:noexiste
   ```

2. Mirá el estado:

   ```bash
   kubectl get pod broken
   ```

3. Inspeccionalo con `describe` y andá directo a la sección `Events:` del final:

   ```bash
   kubectl describe pod broken
   ```

4. Mirá los events del namespace completo, ordenados cronológicamente:

   ```bash
   kubectl get events --sort-by=.lastTimestamp
   ```

5. Filtrá solo los events de tipo `Warning`:

   ```bash
   kubectl get events --field-selector type=Warning
   ```

6. Dejá una terminal observando events en vivo mientras en otra "arreglás" el pod:

   ```bash
   # Terminal 1
   kubectl get events -w

   # Terminal 2
   kubectl set image pod/broken broken=nginx:1.27
   ```

**Preguntas:**

- **4.a** ¿En qué estado quedó el pod `broken` en el paso 2 y qué event de `describe` explica la causa?
- **4.b** ¿Qué diferencia práctica hay entre `kubectl logs` y la sección `Events:` de `kubectl describe pod` a la hora de diagnosticar?
- **4.c** ¿Por qué conviene `--sort-by=.lastTimestamp` al listar events?

---

## Ejercicio 5 — Observar cambios en vivo: `--watch` y `rollout status`

1. Desplegá una aplicación con varias réplicas:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   ```

2. En una terminal, dejá corriendo:

   ```bash
   kubectl get pods -l app=web -w
   ```

3. En otra terminal, dispará un rollout y seguilo con el comando dedicado:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.28
   kubectl rollout status deployment/web
   ```

4. Observá en la primera terminal cómo se crean pods nuevos y se terminan los viejos.

5. Revisá el estado agregado del Deployment y sus condiciones:

   ```bash
   kubectl get deployment web
   kubectl describe deployment web | grep -A 5 Conditions
   ```

**Preguntas:**

- **5.a** ¿Qué ventaja tiene `kubectl rollout status` frente a mirar `kubectl get pods -w` durante un despliegue?
- **5.b** ¿Cuándo termina (devuelve el prompt) el comando `kubectl rollout status`?

---

## Ejercicio 6 — Integrador: diagnosticar un pod OOMKilled solo con herramientas built-in

1. Creá un pod que intenta usar más memoria que su **limit**:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
   spec:
     containers:
     - name: hog
       image: polinux/stress
       command: ["stress", "--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "100Mi"
         limits:
           memory: "128Mi"
   EOF
   ```

2. Observá qué pasa con el pod:

   ```bash
   kubectl get pod memory-hog -w
   ```

3. Cuando veas reinicios, diagnosticá con las tres herramientas del tema:

   ```bash
   kubectl describe pod memory-hog | grep -A 5 "Last State"
   kubectl logs memory-hog --previous
   kubectl top pod memory-hog --containers
   ```

4. Anotá: ¿qué te dijo cada comando? ¿Cuál te dio el dato decisivo?

5. Limpieza final del laboratorio:

   ```bash
   kubectl delete namespace monitor-lab
   kubectl config set-context --current --namespace=default
   ```

**Preguntas:**

- **6.a** ¿Qué valor aparece en `Reason` dentro de `Last State` en el `describe`, y qué significa?
- **6.b** ¿Por qué en este caso `kubectl top` por sí solo podría no mostrarte nunca el problema?
- **6.c** Resumí la "escalera de diagnóstico" del CKAD: ¿en qué orden usás `get`, `describe`, `logs` y `top` frente a un pod que falla, y qué pregunta responde cada uno?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

- **1.a** El **kubelet** de cada nodo recolecta las métricas de CPU y memoria de los containers (a través de cAdvisor, integrado en el kubelet) y metrics-server las agrega y las expone en la Metrics API (`metrics.k8s.io`).
- **1.b** Que **metrics-server no está instalado** (o su pod no está `Ready` todavía). `kubectl top` depende por completo de la Metrics API; sin metrics-server, el comando falla aunque el cluster funcione perfecto.
- **1.c** No. metrics-server solo mantiene el **valor más reciente** de cada métrica, en memoria. Para histórico y alertas se usan herramientas externas como Prometheus, que quedan fuera del alcance de "built-in CLI tools".

### Ejercicio 2

- **2.a** `kubectl top pods` muestra el **consumo real instantáneo** medido por el kubelet. Los **requests** de `describe node` son lo que los pods **reservaron** al schedulearse, se use o no. Un pod puede reservar 500m y consumir 5m, o al revés (si no definió requests).
- **2.b** Por ejemplo:

  ```bash
  kubectl top pods -n <namespace> --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /ruta/archivo.txt
  ```

  La clave del examen es `--sort-by=cpu`: el pod que más consume queda primero.
- **2.c** Son **millicores**: milésimas de un core de CPU. `250m` = 0,25 cores; `1000m` = 1 core completo.

### Ejercicio 3

- **3.a** Falló porque el pod tiene **más de un container** y `kubectl logs` no sabe cuál mostrar. Se resuelve con `-c <nombre-del-container>` o con `--all-containers=true`.
- **3.b** `kubectl logs <pod> --previous` (abreviado `-p`): muestra los logs de la **instancia anterior** del container, que es donde suele estar el mensaje de error que causó el crash.
- **3.c** Debe escribir sus logs a **stdout/stderr**. El kubelet captura esos streams; si la aplicación escribe solo a un archivo interno del container, `kubectl logs` no muestra nada.

### Ejercicio 4

- **4.a** Queda en `ErrImagePull` y después `ImagePullBackOff`. En `Events:` aparece un `Failed` con el mensaje de que la imagen `nginx:noexiste` no pudo ser descargada (`manifest unknown` o similar), y luego `BackOff` mientras reintenta con espera creciente.
- **4.b** `kubectl logs` muestra lo que dice **la aplicación** (necesita que el container haya arrancado). Los `Events:` muestran lo que dice **Kubernetes** sobre el ciclo de vida del pod: scheduling, pull de imágenes, montaje de volúmenes, probes que fallan, kills por memoria. Si el container nunca arrancó, los events son tu única fuente.
- **4.c** Porque por defecto el orden de `kubectl get events` no garantiza cronología, y en un namespace activo el event relevante puede quedar en el medio de la lista. Ordenando por `.lastTimestamp`, lo más reciente queda al final, a la vista.

### Ejercicio 5

- **5.a** `rollout status` interpreta el estado del **Deployment completo** (réplicas nuevas disponibles vs. deseadas) y te dice en una línea si el rollout progresa, terminó o está trabado; con `get pods -w` tenés que deducirlo vos mirando pods individuales.
- **5.b** Cuando el rollout **termina con éxito** (todas las réplicas nuevas disponibles) devuelve exit code 0; si el Deployment excede su `progressDeadlineSeconds`, sale con error. Mientras el rollout progresa, el comando bloquea. Eso lo hace útil también en scripts y pipelines.

### Ejercicio 6

- **6.a** `Reason: OOMKilled` con `Exit Code: 137`. Significa que el kernel mató el proceso porque el container superó su **memory limit** (128Mi) — Out Of Memory.
- **6.b** Porque `kubectl top` muestra un valor instantáneo y con retardo de scraping: si el container consume la memoria de golpe y es matado enseguida, entre una medición y otra quizás nunca lo veas cerca del límite. El dato concluyente está en `describe` (`Last State: OOMKilled`), no en la métrica.
- **6.c** Escalera típica:
  1. `kubectl get pod` — ¿**qué** estado tiene? (Running, CrashLoopBackOff, ImagePullBackOff, cuántos restarts).
  2. `kubectl describe pod` — ¿**por qué**, según Kubernetes? (events, Last State, probes, recursos).
  3. `kubectl logs` (con `--previous` si hubo restart) — ¿**por qué**, según la aplicación?
  4. `kubectl top` — ¿es un problema de **recursos** (CPU/memoria) ahora mismo?

</details>

---

**Fuentes:**

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Resource metrics pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- Kubernetes — Debug Running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes — Referencia de `kubectl`: https://kubernetes.io/docs/reference/kubectl/