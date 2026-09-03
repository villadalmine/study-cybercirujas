# 703.2 — Operaciones básicas de Kubernetes

**LPI DevOps Tools Engineer — Examen 701-100, v2.0.0 · Peso 11.67**
*Nivel: Platform Architect / Senior SRE. Versión de referencia de Kubernetes: v1.32–v1.33.*

---

## 1. El problema de producción que resuelve este objetivo

Antes de Kubernetes, desplegar un servicio significaba responder una pregunta operativa de forma imperativa: *"¿qué host, qué puerto, qué supervisor de procesos, y quién lo reinicia a las 03:00?"* Cada respuesta era un efecto secundario escrito en un runbook, en una receta de Chef o en la memoria de una persona. El modo de fallo era la **deriva de configuración** (*configuration drift*): el estado real de la flota divergía lentamente de lo que todos creían que estaba desplegado, y la divergencia solo se descubría durante un incidente.

Kubernetes reemplaza eso con un **modelo de reconciliación disparado por nivel** (*level-triggered*). No le decís al clúster *qué hacer*; escribís *qué debe ser verdad* — el **estado deseado** — en un almacén de datos replicado (etcd) a través de una única API REST autoritativa. Un conjunto de controladores independientes observa continuamente el **estado real** y emite el conjunto mínimo de acciones para cerrar la brecha. Nada es disparado por flanco (*edge-triggered*): si un controlador pierde un evento, se cae y se reinicia, su siguiente resincronización completa converge igual.

```
                 ┌──────────────────────────────────────────┐
   kubectl ──►   │  kube-apiserver  (the ONLY writer to etcd)│ ◄── controllers
   (HTTP/REST)   │  authn → authz → admission → validation   │     (watch + act)
                 └────────────────┬─────────────────────────┘
                                  │ persists desired state
                                  ▼
                                 etcd
                                  ▲
        ┌─────────────────────────┴───────────────────────────┐
        │           reconciliation loops (level-triggered)    │
        │  deployment-ctl → replicaset-ctl → scheduler        │
        │  endpointslice-ctl, node-ctl, job-ctl, ...          │
        └─────────────────────────┬───────────────────────────┘
                                  ▼
                  kubelet (per node)  ──►  CRI runtime (containerd/CRI-O)
```

Tres consecuencias arquitectónicas gobiernan todo lo que hay en este objetivo:

1. **Todo objeto es un recurso REST.** `kubectl` es un cliente HTTP delgado y prácticamente sin estado. Cualquier cosa que haga `kubectl`, la puede hacer un `curl` contra el API server. Por eso `kubectl --v=8` es la bandera de depuración más útil de todo el ecosistema.
2. **Los controladores son dueños de sus objetos mediante `ownerReferences`.** Un Deployment no crea Pods; crea un ReplicaSet, que crea Pods. Entender esta cadena de tres niveles es la diferencia entre arreglar un rollout y hacer `kubectl delete pod` por inercia.
3. **La identidad es por selector de etiquetas, nunca por nombre.** Los Services no enrutan a nombres de Pods; enrutan a lo que coincida con un selector *ahora mismo*. Eso es lo que hace posibles las actualizaciones progresivas, y también es la causa raíz de la caída más común en un clúster junior: un selector que silenciosamente no coincide con nada.

> **Nota de alcance para el examen.** LPI 703.2 evalúa el uso fluido y correcto de `kubectl` y del conjunto de objetos centrales (Pods, Deployments, ReplicaSets, Services, ConfigMaps, Secrets, namespaces, etiquetas). El material de producción que sigue va más profundo de lo que exige el examen por diseño — la sección de diagnóstico de fallos en particular es lo que separa aprobar el examen de operar un clúster.

---

## 2. El cliente: cómo funciona realmente `kubectl`

`kubectl` no es magia. Ejecuta, en orden:

1. **Carga un kubeconfig** (`--kubeconfig`, si no `$KUBECONFIG` — una *lista* separada por dos puntos, fusionada de izquierda a derecha — si no `~/.kube/config`).
2. **Resuelve el contexto actual** → clúster (URL del servidor + CA), usuario (credenciales o un plugin de credenciales `exec`), y namespace por defecto.
3. **Ejecuta el descubrimiento de la API** contra `/api` y `/apis`, cacheando el resultado en `~/.kube/cache/discovery/<host>/`. Así es como `kubectl get po` sabe que `po` → `pods` → `/api/v1/namespaces/<ns>/pods`.
4. **Mapea el verbo** (`get`, `apply`, `delete`) a un método HTTP y emite la petición.

```console
$ kubectl config get-contexts
CURRENT   NAME              CLUSTER      AUTHINFO         NAMESPACE
*         prod-eu-west-1    prod-eu      sre-oidc         platform
          staging           staging      staging-admin    default

$ kubectl config set-context --current --namespace=payments
Context "prod-eu-west-1" modified.

$ kubectl version
Client Version: v1.33.1
Kustomize Version: v5.6.0
Server Version: v1.32.4
```

**Política de desfase de versiones (*version skew*):** `kubectl` está soportado dentro de una versión menor del API server (`n-1`, `n`, `n+1`). Un cliente v1.33 contra un servidor v1.32 está soportado; un cliente v1.35 no lo está, y omitirá silenciosamente los campos que el servidor no entienda.

### 2.1 Descubrimiento y autodocumentación

Estos dos comandos eliminan la necesidad de memorizar APIs — aprendelos antes de aprender cualquier manifiesto.

```console
$ kubectl api-resources --namespaced=true -o wide | head -8
NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND          VERBS
configmaps    cm           v1           true         ConfigMap     create,delete,get,list,patch,update,watch
endpoints     ep           v1           true         Endpoints     create,delete,get,list,patch,update,watch
events        ev           v1           true         Event         create,delete,get,list,patch,update,watch
pods          po           v1           true         Pod           create,delete,get,list,patch,update,watch
secrets                    v1           true         Secret        create,delete,get,list,patch,update,watch
services      svc          v1           true         Service       create,delete,get,list,patch,update,watch
deployments   deploy       apps/v1      true         Deployment    create,delete,get,list,patch,update,watch

$ kubectl explain deployment.spec.strategy.rollingUpdate.maxSurge
KIND:       Deployment
VERSION:    apps/v1
FIELD: maxSurge <IntOrString>
DESCRIPTION:
    The maximum number of pods that can be scheduled above the desired number of
    pods. Value can be an absolute number (ex: 5) or a percentage of desired pods
    (ex: 10%). This can not be 0 if MaxUnavailable is 0. [...]
```

`kubectl explain --recursive deployment.spec` imprime el subárbol completo — la referencia del esquema sin conexión.

### 2.2 Imperativo vs declarativo vs server-side apply

Esta es una decisión arquitectónica real, no una preferencia de estilo.

| Modo | Comando | Manejo de conflictos | Rastro de auditoría | Veredicto en producción |
|---|---|---|---|---|
| Imperativo | `kubectl create/run/expose/scale/set image` | Gana el último que escribe; `create` falla si el objeto existe | Ninguno fuera del historial de la shell | **Solo ad-hoc + velocidad en el examen.** Nunca en CI. |
| Reemplazo imperativo | `kubectl replace -f` | Sobrescritura completa del objeto; descarta los campos que omitiste | Manifiesto en git | Peligroso: borra silenciosamente campos que otros controladores establecieron. |
| Declarativo CSA | `kubectl apply -f` | Fusión a 3 vías contra la anotación `last-applied-configuration` | Manifiesto en git | El predeterminado durante años; la anotación infla los objetos y se rompe con múltiples escritores. |
| **Declarativo SSA** | `kubectl apply --server-side` | Propiedad por campo rastreada en `metadata.managedFields`; los conflictos son **errores** | Manifiesto en git + gestores de campos | **Recomendado.** Hace respondible la pregunta "quién cambió este campo". |

```console
$ kubectl apply --server-side --field-manager=gitops-ci -f deploy/api.yaml
deployment.apps/payments-api serverside-applied

$ kubectl apply --server-side --field-manager=sre-hotfix -f deploy/api-scaled.yaml
error: Apply failed with 1 conflict: conflict with "gitops-ci" using apps/v1:
- .spec.replicas
Please review the fields above--they currently have other managers. Helper commands:
* You may co-own fields by updating your manifest to match the existing value...
* You may want to use `--force-conflicts` to overwrite the currently managed fields...
```

Ese error es una **funcionalidad**: atrapó a un humano a punto de sobrescribir un campo gestionado por GitOps. Con client-side apply la misma operación habría tenido éxito silenciosamente y habría sido revertida en la siguiente reconciliación, produciendo un incidente de "conteo de réplicas oscilante" que nadie podría explicar.

**Par de pre-vuelo no negociable** — poné ambos en CI antes de cualquier mutación del clúster:

```console
$ kubectl apply -f deploy/ --dry-run=server
deployment.apps/payments-api configured (server dry run)
service/payments-api unchanged (server dry run)

$ kubectl diff -f deploy/api.yaml
diff -u -N /tmp/LIVE-3910/apps.v1.Deployment.payments.payments-api /tmp/MERGED-2277/...
--- LIVE
+++ MERGED
@@ -31,7 +31,7 @@
       containers:
       - name: api
-        image: registry.internal/payments-api:1.14.2
+        image: registry.internal/payments-api:1.15.0
```

`--dry-run=server` ejecuta la **admisión completa** (webhooks, cuota, validación) sin persistir; `--dry-run=client` solo renderiza localmente y no atrapa nada más que sintaxis. `kubectl diff` sale con `1` cuando existe una diferencia — usable directamente como compuerta de deriva.

---

## 3. Namespaces, etiquetas, selectores, anotaciones

### 3.1 Namespaces: un ámbito, no un límite de seguridad

Un namespace acota **nombres**, **cuota** (`ResourceQuota`, `LimitRange`), **RoleBindings de RBAC** y la ruta de búsqueda de DNS. **No** aísla por sí mismo el tráfico de red (necesita `NetworkPolicy`), no aísla el kernel del nodo, y no particiona objetos de ámbito de clúster (Nodes, PersistentVolumes, StorageClasses, ClusterRoles, CRDs).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    kubernetes.io/metadata.name: payments      # set automatically by the apiserver
    app.kubernetes.io/part-of: commerce
    environment: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.cpu: "80"
    limits.memory: 160Gi
    pods: "150"
    count/deployments.apps: "40"
    persistentvolumeclaims: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-defaults
  namespace: payments
spec:
  limits:
    - type: Container
      default:                 # applied as limits when unspecified
        cpu: 500m
        memory: 512Mi
      defaultRequest:          # applied as requests when unspecified
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 16Gi
      min:
        cpu: 10m
        memory: 32Mi
```

El `LimitRange` es lo que hace sobrevivible una `ResourceQuota` sobre `requests.cpu`: una vez que existe una cuota sobre un recurso de cómputo, **cada** Pod de ese namespace debe declarar ese recurso, y un `LimitRange` provee el valor por defecto en lugar de rechazar el Pod.

### 3.2 Etiquetas vs anotaciones

| | Etiquetas | Anotaciones |
|---|---|---|
| Propósito | Metadatos **identificatorios** — selección, agrupación | Metadatos **no identificatorios** — cargas útiles de herramientas |
| Consultable | Sí: `-l`, selectores, complemento `--field-selector` | Sin soporte de selectores |
| Límite de tamaño | Clave ≤ 63 caracteres (+ prefijo de 253 caracteres), valor ≤ 63 caracteres, conjunto de caracteres restringido | Hasta 256 KB en total, bytes arbitrarios |
| Uso típico | `app.kubernetes.io/name`, `tier`, `environment` | `kubernetes.io/change-cause`, checksums, configuración de ingress, `kubectl.kubernetes.io/last-applied-configuration` |
| Costo de indexación | Observadas e indexadas por los controladores | Ignoradas por los selectores |

Adoptá el [conjunto de etiquetas recomendado](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/) — es lo que hace que las consultas entre herramientas (`kubectl`, Prometheus, reportes de costos) hagan join correctamente:

```yaml
labels:
  app.kubernetes.io/name: payments-api
  app.kubernetes.io/instance: payments-api-prod
  app.kubernetes.io/version: "1.15.0"
  app.kubernetes.io/component: api
  app.kubernetes.io/part-of: commerce
  app.kubernetes.io/managed-by: argocd
```

Gramática de selectores, ambas formas:

```console
# equality-based
$ kubectl get pods -l app.kubernetes.io/name=payments-api,environment=production

# set-based: in, notin, exists (key), not-exists (!key)
$ kubectl get pods -l 'environment in (production,canary),!debug' --show-labels
NAME                            READY   STATUS    RESTARTS   AGE   LABELS
payments-api-7d9f4c8b5c-2kq7z   1/1     Running   0          12m   app.kubernetes.io/name=payments-api,environment=production,pod-template-hash=7d9f4c8b5c
payments-api-7d9f4c8b5c-9wxvn   1/1     Running   0          12m   app.kubernetes.io/name=payments-api,environment=production,pod-template-hash=7d9f4c8b5c

# field selectors are a different mechanism — server-side, limited field set
$ kubectl get pods --field-selector status.phase=Running,spec.nodeName=worker-03
```

**Trampa arquitectónica:** `spec.selector.matchLabels` en un Deployment/StatefulSet/DaemonSet es **inmutable**. Cambiarlo requiere eliminar y recrear el controlador. Elegí selectores que codifiquen *solo identidad* (`app.kubernetes.io/name` + `instance`) y nunca incluyas valores volátiles como `version` — de lo contrario cada release se convierte en un borrar/recrear con tiempo fuera de servicio.

---

## 4. Controladores de cargas de trabajo: elegir el correcto

| Controlador | Identidad | Ordenamiento | Almacenamiento | Escalado | Usar cuando |
|---|---|---|---|---|---|
| **Pod** (suelto) | Efímera, sin dueño | — | Cualquiera | Ninguno; nunca se reprograma si el nodo muere | Solo para depuración. Nunca en producción. |
| **ReplicaSet** | Sufijo aleatorio | Ninguno | Compartido/efímero | Manual | Nunca directamente — un detalle de implementación del Deployment. |
| **Deployment** | Sufijo aleatorio, descartable | Ninguno | Efímero o compartido RWX | Manual + HPA | Servicios sin estado. **El predeterminado.** |
| **StatefulSet** | Ordinal estable `web-0..n-1`, DNS estable | Creación/borrado/actualización ordenados (configurable) | PVC por réplica vía `volumeClaimTemplates` | Manual + HPA (con cuidado) | Bases de datos, sistemas de quórum, cualquier cosa que necesite identidad estable. |
| **DaemonSet** | Uno por nodo coincidente | Progresivo por nodo | `hostPath`/efímero | Implícito (cantidad de nodos) | Enviadores de logs, CNI, node exporters, plugins de nodo CSI. |
| **Job** | Sufijo aleatorio | `Indexed` opcional | Efímero | `parallelism`/`completions` | Lotes hasta completar: migraciones, ETL. |
| **CronJob** | Crea Jobs | Por planificación | Efímero | Vía Job | Lotes planificados. Cuidado con `concurrencyPolicy`. |

La cadena de propiedad del Deployment, visible en el grafo de objetos:

```console
$ kubectl get deploy,rs,pod -l app.kubernetes.io/name=payments-api
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/payments-api   4/4     4            4           9d

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/payments-api-7d9f4c8b5c   4         4         4       12m
replicaset.apps/payments-api-6c4b7f9d84   0         0         0       9d

NAME                                READY   STATUS    RESTARTS   AGE
pod/payments-api-7d9f4c8b5c-2kq7z   1/1     Running   0          12m
pod/payments-api-7d9f4c8b5c-9wxvn   1/1     Running   0          12m
pod/payments-api-7d9f4c8b5c-hj4tp   1/1     Running   0          11m
pod/payments-api-7d9f4c8b5c-vn8rq   1/1     Running   0          11m

