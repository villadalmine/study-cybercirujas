# Tema 4.1 — Kubernetes Reconciliation Loop and Control Plane Architecture

> **Perfil:** SRE / Platform Architect. **Peso en el examen:** 3.0.
> **Idea central:** Kubernetes no es un orquestador que "ejecuta pasos"; es un sistema de **estado deseado declarativo** convergido por *control loops* independientes, idempotentes y *level-triggered*. Entender el control plane es entender cómo se cierra el bucle `spec → observación → diff → acción → status` y qué pasa cuando alguna de esas etapas se degrada en producción.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema que resuelve el modelo reconciliativo

Un orquestador imperativo clásico (scripts, Ansible playbooks, `docker run` encadenados) describe **cómo** llegar a un estado: una secuencia de pasos. En producción esto falla por tres razones estructurales:

1. **Drift (deriva de configuración).** Entre la ejecución del script y "ahora", el mundo cambió: un nodo murió, un proceso fue OOM-killed, alguien hizo `kubectl edit` a mano. Un script imperativo no sabe que el mundo cambió; solo sabe reproducir pasos.
2. **Fallas parciales.** El paso 7 de 12 falló. ¿Reintento desde 1? ¿Desde 7? ¿El paso 7 ya tuvo efecto parcial? La lógica de rollback imperativa es cuadrática en casos borde.
3. **Concurrencia y escala.** Con 10.000 Pods y 500 nodos, ningún actor central puede secuenciar todas las transiciones sin convertirse en cuello de botella y en *single point of failure* lógico.

Kubernetes responde con **reconciliación declarativa**: el usuario declara el **estado deseado** (`spec`), y un conjunto de *controllers* observa continuamente el **estado observado** (`status`), calcula el delta y ejecuta acciones idempotentes hasta converger. El bucle no termina nunca; converger es su estado de reposo, no su final.

```
        ┌──────────────────────────────────────────────┐
        │              RECONCILIATION LOOP             │
        │                                              │
   spec ─┼─► OBSERVE ──► DIFF (desired vs actual) ──► ACT ─┼─► mundo real
        │     ▲                                    │     │
        │     └──────────── status  ◄─────────────┘     │
        └──────────────────────────────────────────────┘
                 (nunca termina; reposo == converged)
```

### 1.2 Level-triggered, no edge-triggered

La decisión de diseño más importante —y la más malinterpretada— es que Kubernetes es **level-triggered** (reacciona al *estado actual*), no **edge-triggered** (reacciona a *eventos/transiciones*). Los eventos del `watch` son solo una **optimización de latencia**: le dicen al controller "algo cambió, reconciliá ya" en vez de esperar al *resync* periódico. Pero la lógica de reconciliación **nunca** confía en el evento; siempre lee el estado completo desde su caché y actúa sobre él.

**Consecuencia práctica de producción:** si un controller **pierde** un evento watch (reinició, la conexión se cortó, hubo compaction en etcd), **no importa** — el siguiente resync o el próximo evento lo hará leer el estado completo y converger igual. Esto es lo que hace a Kubernetes robusto frente a particiones de red y reinicios. Un sistema edge-triggered que pierde el evento "Pod borrado" quedaría inconsistente para siempre.

> **Cita:** el patrón "controllers act on level, not edge" está documentado en la guía oficial de arquitectura de controllers: <https://kubernetes.io/docs/concepts/architecture/controller/> y en las convenciones de API de la comunidad (`sig-architecture`): <https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/controllers.md>

### 1.3 Anatomía del control plane

El control plane no es un binario monolítico; es un conjunto de procesos que se comunican **exclusivamente a través del `kube-apiserver`**. Ni el scheduler ni los controllers hablan con etcd directamente ni entre sí. El apiserver es el único que escribe en etcd; todo lo demás es un cliente REST + watch.

