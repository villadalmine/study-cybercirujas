# 3.4 — Primitivos para deployments robustos y self-healing (CKA v1.35, peso 2.5)

Este ejercicio guiado cubre las primitivas de Kubernetes que garantizan que una aplicación se mantenga en el estado deseado: `Deployment`, `ReplicaSet`, `StatefulSet`, `DaemonSet`, `Job`/`CronJob`, probes (`liveness`, `readiness`, `startup`), `restartPolicy` y `PodDisruptionBudget`.

Requisitos: un cluster con al menos 2 nodos (minikube con `--nodes 2` o kind), `kubectl` configurado, y un namespace de trabajo.

```bash
kubectl create namespace cka-3-4
kubectl config set-context --current --namespace=cka-3-4
```

---

## Ejercicio 1 — Deployment y ReplicaSet: la relación primitiva

1. Creá un Deployment simple:

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
```

2. Listá los objetos que se crearon en cadena:

```bash
kubectl get deployment web
kubectl get replicaset -l app=web
kubectl get pods -l app=web -o wide
```

3. Inspeccioná las `ownerReferences` de un Pod para ver quién lo controla:

```bash
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences}'
```

4. Repetí el mismo chequeo sobre el ReplicaSet, para ver que él a su vez tiene como owner al Deployment:

```bash
RS=$(kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences}'
```

> **Pregunta 1.1:** ¿Por qué un Deployment no gestiona los Pods directamente, sino que delega esa tarea en un ReplicaSet intermedio?
>
> **Pregunta 1.2:** Si borrás el ReplicaSet con `kubectl delete rs <nombre>` sin tocar el Deployment, ¿qué pasa a los pocos segundos y por qué?

---

## Ejercicio 2 — El control loop de self-healing en acción

1. Verificá cuántas réplicas hay corriendo y guardá el nombre de un pod:

```bash
kubectl get pods -l app=web
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
```

2. Borrá ese pod manualmente:

```bash
kubectl delete pod "$POD"
```

3. Observá en tiempo real cómo el ReplicaSet lo reemplaza:

```bash
kubectl get pods -l app=web -w
```
(Cortá el watch con `Ctrl+C` cuando veas el pod nuevo en `Running`.)

4. Ahora simulá una falla más drástica: llevá las réplicas a 0 y luego de vuelta a 3, y compará el comportamiento con el paso anterior:

```bash
kubectl scale deployment web --replicas=0
kubectl get pods -l app=web
kubectl scale deployment web --replicas=3
```

> **Pregunta 2.1:** ¿Qué componente del control plane detecta que faltan pods respecto del `replicas` declarado, y cómo se llama ese mecanismo de comparación estado-actual vs. estado-deseado?
>
> **Pregunta 2.2:** ¿El Pod recreado en el paso 2 conserva el mismo `metadata.name` que el original? Justificá por qué sí o por qué no.

---

## Ejercicio 3 — Rolling update y rollback

1. Revisá la estrategia de actualización por defecto:

```bash
kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
```

2. Dispará una actualización de imagen y seguí el rollout:

```bash
kubectl set image deployment/web nginx=nginx:1.26
kubectl rollout status deployment/web
```

3. Mientras el rollout corre (podés repetir el `set image` con otra versión para verlo mejor), observá cómo conviven pods viejos y nuevos:

```bash
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

4. Revisá el historial y volvé a la revisión anterior:

```bash
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
```

> **Pregunta 3.1:** ¿Qué controlan los campos `maxSurge` y `maxUnavailable`, y qué combinación de valores garantizaría cero downtime durante el rollout?
>
> **Pregunta 3.2:** ¿Por qué `kubectl rollout undo` no elimina el ReplicaSet anterior en lugar de simplemente escalarlo de nuevo a 0?

---

## Ejercicio 4 — Liveness y readiness probes

1. Creá un pod con una liveness probe que va a fallar a propósito (el archivo se borra a los 30s):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: probe-demo
  labels:
    app: probe-demo
spec:
  containers:
  - name: app
    image: busybox
    args:
    - /bin/sh
    - -c
    - "touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600"
    livenessProbe:
      exec:
        command: ["cat", "/tmp/healthy"]
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 1
EOF
```

2. Esperá un par de minutos y observá el conteo de reinicios:

```bash
kubectl get pod probe-demo -w
```

3. Revisá los eventos para ver el motivo exacto del restart:

```bash
kubectl describe pod probe-demo | grep -A5 Events
```

4. Ahora agregá una readiness probe a un Deployment y quitale temporalmente el servicio "sano" para ver cómo el pod deja de recibir tráfico sin ser reiniciado:

```bash
kubectl expose deployment web --port=80 --name=web-svc
kubectl exec -it "$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')" -- \
  sh -c "mv /usr/share/nginx/html/index.html /usr/share/nginx/html/index.html.bak"
kubectl get endpoints web-svc
```

> **Pregunta 4.1:** ¿Cuál es la diferencia de consecuencias entre que falle una liveness probe y que falle una readiness probe?
>
> **Pregunta 4.2:** ¿Para qué sirve una startup probe y en qué escenario reemplazarías `initialDelaySeconds` de la liveness probe por una startup probe?

---

## Ejercicio 5 — Jobs y `restartPolicy`

1. Creá un Job cuyo container falla siempre, con reintentos limitados:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: fail-job
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: fail
        image: busybox
        args: ["/bin/sh", "-c", "exit 1"]
EOF
```

2. Observá los reintentos y el estado final del Job:

```bash
kubectl get pods -l job-name=fail-job -w
kubectl get job fail-job
```

3. Creá un segundo Job con `completions: 3` y `parallelism: 2` que sí funcione:

```bash
kubectl create job batch-ok --image=busybox -- /bin/sh -c "echo hola; sleep 5"
kubectl get job batch-ok -o jsonpath='{.spec.completions}{" / "}{.spec.parallelism}{"\n"}'
```

> **Pregunta 5.1:** ¿Por qué un Job no acepta `restartPolicy: Always`, a diferencia de un Deployment?
>
> **Pregunta 5.2:** ¿Qué diferencia hay entre que `backoffLimit` se agote y el Job pase a `Failed`, versus que un Deployment reintente indefinidamente un CrashLoopBackOff?

---

## Ejercicio 6 — CronJob

1. Creá un CronJob que corre cada minuto:

```bash
kubectl create cronjob hello --image=busybox --schedule="*/1 * * * *" -- /bin/sh -c "date; echo hello"
```

2. Esperá 2-3 minutos y revisá los Jobs generados:

```bash
kubectl get jobs -l job-name --watch --timeout=180s
kubectl get cronjob hello
```

3. Revisá los logs de la última ejecución:

```bash
kubectl logs job/$(kubectl get jobs -o jsonpath='{.items[-1:].metadata.name}')
```

> **Pregunta 6.1:** ¿Qué controla `concurrencyPolicy` y qué pasaría con valor `Forbid` si una ejecución tarda más que el intervalo del `schedule`?

---

## Ejercicio 7 — DaemonSet

1. Creá un DaemonSet:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  selector:
    matchLabels:
      app: node-agent
  template:
    metadata:
      labels:
        app: node-agent
    spec:
      containers:
      - name: agent
        image: busybox
        args: ["/bin/sh", "-c", "sleep 3600"]
EOF
```

2. Verificá que hay exactamente un pod por nodo elegible:

```bash
kubectl get pods -l app=node-agent -o wide
kubectl get nodes
```

3. Agregá un `nodeSelector` o `taint` a un nodo y observá que el DaemonSet respeta ese filtro sin necesidad de tocar réplicas manualmente:

```bash
kubectl taint nodes <nombre-nodo> dedicated=infra:NoSchedule
kubectl get pods -l app=node-agent -o wide
```

> **Pregunta 7.1:** ¿Por qué un DaemonSet no tiene campo `replicas` en su `spec`, a diferencia de Deployment y ReplicaSet?
>
> **Pregunta 7.2:** Tras aplicar el taint del paso 3, ¿qué pasó con el pod que ya corría en ese nodo?

---

## Ejercicio 8 — StatefulSet: identidad estable

1. Creá un Service headless y un StatefulSet:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None
  selector:
    app: sts-demo
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sts-demo
spec:
  serviceName: web-headless
  replicas: 3
  selector:
    matchLabels:
      app: sts-demo
  template:
    metadata:
      labels:
        app: sts-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF
```

2. Observá los nombres ordinales de los pods y el orden de creación:

```bash
kubectl get pods -l app=sts-demo -w
```

3. Borrá el pod del medio y verificá que vuelve con exactamente el mismo nombre:

```bash
kubectl delete pod sts-demo-1
kubectl get pods -l app=sts-demo
```

4. Resolvé el DNS estable de ese pod desde otro pod del cluster:

```bash
kubectl run dns-test --image=busybox --rm -it --restart=Never -- \
  nslookup sts-demo-1.web-headless.cka-3-4.svc.cluster.local
```

> **Pregunta 8.1:** ¿Por qué `sts-demo-1` recupera el mismo nombre y la misma identidad de red tras ser recreado, mientras que en el Ejercicio 2 el Pod del Deployment recibió un nombre distinto?
>
> **Pregunta 8.2:** ¿Qué garantía adicional (fuera del nombre) provee un StatefulSet cuando cada réplica usa un `volumeClaimTemplate`?

---

## Ejercicio 9 — PodDisruptionBudget

1. Creá un PDB para el Deployment `web`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
EOF
```

2. Revisá el estado del PDB:

```bash
kubectl get pdb web-pdb
```

3. Intentá drenar (evict) el nodo donde corre uno de los pods de `web`, forzando una disrupción voluntaria:

```bash
kubectl drain <nombre-nodo> --ignore-daemonsets --delete-emptydir-data
```

> **Pregunta 9.1:** Si `minAvailable: 2` y hay 3 réplicas corriendo, ¿cuántas evictions voluntarias simultáneas permite el PDB antes de bloquear el `drain`?
>
> **Pregunta 9.2:** ¿Un PodDisruptionBudget protege contra que un nodo se caiga de forma abrupta (disrupción involuntaria)? Justificá.

---

## Limpieza

```bash
kubectl delete namespace cka-3-4
kubectl taint nodes <nombre-nodo> dedicated=infra:NoSchedule-
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**1.1** — El Deployment gestiona la estrategia de actualización (versionado, rolling update, rollback) creando un nuevo ReplicaSet por cada revisión del `podTemplate`. El ReplicaSet es la primitiva más simple, cuya única responsabilidad es mantener el número de réplicas de una versión fija de Pod. Separar ambas responsabilidades permite que el Deployment conserve el historial de ReplicaSets viejos (escalados a 0) para poder hacer rollback sin recrear objetos.

**1.2** — El Deployment controller detecta que ya no existe un ReplicaSet que coincida con la revisión actual (`pod-template-hash`) y crea uno nuevo idéntico al anterior. Los pods vuelven a levantarse porque el Deployment, no el ReplicaSet, es la fuente de verdad del estado deseado.

**2.1** — El `kube-controller-manager`, específicamente el ReplicaSet controller, corre un reconciliation loop que compara continuamente `status.replicas` (estado observado vía el API server/etcd) contra `spec.replicas` (estado deseado), y crea o borra pods hasta igualarlos.

**2.2** — No. Un Pod nuevo recibe un `metadata.name` distinto (mismo prefijo del ReplicaSet más un sufijo aleatorio nuevo) porque los Pods son efímeros y no tienen identidad persistente garantizada; el ReplicaSet controller crea un objeto Pod completamente nuevo, no "revive" el anterior.

**3.1** — `maxUnavailable` limita cuántos pods del estado anterior pueden estar no disponibles durante el update, y `maxSurge` limita cuántos pods por encima de `replicas` se pueden crear temporalmente. Con `maxUnavailable: 0` y `maxSurge: 1` (o más) se garantiza que nunca haya menos pods disponibles que las réplicas declaradas, logrando cero downtime.

**3.2** — Porque el ReplicaSet anterior conserva el `podTemplate` exacto de esa revisión (incluida la imagen). Recrearlo desde cero implicaría perder el historial de revisiones que `kubectl rollout history` expone; escalarlo de 0 a N es más rápido y es lo que permite rollbacks instantáneos.

**4.1** — Si falla la liveness probe, el kubelet mata y reinicia el container (afecta la disponibilidad del propio pod). Si falla la readiness probe, el pod sigue corriendo pero se lo remueve de los `Endpoints` de cualquier Service que lo seleccione, dejando de recibir tráfico sin que se reinicie nada.

**4.2** — La startup probe pausa la ejecución de las demás probes (liveness/readiness) hasta que la aplicación termine de arrancar, útil para apps con arranque lento y variable. Es preferible a inflar `initialDelaySeconds` porque este último es un valor fijo: si la app tarda menos, se pierde tiempo de detección; si tarda más, la liveness probe puede matar el container antes de que arranque.

**5.1** — Un Job ejecuta una tarea que debe terminar (run-to-completion), no un proceso de larga duración. `restartPolicy: Always` implicaría que el container se reinicia incluso tras terminar con éxito, lo cual es incompatible con la semántica de "completar N veces y parar"; por eso solo acepta `OnFailure` o `Never`.

**5.2** — Un Job con `backoffLimit` agotado pasa a estado `Failed` de forma definitiva y no vuelve a reintentar: requiere intervención manual. Un Deployment en CrashLoopBackOff sigue reintentando indefinidamente (con backoff exponencial) porque su contrato es "esta réplica debe estar corriendo siempre", sin noción de éxito/fracaso final.

**6.1** — `concurrencyPolicy` define qué pasa si llega la hora de una nueva ejecución mientras la anterior sigue corriendo: `Allow` (default) permite que corran en paralelo, `Forbid` salta la nueva ejecución si la anterior no terminó, y `Replace` cancela la anterior para lanzar la nueva. Con `Forbid`, si una ejecución tarda más que el intervalo del `schedule`, las corridas subsiguientes simplemente se omiten hasta que la actual termine.

**7.1** — Porque el número de réplicas de un DaemonSet no es un valor arbitrario: está determinado dinámicamente por la cantidad de nodos que matchean su `nodeSelector`/tolerations en un momento dado. No tiene sentido declarar `replicas` cuando el propio cluster define ese número.

**7.2** — El DaemonSet controller detecta que el nodo ya no matchea (por el nuevo taint sin la tolerance correspondiente) y elimina el pod de ese nodo; no se crea un pod de reemplazo en ningún otro nodo, porque un DaemonSet garantiza "uno por nodo elegible", no un número fijo total.

**8.1** — Porque el StatefulSet controller asigna identidad ordinal estable (`<nombre>-<índice>`) a cada réplica y, al recrear un pod, reutiliza el mismo índice y por lo tanto el mismo nombre y el mismo registro DNS. El ReplicaSet de un Deployment, en cambio, no tiene noción de índices: cada pod es intercambiable y anónimo.

**8.2** — Cada réplica del StatefulSet obtiene su propio PVC persistente (vía `volumeClaimTemplate`) que sobrevive a la eliminación del pod y se vuelve a montar en el pod recreado con el mismo ordinal. Esto garantiza que, además del nombre y el DNS, cada instancia conserve su propio almacenamiento estable entre reinicios.

**9.1** — Solo 1. Con 3 réplicas y `minAvailable: 2`, el PDB permite que como máximo 1 pod esté no disponible por una disrupción voluntaria en un momento dado; cualquier eviction adicional simultánea es rechazada hasta que un pod vuelva a estar `Ready`.

**9.2** — No. El PDB solo limita las disrupciones voluntarias iniciadas vía la Eviction API (`kubectl drain`, upgrades de nodo, autoscaling down, etc.). Si un nodo se cae abruptamente (hardware, kernel panic, red), el PDB no puede impedirlo ni retrasarlo; ese escenario lo cubre el ReplicaSet/StatefulSet controller recreando los pods en otro nodo una vez que el `node-monitor-grace-period` expira.

</details>

---

## Referencias

- Curriculum oficial CKA v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes docs — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes docs — ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes docs — StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Kubernetes docs — DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes docs — Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes docs — CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes docs — Liveness/Readiness/Startup Probes: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes
- Kubernetes docs — Pod Disruption Budgets: https://kubernetes.io/docs/tasks/run-application/configure-pdb/