$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z -o jsonpath='{.metadata.ownerReferences}' | jq
[
  {
    "apiVersion": "apps/v1",
    "kind": "ReplicaSet",
    "name": "payments-api-7d9f4c8b5c",
    "uid": "0a4f...c31",
    "controller": true,
    "blockOwnerDeletion": true
  }
]
```

El sufijo `7d9f4c8b5c` es el **pod-template-hash**: un hash de la plantilla del Pod, agregado tanto al nombre del ReplicaSet como a las etiquetas del Pod. Es cómo un Deployment distingue las réplicas "viejas" de las "nuevas" durante un rollout, y es por eso que el ReplicaSet viejo se conserva con 0 réplicas — ese objeto *es* el destino del rollback.

El **borrado en cascada** está gobernado por `ownerReferences` + finalizadores:

```console
$ kubectl delete deploy payments-api --cascade=background   # default: GC deletes children async
$ kubectl delete deploy payments-api --cascade=foreground    # blocks until children are gone
$ kubectl delete deploy payments-api --cascade=orphan        # keeps ReplicaSet+Pods running
```

`--cascade=orphan` es la palanca de emergencia para "desacoplar la carga de trabajo de un controlador roto sin cortar el tráfico".

---

## 5. El Pod: un manifiesto de producción completo

Esta es la especificación de Pod de referencia de la que derivan todos los demás manifiestos de este material. No se omite nada.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payments-api-reference
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  # --- scheduling -----------------------------------------------------------
  serviceAccountName: payments-api
  automountServiceAccountToken: false        # explicit: this Pod does not call the API
  nodeSelector:
    kubernetes.io/os: linux
    node.kubernetes.io/instance-type: m6i.2xlarge
  tolerations:
    - key: workload
      operator: Equal
      value: payments
      effect: NoSchedule
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: payments-api
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: payments-api

  # --- security -------------------------------------------------------------
  securityContext:                            # pod-level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault

  # --- lifecycle ------------------------------------------------------------
  restartPolicy: Always                       # Always | OnFailure | Never
  terminationGracePeriodSeconds: 45
  dnsPolicy: ClusterFirst

  # --- init containers ------------------------------------------------------
  initContainers:
    - name: wait-for-db
      image: registry.internal/base/postgres-client:16.3
      command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          until pg_isready -h "$DB_HOST" -p 5432 -t 3; do
            echo "waiting for ${DB_HOST}:5432 ..." >&2
            sleep 2
          done
          echo "database reachable"
      env:
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: payments-api-config
              key: DB_HOST
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

    # native sidecar: an initContainer with restartPolicy Always starts before the
    # app containers, keeps running alongside them, and is terminated last.
    # (beta and on by default since v1.29, GA in v1.33)
    - name: log-forwarder
      image: registry.internal/observability/fluent-bit:3.1.6
      restartPolicy: Always
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
        - name: fluentbit-config
          mountPath: /fluent-bit/etc
          readOnly: true
      resources:
        requests: { cpu: 50m,  memory: 64Mi }
        limits:   { cpu: 200m, memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

  # --- application container ------------------------------------------------
  containers:
    - name: api
      image: registry.internal/payments-api:1.15.0
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        - name: metrics
          containerPort: 9090
          protocol: TCP

      args: ["--config=/etc/payments/config.yaml", "--log-format=json"]

      env:
        - name: POD_NAME
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef: { fieldPath: metadata.namespace }
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
        - name: POD_IP
          valueFrom:
            fieldRef: { fieldPath: status.podIP }
        - name: MEM_LIMIT_BYTES
          valueFrom:
            resourceFieldRef:
              containerName: api
              resource: limits.memory
              divisor: "1"
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: payments-db
              key: password
      envFrom:
        - configMapRef:
            name: payments-api-config

      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
          ephemeral-storage: "1Gi"
        limits:
          cpu: "2"
          memory: "512Mi"          # == request → predictable OOM boundary
          ephemeral-storage: "2Gi"

      startupProbe:                 # protects a slow JVM/dotnet start from liveness
        httpGet: { path: /healthz/startup, port: http }
        periodSeconds: 5
        failureThreshold: 60        # up to 5 min to become live
      livenessProbe:                # "is the process wedged?" → restart
        httpGet: { path: /healthz/live, port: http }
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      readinessProbe:               # "should it receive traffic?" → endpoint churn
        httpGet: { path: /healthz/ready, port: http }
        periodSeconds: 5
        timeoutSeconds: 2
        successThreshold: 1
        failureThreshold: 2

      lifecycle:
        preStop:
          exec:
            # Bridge the async gap between endpoint removal and SIGTERM.
            command: ["/bin/sh", "-c", "sleep 10"]

      volumeMounts:
        - name: config
          mountPath: /etc/payments
          readOnly: true
        - name: tls
          mountPath: /etc/payments/tls
          readOnly: true
        - name: applogs
          mountPath: /var/log/app
        - name: tmp
          mountPath: /tmp

      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

  # --- volumes --------------------------------------------------------------
  volumes:
    - name: config
      configMap:
        name: payments-api-files
        defaultMode: 0444
    - name: tls
      secret:
        secretName: payments-api-tls
        defaultMode: 0400
    - name: fluentbit-config
      configMap:
        name: fluent-bit-config
    - name: applogs
      emptyDir:
        sizeLimit: 512Mi
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
```

### 5.1 Ciclo de vida: fases vs condiciones vs estados de contenedor

Tres máquinas de estado ortogonales que la gente confunde habitualmente.

| Capa | Valores | Significado |
|---|---|---|
| `status.phase` | `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown` | Grueso, **nunca** una señal de salud. Un Pod en `CrashLoopBackOff` está en fase `Running`. |
| `status.conditions` | `PodScheduled`, `PodReadyToStartContainers`, `Initialized`, `ContainersReady`, `Ready` | La progresión real. `Ready=False` es lo que lo saca de los endpoints del Service. |
| `containerStatuses[].state` | `waiting{reason}`, `running{startedAt}`, `terminated{exitCode,reason}` | La verdad por contenedor: `ImagePullBackOff`, `CrashLoopBackOff`, `OOMKilled` viven acá. |

```console
$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z \
    -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"\t"}{.reason}{"\n"}{end}'
PodReadyToStartContainers=True
Initialized=True
Ready=True
ContainersReady=True
PodScheduled=True
```

### 5.2 Probes — la tabla semántica que la gente se equivoca

| Probe | Acción ante fallo | Implementación correcta | Error clásico |
|---|---|---|---|
| `startupProbe` | Deshabilita a las otras dos hasta que pase una vez | Chequeo barato de "el proceso está arriba" con un `failureThreshold` generoso | Omitirlo, y después poner un `initialDelaySeconds` enorme en liveness — lo que también retrasa los reinicios para siempre |
| `livenessProbe` | **Mata el contenedor** (reinicio, backoff) | Puramente local: bucle de eventos responsivo, sin deadlock. **Sin chequeos de dependencias.** | Chequear la base de datos → un pestañeo de la DB reinicia todas las réplicas simultáneamente y convierte una degradación en una caída |
| `readinessProbe` | Saca el Pod de **todos** los endpoints de Service | Puede chequear dependencias duras; debe poder volver a sano | Hacerlo idéntico a liveness, de modo que el Pod nunca descarga tráfico con elegancia |

`terminationGracePeriodSeconds` puede sobrescribirse por probe (`livenessProbe.terminationGracePeriodSeconds`) para que un proceso trabado reciba SIGKILL rápido sin acortar el apagado elegante de uno sano.

### 5.3 Clases de QoS y orden de desalojo

QoS es **derivada**, nunca declarada:

| Clase | Condición | Comportamiento bajo presión del nodo | `oom_score_adj` |
|---|---|---|---|
| `Guaranteed` | Cada contenedor fija cpu **y** memoria, con `requests == limits` | Desalojado último | −997 |
| `Burstable` | Al menos un request fijado, pero no totalmente igual a los limits | Desalojado después de BestEffort, primero el que más excede sus requests | 2–999 (escalado) |
| `BestEffort` | Sin requests ni limits en ningún lado | **Desalojado primero** | 1000 |

```console
$ kubectl get pods -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName
NAME                            QOS         NODE
payments-api-7d9f4c8b5c-2kq7z   Burstable   worker-03
payments-worker-5f7c9d4b6-x8k2p Guaranteed  worker-01
debug-shell                     BestEffort  worker-05
```

**Regla de producción:** fijá siempre el request de `memory` == limit (la memoria es incompresible — exceder el límite es una muerte por OOM instantánea, así que el "burst" es una ficción), y fijá un request de `cpu` pero considerá omitir el limit de `cpu` para servicios sensibles a la latencia, porque el estrangulamiento por cuota CFS produce picos de latencia de cola incluso cuando el nodo está ocioso. Eso produce deliberadamente `Burstable`, y ese es el compromiso correcto para una API que atiende peticiones.

---

## 6. Deployments y rollouts

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  annotations:
    kubernetes.io/change-cause: "release 1.15.0 — idempotent refund handler (JIRA PAY-4192)"
spec:
  replicas: 4
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  minReadySeconds: 15
  selector:
    matchLabels:                       # IMMUTABLE — identity only
      app.kubernetes.io/name: payments-api
      app.kubernetes.io/component: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                      # absolute values beat percentages at low replica counts
      maxUnavailable: 0                # zero-downtime: never dip below `replicas`
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/component: api
        app.kubernetes.io/version: "1.15.0"
      annotations:
        # forces a rollout when the ConfigMap content changes
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543a1e2c3d4b5f6a7b8c9d0e1f2a3b4c5d6"
    spec:
      serviceAccountName: payments-api
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: registry.internal/payments-api:1.15.0
          ports:
            - { name: http, containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          envFrom:
            - configMapRef: { name: payments-api-config }
            - secretRef:    { name: payments-api-secrets }
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits:   { memory: 512Mi }
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              exec: { command: ["/bin/sh", "-c", "sleep 10"] }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 64Mi }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments
spec:
  minAvailable: 3                      # or maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
      app.kubernetes.io/component: api
```

### 6.1 Compromisos de las estrategias de rollout

| Estrategia | Tiempo fuera de servicio | Capacidad extra | Solapamiento de versiones | Velocidad de rollback | Cuándo |
|---|---|---|---|---|---|
| `Recreate` | Caída total | 0 | Ninguno | Lenta (reinicio completo) | Singleton con volumen RWO; actualización incompatible de esquema |
| `RollingUpdate` `maxUnavailable:0, maxSurge:1` | Ninguno | +1 Pod | Sí — N y N+1 sirven simultáneamente | Rápida (se retiene el RS viejo) | **Predeterminado para HTTP sin estado** |
| `RollingUpdate` `maxUnavailable:1, maxSurge:0` | Caída de capacidad | 0 | Sí | Rápida | El clúster está restringido en capacidad / limitado por cuota |
| Blue-green (dos Deployments + cambio del selector del Service) | Ninguno | 2× | No | Instantánea (volver a cambiar) | Cambio incompatible del protocolo de cable |
| Canary (segundo Deployment, selector de Service compartido) | Ninguno | +k Pods | Sí | Rápida | Cambio riesgoso que necesita validación con tráfico real |

La consecuencia de *cualquier* estrategia progresiva es el **solapamiento de versiones**: tu API y el esquema de tu base de datos deben ser retrocompatibles durante toda la duración del rollout. Este es el patrón de migración expand/contract, y es una restricción de diseño impuesta por el orquestador, no una práctica opcional.

### 6.2 Conducir y observar un rollout

```console
$ kubectl set image deployment/payments-api api=registry.internal/payments-api:1.15.0
deployment.apps/payments-api image updated

$ kubectl annotate deployment/payments-api \
    kubernetes.io/change-cause="release 1.15.0 — idempotent refund handler (PAY-4192)" --overwrite
deployment.apps/payments-api annotated

$ kubectl rollout status deployment/payments-api --timeout=300s
Waiting for deployment "payments-api" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 1 old replicas are pending termination...
deployment "payments-api" successfully rolled out

$ echo $?
0
```

`kubectl rollout status` sale con código distinto de cero ante un timeout o ante una condición `Progressing` fallida — **esa es tu compuerta de despliegue en CI**. Nunca `kubectl apply && exit 0`.

```console
$ kubectl rollout history deployment/payments-api
deployment.apps/payments-api
REVISION  CHANGE-CAUSE
7         release 1.14.2 — connection pool tuning (PAY-4088)
8         release 1.15.0 — idempotent refund handler (PAY-4192)

$ kubectl rollout history deployment/payments-api --revision=7 | head -12
deployment.apps/payments-api with revision #7
Pod Template:
  Labels:  app.kubernetes.io/component=api
           app.kubernetes.io/name=payments-api
           app.kubernetes.io/version=1.14.2
           pod-template-hash=6c4b7f9d84
  Containers:
   api:
    Image:  registry.internal/payments-api:1.14.2
    Ports:  8080/TCP, 9090/TCP

$ kubectl rollout undo deployment/payments-api --to-revision=7
deployment.apps/payments-api rolled back
```

Freno de emergencia para un rollout que sale mal a mitad de vuelo:

```console
$ kubectl rollout pause deployment/payments-api
deployment.apps/payments-api paused
# ... investigate; the partially-updated state is frozen, both versions serving ...
$ kubectl rollout resume deployment/payments-api    # or: kubectl rollout undo ...
deployment.apps/payments-api resumed
```

Un rollout estancado se manifiesta como una condición, no como una línea de log:

```console
$ kubectl get deploy payments-api -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Available=False (MinimumReplicasUnavailable)
Progressing=False (ProgressDeadlineExceeded)
```

`ProgressDeadlineExceeded` significa: transcurrió `progressDeadlineSeconds` sin que una sola réplica nueva llegara a estar disponible. **No** hace rollback automáticamente — Kubernetes no tiene rollback automático. Tu pipeline debe llamar a `kubectl rollout undo`.

---

## 7. Services, endpoints y DNS

Un Service es una **identidad virtual estable** al frente de un conjunto cambiante de Pods. El controlador de Service asigna una `clusterIP` del CIDR de servicios; el controlador de EndpointSlice observa los Pods que coinciden con `spec.selector` y publica los que están **ready**; `kube-proxy` en cada nodo programa el plano de datos para hacer DNAT de la ClusterIP a una IP de Pod real.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
spec:
  type: ClusterIP
  selector:                             # matches Pod labels, NOT the Deployment
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  ports:
    - name: http
      port: 80                          # the ClusterIP port
      targetPort: http                  # named container port — survives port renumbering
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
  sessionAffinity: None
  internalTrafficPolicy: Cluster
---
# Headless Service: no ClusterIP, DNS returns one A record per ready Pod.
# Required by StatefulSets and by client-side load balancing (gRPC).
apiVersion: v1
kind: Service
metadata:
  name: payments-api-headless
  namespace: payments
spec:
  clusterIP: None
  publishNotReadyAddresses: false
  selector:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  ports:
    - { name: http, port: 8080, targetPort: http }
```

### 7.1 Tipos de Service

| Tipo | Alcanzable desde | Asigna | Costo / advertencias |
|---|---|---|---|
| `ClusterIP` | Solo dentro del clúster | IP virtual | Predeterminado; invisible desde afuera. |
| `NodePort` | `<AnyNodeIP>:30000–32767` | ClusterIP + un puerto en **cada** nodo | Proliferación de puertos, sin terminación TLS, el cliente debe conocer las IPs de los nodos. Aceptable on-prem detrás de un LB externo. |
| `LoadBalancer` | VIP de LB público/privado | ClusterIP + NodePort + LB de nube | Un LB de nube **por Service** — el generador de costos que empuja a los equipos hacia Ingress/Gateway. |
| `ExternalName` | Solo CNAME de DNS | Nada | Sin proxy, sin remapeo de puertos; se usa para dar alias a hosts externos. |
| Headless (`clusterIP: None`) | DNS interno del clúster | Nada | El cliente hace su propio balanceo de carga; obligatorio para la identidad estable de StatefulSet. |

Compromiso de `externalTrafficPolicy` para `NodePort`/`LoadBalancer`:

| Valor | IP de origen del cliente | Salto extra | Balanceo |
|---|---|---|---|
| `Cluster` (predeterminado) | **Perdida** (SNAT) | Sí — puede saltar a otro nodo | Parejo |
| `Local` | Preservada | No | Desparejo — proporcional a los Pods por nodo; los nodos con 0 Pods fallan el chequeo de salud del LB |

### 7.2 Modos del plano de datos de kube-proxy

| Modo | Complejidad de reglas | Costo de actualización a escala | Notas |
|---|---|---|---|
| `iptables` | O(n) cadenas, coincidencia secuencial | Reescritura de tabla completa; segundos de latencia con ~5k Services | Predeterminado de larga data. |
| `ipvs` | Tabla hash, coincidencia O(1) | Incremental | Requiere los módulos de kernel `ip_vs`; varios algoritmos de planificación (`rr`, `lc`, `dh`). |
| `nftables` | Mapas de veredicto, O(1) | Incremental, atómico | Reemplazo moderno del backend iptables; GA en v1.33. |

Nada de esto cambia tus manifiestos — ese es el punto de la abstracción. Cambia tu *respuesta a incidentes*, porque "el Service existe pero el tráfico no fluye" se diagnostica distinto en cada modo.

### 7.3 EndpointSlices — dónde vive la verdad

```console
$ kubectl get endpointslices -l kubernetes.io/service-name=payments-api
NAME                 ADDRESSTYPE   PORTS       ENDPOINTS                                   AGE
payments-api-x4m9t   IPv4          8080,9090   10.244.2.17,10.244.1.9,10.244.3.22 + 1 more 9d

$ kubectl get endpointslice payments-api-x4m9t -o yaml | sed -n '1,30p'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
addressType: IPv4
endpoints:
- addresses:
  - 10.244.2.17
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: worker-03
  targetRef:
    kind: Pod
    name: payments-api-7d9f4c8b5c-2kq7z
    namespace: payments
  zone: eu-west-1a
```

`ENDPOINTS: <none>` es, con diferencia, la causa raíz más común de "el Service está roto", y siempre significa una de exactamente tres cosas: (a) el selector no coincide con ningún Pod, (b) los Pods coincidentes no están `Ready`, (c) `targetPort` nombra un puerto que el contenedor no declara.

### 7.4 DNS

`CoreDNS` sirve `<service>.<namespace>.svc.cluster.local`. Dentro de un Pod:

```console
$ kubectl run dnstest --rm -it --image=registry.internal/base/netshoot:0.13 --restart=Never -- bash
If you don't see a command prompt, try pressing enter.

dnstest:~# cat /etc/resolv.conf
search payments.svc.cluster.local svc.cluster.local cluster.local eu-west-1.compute.internal
nameserver 10.96.0.10
options ndots:5

dnstest:~# dig +short payments-api.payments.svc.cluster.local
10.96.211.44

dnstest:~# dig +short payments-api-headless.payments.svc.cluster.local
10.244.1.9
10.244.2.17
10.244.3.22
10.244.0.31

dnstest:~# curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://payments-api/healthz/ready
200 0.004221s
```

`options ndots:5` significa que cualquier nombre con menos de 5 puntos se prueba primero contra cada entrada de `search` — así que `api.example.com` (2 puntos) genera cuatro búsquedas fallidas antes de la correcta. En cargas de trabajo sensibles a la latencia, o bien usá un nombre totalmente calificado con un punto final (`api.example.com.`) o bajá `ndots` vía `spec.dnsConfig`.

---

## 8. Configuración: ConfigMaps y Secrets

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-config
  namespace: payments
immutable: false
data:                                   # env-style keys, consumed via envFrom
  LOG_LEVEL: "info"
  DB_HOST: "postgres-primary.data.svc.cluster.local"
  DB_PORT: "5432"
  DB_MAX_CONNS: "40"
  FEATURE_IDEMPOTENT_REFUNDS: "true"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-files
  namespace: payments
immutable: true                         # rev-locked; a change means a new object name
data:
  config.yaml: |
    server:
      addr: ":8080"
      readTimeout: 5s
      writeTimeout: 10s
      shutdownGracePeriod: 30s
    telemetry:
      metricsAddr: ":9090"
      tracing:
        enabled: true
        sampleRatio: 0.05
    refunds:
      idempotencyWindow: 24h
      maxRetries: 3
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-api-secrets
  namespace: payments
type: Opaque
stringData:                             # write-only convenience: server stores base64 in .data
  DB_PASSWORD: "PLACEHOLDER_INJECTED_BY_EXTERNAL_SECRETS"
  HMAC_SIGNING_KEY: "PLACEHOLDER_INJECTED_BY_EXTERNAL_SECRETS"
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-api-tls
  namespace: payments
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==   # truncated for brevity
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCg==
```

### 8.1 Mecanismos de inyección comparados

| Mecanismo | ¿Actualización en vivo? | ¿Visible en `/proc/<pid>/environ`? | ¿Seguro con `subPath`? | Usar para |
|---|---|---|---|---|
| `env.valueFrom.configMapKeyRef` | **No** — fijado al iniciar el contenedor | Sí | n/a | Escalares pequeños donde reiniciar al cambiar es aceptable |
| `envFrom.configMapRef` | **No** | Sí | n/a | Configuración 12-factor a granel |
| `env.valueFrom.secretKeyRef` | **No** | **Sí — se filtra en volcados de fallo y en el `kubectl describe` de la spec** | n/a | Evitar para secretos de alto valor |
| **Volumen** de ConfigMap | Sí (sincronización del kubelet, ~60 s + TTL de caché) | No | **No** — los montajes con `subPath` nunca se actualizan | Archivos de configuración con recarga por SIGHUP |
| **Volumen** de Secret | Sí | No | No | **Preferido para secretos**: modo de archivo 0400, respaldado por tmpfs |
| Volumen proyectado | Sí | No | No | Combinar CM + Secret + downward API + token de SA en un solo directorio |

**La trampa de `subPath`** merece enunciarse explícitamente porque produce una obsolescencia silenciosa y permanente: montar un `configMap` con `subPath: config.yaml` para colocar un único archivo dentro de un directorio existente evita el intercambio atómico de enlaces simbólicos del kubelet, así que el archivo se escribe una vez al iniciar el contenedor y **nunca se actualiza de nuevo**. Montá en cambio el volumen completo en un directorio dedicado.

**La trampa del Secret:** `data` es base64 — una *codificación*, no cifrado. Cualquiera con `get secrets` en el namespace tiene el texto plano, y por defecto etcd lo almacena en claro. Producción requiere (a) `EncryptionConfiguration` con un proveedor KMS en el API server, (b) RBAC que no otorgue `get`/`list` sobre `secrets` de forma amplia, y (c) un almacén de secretos externo (Vault, SM de nube) sincronizando hacia adentro.

### 8.2 Hacer que los cambios de configuración realmente se desplieguen

Dado que la configuración inyectada por entorno queda fijada al iniciar el contenedor, cambiar un ConfigMap **no hace nada** a los Pods en ejecución. Dos patrones correctos:

```console
# Pattern A — checksum annotation in the Pod template (works with any tooling)
$ CS=$(kubectl get cm payments-api-config -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1)
$ kubectl patch deployment payments-api --type=merge -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$CS\"}}}}}"
deployment.apps/payments-api patched

# Pattern B — immutable, content-addressed ConfigMap names (kustomize configMapGenerator)
#   payments-api-files-7t2gd94hbf  →  a new name is a new Pod template is a new rollout
```

El instrumento contundente, cuando ninguno de los dos está cableado:

```console
$ kubectl rollout restart deployment/payments-api
deployment.apps/payments-api restarted
```

Esto funciona estampando `kubectl.kubernetes.io/restartedAt` en la plantilla del Pod — una actualización progresiva normal, que respeta los PDB, no una tormenta de `delete pod`.

---

## 9. Cargas de trabajo por lotes y con estado

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payments-schema-migrate-1150
  namespace: payments
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 3
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400        # GC the Job object after 24 h
  podFailurePolicy:
    rules:
      - action: FailJob                 # a config error must not burn all retries
        onExitCodes:
          containerName: migrate
          operator: In
          values: [78]                  # EX_CONFIG
      - action: Ignore                  # preemption is not the workload's fault
        onPodConditions:
          - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never              # Never or OnFailure — Always is rejected
      serviceAccountName: payments-migrator
      containers:
        - name: migrate
          image: registry.internal/payments-migrate:1.15.0
          args: ["up", "--dsn=$(DSN)"]
          env:
            - name: DSN
              valueFrom:
                secretKeyRef: { name: payments-db, key: dsn }
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { memory: 256Mi }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: payments-reconcile
  namespace: payments
spec:
  schedule: "17 2 * * *"
  timeZone: "Europe/Madrid"             # stable since v1.27 — do not rely on node TZ
  concurrencyPolicy: Forbid             # Allow | Forbid | Replace
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  suspend: false
  jobTemplate:
    spec:
      backoffLimit: 2
      ttlSecondsAfterFinished: 604800
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: reconcile
              image: registry.internal/payments-reconcile:1.15.0
              resources:
                requests: { cpu: 500m, memory: 1Gi }
                limits:   { memory: 1Gi }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: payments-ledger
  namespace: payments
spec:
  serviceName: payments-ledger          # MUST be a headless Service
  replicas: 3
  podManagementPolicy: OrderedReady     # OrderedReady | Parallel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0                      # >0 → canary the highest ordinals only
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-ledger
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsNonRoot: true
        runAsUser: 10002
        fsGroup: 10002
      containers:
        - name: ledger
          image: registry.internal/payments-ledger:3.2.1
          ports:
            - { name: peer, containerPort: 7000 }
            - { name: client, containerPort: 7001 }
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: PEERS
              value: "payments-ledger-0.payments-ledger,payments-ledger-1.payments-ledger,payments-ledger-2.payments-ledger"
          readinessProbe:
            tcpSocket: { port: client }
            periodSeconds: 5
          resources:
            requests: { cpu: "2", memory: 8Gi }
            limits:   { cpu: "4", memory: 8Gi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/ledger }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-nvme
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: Service
metadata:
  name: payments-ledger
  namespace: payments
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: payments-ledger
  ports:
    - { name: peer, port: 7000 }
    - { name: client, port: 7001 }
```

**Hechos operativos de StatefulSet que muerden:** los PVC creados a partir de `volumeClaimTemplates` **no** se eliminan cuando se elimina el StatefulSet (a menos que `persistentVolumeClaimRetentionPolicy` diga lo contrario) — esto es protección de datos deliberada, y también es por eso que un "redespliegue limpio" reengancha silenciosamente datos viejos. Reducir la escala tampoco elimina los PVC; volver a escalar hacia arriba los reutiliza.

```console
$ kubectl get pods -l app.kubernetes.io/name=payments-ledger -o wide
NAME                 READY   STATUS    RESTARTS   AGE   IP            NODE
payments-ledger-0    1/1     Running   0          6d    10.244.1.44   worker-01
payments-ledger-1    1/1     Running   0          6d    10.244.2.51   worker-03
payments-ledger-2    1/1     Running   0          6d    10.244.3.19   worker-05

$ kubectl get pvc -l app.kubernetes.io/name=payments-ledger
NAME                      STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-payments-ledger-0    Bound    pvc-9a1f..   200Gi      RWO            fast-nvme      6d
data-payments-ledger-1    Bound    pvc-3c8b..   200Gi      RWO            fast-nvme      6d
data-payments-ledger-2    Bound    pvc-71de..   200Gi      RWO            fast-nvme      6d
```

---

## 10. Escalado

```console
# manual, imperative
$ kubectl scale deployment/payments-api --replicas=8
deployment.apps/payments-api scaled

# guarded: only act if the current value is what you believe it is
$ kubectl scale deployment/payments-api --current-replicas=8 --replicas=12
deployment.apps/payments-api scaled
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 4
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70        # % of the CPU *request*, not the limit
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "30"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
        - { type: Pods,    value: 4,   periodSeconds: 30 }
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300   # damp flapping; look back 5 min
      policies:
        - { type: Percent, value: 25, periodSeconds: 60 }
```

```console
$ kubectl get hpa payments-api
NAME           REFERENCE                 TARGETS                        MINPODS  MAXPODS  REPLICAS  AGE
payments-api   Deployment/payments-api   cpu: 58%/70%, 21/30 (avg)      4        40       6         9d
```

**Interacción crítica:** si un HPA es dueño de `spec.replicas`, tu manifiesto de GitOps **no** debe declarar también `replicas`, o ambos pelearán para siempre. Bajo server-side apply esto aparece como un conflicto de propiedad de campo (bueno). Bajo client-side apply aparece como oscilación de réplicas en cada reconciliación (malo). Omití `replicas` del manifiesto siempre que un HPA lo tenga como objetivo.

`averageUtilization` es un porcentaje del **request**. Un Pod con `requests.cpu: 100m` y sin limit, consumiendo 400m, reporta 400% y escalará hacia afuera agresivamente — una razón más por la que los requests deben ser honestos.

---

## 11. Verificación y diagnóstico de fallos

### 11.1 El bucle de triaje de cuatro comandos

```console
$ kubectl get pods -o wide                      # 1. what is the coarse state?
$ kubectl describe pod <name>                   # 2. events + probe + scheduling detail
$ kubectl logs <name> -c <ctr> --previous       # 3. what did the DEAD container say?
$ kubectl events --for pod/<name> --types=Warning   # 4. cluster-level narrative
```

`--previous` es el que la gente olvida. En un `CrashLoopBackOff` el contenedor actual todavía no arrancó, así que `kubectl logs` sin `--previous` no devuelve nada útil, y el stack trace real está en la instancia terminada.

```console
$ kubectl get pods -n payments -o wide
NAME                            READY   STATUS             RESTARTS      AGE   IP            NODE        NOMINATED NODE   READINESS GATES
payments-api-6f8c4d9b7-4h2mv    0/1     CrashLoopBackOff   6 (94s ago)   11m   10.244.2.31   worker-03   <none>           <none>
payments-api-6f8c4d9b7-9pk3s    1/1     Running            0             11m   10.244.1.18   worker-01   <none>           <none>
payments-worker-58d9f7c4-tzn8q  0/1     Pending            0             4m    <none>        <none>      <none>           <none>
payments-batch-b7f2x            0/1     ImagePullBackOff   0             2m    10.244.3.7    worker-05   <none>           <none>

$ kubectl describe pod payments-api-6f8c4d9b7-4h2mv -n payments | tail -22
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Wed, 03 Sep 2026 09:41:02 +0200
      Finished:     Wed, 03 Sep 2026 09:41:03 +0200
    Ready:          False
    Restart Count:  6
Events:
  Type     Reason     Age                   From               Message
  ----     ------     ----                  ----               -------
  Normal   Scheduled  11m                   default-scheduler  Successfully assigned payments/payments-api-6f8c4d9b7-4h2mv to worker-03
  Normal   Pulled     11m                   kubelet            Container image "registry.internal/payments-api:1.15.1" already present on machine
  Warning  BackOff    91s (x38 over 10m)    kubelet            Back-off restarting failed container api in pod payments-api-6f8c4d9b7-4h2mv

$ kubectl logs payments-api-6f8c4d9b7-4h2mv -n payments --previous
{"level":"fatal","ts":"2026-09-03T07:41:03Z","msg":"config load failed",
 "error":"open /etc/payments/config.yaml: no such file or directory"}
```

Causa raíz encontrada en tres comandos: la release subió la versión de la imagen pero el manifiesto perdió el `volumeMount` de `config`.

### 11.2 Catálogo de fallos

| Síntoma (`STATUS` / condición) | Capa | Causas más probables | Diagnóstico |
|---|---|---|---|
| `Pending`, sin `nodeName` | Scheduler | CPU/memoria insuficiente; ningún nodo coincide con `nodeSelector`/afinidad; taint no tolerado; PVC sin vincular; distribución topológica insatisfacible | `kubectl describe pod` → el mensaje `FailedScheduling` nombra el predicado; `kubectl describe node \| grep -A5 Allocated` |
| `Pending` con `nodeName` fijado | kubelet | Nodo no listo; descarga de imagen en curso; el CNI no asigna IPs | `kubectl describe node <n>`; `kubectl get pod -o jsonpath='{.status.conditions}'` |
| `ImagePullBackOff` / `ErrImagePull` | Registro | Tag/nombre incorrecto; registro privado sin `imagePullSecrets`; límite de tasa; arquitectura incorrecta | Eventos de `kubectl describe pod`; `kubectl get sa <sa> -o yaml` para ver `imagePullSecrets` |
| `ErrImageNeverPull` | Política | `imagePullPolicy: Never` y la imagen no está en ese nodo | Precargá la imagen o cambiá la política |
| `CreateContainerConfigError` | kubelet | La **clave** o el objeto ConfigMap/Secret referenciado no existe | `kubectl describe pod`; `kubectl get cm,secret -n <ns>` |
| `CreateContainerError` | Runtime | `command`/`workingDir` incorrecto; `runAsNonRoot` con una imagen que solo funciona como root; rootfs de solo lectura sobre el que la app escribe | Eventos + `kubectl logs --previous` |
| `CrashLoopBackOff` | App | Configuración incorrecta, dependencia faltante, pánico al arrancar, el PID 1 sale de inmediato | `kubectl logs --previous`; revisá el código de salida en `describe` |
| `OOMKilled` (salida 137) | cgroup del kernel | Límite de memoria por debajo del conjunto de trabajo real; heap que no considera el límite (JVM `-XX:MaxRAMPercentage`) | `kubectl get pod -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'` |
| `Running` pero `0/1 READY` | Probe | `readinessProbe` fallando; puerto/ruta incorrectos; app más lenta de lo que el probe permite | `describe` → eventos `Unhealthy`; `kubectl exec` + `curl` a la ruta del probe localmente |
| `Evicted` | Presión del nodo | Umbrales de `memory.available`/`nodefs`; QoS BestEffort | `kubectl describe node` → `Conditions: MemoryPressure/DiskPressure` |
| `Terminating` para siempre | API/finalizadores | Finalizador no removido; kubelet que no responde; desmontaje de volumen atascado | `kubectl get pod -o jsonpath='{.metadata.finalizers}'`; último recurso `--force --grace-period=0` (**puede duplicar la ejecución de un Pod de StatefulSet — riesgo de datos**) |
| Service `ENDPOINTS: <none>` | Service | Selector que no coincide; sin Pods Ready; `targetPort` nombra un puerto inexistente | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` |
| Conexión rechazada vía Service, funciona vía IP del Pod | Plano de datos | `targetPort` ≠ puerto del contenedor; `NetworkPolicy` denegando; kube-proxy no saludable | `kubectl port-forward` al Pod vs al Service para bisecar |
| `Init:0/2`, `Init:Error`, `Init:CrashLoopBackOff` | Init container | La dependencia nunca llega a estar lista | `kubectl logs <pod> -c <init-container>` |

### 11.3 Meterse dentro de un Pod en ejecución (o no saludable)

```console
$ kubectl exec -it payments-api-7d9f4c8b5c-2kq7z -c api -- /bin/sh
/ $ wget -qO- http://127.0.0.1:8080/healthz/ready ; echo
{"status":"ok","db":"ok","cache":"ok"}
/ $ exit
```

Cuando la imagen es distroless y no tiene shell — como debería serlo toda imagen de producción endurecida — usá un **contenedor efímero**:

```console
$ kubectl debug -it payments-api-7d9f4c8b5c-2kq7z \
    --image=registry.internal/base/netshoot:0.13 \
    --target=api --profile=general -- bash
Targeting container "api". If you don't see processes from this container it may be
because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-p9x2q.

debugger:~# ss -lntp
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096          0.0.0.0:8080        0.0.0.0:*      users:(("payments-api",pid=1,fd=7))
LISTEN  0       4096          0.0.0.0:9090        0.0.0.0:*      users:(("payments-api",pid=1,fd=9))

debugger:~# curl -s localhost:8080/healthz/ready
{"status":"ok","db":"ok","cache":"ok"}
```

`--target=api` comparte el **espacio de nombres de procesos** del contenedor objetivo, así que ves sus PIDs, su `/proc` y sus sockets a la escucha. El contenedor efímero se agrega al Pod en ejecución — no lo reinicia, y no puede ser removido (desaparece con el Pod).

Copiar un Pod para depurar uno en crash-loop sin perturbar el tráfico de producción:

```console
$ kubectl debug payments-api-6f8c4d9b7-4h2mv --copy-to=api-debug --container=api -- sleep infinity
$ kubectl exec -it api-debug -c api -- sh      # same volumes/env, but the entrypoint is replaced
```

Y para depurar el nodo mismo:

```console
$ kubectl debug node/worker-03 -it --image=registry.internal/base/netshoot:0.13
Creating debugging pod node-debugger-worker-03-h7k2n with container debugger on node worker-03.
debugger:~# chroot /host journalctl -u kubelet -n 50 --no-pager
```

### 11.4 Acceso local sin exponer nada

```console
$ kubectl port-forward svc/payments-api 8080:80 -n payments
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
Handling connection for 8080

# in another shell
$ curl -s localhost:8080/metrics | grep -m3 '^http_requests_total'
http_requests_total{code="200",method="GET",path="/healthz/ready"} 41823
http_requests_total{code="200",method="POST",path="/v1/payments"} 90114
http_requests_total{code="409",method="POST",path="/v1/refunds"} 27
```

`port-forward` a un **Service** elige un Pod de respaldo arbitrario y tuneliza hacia él — no balancea carga. Para bisecar un problema de "algunas peticiones fallan" tenés que redirigir a Pods individuales.

### 11.5 Presión de recursos y salud del nodo

```console
$ kubectl top nodes
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-01   3820m        47%    18942Mi         61%
worker-03   7104m        88%    29118Mi         94%
worker-05   1211m        15%    7440Mi          24%

$ kubectl top pods -n payments --sort-by=memory
NAME                            CPU(cores)   MEMORY(bytes)
payments-ledger-1               1902m        7811Mi
payments-ledger-0               1744m        7602Mi
payments-api-7d9f4c8b5c-2kq7z   410m         388Mi

$ kubectl describe node worker-03 | sed -n '/Allocated resources/,/Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                7250m (90%)   14200m (177%)
  memory             28Gi (92%)    30Gi (98%)
  ephemeral-storage  12Gi (14%)    24Gi (28%)
  pods               47            47
```

`kubectl top` requiere **metrics-server**; sin él obtenés `error: Metrics API not available`. Notá que `describe node` muestra **requests**, que es lo que usa el scheduler — un nodo con 90% solicitado pero 40% realmente usado está *lleno* en lo que respecta a la planificación. Esa brecha es la mayor fuente individual de desperdicio de costos del clúster.

### 11.6 Mantenimiento de nodos

```console
$ kubectl cordon worker-03
node/worker-03 cordoned

$ kubectl drain worker-03 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m
node/worker-03 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/node-exporter-x8k2f, kube-system/cilium-p4m9q
evicting pod payments/payments-api-7d9f4c8b5c-2kq7z
evicting pod payments/payments-ledger-1
error when evicting pods/"payments-ledger-1" -n "payments" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod payments/payments-ledger-1
pod/payments-api-7d9f4c8b5c-2kq7z evicted
pod/payments-ledger-1 evicted
node/worker-03 drained

$ kubectl uncordon worker-03
node/worker-03 uncordoned
```

El rechazo por PDB seguido de un reintento exitoso es el sistema funcionando correctamente: la API de desalojo se negó a romper el quórum hasta que un Pod de reemplazo estuvo Ready en otro lado. Un PDB que *nunca* puede satisfacerse (por ejemplo `minAvailable: 3` en un StatefulSet de 3 réplicas) convierte cada drenaje en un bucle infinito de reintentos — una causa común de actualizaciones de clúster atascadas.

### 11.7 Escalar hasta la API cruda

Cuando la salida de `kubectl` no alcanza, mirá el cable:

```console
$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z --v=8 2>&1 | grep -E 'GET|Response Status'
I0903 09:52:11.402  round_trippers.go:463] GET https://10.0.0.10:6443/api/v1/namespaces/payments/pods/payments-api-7d9f4c8b5c-2kq7z
I0903 09:52:11.418  round_trippers.go:570] HTTP Statistics: GetConnection 0 ms ... Duration 15 ms
I0903 09:52:11.418  round_trippers.go:577] Response Status: 200 OK in 15 milliseconds

$ kubectl auth can-i delete pods --namespace payments
no

$ kubectl auth can-i --list --namespace payments | head -5
Resources                     Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authorization.k8s.io   []      []               [create]
pods                          []                  []               [get list watch]
deployments.apps              []                  []               [get list watch patch update]
configmaps                    []                  []               [get list watch]

$ kubectl get --raw /healthz?verbose | head -6
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]informer-sync ok
[+]shutdown ok
```

Un `403 Forbidden` en la salida de `--v=8` es un problema de RBAC, no un problema de la aplicación — una distinción que ahorra horas.

---

## 12. Runbook de verificación de extremo a extremo

Una secuencia copiable y pegable que prueba que un despliegue está genuinamente sano, no solo "en verde en la interfaz".

```console
# 0. Confirm the target — the most common production accident is the wrong context.
$ kubectl config current-context
prod-eu-west-1
$ kubectl config view --minify -o jsonpath='{..namespace}'; echo
payments

# 1. Validate before touching the cluster.
$ kubectl apply -f deploy/ --dry-run=server >/dev/null && echo "admission OK"
admission OK
$ kubectl diff -f deploy/ ; echo "diff exit=$?"
diff exit=1                                # 1 == there are changes to apply

# 2. Apply with an owned field manager.
$ kubectl apply --server-side --field-manager=release-pipeline -f deploy/
configmap/payments-api-config serverside-applied
secret/payments-api-secrets serverside-applied
deployment.apps/payments-api serverside-applied
service/payments-api serverside-applied
poddisruptionbudget.policy/payments-api serverside-applied
horizontalpodautoscaler.autoscaling/payments-api serverside-applied

# 3. Gate on the rollout, not on the apply.
$ kubectl rollout status deployment/payments-api --timeout=600s
deployment "payments-api" successfully rolled out

# 4. Prove the ReplicaSet generation actually converged.
$ kubectl get deploy payments-api -o jsonpath=\
'{.metadata.generation} {.status.observedGeneration} {.status.updatedReplicas}/{.status.readyReplicas}/{.spec.replicas}'; echo
9 9 4/4/4

# 5. Prove the Service has real endpoints (the step everyone skips).
$ kubectl get endpointslices -l kubernetes.io/service-name=payments-api \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
10.244.1.9 ready=true
10.244.2.17 ready=true
10.244.3.22 ready=true
10.244.0.31 ready=true

# 6. Prove the running image is the one you intended.
$ kubectl get pods -l app.kubernetes.io/name=payments-api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
payments-api-7d9f4c8b5c-2kq7z  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-9wxvn  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-hj4tp  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-vn8rq  registry.internal/payments-api@sha256:c1f0...9ab3

# 7. Prove there were no restarts during the window.
$ kubectl get pods -l app.kubernetes.io/name=payments-api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
payments-api-7d9f4c8b5c-2kq7z  0
payments-api-7d9f4c8b5c-9wxvn  0
payments-api-7d9f4c8b5c-hj4tp  0
payments-api-7d9f4c8b5c-vn8rq  0

# 8. Prove it answers real traffic.
$ kubectl run smoke --rm -i --restart=Never --image=registry.internal/base/curl:8.9 -- \
    curl -sf -o /dev/null -w '%{http_code}\n' http://payments-api.payments.svc.cluster.local/healthz/ready
200
pod "smoke" deleted

# 9. Confirm nothing is warning at the cluster level.
$ kubectl events -n payments --types=Warning --for deployment/payments-api
No events found.
```

Los pasos 4–7 son la diferencia entre "el comando de despliegue tuvo éxito" y "el despliegue funcionó". `observedGeneration == generation` prueba que el controlador procesó tu cambio en lugar de estar rezagado; el digest de imageID prueba que un tag mutable no resolvió a algo inesperado en un nodo.

---

## 13. Trampas operativas que vale la pena interiorizar

- **`kubectl delete pod` no es un arreglo.** Bajo un Deployment es un reemplazo disparado por el controlador; el defecto subyacente del manifiesto persiste y vuelve en la siguiente ronda de planificación. Bajo un StatefulSet con `--force --grace-period=0` puede crear un segundo escritor en split-brain.
- **Un namespace atascado en `Terminating`** es prácticamente siempre un finalizador en un recurso hijo (frecuentemente un APIService agregado roto o un CRD cuyo operador ya no está): `kubectl get namespace <ns> -o jsonpath='{.spec.finalizers}'` y `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns> --show-kind --ignore-not-found`.
- **`kubectl get all` no obtiene todo.** Cubre una lista corta cableada en el código (pods, services, daemonsets, deployments, replicasets, statefulsets, jobs, cronjobs). ConfigMaps, Secrets, PVCs, Ingresses, NetworkPolicies y todo CRD quedan excluidos. Nunca lo uses para verificar una limpieza.
- **Los eventos expiran.** La retención predeterminada es de una hora. Si el incidente es más viejo, los eventos ya no están — por eso los fallos de probes y las muertes por OOM deben exportarse a tu backend de monitoreo, no leerse desde `describe`.
- **Los tags `latest` más `imagePullPolicy: IfNotPresent`** producen nodos ejecutando código distinto con un manifiesto idéntico. Desplegá por digest, o como mínimo por tag semver inmutable.
- **Un `preStop` con sleep no es superstición.** La remoción del endpoint (API → EndpointSlice → kube-proxy en cada nodo) y la entrega de SIGTERM son concurrentes y con condición de carrera. Sin un breve retardo en `preStop`, una fracción de las conexiones en vuelo golpea un socket que ya se está cerrando — el clásico "pico de 5xx solo durante los despliegues".
- **`kubectl get -w` no es duradero.** Un watch puede ser cerrado por el API server en cualquier momento (`too old resource version`); `kubectl` lo reinicia de forma transparente, pero los scripts que parsean el flujo deben manejar el re-listado.
- **Formatos de salida que deberías usar por reflejo:** `-o wide`, `-o yaml`, `-o json | jq`, `-o jsonpath=...`, `-o custom-columns=...`, `--show-labels`, `--sort-by=.metadata.creationTimestamp`, `--field-selector`, `-A` (todos los namespaces).

---

## 14. Referencias

**LPI**
- Exam 701-100 objectives (DevOps Tools Engineer, v2.0) — https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview — https://www.lpi.org/our-certifications/devops-overview/

**Kubernetes — kubectl y la API**
- kubectl reference — https://kubernetes.io/docs/reference/kubectl/
- kubectl command reference (generated) — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
- kubectl Quick Reference (cheat sheet) — https://kubernetes.io/docs/reference/kubectl/quick-reference/
- Declarative management with configuration files — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Organizing cluster access with kubeconfig — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Version skew policy — https://kubernetes.io/releases/version-skew-policy/

**Objetos, etiquetas y namespaces**
- Kubernetes objects — https://kubernetes.io/docs/concepts/overview/working-with-objects/
- Labels and selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Recommended labels — https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Annotations — https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/
- Namespaces — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Resource quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Owners and dependents / garbage collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/

**Cargas de trabajo**
- Pods — https://kubernetes.io/docs/concepts/workloads/pods/
- Pod lifecycle — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Init containers — https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Sidecar containers — https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Deployments — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSets — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- StatefulSets — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSets — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs — https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJobs — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/

**Configuración y recursos**
- ConfigMaps — https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets — https://kubernetes.io/docs/concepts/configuration/secret/
- Resource management for Pods and containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod Quality of Service classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Configure liveness, readiness and startup probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Encrypting confidential data at rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

**Redes**
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- DNS for Services and Pods — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Virtual IPs and Service proxies (kube-proxy modes) — https://kubernetes.io/docs/reference/networking/virtual-ips/

**Planificación, escalado y disrupción**
- Assigning Pods to nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints and tolerations — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Horizontal Pod Autoscaling — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Pod Disruption Budgets — https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Safely drain a node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Node-pressure eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/

**Depuración**
- Debug running Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Debug Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Debug Services — https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Ephemeral containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- `kubectl debug` reference — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/
- Resource metrics pipeline — https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/