```
                         ┌──────────────────────────────┐
                         │            etcd              │  (Raft, MVCC, watch)
                         │   única fuente de verdad     │
                         └───────────────▲──────────────┘
                                         │ (único que escribe/lee etcd)
                         ┌───────────────┴──────────────┐
    kubectl / clientes ──► │        kube-apiserver        │ ◄── kubelets, controllers
                         │  authn → authz → admission   │
                         │  → validation → storage →    │
                         │  watch cache                 │
                         └───▲─────────▲─────────▲──────┘
                             │         │         │  (watch/list/update via REST)
              kube-scheduler │         │         │ kube-controller-manager
                             │  cloud-controller-manager │  (deployment, rs, node,
                             │                           │   endpoint, job, gc…)
                             └───────────────────────────┘
```

| Componente | Rol | Estado propio | Consecuencia si cae |
|---|---|---|---|
| **etcd** | Fuente de verdad; KV consistente por Raft | Todo el estado del cluster | El cluster es "read-only" del último estado cacheado; nada se escribe. Sin quórum, el apiserver rechaza escrituras. |
| **kube-apiserver** | Puerta única al estado; authn/authz/admission/validación/watch | Ninguno persistente (watch cache en memoria) | Nada del control plane funciona; kubelets siguen corriendo Pods existentes pero sin actualizaciones. Es *stateless* → escalable horizontalmente. |
| **kube-controller-manager** | Ejecuta los controllers built-in (Deployment, ReplicaSet, Node, Endpoint, Job, GC, ServiceAccount…) | Ninguno (todo en apiserver) | Se detiene la reconciliación: los Deployments no se auto-reparan, los nodos NotReady no evacúan. Pods vivos siguen. |
| **kube-scheduler** | Asigna Pods `Pending` a nodos (bind) | Ninguno | Pods nuevos quedan `Pending`; los ya bound no se tocan. |
| **cloud-controller-manager** | Controllers específicos de cloud (LoadBalancer, Node lifecycle, Route) | Ninguno | LoadBalancers y rutas no se aprovisionan; el resto del cluster sigue. |

**El punto arquitectónico clave para un Platform Architect:** el apiserver es *stateless* (todo el estado vive en etcd), por eso se corre en 3+ réplicas detrás de un LB sin coordinación. Los controllers y el scheduler, en cambio, corren en múltiples réplicas pero con **un solo líder activo** vía *leader election* (§5.4), porque dos controllers reconciliando el mismo objeto en paralelo producirían acciones duplicadas (dos ReplicaSets, dos LoadBalancers).

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Level-triggered vs Edge-triggered

| Dimensión | Level-triggered (Kubernetes) | Edge-triggered (event-driven puro) |
|---|---|---|
| Reacciona a | Estado actual completo | Transición/evento discreto |
| Pérdida de un evento | Irrelevante; el resync converge igual | Inconsistencia permanente |
| Idempotencia requerida | **Sí**, es el fundamento | No necesariamente |
| Costo | Re-lee y re-evalúa todo el objeto | Solo procesa el delta (más barato por evento) |
| Robustez ante reinicio/partición | Alta | Baja (hay que reconstruir el stream) |
| Latencia de reacción | Watch da baja latencia; resync es el piso | Muy baja mientras el stream esté sano |
| Modelo mental | "Convergé al deseado" | "Aplicá esta transición" |

### 2.2 Modelo declarativo vs imperativo

| | Declarativo (`kubectl apply`, GitOps) | Imperativo (`kubectl create/scale/edit`, scripts) |
|---|---|---|
| Fuente de verdad | El manifiesto/Git | La secuencia de comandos ejecutados |
| Auto-reparación (self-healing) | Sí — el controller re-converge | No — hay que re-ejecutar el script |
| Detección de drift | Nativa (spec vs status) | Manual |
| Auditoría | `last-applied-configuration` / historial Git | Historial de shell (frágil) |
| Concurrencia segura | Sí, vía `resourceVersion` (optimistic) | Race conditions |
| Punto débil | Requiere que TODO controller sea idempotente | Simple para one-shots, frágil a escala |

> **Amarre con la disciplina de Platform Engineering (dominio central de CNPA):** GitOps (Argo CD, Flux) es *exactamente* el mismo control loop reconciliativo, subido un nivel: el "estado deseado" es un repo Git y el "controller" es el agente GitOps que reconcilia el cluster contra Git. Comprender §1 es comprender por qué GitOps es *pull-based* y auto-reparador.

### 2.3 Estrategias de reconciliación de un controller

| Estrategia | Cuándo | Trade-off |
|---|---|---|
| **Full resync periódico** (`resyncPeriod`) | Red de seguridad ante eventos perdidos | Carga de CPU/apiserver proporcional a la frecuencia; demasiado corto → *hot loop* |
| **Watch + workqueue** (edge-notification) | Baja latencia normal | Requiere caché local (informer) y dedup en la cola |
| **Requeue con backoff** (`RequeueAfter`) | El recurso aún no está listo (esperando algo externo) | Mal calibrado → *hot loop* o convergencia lenta |
| **Rate-limited workqueue** | Absorber ráfagas, evitar martillar el apiserver | Añade latencia bajo carga |
| **Optimistic concurrency** (`resourceVersion` en update) | Múltiples escritores / controller vs usuario | Conflictos 409 → hay que releer y reintentar |

### 2.4 Optimistic vs Pessimistic concurrency

| | Optimistic (Kubernetes) | Pessimistic (locks) |
|---|---|---|
| Mecanismo | `resourceVersion` en el `update`; 409 Conflict si cambió | Lock exclusivo mientras se escribe |
| Escalabilidad | Alta (sin locks distribuidos) | Baja (contención) |
| Manejo de conflicto | Releer + retry (idempotente) | Esperar el lock |
| Riesgo | *Livelock* si dos actores pelean el mismo objeto sin backoff | Deadlock / bloqueo de progreso |

---

## 3. Manifiestos e infraestructura completos

### 3.1 El manifiesto estático del `kube-apiserver` (control plane self-hosted vía kubelet static pods)

En un cluster con `kubeadm`, el kubelet observa `/etc/kubernetes/manifests/` y reconcilia esos *static pods* (el kubelet es, él mismo, un controller level-triggered sobre ese directorio). Este es el manifiesto real, sin recortar, que ilustra la cadena authn→authz→admission y la conexión a etcd:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.10:6443
spec:
  priorityClassName: system-node-critical
  hostNetwork: true
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.31.0
      command:
        - kube-apiserver
        # --- conexión a etcd (única fuente de verdad) ---
        - --etcd-servers=https://127.0.0.1:2379
        - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
        # --- cadena de admisión: orden importa ---
        - --enable-admission-plugins=NodeRestriction,PodSecurity,ResourceQuota,LimitRanger,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook,ValidatingAdmissionWebhook
        # --- authn ---
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        # --- authz ---
        - --authorization-mode=Node,RBAC
        # --- API Priority & Fairness: protege el apiserver de clientes ruidosos ---
        - --enable-priority-and-fairness=true
        - --max-requests-inflight=400
        - --max-mutating-requests-inflight=200
        # --- watch cache: reduce lecturas a etcd ---
        - --watch-cache=true
        - --default-watch-cache-size=100
        - --secure-port=6443
        - --advertise-address=10.0.0.10
      livenessProbe:
        httpGet:
          host: 10.0.0.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
      readinessProbe:
        httpGet:
          host: 10.0.0.10
          path: /readyz
          port: 6443
          scheme: HTTPS
        periodSeconds: 1
        failureThreshold: 3
      startupProbe:
        httpGet:
          host: 10.0.0.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        failureThreshold: 24
      resources:
        requests:
          cpu: 250m
      volumeMounts:
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
  volumes:
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
```

**Lectura arquitectónica:** los tres *health endpoints* (`/livez`, `/readyz`, `/healthz`) no son intercambiables. `/livez` responde si el proceso está vivo; `/readyz` sólo pasa a "OK" cuando la conexión a etcd está sana y la cadena de arranque terminó. Un LB frente a 3 apiservers debe balancear por `/readyz`, no por `/livez`, o mandará tráfico a un apiserver que perdió etcd.

### 3.2 Un controller custom completo: CRD + Deployment con leader election + RBAC

Esto muestra el patrón reconciliativo *que vos podés escribir* — la extensión natural del control plane. Primero el CRD (el "tipo" que el controller reconcilia):

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: cacheclusters.platform.example.io
spec:
  group: platform.example.io
  scope: Namespaced
  names:
    plural: cacheclusters
    singular: cachecluster
    kind: CacheCluster
    shortNames: [cc]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}                    # <- separa spec (deseado) de status (observado)
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [replicas, engine]
              properties:
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 9
                engine:
                  type: string
                  enum: [redis, valkey]
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
                observedGeneration:     # <- clave para diagnosticar (§5.2)
                  type: integer
                  format: int64
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type: { type: string }
                      status: { type: string }
                      reason: { type: string }
                      message: { type: string }
                      lastTransitionTime: { type: string, format: date-time }
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Desired
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
```

El Deployment del controller, con **leader election** (garantiza un único reconciliador activo) y sondas ligadas a la salud del manager de controller-runtime:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cachecluster-controller
  namespace: platform-system
  labels: { app: cachecluster-controller }
spec:
  replicas: 2                          # 2 réplicas, pero solo 1 líder activo
  selector:
    matchLabels: { app: cachecluster-controller }
  template:
    metadata:
      labels: { app: cachecluster-controller }
    spec:
      serviceAccountName: cachecluster-controller
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: manager
          image: registry.example.io/cachecluster-controller:v0.4.2
          args:
            - --leader-elect=true
            - --leader-election-id=cachecluster.platform.example.io
            - --health-probe-bind-address=:8081
            - --metrics-bind-address=:8443
          ports:
            - { name: metrics, containerPort: 8443 }
            - { name: health,  containerPort: 8081 }
          livenessProbe:
            httpGet: { path: /healthz, port: 8081 }
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /readyz, port: 8081 }
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

El **RBAC** — un controller sólo puede reconciliar lo que su ServiceAccount tiene permitido; sobrepermisos aquí son un hallazgo de seguridad, y el permiso `leases` es lo que habilita la elección de líder:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cachecluster-controller
  namespace: platform-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cachecluster-controller
rules:
  # el tipo que reconcilia
  - apiGroups: ["platform.example.io"]
    resources: ["cacheclusters"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["platform.example.io"]
    resources: ["cacheclusters/status"]     # subrecurso status por separado
    verbs: ["get", "update", "patch"]
  # objetos "hijos" que crea para converger
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # eventos para observabilidad
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cachecluster-leader-election
  namespace: platform-system
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]                    # <- el corazón del leader election
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cachecluster-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cachecluster-controller
subjects:
  - kind: ServiceAccount
    name: cachecluster-controller
    namespace: platform-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cachecluster-leader-election
  namespace: platform-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cachecluster-leader-election
subjects:
  - kind: ServiceAccount
    name: cachecluster-controller
    namespace: platform-system
```

### 3.3 El objeto `Lease` de leader election (lo que verás en runtime)

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: cachecluster.platform.example.io
  namespace: platform-system
spec:
  holderIdentity: cachecluster-controller-6b8f7d9c4-abcde_a1b2c3d4-...  # pod líder
  leaseDurationSeconds: 15        # si el líder no renueva en 15s, otro toma el relevo
  acquireTime: "2026-08-07T10:12:03.000000Z"
  renewTime: "2026-08-07T10:19:48.000000Z"   # se actualiza cada ~2s mientras vive
  leaseTransitions: 3             # cuántas veces cambió de líder (síntoma si sube mucho)
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Ver el estado del control plane

```console
$ kubectl get --raw='/readyz?verbose'
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/bootstrap-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
readyz check passed
```

```console
$ kubectl get pods -n kube-system -l tier=control-plane
NAME                            READY   STATUS    RESTARTS   AGE
etcd-cp1                        1/1     Running   0          41d
kube-apiserver-cp1              1/1     Running   0          41d
kube-controller-manager-cp1     1/1     Running   2          41d
kube-scheduler-cp1              1/1     Running   1          41d
```

### 4.2 Observar la reconciliación en vivo — `generation` vs `observedGeneration`

Este par es la sonda más directa de "¿el controller está reconciliando?". Cada cambio al `spec` incrementa `metadata.generation`; el controller copia el valor que efectivamente procesó a `status.observedGeneration`. Si divergen, el controller está **atrasado o detenido**.

```console
$ kubectl scale deployment web --replicas=5
deployment.apps/web scaled

$ kubectl get deployment web -o jsonpath='{"gen="}{.metadata.generation}{"  observed="}{.status.observedGeneration}{"\n"}'
gen=7  observed=7

$ kubectl get deployment web -w
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/5     5            3           9d
web    4/5     5            4           9d
web    5/5     5            5           9d
```

### 4.3 `resourceVersion`, watch y optimistic concurrency

El `resourceVersion` es un token opaco derivado de la revisión MVCC de etcd. Se usa para (a) reanudar watches y (b) optimistic concurrency en updates.

```console
$ kubectl get configmap app-config -o jsonpath='{.metadata.resourceVersion}{"\n"}'
1048577

# Watch reanudable desde una versión concreta (lo que hace un informer al reconectar):
$ kubectl get configmaps --watch --output-watch-events \
    --resource-version=1048577 -o jsonpath='{.type}{" "}{.object.metadata.name}{"\n"}'
MODIFIED app-config
ADDED    feature-flags
```

Simulando el conflicto 409 que un controller debe manejar (releer + retry):

```console
$ kubectl replace -f cm-stale.yaml
Error from server (Conflict): error when replacing "cm-stale.yaml": Operation cannot be
fulfilled on configmaps "app-config": the object has been modified; please apply your
changes to the latest version and try again
```

### 4.4 Leader election en runtime

```console
$ kubectl get lease -n kube-system kube-controller-manager -o yaml | grep -E 'holderIdentity|renewTime|leaseTransitions'
  holderIdentity: cp1_2f0a...   # nodo que hoy corre los controllers
  leaseTransitions: 1
  renewTime: "2026-08-07T10:41:22.512000Z"

$ kubectl get leases -A
NAMESPACE         NAME                                   HOLDER              AGE
kube-node-lease   cp1                                    cp1                 41d
kube-system       kube-controller-manager                cp1_2f0a...         41d
kube-system       kube-scheduler                         cp1_9b1c...         41d
platform-system   cachecluster.platform.example.io       ...-abcde_a1b2...   6d
```

### 4.5 Métricas del control loop (Prometheus del controller-manager / controller custom)

```console
$ kubectl get --raw '/metrics' | grep -E 'workqueue_depth|workqueue_adds_total|reconcile' | head
workqueue_depth{name="deployment"} 0
workqueue_adds_total{name="deployment"} 184213
workqueue_longest_running_processor_seconds{name="deployment"} 0
controller_runtime_reconcile_total{controller="cachecluster",result="success"} 5021
controller_runtime_reconcile_total{controller="cachecluster",result="error"} 3
controller_runtime_reconcile_time_seconds_bucket{controller="cachecluster",le="0.1"} 4890
```

### 4.6 etcd: salud, revisiones y compaction

```console
$ ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
+------------------------+------------------+---------+---------+-----------+------------+
| https://127.0.0.1:2379 | 8e9e05c52164694d |  3.5.15 |  87 MB  |   true    |         12 |
+------------------------+------------------+---------+---------+-----------+------------+

$ etcdctl endpoint health --cluster
https://10.0.0.10:2379 is healthy: successfully committed proposal: took = 3.1ms
https://10.0.0.11:2379 is healthy: successfully committed proposal: took = 4.0ms
https://10.0.0.12:2379 is healthy: successfully committed proposal: took = 3.4ms
```

---

## 5. Verificación y diagnóstico de fallas

El diagnóstico del control plane se hace **por etapa del bucle**: ¿el apiserver acepta y persiste? ¿el controller observa? ¿reconcilia? ¿escribe status? Cada síntoma mapea a una etapa.

### 5.1 Matriz síntoma → etapa → verificación

| Síntoma en producción | Etapa sospechosa | Verificación de primera línea |
|---|---|---|
| `kubectl apply` da timeout / 500 | apiserver ↔ etcd | `kubectl get --raw '/readyz?verbose'`; `etcdctl endpoint health` |
| Deployment no escala tras editar spec | controller-manager / reconcile | `generation` vs `observedGeneration` (§4.2); logs del CM |
| CR custom "no hace nada" | tu controller detenido / sin líder | `kubectl get lease`; logs del pod; `workqueue_depth` |
| Pods quedan `Pending` para siempre | scheduler | `kubectl get events`; `kubectl describe pod`; lease del scheduler |
| Cambios se "revierten solos" | drift + reconciliación (¡esperado!) | Editaste un objeto *owned*; cambiá el owner, no el hijo |
| CPU del controller al 100%, sin progreso | *hot loop* | Ritmo de `reconcile_total`; `RequeueAfter` mal calibrado |
| Latencia alta de writes en todo el cluster | etcd lento (disco/fsync) | `etcd_disk_wal_fsync_duration_seconds`; `endpoint status` |

### 5.2 Reconciliación detenida: `observedGeneration` estancado

```console
$ kubectl get deploy web -o jsonpath='{.metadata.generation} {.status.observedGeneration}{"\n"}'
9 6                     # generation avanzó a 9, el controller sólo procesó hasta 6 → ATRASADO

# ¿El controller-manager está vivo y es líder?
$ kubectl -n kube-system logs kube-controller-manager-cp1 --tail=20
E0807 10:44:01.113  deployment_controller.go:497] Sync "prod/web" failed:
    Operation cannot be fulfilled on replicasets "web-7c9": the object has been modified

$ kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}{"\n"}'
<vacío>                 # ← NADIE tiene el lease: ningún CM activo → nada reconcilia
```

### 5.3 Diagnóstico de *hot loop* (requeue inmediato)

Un controller mal escrito que hace `return ctrl.Result{Requeue: true}` sin backoff, o que escribe status en cada reconcile aunque nada cambió, entra en bucle caliente: martilla el apiserver y quema CPU sin converger.

```console
# El contador de reconcile crece cientos de veces por segundo para el MISMO objeto:
$ kubectl get --raw /metrics | grep 'reconcile_total.*cachecluster'
controller_runtime_reconcile_total{controller="cachecluster",result="requeue"} 918442

# Confirmá con el ritmo de adds a la workqueue (delta en 5s):
$ for i in 1 2; do kubectl get --raw /metrics | grep 'workqueue_adds_total{name="cachecluster"}'; sleep 5; done
workqueue_adds_total{name="cachecluster"} 918442
workqueue_adds_total{name="cachecluster"} 923870      # +5428 en 5s == ~1086/s → HOT LOOP
```

**Causa raíz típica:** el controller escribe `status` con un timestamp o campo que cambia en cada pasada → el watch dispara un nuevo evento → reconcile → escribe status → … El fix es **comparar antes de escribir** (`if !equality.Semantic.DeepEqual(old.Status, new.Status)`), o requeue con `RequeueAfter` en vez de `Requeue: true`.

### 5.4 Leader election patológico (*flapping*)

```console
$ kubectl get lease -n platform-system cachecluster.platform.example.io \
    -o jsonpath='{.spec.leaseTransitions}{"\n"}'
147                     # 147 transiciones de líder en 6 días → FLAPPING

# Causa habitual: réplicas que no renuevan a tiempo por GC pauses / apiserver lento.
$ kubectl -n platform-system logs deploy/cachecluster-controller | grep -i "leader"
I0807 10:31:02  leaderelection.go:283] failed to renew lease platform-system/cachecluster...:
    timed out waiting for the condition
I0807 10:31:02  leaderelection.go:297] lost lease, stopping controllers
```

**Regla de calibración:** `leaseDuration > renewDeadline > retryPeriod`, y `renewDeadline` debe ser holgado respecto al p99 de latencia del apiserver. Con apiserver lento, subí `leaseDuration` (p.ej. 15s→30s) antes de culpar al controller.

### 5.5 etcd como cuello de botella (raíz de casi toda latencia global)

```console
$ kubectl get --raw /metrics | grep etcd_disk_wal_fsync_duration_seconds_bucket | tail -3
etcd_disk_wal_fsync_duration_seconds_bucket{le="0.128"} 41003
etcd_disk_wal_fsync_duration_seconds_bucket{le="0.256"} 41011
etcd_disk_wal_fsync_duration_seconds_bucket{le="+Inf"}  41090
# p99 de fsync > 100ms == disco no apto para etcd (necesita SSD/NVMe con fsync bajo)

# Base creciendo hacia la cuota → escrituras entrarán en modo "NOSPACE" (alarm):
$ etcdctl alarm list
memberID:8e9e05c52164694d alarm:NOSPACE

# Remediación: compact hasta la revisión actual + defrag (impacta latencia, hacelo por miembro):
$ rev=$(etcdctl endpoint status --write-out=json | grep -o '"revision":[0-9]*' | cut -d: -f2)
$ etcdctl compact $rev
compacted revision 20940231
$ etcdctl defrag --cluster
Finished defragmenting etcd member[https://10.0.0.10:2379]
$ etcdctl alarm disarm
```

### 5.6 Checklist de verificación de salud del control loop (runbook)

```console
# 1. apiserver listo (no sólo vivo):
kubectl get --raw '/readyz?verbose'
# 2. etcd con quórum y latencia sana:
etcdctl endpoint health --cluster && etcdctl endpoint status -w table
# 3. controllers y scheduler tienen líder:
kubectl get lease -A | grep -E 'controller-manager|scheduler'
# 4. reconciliación al día (por cada tipo crítico):
kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,GEN:.metadata.generation,OBS:.status.observedGeneration'
# 5. colas no crecen sin límite:
kubectl get --raw /metrics | grep 'workqueue_depth'
# 6. sin ráfaga anómala de eventos (síntoma de hot loop / crashloop):
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

---

## 6. Referencias

- Kubernetes — *Controllers* (patrón reconciliativo, level-triggered): <https://kubernetes.io/docs/concepts/architecture/controller/>
- Kubernetes — *Kubernetes Components* (control plane): <https://kubernetes.io/docs/concepts/overview/components/>
- Kubernetes — *The Kubernetes API* y *API concepts* (watch, `resourceVersion`, optimistic concurrency): <https://kubernetes.io/docs/reference/using-api/api-concepts/>
- Kubernetes — *Operator pattern* (extender el control loop): <https://kubernetes.io/docs/concepts/extend-kubernetes/operator/>
- Kubernetes — *Custom Resources / CRDs*: <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>
- Kubernetes — *Leader election / Coordinated Leader Election*: <https://kubernetes.io/docs/concepts/cluster-administration/coordinated-leader-election/>
- Kubernetes — *API Priority and Fairness*: <https://kubernetes.io/docs/concepts/cluster-administration/flow-control/>
- Kubernetes — *Operating etcd clusters for Kubernetes*: <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Kubernetes — *kube-apiserver reference* (flags): <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>
- Kubernetes — *kube-controller-manager reference*: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/>
- Kubernetes community — *Writing Controllers* (convenciones SIG API Machinery): <https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/controllers.md>
- Kubernetes Enhancement Proposals — *API Server Watch Cache / Consistent reads*: <https://github.com/kubernetes/enhancements/tree/master/keps/sig-api-machinery>
- etcd — *Documentation* (MVCC, watch, maintenance/compaction/defrag): <https://etcd.io/docs/latest/>
- controller-runtime — *Reconcile / Manager* (godoc): <https://pkg.go.dev/sigs.k8s.io/controller-runtime>
- CNCF — *CNPA Curriculum*: <https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf>