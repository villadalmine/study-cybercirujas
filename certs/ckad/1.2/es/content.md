# 1.2 — Choose and use the right workload resource (Deployment, DaemonSet, CronJob, etc.)

## Por qué no usar Pods "sueltos"

Un **Pod** creado directamente (a veces llamado *bare Pod*) no tiene ningún mecanismo de recuperación: si el nodo donde corre falla, el Pod desaparece y nadie lo recrea. Por eso, en la práctica casi nunca se crean Pods a mano. En su lugar, Kubernetes ofrece **workload resources**: objetos de más alto nivel que crean y gestionan Pods a través de un *controller* que vigila constantemente que el estado real coincida con el estado deseado.

Elegir el workload resource correcto es una decisión de diseño que el examen CKAD evalúa de forma directa: te describen un escenario y tenés que decidir (y crear) el objeto adecuado.

La regla general:

| Necesidad | Workload resource |
|---|---|
| Aplicación **stateless** de larga duración (web, API) | **Deployment** |
| Aplicación **stateful** con identidad estable (DB, colas) | **StatefulSet** |
| Un Pod **en cada nodo** (agentes de logs, monitoreo, red) | **DaemonSet** |
| Tarea que **corre hasta completarse** (migración, batch) | **Job** |
| Tarea **programada/recurrente** (backups, reportes) | **CronJob** |
| Réplicas idénticas sin rolling updates (casi nunca directo) | **ReplicaSet** |

---

## Deployment

Es el workload resource por defecto para aplicaciones **stateless**. Un Deployment gestiona un **ReplicaSet**, y el ReplicaSet gestiona los Pods. Esa capa extra es la que permite hacer **rolling updates** y **rollbacks**: cada cambio en el Pod template crea un ReplicaSet nuevo y el Deployment migra las réplicas de uno a otro de forma controlada.

### Creación imperativa (la vía rápida en el examen)

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=3
```

```
deployment.apps/web created
```

```bash
kubectl get deployments
```

```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/3     3            3           15s
```

Truco de examen: generar el YAML base sin crear el objeto y editarlo después:

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=3 \
  --dry-run=client -o yaml > deploy.yaml
```

### Manifiesto típico

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
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
        image: nginx:1.27
        ports:
        - containerPort: 80
```

Punto clave: `spec.selector.matchLabels` **debe coincidir** con `spec.template.metadata.labels`. Si no coinciden, el API server rechaza el objeto.

### Operaciones frecuentes

```bash
# Escalar
kubectl scale deployment web --replicas=5

# Actualizar la imagen (dispara un rolling update)
kubectl set image deployment/web nginx=nginx:1.28

# Seguir el estado del rollout
kubectl rollout status deployment/web
```

```
Waiting for deployment "web" rollout to finish: 2 out of 5 new replicas have been updated...
deployment "web" successfully rolled out
```

```bash
# Historial y rollback
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout undo deployment/web --to-revision=1
```

El comportamiento del rolling update se controla con `spec.strategy`:

```yaml
strategy:
  type: RollingUpdate        # o Recreate (mata todo y recrea)
  rollingUpdate:
    maxSurge: 1              # cuántos Pods extra puede crear por encima de replicas
    maxUnavailable: 0        # cuántos Pods pueden faltar durante la actualización
```

Con `Recreate` hay downtime garantizado (borra todos los Pods antes de crear los nuevos); se usa cuando dos versiones no pueden convivir (por ejemplo, comparten un volumen `ReadWriteOnce`).

---

## ReplicaSet

Garantiza que exista un número fijo de réplicas de un Pod. Es el mecanismo que el Deployment usa por debajo, y **casi nunca se crea directamente**: si lo hacés, perdés rolling updates y rollbacks. Para el examen alcanza con saber reconocerlo y entender la relación de propiedad:

```bash
kubectl get replicasets
```

```
NAME             DESIRED   CURRENT   READY   AGE
web-7d4b9c8f6d   3         3         3       2m
```

El sufijo hash (`7d4b9c8f6d`) identifica al Pod template; cada versión del Deployment genera un ReplicaSet distinto.

---

## DaemonSet

Garantiza que corra **exactamente un Pod por nodo** (o por subconjunto de nodos, si usás `nodeSelector`/`affinity`). Cuando se agrega un nodo al cluster, el DaemonSet le programa un Pod automáticamente; cuando el nodo se elimina, el Pod se recolecta.

Casos de uso típicos: agentes de logging (Fluentd, Fluent Bit), monitoreo por nodo (node-exporter), plugins de red o de storage.

No existe comando imperativo `kubectl create daemonset`; en el examen lo más rápido es generar un Deployment con `--dry-run=client -o yaml`, cambiar `kind: Deployment` por `kind: DaemonSet` y borrar `replicas` y `strategy`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:3.1
```

Notá el `tolerations`: sin él, el Pod no se programa en nodos con *taints* (como los del control plane). Es un patrón muy común en DaemonSets porque suelen necesitar cubrir **todos** los nodos.

```bash
kubectl get daemonsets -n kube-system
```

```
NAME        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
log-agent   4         4         4       4            4           <none>          1m
```

`DESIRED` es igual al número de nodos elegibles — un DaemonSet **no tiene campo `replicas`**.

---

## StatefulSet

Para aplicaciones que necesitan **identidad estable**: bases de datos, brokers de mensajería, sistemas distribuidos con quórum. A diferencia del Deployment, donde los Pods son intercambiables, un StatefulSet da a cada Pod:

- **Nombre estable y ordinal**: `db-0`, `db-1`, `db-2` (no un hash aleatorio).
- **DNS estable** vía un *headless Service* (`clusterIP: None`): `db-0.db.default.svc.cluster.local`.
- **Storage propio y persistente** con `volumeClaimTemplates`: cada Pod recibe su propio PersistentVolumeClaim, que sobrevive a reprogramaciones.
- **Orden de despliegue y terminación**: crea `db-0`, espera a que esté Ready, luego `db-1`, etc.; escala hacia abajo en orden inverso.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db            # headless Service que debe existir
  replicas: 3
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: postgres
        image: postgres:16
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```

```bash
kubectl get pods -l app=db
```

```
NAME   READY   STATUS    RESTARTS   AGE
db-0   1/1     Running   0          2m
db-1   1/1     Running   0          90s
db-2   1/1     Running   0          60s
```

Regla de decisión rápida: si la aplicación funciona igual sin importar *qué* réplica atiende la request, usá **Deployment**. Si cada réplica tiene datos o rol propio (primary/replica, particiones), usá **StatefulSet**.

---

## Job

Ejecuta Pods **hasta que la tarea termina con éxito** y después los deja en estado `Completed` (no los reinicia indefinidamente como un Deployment). Casos de uso: migraciones de esquema, procesamiento batch, cálculos puntuales.

```bash
kubectl create job pi --image=perl:5.34 -- perl -Mbignum=bpi -wle 'print bpi(2000)'
```

```bash
kubectl get jobs
```

```
NAME   STATUS     COMPLETIONS   DURATION   AGE
pi     Complete   1/1           12s        30s
```

```bash
kubectl logs job/pi | head -c 40
```

```
3.14159265358979323846264338327950288419
```

### Campos clave del spec

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-proc
spec:
  completions: 5        # cuántas ejecuciones exitosas se necesitan en total
  parallelism: 2        # cuántos Pods corren a la vez
  backoffLimit: 4       # reintentos antes de marcar el Job como Failed
  activeDeadlineSeconds: 300   # tiempo máximo total del Job
  ttlSecondsAfterFinished: 60  # limpieza automática del Job terminado
  template:
    spec:
      restartPolicy: Never     # obligatorio: Never u OnFailure (nunca Always)
      containers:
      - name: worker
        image: busybox:1.36
        command: ["sh", "-c", "echo processing && sleep 5"]
```

Dos errores clásicos de examen:

1. **`restartPolicy`**: el default de un Pod es `Always`, pero un Job solo acepta `Never` u `OnFailure`. Si generás el YAML con `--dry-run` desde otro objeto, acordate de ajustarlo.
2. **`completions` vs `parallelism`**: `completions: 5, parallelism: 2` significa "necesito 5 finalizaciones exitosas, corriendo de a 2 Pods simultáneos".

---

## CronJob

Un **CronJob** crea Jobs según un cronograma con sintaxis cron estándar de 5 campos (`minuto hora día-del-mes mes día-de-la-semana`), evaluada en la zona horaria del kube-controller-manager salvo que se defina `timeZone`.

```bash
kubectl create cronjob backup --image=busybox:1.36 \
  --schedule="0 3 * * *" -- sh -c 'echo running backup'
```

```bash
kubectl get cronjobs
```

```
NAME     SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
backup   0 3 * * *   <none>     False     0        <none>          20s
```

### Campos que hay que conocer

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "0 3 * * *"
  timeZone: "America/Argentina/Buenos_Aires"
  concurrencyPolicy: Forbid        # Allow (default) | Forbid | Replace
  startingDeadlineSeconds: 120     # margen para lanzar un run que se perdió
  successfulJobsHistoryLimit: 3    # Jobs exitosos que se conservan (default 3)
  failedJobsHistoryLimit: 1        # Jobs fallidos que se conservan (default 1)
  suspend: false                   # true pausa el cronograma sin borrar nada
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: busybox:1.36
            command: ["sh", "-c", "echo running backup"]
```

- `concurrencyPolicy: Forbid` evita que un run nuevo arranque si el anterior sigue corriendo; `Replace` mata el viejo y lanza el nuevo.
- El `jobTemplate` contiene un **Job spec completo**: todo lo de la sección anterior (incluido `restartPolicy`) aplica adentro.

Para probar un CronJob sin esperar al horario, crear un Job manual a partir de él:

```bash
kubectl create job backup-manual --from=cronjob/backup
```

```
job.batch/backup-manual created
```

---

## Cómo decidir en el examen

Preguntate, en orden:

1. **¿Termina alguna vez?** Si la tarea corre y finaliza → **Job**. Si además se repite en horario → **CronJob**.
2. **¿Tiene que correr en cada nodo?** → **DaemonSet**.
3. **¿Las réplicas necesitan identidad o storage propio?** → **StatefulSet**.
4. **Todo lo demás** (stateless, réplicas intercambiables) → **Deployment**.

Y para ir rápido con `kubectl`:

```bash
kubectl create deployment NAME --image=IMG --replicas=N --dry-run=client -o yaml
kubectl create job NAME --image=IMG --dry-run=client -o yaml -- CMD
kubectl create cronjob NAME --image=IMG --schedule="*/5 * * * *" --dry-run=client -o yaml -- CMD
kubectl explain deployment.spec.strategy    # documentación offline de cualquier campo
```

`kubectl explain` está disponible durante el examen y es la forma más rápida de recordar la estructura exacta de un campo.

---

## Referencias

- Workloads (visión general): https://kubernetes.io/docs/concepts/workloads/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Referencia de `kubectl create`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/
- Curriculum oficial CKAD v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf