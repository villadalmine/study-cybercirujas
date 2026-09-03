# 702.2 Orquestación de contenedores

**LPI DevOps Tools Engineer — Examen 701-100, v2.0.0**
**Peso del tema: 5** · Perfil avanzado SRE / Platform Architect

---

## 1. Motivación: el problema arquitectónico que la orquestación resuelve realmente

### 1.1 El punto donde «ejecutar el contenedor» deja de funcionar

Un contenedor aislado es un proceso con una vista privada de los namespaces de sistema de archivos, red y PID, limitado por cgroups. Ejecutar uno es trivial: `podman run`, `docker run`, o una unidad de systemd que envuelva a cualquiera de los dos. El modelo operativo se rompe en un umbral concreto e identificable — cuando **dos cualesquiera** de las siguientes condiciones se cumplen al mismo tiempo:

1. La carga de trabajo debe sobrevivir a la pérdida de la máquina en la que se ejecuta.
2. Existe más de una réplica de la carga de trabajo, de modo que *algo* debe decidir qué réplica recibe una petición dada.
3. El conjunto de máquinas cambia (autoescalado, reemplazo de hardware, parcheo del kernel) más rápido de lo que un humano puede actualizar el inventario.
4. Los despliegues deben ocurrir sin ventana de mantenimiento.

Por debajo de ese umbral, `systemd` + Podman Quadlets + una configuración estática de proxy inverso es una arquitectura de producción perfectamente defendible, y es materialmente más barata de operar. Por encima, uno está reimplementando un planificador, un registro de servicios con comprobación de salud y una máquina de estados de despliegue en shell — mal, y sin tests.

### 1.2 La trampa imperativa

La automatización de flota ingenua es un modelo push: una ejecución de gestión de configuración enumera hosts, copia una especificación de contenedor y reinicia una unidad.

```
$ ansible-playbook -i inventory/prod deploy-api.yml
PLAY RECAP ****************************************************************
node-07   : ok=12  changed=3  unreachable=0  failed=0
node-08   : ok=12  changed=3  unreachable=0  failed=0
node-09   : ok=0   changed=0  unreachable=1  failed=0
```

`node-09` estaba inalcanzable. El playbook termina, el operador sigue con lo suyo, y el clúster tiene ahora un **estado dividido**: dos nodos en `v2.4.1`, un nodo en `v2.4.0` — y nada en el sistema es consciente de ello ni responsable de arreglarlo. La convergencia ocurrió una vez, a las 14:02, y después se detuvo. Peor aún: cuando `node-09` vuelve a las 03:10, regresa ejecutando la imagen *antigua* y recibe tráfico del balanceador de carga de inmediato, porque la comprobación de salud del LB solo prueba TCP:8080.

Este es el fallo de fondo: **la automatización push converge en el momento de la ejecución; la producción diverge continuamente.**

### 1.3 La respuesta del bucle de control

Un orquestador invierte el modelo. Uno envía una *declaración* de intención a una API. Controladores independientes observan esa declaración y el mundo observado, y llevan continuamente la diferencia a cero:

```
        ┌──────────────────────────────────────────────┐
        │  Declared state (API objects, persisted)     │
        │  replicas: 3, image: api:v2.4.1              │
        └───────────────┬──────────────────────────────┘
                        │ WATCH (long-lived, incremental)
                        ▼
        ┌──────────────────────────────────────────────┐
        │  Controller: diff(declared, observed) → act   │
        │  level-triggered, idempotent, re-entrant      │
        └───────────────┬──────────────────────────────┘
                        │ CREATE / DELETE / PATCH
                        ▼
        ┌──────────────────────────────────────────────┐
        │  Observed state (kubelet-reported, /status)   │
        └──────────────────────────────────────────────┘
```

Tres propiedades son innegociables y vale la pena nombrarlas con precisión, porque son lo que realmente se está comprando:

- **Disparo por nivel, no por flanco.** Un controlador no reacciona a eventos del tipo «un pod murió». Reacciona a «el recuento actual es 2, el recuento deseado es 3». Un evento perdido no es, por tanto, una actualización perdida — la siguiente resincronización recalcula la misma diferencia. Por eso los orquestadores se recuperan de sus propias caídas.
- **Reconciliación idempotente.** Ejecutar el cuerpo del bucle dos veces con las mismas entradas produce el mismo resultado. Esto es lo que permite reiniciar controladores con seguridad a mitad de una acción.
- **Separación del estado deseado y del observado en subrecursos distintos.** En Kubernetes, `spec` lo escriben los usuarios, `status` lo escriben los controladores. Son rutas de escritura separadas (subrecurso `/status`) con RBAC separado, y por eso una carga de trabajo comprometida no puede mentir sobre su propia configuración deseada.

### 1.4 Los cinco subproblemas que un orquestador debe resolver

| Subproblema | Respuesta ingenua | Respuesta orquestada |
|---|---|---|
| **Ubicación** | Asignación estática de hosts en el inventario | Planificador: filtrar nodos viables, puntuarlos, enlazar |
| **Ciclo de vida** | `systemd` `Restart=always` por host | El controlador recrea la carga de trabajo *en cualquier lugar* de la flota |
| **Descubrimiento** | Upstreams estáticos en HAProxy / DNS con TTL | IP virtual + conjunto de endpoints actualizado continuamente |
| **Despliegue progresivo** | Ejecución serial de playbook, sin estado de rollback | Máquina de estados con presupuesto de surge/indisponibilidad e historial de revisiones |
| **Arbitraje de recursos** | Esperanza | Requests/limits, clases QoS, cuotas, preempción |

Todo lo demás en este tema es un detalle de alguno de esos cinco.

---

## 2. Panorama de orquestadores y compromisos

### 2.1 El campo de juego

Los objetivos del 701 exigen *comprensión de los conceptos de orquestación de contenedores* y familiaridad práctica con Kubernetes y Docker Swarm. En términos de arquitectura de producción, la matriz de decisión real es más amplia.

| | **Kubernetes** | **Docker Swarm (modo clásico)** | **HashiCorp Nomad** | **Systemd + Podman Quadlets** |
|---|---|---|---|---|
| **Almacén de estado** | etcd (Raft), externo a los componentes | Raft integrado en los managers | Raft (servers), más Consul opcionalmente | Ninguno (archivos de unidad locales al host) |
| **Superficie de API** | REST declarativa, extensible mediante CRDs | Docker Engine API + `stack deploy` | API HTTP + especificación de job en HCL | D-Bus de systemd |
| **Modelo de planificación** | Framework enchufable, ~20 plugins por defecto | Estrategias spread / bin-pack sobre servicios | Bin-pack / spread, multi-carga (también VMs, raw exec) | El cerebro del operador |
| **Redes** | Requiere plugin CNI, red de pods plana | Overlay integrado (VXLAN) + routing mesh | CNI, o host/bridge; Consul Connect para mesh | Host / bridge / `podman network` |
| **Descubrimiento de servicios** | VIP ClusterIP + CoreDNS + EndpointSlice | DNS embebido + VIP por servicio | Catálogo de Consul / DNS de Nomad | Configuración estática |
| **Extensibilidad** | CRD + controlador = objetos de API de primera clase | Prácticamente ninguna | Task drivers, plugins | Cualquier cosa, sin gestionar |
| **Multi-tenancy** | Namespaces, RBAC, ResourceQuota, NetworkPolicy | Débil (sin namespaces) | Namespaces + ACLs (Enterprise para completo) | Ninguna |
| **Cargas con estado** | StatefulSet + CSI (un PVC por réplica) | Los volúmenes son locales al nodo salvo con plugin | Volúmenes de host / CSI | Local |
| **Coste operativo** | Alto: plano de control, CNI, CSI, actualizaciones, proliferación de CRDs | Bajo: un binario, `swarm init` | Medio: binario único, pocas piezas móviles | Muy bajo |
| **Semántica de rollback** | Historial de revisiones, `rollout undo`, drenado consciente de PDB | `service rollback`, solo la especificación anterior | `job revert` a cualquier versión previa | Manual |
| **Gravedad del ecosistema** | Abrumadora (CNCF, operadores, Helm) | En modo mantenimiento | Modesta | N/D |

### 2.2 Elegir, con el compromiso declarado honestamente

- **Kubernetes** gana cuando se necesita extensibilidad (operadores que codifican conocimiento de dominio), multi-tenancy fuerte, o el ecosistema. Cuesta un equipo de plataforma permanente. La API es el producto; los pods son incidentales.
- **Swarm** gana para un parque de 3–20 nodos con servicios sin estado y un equipo pequeño. De `docker swarm init` a una red overlay funcionando hay menos de un minuto. Pierde cuando se necesitan volúmenes persistentes por réplica, política de red real, o cualquier cosa que los objetos integrados no modelen — no hay punto de extensión.
- **Nomad** gana en parques heterogéneos (contenedores *y* jars de JVM *y* VMs QEMU) y donde la simplicidad operativa pesa mucho. Pierde el ecosistema.
- **Quadlets/systemd** gana para appliances de un solo nodo y despliegues en el borde. Podman genera unidades de systemd a partir de archivos `.container`; se obtienen políticas de reinicio, ordenación de dependencias e integración con journald gratis, y no se obtiene *nada* sobre ubicación ni descubrimiento.

> **Regla arquitectónica práctica:** si la respuesta a «qué pasa cuando este nodo muere a las 04:00» es «la carga de trabajo se reinicia en otro sitio automáticamente», hace falta un orquestador. Si es «el standby toma el relevo» o «avisamos a alguien», puede que no.

---

## 3. Arquitectura de Kubernetes: la mecánica

### 3.1 Topología de componentes

```
CONTROL PLANE (typically 3 or 5 nodes, tainted NoSchedule)
┌──────────────────────────────────────────────────────────────┐
│  kube-apiserver   ── the ONLY component that talks to etcd   │
│      │  authn → authz (RBAC) → admission (mutating,          │
│      │  then validating) → schema validation → persist       │
│      ▼                                                       │
│  etcd  (Raft consensus, quorum = floor(N/2)+1)               │
│                                                              │
│  kube-controller-manager  ── ~40 controllers in one process  │
│      (deployment, replicaset, node, endpointslice, job,      │
│       pv-binder, ttl-after-finished, …) leader-elected       │
│                                                              │
│  kube-scheduler   ── binds unscheduled Pods to Nodes         │
│  cloud-controller-manager (optional, out-of-tree providers)  │
└──────────────────────────────────────────────────────────────┘
                    ▲ watch/list + PATCH status
                    │
WORKER NODE (every node, including control plane)
┌──────────────────────────────────────────────────────────────┐
│  kubelet ── the node agent. Owns the Pod lifecycle.          │
│     ├── CRI  → containerd / CRI-O  → runc / crun / kata      │
│     ├── CNI  → Calico / Cilium / Flannel (pod networking)    │
│     └── CSI  → volume attach/mount via node-driver-registrar │
│  kube-proxy ── programs Service VIP dataplane (or replaced   │
│                entirely by an eBPF CNI such as Cilium)       │
└──────────────────────────────────────────────────────────────┘
```

Dos hechos que importan repetidamente en la revisión de incidentes:

- **Solo el apiserver escribe en etcd.** Todos los demás componentes son clientes de la API. Por tanto, la latencia de etcd es la latencia del apiserver es la latencia de *todo*. Un p99 de `etcd_disk_wal_fsync_duration_seconds` por encima de ~25 ms es el aviso fiable más temprano de un clúster en problemas.
- **El kubelet es la autoridad sobre lo que realmente se está ejecutando.** Si el apiserver desaparece, los pods en ejecución siguen ejecutándose — el kubelet no los mata. Esto es deliberado: una caída del plano de control no debe ser una caída del plano de datos.

### 3.2 El mecanismo de watch y la concurrencia optimista

Los controladores no hacen polling. Ejecutan `LIST` una vez para construir una caché local (un *informer*), registran el `resourceVersion` devuelto, y luego abren un `WATCH` desde esa versión y reciben un flujo incremental de eventos. Las escrituras usan concurrencia optimista: el cliente envía el objeto con el `resourceVersion` que leyó; el apiserver rechaza la escritura con `409 Conflict` si la versión almacenada ha avanzado.

```
$ kubectl get deployment api -o jsonpath='{.metadata.resourceVersion}{"\n"}'
48211937

$ kubectl get --raw '/apis/apps/v1/namespaces/prod/deployments?watch=1&resourceVersion=48211937' | head -2
{"type":"MODIFIED","object":{"kind":"Deployment","apiVersion":"apps/v1","metadata":{"name":"api","namespace":"prod","resourceVersion":"48211944", ...
{"type":"MODIFIED","object":{"kind":"Deployment","apiVersion":"apps/v1","metadata":{"name":"api","namespace":"prod","resourceVersion":"48211952", ...
```

La consecuencia práctica: **los conflictos de escritura son normales y deben reintentarse, no tratarse como errores**. Cualquier controlador o job de CI que aplique parches a objetos de Kubernetes y no reintente ante un 409 será inestable bajo carga.

### 3.3 El planificador, con precisión

`kube-scheduler` ejecuta un ciclo por Pod construido a partir de puntos de extensión del framework. Las dos fases que importan operativamente:

1. **Filter (viabilidad).** Cada plugin responde sí/no por nodo. Fallar aquí produce `Pending` con un mensaje que enumera *por qué se rechazó cada nodo*. Filtros principales: `NodeResourcesFit` (requests frente a allocatable), `NodeAffinity`, `TaintToleration`, `PodTopologySpread` (cuando `whenUnsatisfiable: DoNotSchedule`), `NodePorts`, `VolumeBinding`, `NodeUnschedulable`.
2. **Score (preferencia).** Los nodos supervivientes se puntúan de 0 a 100 por plugin y se ponderan. Puntuadores principales: `NodeResourcesBalancedAllocation`, `ImageLocality`, `InterPodAffinity`, `PodTopologySpread`, `TaintToleration`.

Si el filtrado deja cero nodos, **PostFilter** ejecuta la preempción: el planificador busca un nodo donde desalojar pods de `PriorityClass` inferior haría que el pod pendiente encajara y, si lo encuentra, elimina las víctimas (respetando sus `terminationGracePeriodSeconds`) y *nomina* el nodo.

Fundamental: **el planificador decide sobre `requests`, el kernel aplica `limits`.** Un nodo cuyos pods solicitan 2 CPU en total pero consumen 30 CPU está, para el planificador, casi vacío. Unas requests que no reflejan la realidad son la causa raíz más común de «el clúster está ardiendo pero el panel dice 20 % asignado».

### 3.4 Clases de calidad de servicio y orden de desalojo

| Clase QoS | Condición | `oom_score_adj` | Orden de desalojo bajo presión del nodo |
|---|---|---|---|
| **Guaranteed** | Todos los contenedores fijan requests == limits tanto para CPU como para memoria | −997 | Último |
| **Burstable** | Al menos una request fijada, pero no Guaranteed | 2…999, escalado según la request de memoria frente a la capacidad del nodo | Segundo |
| **BestEffort** | Ninguna request ni limit | 1000 | Primero |

Bajo presión de memoria, el kubelet ordena a los candidatos por clase QoS y después por uso *por encima de las requests*. Por eso un pod Burstable con una request de memoria grande y honesta sobrevive más que uno con una request simbólica de `64Mi` — la request es la protección.

---

## 4. Controladores de cargas de trabajo

### 4.1 Comparación

| Controlador | Identidad | Ordenación | Almacenamiento | Escalado | Uso típico |
|---|---|---|---|---|---|
| **Deployment** → ReplicaSet | Sufijo aleatorio, intercambiables | Ninguna | Compartido o efímero | `replicas`, HPA | Servicios sin estado |
| **StatefulSet** | Ordinal estable `web-0…web-N`, DNS estable | Creación/borrado/actualización ordenados (configurable) | `volumeClaimTemplates`: un PVC por ordinal, retenido | `replicas`, HPA (con cuidado) | Bases de datos, sistemas de quórum, brokers |
| **DaemonSet** | Un pod por nodo coincidente | N/D | Típicamente `hostPath` | Implícito: número de nodos | Recolectores de logs, agentes CNI, node exporters |
| **Job** | Ejecución hasta completar | Paralelismo controlado | Efímero | `completions`/`parallelism` | Migraciones, procesamiento por lotes |
| **CronJob** → Job | Dirigido por planificación | Política de concurrencia | Efímero | N/D | Copias de seguridad, reconciliación |
| **ReplicaSet** (a secas) | Aleatoria | Ninguna | — | `replicas` | Casi nunca de forma directa |

### 4.2 Un Deployment completo, con forma de producción

Este manifiesto está deliberadamente sin recortar. Cada campo presente es uno que se pediría justificar en una revisión de diseño.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: prod
data:
  LOG_LEVEL: "info"
  UPSTREAM_TIMEOUT_MS: "2500"
  application.yaml: |
    server:
      port: 8080
      shutdownGracePeriodMs: 20000
    metrics:
      path: /metrics
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: storefront
    app.kubernetes.io/version: "2.4.1"
spec:
  replicas: 6
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 15
  selector:
    matchLabels:
      app.kubernetes.io/name: api
      app.kubernetes.io/component: backend
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2          # absolute or percentage; rounded UP
      maxUnavailable: 0    # zero-downtime posture: never dip below replicas
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/component: backend
        app.kubernetes.io/version: "2.4.1"
      annotations:
        # Forces a rollout when the ConfigMap content changes. Without this,
        # editing a ConfigMap changes nothing for already-running Pods that
        # consume it through env vars.
        checksum/config: "9f2c4d1e7a8b30f5c6d2e1a4b7c9d0e3f1a2b3c4"
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      # Give the scheduler a chance to place pods on separate failure domains.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
              app.kubernetes.io/component: backend
          matchLabelKeys:
            - pod-template-hash        # spread each ReplicaSet independently
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
              app.kubernetes.io/component: backend
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        # Native sidecar: an initContainer with restartPolicy Always starts
        # before the app containers, keeps running alongside them, and is
        # terminated only after they exit. This solves the classic
        # "Job never completes because the proxy never exits" problem.
        - name: log-shipper
          image: registry.internal/fluent-bit:3.1.9
          restartPolicy: Always
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { memory: "128Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: varlog, mountPath: /var/log/app, readOnly: true }
      containers:
        - name: api
          image: registry.internal/storefront/api:2.4.1@sha256:5d3b0f2ac71e8fbd4a9c60e2b1d7f38c92a4e5610bc7d8a3f2e9014c6b5d7a8e
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http,    containerPort: 8080, protocol: TCP }
            - { name: metrics, containerPort: 9090, protocol: TCP }
          envFrom:
            - configMapRef:
                name: api-config
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: POD_IP
              valueFrom: { fieldRef: { fieldPath: status.podIP } }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: api-db
                  key: password
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
              ephemeral-storage: "256Mi"
            limits:
              memory: "512Mi"          # == request → protects QoS on memory
              ephemeral-storage: "1Gi"
              # CPU limit deliberately omitted: CFS throttling on a latency
              # sensitive service costs more than the noisy-neighbour risk,
              # which requests already bound. Set one only where you must
              # guarantee determinism.
          startupProbe:
            httpGet: { path: /healthz/started, port: http }
            periodSeconds: 5
            failureThreshold: 60        # tolerate up to 300 s cold start
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 3         # out of rotation after ~15 s
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6         # restart only after ~60 s of failure
          lifecycle:
            preStop:
              exec:
                # Deregistration race: endpoint removal and SIGTERM are
                # concurrent. Sleep long enough for every kube-proxy /
                # ingress controller to observe the endpoint deletion.
                command: ["/bin/sh", "-c", "sleep 8"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: config,  mountPath: /etc/api,  readOnly: true }
            - { name: tmp,     mountPath: /tmp }
            - { name: varlog,  mountPath: /var/log/app }
      volumes:
        - name: config
          configMap:
            name: api-config
            items:
              - { key: application.yaml, path: application.yaml }
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        - name: varlog
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: prod
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
  ports:
    - { name: http, port: 80, targetPort: http, protocol: TCP }
  # Keep a client pinned to one backend for the life of its source IP.
  # Default is None (per-connection hashing).
  sessionAffinity: None
  internalTrafficPolicy: Cluster
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
  namespace: prod
spec:
  # minAvailable is evaluated against the *current* replica count, so with
  # an HPA prefer maxUnavailable to avoid deadlocking drains at low scale.
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: api
      app.kubernetes.io/component: backend
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 6
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70      # % of the *request*, not of the node
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
      selectPolicy: Max
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
        - { type: Pods,    value: 8,   periodSeconds: 30 }
    scaleDown:
      stabilizationWindowSeconds: 600   # damp flapping; default is 300
      selectPolicy: Min
      policies:
        - { type: Percent, value: 20, periodSeconds: 120 }
```

**Notas de diseño que deberías poder defender:**

- `maxUnavailable: 0` + `maxSurge: 2` da despliegues con pérdida de capacidad estrictamente nula, a cambio de necesitar margen para 2 pods extra y un despliegue más lento. Lo inverso (`maxUnavailable: 1, maxSurge: 0`) es lo correcto cuando la carga de trabajo retiene un recurso exclusivo (un puerto local al nodo, un puesto de licencia).
- `minReadySeconds: 15` previene el desastre clásico del despliegue rápido: el pod nuevo pasa readiness, el controlador termina de inmediato uno viejo, y *entonces* el pod nuevo compila JIT / calienta el pool de conexiones y empieza a dar errores. Convierte «ready» en «ready y estable durante 15 s».
- El `preStop` con sleep no es superstición. La eliminación del endpoint se propaga de forma asíncrona a cada kube-proxy y controlador de ingress; SIGTERM se entrega concurrentemente. Sin el retardo, las peticiones en vuelo se enrutan a un socket que ya se está cerrando. Duerme ≥ el tiempo de convergencia de tu plano de datos.
- Fijar la imagen por digest (`@sha256:…`) junto con la etiqueta hace el despliegue reproducible incluso si la etiqueta se sobrescribe upstream.

### 4.3 Mecánica de la actualización progresiva, calculada

Con `replicas: 6`, `maxSurge: 2`, `maxUnavailable: 0`:

- Cota superior de pods totales: `6 + 2 = 8`
- Cota inferior de pods disponibles: `6 − 0 = 6`

El controlador de Deployment escala por tanto el ReplicaSet nuevo a 2, espera a que ambos estén Available (`Ready` durante `minReadySeconds`), luego escala el ReplicaSet viejo a 4, después el nuevo a 4, y así sucesivamente. Con porcentajes: `maxSurge` redondea **hacia arriba**, `maxUnavailable` redondea **hacia abajo** — el par está deliberadamente sesgado hacia la disponibilidad. Nótese que ambos no pueden ser cero; la API lo rechaza, porque el despliegue nunca podría progresar.

`progressDeadlineSeconds: 600` significa: si el despliegue no hace progreso durante 10 minutos, el Deployment obtiene `Progressing=False` con razón `ProgressDeadlineExceeded`. **No hace rollback automáticamente.** Marca la condición, y `kubectl rollout status` sale con código distinto de cero — que es exactamente el gancho sobre el que tu pipeline de CI debería estar haciendo de compuerta.

```
$ kubectl -n prod set image deployment/api api=registry.internal/storefront/api:2.5.0
deployment.apps/api image updated

$ kubectl -n prod rollout status deployment/api --timeout=10m
Waiting for deployment "api" rollout to finish: 2 out of 6 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 4 out of 6 new replicas have been updated...
Waiting for deployment "api" rollout to finish: 2 old replicas are pending termination...
deployment "api" successfully rolled out

$ kubectl -n prod rollout history deployment/api
deployment.apps/api
REVISION  CHANGE-CAUSE
3         <none>
4         <none>
5         <none>

$ kubectl -n prod rollout undo deployment/api --to-revision=4
deployment.apps/api rolled back
```

Un despliegue fallido, y cómo se lee:

```
$ kubectl -n prod rollout status deployment/api --timeout=2m
Waiting for deployment "api" rollout to finish: 2 out of 6 new replicas have been updated...
error: timed out waiting for the condition

$ kubectl -n prod get deployment api -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
Available       True    MinimumReplicasAvailable
Progressing     False   ProgressDeadlineExceeded
```

`Available=True` con `Progressing=False` es la firma de un despliegue fallido *seguro*: los pods de surge nunca llegaron a ready, así que el ReplicaSet viejo nunca se redujo. El tráfico está bien. Esto es precisamente lo que compró `maxUnavailable: 0`.

### 4.4 StatefulSet: identidad, ordenación y canarios particionados

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: pg-headless
  namespace: data
  labels:
    app.kubernetes.io/name: postgres
spec:
  clusterIP: None                 # headless: DNS returns pod IPs, no VIP
  publishNotReadyAddresses: true  # peers must resolve each other pre-readiness
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - { name: pg, port: 5432, targetPort: pg }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
  namespace: data
spec:
  serviceName: pg-headless        # MUST match the headless Service name
  replicas: 3
  podManagementPolicy: OrderedReady   # or Parallel for non-quorum systems
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0                # ordinals >= partition are updated
      maxUnavailable: 1
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: postgres
          image: registry.internal/postgres:16.4
          ports:
            - { name: pg, containerPort: 5432 }
          env:
            - name: POD_ORDINAL
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: pg-superuser, key: password }
          resources:
            requests: { cpu: "1",  memory: "4Gi" }
            limits:   { memory: "4Gi" }
          readinessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U postgres -h 127.0.0.1"]
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            exec:
              command: ["/bin/sh","-c","pg_isready -U postgres -h 127.0.0.1"]
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 6
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ssd-retain
        resources:
          requests:
            storage: 200Gi
```

Comportamiento que hay que interiorizar:

- El DNS del pod es `pg-0.pg-headless.data.svc.cluster.local` — **estable a través de reprogramaciones**, que es lo que requieren los protocolos de quórum.
- Los PVC se llaman `data-pg-0`, `data-pg-1`, `data-pg-2` y **no** se eliminan cuando se elimina el pod. `persistentVolumeClaimRetentionPolicy` controla qué ocurre al eliminar el StatefulSet y al reducir escala; `Retain` es el valor seguro por defecto para bases de datos.
- Las actualizaciones proceden **desde el ordinal más alto hacia abajo**. `partition: 2` en un conjunto de 3 réplicas actualiza solo `pg-2` — un canario genuino. Verifícalo, y luego pon `partition: 0` para completar. Esto es lo más parecido a una primitiva integrada de entrega progresiva en el Kubernetes core.

```
$ kubectl -n data patch statefulset pg --type=merge \
    -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
statefulset.apps/pg patched

$ kubectl -n data set image statefulset/pg postgres=registry.internal/postgres:16.5
statefulset.apps/pg image updated

$ kubectl -n data get pods -l app.kubernetes.io/name=postgres \
    -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,REV:.metadata.labels.controller-revision-hash'
NAME   IMAGE                                  REV
pg-0   registry.internal/postgres:16.4        pg-6c47d9f8b4
pg-1   registry.internal/postgres:16.4        pg-6c47d9f8b4
pg-2   registry.internal/postgres:16.5        pg-7f9a1c2e05
```

### 4.5 DaemonSet, Job, CronJob

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: observability
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: node-exporter }
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
      maxSurge: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: node-exporter }
    spec:
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      # Run everywhere, including tainted control-plane and cordoned nodes.
      tolerations:
        - operator: Exists
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.8.2
          args:
            - --path.rootfs=/host
            - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
          ports:
            - { name: metrics, containerPort: 9100, hostPort: 9100 }
          resources:
            requests: { cpu: "20m", memory: "48Mi" }
            limits:   { memory: "128Mi" }
          securityContext:
            runAsUser: 65534
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: rootfs, mountPath: /host, readOnly: true, mountPropagation: HostToContainer }
      volumes:
        - name: rootfs
          hostPath: { path: /, type: Directory }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-migrate-2-5-0
  namespace: prod
spec:
  backoffLimit: 3
  completions: 1
  parallelism: 1
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400   # GC the Job object after 24 h
  podFailurePolicy:
    rules:
      # A non-retryable application error: stop immediately, do not burn
      # the backoffLimit on a migration that will never succeed.
      - action: FailJob
        onExitCodes:
          containerName: migrate
          operator: In
          values: [42]
      # Node preemption is infrastructure noise: retry without counting it.
      - action: Ignore
        onPodConditions:
          - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: registry.internal/storefront/migrate:2.5.0
          args: ["--target-version", "2.5.0", "--lock-timeout", "60s"]
          env:
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: api-db, key: url } }
          resources:
            requests: { cpu: "200m", memory: "256Mi" }
            limits:   { memory: "512Mi" }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-basebackup
  namespace: data
spec:
  schedule: "17 2 * * *"
  timeZone: "Europe/Madrid"       # without this, the schedule is controller-local time
  concurrencyPolicy: Forbid       # Allow | Forbid | Replace
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 7200
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: basebackup
              image: registry.internal/postgres:16.4
              command:
                - /bin/sh
                - -c
                - |
                  set -euo pipefail
                  TS="$(date -u +%Y%m%dT%H%M%SZ)"
                  pg_basebackup -h pg-0.pg-headless.data.svc.cluster.local \
                                -U replicator -D - -Ft -X stream -z \
                    | aws s3 cp - "s3://backups-prod/pg/${TS}.tar.gz"
              env:
                - name: PGPASSWORD
                  valueFrom: { secretKeyRef: { name: pg-replicator, key: password } }
              resources:
                requests: { cpu: "500m", memory: "512Mi" }
                limits:   { memory: "1Gi" }
```

`startingDeadlineSeconds` merece una advertencia: si el controlador de CronJob está caído durante más tiempo que este, la ejecución perdida se **omite**, no se encola. Y si se omite el campo por completo mientras el controlador está caído durante horas, el controlador puede contar más de 100 arranques perdidos y negarse a planificar en absoluto, registrando `Cannot determine if job needs to be started: too many missed start times`.

---

## 5. Redes y descubrimiento de servicios

### 5.1 El modelo de red, como conjunto de invariantes

Kubernetes no especifica *cómo* implementar la red; especifica restricciones que un plugin CNI debe satisfacer:

1. Cada Pod obtiene una dirección IP única y enrutable en una red plana.
2. Los Pods pueden alcanzar a todos los demás Pods sin NAT.
3. Los agentes del nodo (kubelet, demonios) pueden alcanzar todos los Pods de ese nodo.

Ese último punto es la razón de que funcionen los DaemonSets con `hostNetwork`. El punto 2 es la razón de que «usá `hostPort` y ya» sea un olor de diseño — reintroduce el problema de asignación de puertos que la orquestación eliminó.

### 5.2 Tipos de Service

| Tipo | Asigna | Alcanzable desde | Uso típico |
|---|---|---|---|
| `ClusterIP` | IP virtual del CIDR de servicios | Solo dentro del clúster | Tráfico este-oeste; el valor por defecto |
| `ClusterIP: None` (headless) | Nada | DNS devuelve directamente las IPs de los pods | Pares de StatefulSet, LB en el cliente, gRPC |
| `NodePort` | ClusterIP + un puerto (30000–32767) en **cada** nodo | Cualquier cosa que alcance una IP de nodo | Punto de entrada de ingress en bare metal |
| `LoadBalancer` | NodePort + LB externo vía cloud-controller / MetalLB | Internet / VPC | Puntos de entrada públicos |
| `ExternalName` | Nada; CoreDNS devuelve un CNAME | Dentro del clúster | Alias de una dependencia fuera del clúster |

`externalTrafficPolicy` es el campo que la gente olvida:

- `Cluster` (por defecto): un nodo que recibe tráfico externo puede hacer SNAT y reenviar a un pod en otro nodo. Distribución uniforme de carga, **se pierde la IP de origen del cliente**.
- `Local`: solo son elegibles los pods del nodo receptor. Se preserva la IP de origen, y el nodo falla la comprobación de salud del LB cuando no tiene endpoint local — pero la distribución se vuelve desigual y depende de la ubicación de pods por nodo.

### 5.3 EndpointSlice: qué produce realmente el selector del Service

```
$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                   AGE
api-7fk2x   IPv4          8080    10.244.3.17,10.244.1.44,10.244.2.9 + 3      41d

$ kubectl -n prod get endpointslice api-7fk2x -o yaml | sed -n '1,40p'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
addressType: IPv4
metadata:
  name: api-7fk2x
  namespace: prod
  labels:
    kubernetes.io/service-name: api
endpoints:
- addresses:
  - 10.244.3.17
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: node-07
  targetRef:
    kind: Pod
    name: api-6c47d9f8b4-x9pql
    namespace: prod
  zone: eu-west-1a
- addresses:
  - 10.244.1.44
  conditions:
    ready: false
    serving: true
    terminating: true
  nodeName: node-08
  targetRef:
    kind: Pod
    name: api-5b9f0c1a22-mn4tv
    namespace: prod
  zone: eu-west-1b
ports:
- name: http
  port: 8080
  protocol: TCP
```

El trío `ready` / `serving` / `terminating` es el mecanismo que hay detrás del apagado ordenado: un pod en terminación tiene `ready: false` (las conexiones nuevas se detienen) pero `serving: true` (los planos de datos que soportan drenado de conexiones pueden terminar el trabajo en vuelo). Los EndpointSlices reemplazan al objeto único `Endpoints` heredado precisamente porque un Service de 5000 endpoints producía un objeto de varios megabytes reescrito ante cada cambio de pod — un riesgo para el apiserver y para etcd. Los slices tienen un tope de 100 endpoints por defecto.

### 5.4 Modos del plano de datos de kube-proxy

| Modo | Estructura de reglas | Coste de actualización de reglas | Balanceo de carga | Notas |
|---|---|---|---|---|
| `iptables` | Cadenas lineales por Service, DNAT en `KUBE-SERVICES` | Reescritura O(n) del conjunto de reglas; se degrada pasados unos pocos miles de Services | Aleatorio con pesos de probabilidad | Valor por defecto histórico; bien comprendido |
| `ipvs` | Tabla hash en el kernel, un servidor virtual por Service | O(1) por actualización de Service | rr, lc, dh, sh, sed, nq | Mejor para grandes cantidades de Services; requiere los módulos `ip_vs*` |
| `nftables` | Sets/maps nativos de nftables, búsqueda en mapa del lado del kernel | ~O(1); actualizaciones incrementales mucho más baratas | Basado en mapas | Introducido como alpha en v1.29, beta en v1.31; revisá las notas de versión para el nivel de graduación y el valor por defecto actuales |
| *(ninguno)* | Programas eBPF en los hooks tc/XDP (Cilium `kubeProxyReplacement`) | Actualización de entrada del mapa | Maglev / aleatorio | kube-proxy eliminado por completo |

Inspeccionando el plano de datos programado en un nodo:

```
$ sudo iptables -t nat -L KUBE-SERVICES -n | head -8
Chain KUBE-SERVICES (2 references)
target            prot opt source     destination
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0  10.96.0.1     /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  0.0.0.0/0  10.96.0.10    /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-SVC-QMWWTXBG7KFJQKLO  tcp  --  0.0.0.0/0  10.107.44.19  /* prod/api:http cluster IP */ tcp dpt:80

$ sudo ipvsadm -Ln | sed -n '/10.107.44.19/,+7p'
TCP  10.107.44.19:80 rr
  -> 10.244.1.44:8080             Masq    1      12         3
  -> 10.244.2.9:8080              Masq    1      15         1
  -> 10.244.3.17:8080             Masq    1      11         4
```

### 5.5 DNS

CoreDNS resuelve `<service>.<namespace>.svc.cluster.local` a la ClusterIP; para Services headless devuelve el conjunto de registros A de los pods. Cada pod recibe un `resolv.conf` con una lista `search` y `ndots:5`:

```
$ kubectl -n prod exec -it deploy/api -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

**`ndots:5` es una trampa real de rendimiento.** Cualquier consulta con menos de cinco puntos — que es esencialmente cualquier nombre de host externo, p. ej. `api.stripe.com` — se prueba primero contra los tres dominios de búsqueda, produciendo tres viajes de ida y vuelta NXDOMAIN antes de la consulta absoluta. En un servicio charlatán, esto triplica las QPS de DNS. Dos arreglos: añadir un punto final a los nombres externos en la configuración (`api.stripe.com.`), o fijar un `dnsConfig` por pod:

```yaml
      dnsPolicy: ClusterFirst
      dnsConfig:
        options:
          - { name: ndots, value: "2" }
          - { name: single-request-reopen }
```

### 5.6 Ingress y Gateway API

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: storefront
  namespace: prod
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["shop.example.com"]
      secretName: shop-example-com-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  name: http
```

Ingress es deliberadamente mínimo, y por eso todo despliegue real acaba escapándose hacia anotaciones específicas del proveedor — y esas anotaciones no son portables. La Gateway API es la sucesora, modelando el mismo problema con separación de roles (`GatewayClass` = proveedor de infraestructura, `Gateway` = operador del clúster, `HTTPRoute` = equipo de aplicación) y campos tipados en lugar de anotaciones:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: infra
spec:
  gatewayClassName: envoy
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - { kind: Secret, name: wildcard-example-com-tls }
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: { gateway-access: "true" }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: prod
spec:
  parentRefs:
    - { name: edge, namespace: infra, sectionName: https }
  hostnames: ["shop.example.com"]
  rules:
    # Weighted canary: 5 % of /api traffic to the v2 Service.
    - matches:
        - path: { type: PathPrefix, value: /api }
      backendRefs:
        - { name: api,    port: 80, weight: 95 }
        - { name: api-v2, port: 80, weight: 5 }
      timeouts:
        request: 30s
        backendRequest: 10s
```

El reparto de tráfico por peso es aquí un campo de primera clase, donde en Ingress es una anotación específica de nginx. Ese es todo el argumento para migrar.

### 5.7 NetworkPolicy

La red de pods es plana y completamente abierta por defecto. NetworkPolicy es de permiso aditivo: en cuanto *cualquier* política selecciona un pod para una dirección, esa dirección pasa a ser deny por defecto para ese pod.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}                 # every pod in the namespace
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
        - podSelector:
            matchLabels: { app.kubernetes.io/name: frontend }
      ports:
        - { protocol: TCP, port: 8080 }
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: observability }
      ports:
        - { protocol: TCP, port: 9090 }
  egress:
    # DNS must be allowed explicitly or every lookup fails, which presents
    # as a total, confusing outage.
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: data }
          podSelector:
            matchLabels: { app.kubernetes.io/name: postgres }
      ports:
        - { protocol: TCP, port: 5432 }
    # Egress to an off-cluster payment provider, minus internal RFC1918.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - { protocol: TCP, port: 443 }
```

Tres trampas: (1) **NetworkPolicy la aplica el plugin CNI** — Flannel por sí solo la ignora por completo, y el manifiesto se aplica con éxito sin aplicar nada; (2) olvidar el egress de DNS es la caída autoinfligida más común; (3) en `from:`/`to:`, un `namespaceSelector` y un `podSelector` en el **mismo elemento de la lista** se combinan con AND, mientras que elementos de lista separados se combinan con OR. Esa diferencia de indentación cambia la política por completo.

---

## 6. Configuración, secretos y almacenamiento

### 6.1 Semántica de propagación de ConfigMap y Secret

| Método de consumo | ¿Se actualiza cuando cambia el objeto? | Latencia | Notas |
|---|---|---|---|
| `env` / `envFrom` | **No** | nunca | El entorno se fija al arrancar el contenedor. Requiere reiniciar el pod. |
| Montaje de volumen (objeto completo) | Sí | ~ periodo de sincronización del kubelet + TTL de caché (alrededor de un minuto) | Intercambio atómico de enlace simbólico de todo el directorio |
| Montaje de volumen con `subPath` | **No** | nunca | La sorpresa de configuración más común de todas |
| Volumen `projected` | Sí | igual que arriba | Combina ConfigMap + Secret + downwardAPI + token de SA |

Como las variables de entorno nunca se actualizan, y como una configuración montada que se recarga en caliente de forma silenciosa puede ser peor que un despliegue explícito, el patrón de la anotación `checksum/config` de §4.2 es el estándar: cambiar el contenido del ConfigMap → cambiar la anotación → cambia el hash de la plantilla del pod → ocurre una actualización progresiva normal, observable y reversible.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: api-db
  namespace: prod
type: Opaque
stringData:
  password: "REPLACED-BY-EXTERNAL-SECRETS-OPERATOR"
  url: "postgres://api@pg-0.pg-headless.data.svc.cluster.local:5432/store"
```

Los datos de un `Secret` están codificados en base64, **no cifrados** — se almacenan en etcd en texto plano salvo que el apiserver esté configurado con un `EncryptionConfiguration`, y cualquiera con permiso RBAC de `get secrets` en el namespace puede leerlos. Tratá «es un Secret» como «está separado de los ConfigMaps por motivos de RBAC y auditoría», nada más.

### 6.2 Almacenamiento

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ssd-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
# Delay binding until a Pod is scheduled, so the volume is created in the
# zone the Pod actually landed in. Omitting this on a multi-AZ cluster
# produces Pods that are permanently unschedulable.
volumeBindingMode: WaitForFirstConsumer
```

| Modo de acceso | Significado | Respaldado por |
|---|---|---|
| `ReadWriteOnce` (RWO) | Montable en lectura-escritura por **un nodo** | Almacenamiento de bloques (EBS, RBD, iSCSI, LVM) |
| `ReadWriteOncePod` | Montable en lectura-escritura por exactamente **un Pod** | Controladores CSI que lo soporten; la elección correcta para una base de datos con un solo escritor |
| `ReadOnlyMany` (ROX) | Solo lectura por muchos nodos | Instantáneas, imágenes compartidas |
| `ReadWriteMany` (RWX) | Lectura-escritura por muchos nodos | NFS, CephFS, EFS |

`ReadWriteOnce` es *por nodo*, no por pod — dos pods en el mismo nodo pueden montar ambos un volumen RWO. Si la corrección de tu base de datos depende de un único escritor, `ReadWriteOncePod` es lo que querés.

---

## 7. Docker Swarm

El modo Swarm sigue en los objetivos del examen y es una elección genuinamente razonable para parques pequeños. El diseño es una simplificación deliberada de los mismos conceptos.

### 7.1 Arquitectura

Los managers forman un clúster Raft y mantienen el estado deseado; los workers ejecutan tareas. Un *servicio* declara un estado deseado; el orquestador crea *tareas* (cada tarea es un contenedor más su estado de ciclo de vida), y el planificador asigna tareas a nodos. El tráfico entre nodos se cifra con TLS mutuo usando una CA interna, rotada automáticamente.

El **routing mesh**: cada nodo escucha en el puerto publicado de cada servicio, con independencia de si una tarea de ese servicio se ejecuta localmente, y reenvía a través de la red overlay `ingress`. Esto significa que un balanceador de carga TCP simple delante de *cualquier* nodo funciona.

### 7.2 Arranque del clúster

```
$ docker swarm init --advertise-addr 192.168.178.11 --data-path-port 4789
Swarm initialized: current node (k1r8mv3xq2nz7f5d0plw9aycb) is now a manager.

To add a worker to this swarm, run the following command:

    docker swarm join --token SWMTKN-1-2y8w1kq9x0fj3mvz6bd7hn4pgs5cta0lre8u1o9y3wq7k2m4x-9djv02hbfqz7wsn1xtp3ykgra 192.168.178.11:2377

To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.

$ docker node ls
ID                            HOSTNAME    STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
k1r8mv3xq2nz7f5d0plw9aycb *   swarm-01    Ready     Active         Leader           27.3.1
p7t2ye9nc4bl6hkza0dvxrguj     swarm-02    Ready     Active         Reachable        27.3.1
w3q8fjm1odsx5vbc2rntyk0ap     swarm-03    Ready     Active         Reachable        27.3.1
z6h4bdvq0ntms8xge1rykpc7l     swarm-04    Ready     Active                          27.3.1
z9c1xkte5rwo3fnbj7mhqva28     swarm-05    Ready     Active                          27.3.1
```

El número de managers sigue a Raft: 3 managers toleran 1 fallo, 5 toleran 2. **Nunca ejecutes un número par** — 4 managers toleran el mismo fallo único que 3 mientras añaden un modo de fallo.

```
$ docker node update --label-add tier=edge swarm-04
swarm-04
$ docker node update --availability drain swarm-03
swarm-03
```

`drain` es el análogo en Swarm de `kubectl drain`: las tareas existentes se reprograman en otro sitio y no se ubican nuevas.

### 7.3 Un archivo de stack completo

```yaml
# docker-stack.yml — deploy with: docker stack deploy -c docker-stack.yml storefront
version: "3.9"

services:
  api:
    image: registry.internal/storefront/api:2.4.1
    networks:
      - backend
      - frontend
    ports:
      - target: 8080
        published: 8080
        protocol: tcp
        mode: ingress          # ingress = routing mesh; host = bypass it
    environment:
      LOG_LEVEL: info
      UPSTREAM_TIMEOUT_MS: "2500"
    secrets:
      - source: db_password
        target: /run/secrets/db_password
        mode: 0400
    configs:
      - source: api_config_v3
        target: /etc/api/application.yaml
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/healthz/ready"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 40s
    stop_grace_period: 45s
    deploy:
      mode: replicated
      replicas: 6
      endpoint_mode: vip       # vip (default) or dnsrr for client-side LB
      update_config:
        parallelism: 2
        delay: 20s
        order: start-first     # surge, like maxSurge>0 / maxUnavailable=0
        failure_action: rollback
        monitor: 60s
        max_failure_ratio: 0.1
      rollback_config:
        parallelism: 2
        delay: 10s
        order: stop-first
        failure_action: pause
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 5
        window: 120s
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          cpus: "0.25"
          memory: 512M
      placement:
        max_replicas_per_node: 2
        constraints:
          - node.role == worker
          - node.labels.tier == edge
        preferences:
          - spread: node.labels.zone
      labels:
        com.example.service: api

  pg:
    image: registry.internal/postgres:16.4
    networks: [backend]
    volumes:
      - pgdata:/var/lib/postgresql/data
    secrets:
      - db_password
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      PGDATA: /var/lib/postgresql/data/pgdata
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.labels.storage == local-ssd
      restart_policy:
        condition: any
        delay: 10s
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 4G

  node-agent:
    image: quay.io/prometheus/node-exporter:v1.8.2
    command:
      - --path.rootfs=/host
    networks: [backend]
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
    deploy:
      mode: global            # the Swarm equivalent of a DaemonSet
      resources:
        limits:
          memory: 128M

networks:
  frontend:
    driver: overlay
    attachable: false
  backend:
    driver: overlay
    driver_opts:
      encrypted: "true"       # IPsec on the VXLAN data path; costs throughput
    attachable: false

volumes:
  pgdata:
    driver: local

secrets:
  db_password:
    external: true

configs:
  api_config_v3:              # configs are immutable: version the NAME
    file: ./config/application.yaml
```

Despliegue e inspección:

```
$ echo -n 'S3cr3t-Rot4ted-2026Q3' | docker secret create db_password -
u8kq2mzx0v7ndprty1achw3fe

$ docker stack deploy -c docker-stack.yml storefront
Creating network storefront_backend
Creating network storefront_frontend
Creating config storefront_api_config_v3
Creating service storefront_api
Creating service storefront_pg
Creating service storefront_node-agent

$ docker stack services storefront
ID             NAME                       MODE         REPLICAS   IMAGE                                  PORTS
9v0kxq2mzt4a   storefront_api             replicated   6/6        registry.internal/storefront/api:2.4.1 *:8080->8080/tcp
c3n7yfdb1lo8   storefront_node-agent      global       5/5        quay.io/prometheus/node-exporter:v1.8.2
x1p4wsjr6heu   storefront_pg              replicated   1/1        registry.internal/postgres:16.4

$ docker service ps storefront_api --no-trunc --filter desired-state=running
ID             NAME                IMAGE                                     NODE       DESIRED STATE   CURRENT STATE            ERROR   PORTS
q7m2v8x1cnwr   storefront_api.1    registry.internal/storefront/api:2.4.1    swarm-04   Running         Running 4 minutes ago
b4t9zf0kdslp   storefront_api.2    registry.internal/storefront/api:2.4.1    swarm-05   Running         Running 4 minutes ago
h1c6yrn3axkv   storefront_api.3    registry.internal/storefront/api:2.4.1    swarm-04   Running         Running 3 minutes ago
m8w0dqlt2feb   storefront_api.4    registry.internal/storefront/api:2.4.1    swarm-05   Running         Running 3 minutes ago
n5j3xghp7oyu   storefront_api.5    registry.internal/storefront/api:2.4.1    swarm-02   Running         Running 3 minutes ago
r2k9lbvs4ndc   storefront_api.6    registry.internal/storefront/api:2.4.1    swarm-02   Running         Running 3 minutes ago
```

Actualización progresiva y rollback:

```
$ docker service update --image registry.internal/storefront/api:2.5.0 storefront_api
storefront_api
overall progress: 6 out of 6 tasks
1/6: running   [==================================================>]
2/6: running   [==================================================>]
3/6: running   [==================================================>]
4/6: running   [==================================================>]
5/6: running   [==================================================>]
6/6: running   [==================================================>]
verify: Service storefront_api converged

$ docker service inspect storefront_api \
    --format '{{.UpdateStatus.State}} {{.UpdateStatus.Message}}'
completed update completed

$ docker service rollback storefront_api
storefront_api
rollback: manually requested rollback
overall progress: rolling back update: 6 out of 6 tasks
verify: Service storefront_api converged
```

Un rollback automático disparado por `failure_action: rollback` se lee así:

```
$ docker service inspect storefront_api --format '{{json .UpdateStatus}}' | jq
{
  "State": "rollback_completed",
  "StartedAt": "2026-09-03T09:14:02.118374Z",
  "CompletedAt": "2026-09-03T09:16:47.902551Z",
  "Message": "rollback completed"
}
```

### 7.4 Mapa de conceptos Kubernetes ↔ Swarm

| Concepto | Kubernetes | Swarm |
|---|---|---|
| Unidad declarativa | Deployment / StatefulSet / DaemonSet | Service (`mode: replicated` / `global`) |
| Grupo de archivos | Chart de Helm / Kustomize | Stack (`docker stack deploy -c`) |
| Instancia | Pod (puede contener varios contenedores) | Task (exactamente un contenedor) |
| Despliegue con surge | `maxSurge > 0`, `maxUnavailable: 0` | `order: start-first` |
| Tamaño de lote del despliegue | derivado de surge/unavailable | `parallelism` |
| Rollback automático | ninguno integrado (compuerta de CI sobre `rollout status`) | `failure_action: rollback` |
| Descubrimiento | VIP ClusterIP + CoreDNS | VIP de servicio + DNS embebido |
| Antiafinidad | `topologySpreadConstraints` / podAntiAffinity | `placement.preferences: spread` |
| Presupuesto de interrupción | PodDisruptionBudget | ninguno |
| Silenciar un nodo | `kubectl drain` | `docker node update --availability drain` |
| Objeto de configuración | ConfigMap (mutable) | Config (**inmutable**, versioná el nombre) |

---

## 8. Infraestructura: arrancar un clúster de Kubernetes con kubeadm

### 8.1 Preparación del nodo

```bash
# --- Kernel modules and sysctls required by the CNI and kube-proxy --------
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
sudo sysctl --system

# --- Swap must be off (or the kubelet configured to tolerate it) ---------
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
```

### 8.2 containerd

```toml
# /etc/containerd/config.toml  (containerd 1.7.x; containerd 2.x uses version = 3)
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"

  [plugins."io.containerd.grpc.v1.cri".containerd]
    default_runtime_name = "runc"
    discard_unpacked_layers = true

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        # MUST match the kubelet cgroup driver. Mismatch => pods that start
        # and are then killed with confusing OOM/cgroup errors.
        SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
```

```
$ sudo systemctl restart containerd && sudo systemctl is-active containerd
active

$ sudo ctr version
Client:
  Version:  1.7.22
  Revision: c4e9c0d0e3b1a4f0f1e2d3a5b6c7d8e9f0a1b2c3
  Go version: go1.22.7

Server:
  Version:  1.7.22
  UUID: 3f9c1a2e-7d84-4b60-9e15-2c8a0d6f4b71
```

### 8.3 Inicialización del plano de control, totalmente declarativa

```yaml
# kubeadm-config.yaml
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.178.11
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - { name: node-ip, value: "192.168.178.11" }
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.2
clusterName: leloir-prod
controlPlaneEndpoint: "k8s-api.internal:6443"   # a VIP or LB, set it NOW
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - { name: quota-backend-bytes, value: "8589934592" }   # 8 GiB
      - { name: auto-compaction-retention, value: "1h" }
apiServer:
  certSANs:
    - k8s-api.internal
    - 192.168.178.10
    - 192.168.178.11
  extraArgs:
    - { name: audit-log-path,      value: /var/log/kubernetes/audit.log }
    - { name: audit-log-maxage,    value: "30" }
    - { name: audit-log-maxbackup, value: "10" }
    - { name: audit-log-maxsize,   value: "100" }
    - { name: audit-policy-file,   value: /etc/kubernetes/audit-policy.yaml }
    - { name: encryption-provider-config, value: /etc/kubernetes/encryption.yaml }
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
      pathType: File
    - name: audit-logs
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      pathType: DirectoryOrCreate
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption.yaml
      mountPath: /etc/kubernetes/encryption.yaml
      readOnly: true
      pathType: File
controllerManager:
  extraArgs:
    - { name: bind-address, value: "0.0.0.0" }
    - { name: node-monitor-period, value: "5s" }
    - { name: node-monitor-grace-period, value: "40s" }
scheduler:
  extraArgs:
    - { name: bind-address, value: "0.0.0.0" }
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
rotateCertificates: true
maxPods: 110
# Reserve capacity so a runaway pod cannot starve kubelet/containerd/sshd.
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "1Gi"
evictionSoftGracePeriod:
  memory.available: "2m"
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
  strictARP: true          # required by MetalLB in L2 mode
```

```
$ sudo kubeadm init --config kubeadm-config.yaml --upload-certs
[init] Using Kubernetes version: v1.33.2
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes cluster
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [cp-01 k8s-api.internal kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 192.168.178.11 192.168.178.10]
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] Generating "sa" key and public key
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
[kubeconfig] Writing "kubelet.conf" kubeconfig file
[kubeconfig] Writing "controller-manager.conf" kubeconfig file
[kubeconfig] Writing "scheduler.conf" kubeconfig file
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[kubelet-start] Starting the kubelet
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[apiclient] All control plane components are healthy after 9.503816 seconds
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system
[upload-certs] Using certificate key: 4a2f9c1e7b53d8064af1c2e93b07d5486ea19f2c3d0b7845e6a1c9f30b2d5e74
[mark-control-plane] Marking the node cp-01 as control-plane by adding the taints [node-role.kubernetes.io/control-plane:NoSchedule]
[bootstrap-token] Using token: 8j3k2q.4mv7z0xd1pqrt6bn
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes running the following command on each as root:

  kubeadm join k8s-api.internal:6443 --token 8j3k2q.4mv7z0xd1pqrt6bn \
        --discovery-token-ca-cert-hash sha256:1f9d0c73a248e6b5f01c93da7e2b48605cf1a739e0b6d2843c5f7a109e4b2d68 \
        --control-plane --certificate-key 4a2f9c1e7b53d8064af1c2e93b07d5486ea19f2c3d0b7845e6a1c9f30b2d5e74

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join k8s-api.internal:6443 --token 8j3k2q.4mv7z0xd1pqrt6bn \
        --discovery-token-ca-cert-hash sha256:1f9d0c73a248e6b5f01c93da7e2b48605cf1a739e0b6d2843c5f7a109e4b2d68

$ mkdir -p "$HOME/.kube" && sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config" \
    && sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

$ kubectl get nodes
NAME    STATUS     ROLES           AGE   VERSION
cp-01   NotReady   control-plane   62s   v1.33.2
```

`NotReady` es **lo esperado** aquí: no hay CNI instalado, así que el kubelet informa `NetworkReady=false`.

```
$ kubectl -n kube-system describe node cp-01 | grep -A2 'Ready '
  Ready   False   Fri, 03 Sep 2026 09:41:12  KubeletNotReady
    container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady
    message:Network plugin returns error: cni plugin not initialized
```

Instalá el CNI (coincidiendo con `podSubnet` de la configuración), y volvé a comprobar:

```
$ helm repo add cilium https://helm.cilium.io/ && helm repo update
$ helm install cilium cilium/cilium --version 1.16.3 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
    --set kubeProxyReplacement=false \
    --set k8sServiceHost=k8s-api.internal --set k8sServicePort=6443

$ kubectl get nodes -o wide
NAME      STATUS   ROLES           AGE     VERSION   INTERNAL-IP       OS-IMAGE            KERNEL-VERSION      CONTAINER-RUNTIME
cp-01     Ready    control-plane   6m18s   v1.33.2   192.168.178.11    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
cp-02     Ready    control-plane   4m02s   v1.33.2   192.168.178.12    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
cp-03     Ready    control-plane   3m47s   v1.33.2   192.168.178.13    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-07   Ready    <none>          2m11s   v1.33.2   192.168.178.17    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-08   Ready    <none>          2m09s   v1.33.2   192.168.178.18    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
node-09   Ready    <none>          2m05s   v1.33.2   192.168.178.19    Debian GNU/Linux 12 6.1.0-25-amd64      containerd://1.7.22
```

### 8.4 Actualizaciones y copia de seguridad de etcd

```
$ sudo kubeadm upgrade plan
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: v1.33.2
[upgrade/versions] kubeadm version: v1.34.0

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT       TARGET
kubelet     6 x v1.33.2   v1.34.0

Upgrade to the latest stable version:

COMPONENT                 CURRENT   TARGET
kube-apiserver            v1.33.2   v1.34.0
kube-controller-manager   v1.33.2   v1.34.0
kube-scheduler            v1.33.2   v1.34.0
kube-proxy                v1.33.2   v1.34.0
CoreDNS                   v1.11.3   v1.11.3
etcd                      3.5.16    3.5.16

You can now apply the upgrade by executing the following command:

        kubeadm upgrade apply v1.34.0
```

La secuencia por nodo worker — este es el bucle que debe respetar los PodDisruptionBudgets:

```
$ kubectl drain node-07 --ignore-daemonsets --delete-emptydir-data --timeout=600s
node/node-07 cordoned
Warning: ignoring DaemonSet-managed Pods: observability/node-exporter-4xk9d, kube-system/cilium-p2m7v
evicting pod prod/api-6c47d9f8b4-x9pql
evicting pod prod/api-6c47d9f8b4-tz84r
error when evicting pods/"api-6c47d9f8b4-tz84r" -n "prod" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/api-6c47d9f8b4-x9pql evicted
pod/api-6c47d9f8b4-tz84r evicted
node/node-07 drained

$ sudo kubeadm upgrade node && \
  sudo apt-get install -y --allow-change-held-packages kubelet=1.34.0-1.1 kubectl=1.34.0-1.1 && \
  sudo systemctl daemon-reload && sudo systemctl restart kubelet

$ kubectl uncordon node-07
node/node-07 uncordoned
```

El reintento ante `Cannot evict pod as it would violate the pod's disruption budget` es el PDB haciendo exactamente su trabajo: serializar el drenado frente al despliegue.

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-$(date -u +%Y%m%dT%H%M%SZ).db
{"level":"info","msg":"created temporary db file","path":"/var/backups/etcd-20260903T094812Z.db.part"}
{"level":"info","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
{"level":"info","msg":"fetched snapshot","endpoint":"https://127.0.0.1:2379","size":"142 MB","took":"1.884 s"}
Snapshot saved at /var/backups/etcd-20260903T094812Z.db
```

**Una copia de seguridad de etcd sin probar no es una copia de seguridad.** Simulacro de restauración: `etcdutl snapshot restore <file> --data-dir /var/lib/etcd-restore`, reapuntar el manifiesto del pod estático, reiniciar el kubelet en cada nodo del plano de control.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 La escalera de diagnóstico

Trabajá de arriba hacia abajo; no te saltes peldaños. Cada peldaño responde una pregunta distinta, y la respuesta determina si hay que descender más.

```
1. kubectl get <kind> -o wide          → what does the API believe?
2. kubectl describe <kind>/<name>      → what do controllers say (Events, Conditions)?
3. kubectl get events --sort-by=...    → cluster-wide ordering of what happened
4. kubectl logs [-p] [-c]              → what did the application say (and the PREVIOUS instance)?
5. kubectl exec / kubectl debug        → interactive, inside the failure domain
6. ssh node → journalctl -u kubelet    → what does the node agent say?
7. ssh node → crictl ps/logs/inspect   → below the kubelet, at the runtime
```

```
$ kubectl -n prod get events --sort-by=.lastTimestamp | tail -12
LAST SEEN   TYPE      REASON              OBJECT                        MESSAGE
3m12s       Normal    Scheduled           pod/api-7f9a1c2e05-k4pmz      Successfully assigned prod/api-7f9a1c2e05-k4pmz to node-08
3m10s       Normal    Pulling             pod/api-7f9a1c2e05-k4pmz      Pulling image "registry.internal/storefront/api:2.5.0"
2m58s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Failed to pull image "registry.internal/storefront/api:2.5.0": rpc error: code = NotFound desc = failed to pull and unpack image: not found
2m58s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Error: ErrImagePull
2m31s       Normal    BackOff             pod/api-7f9a1c2e05-k4pmz      Back-off pulling image "registry.internal/storefront/api:2.5.0"
2m31s       Warning   Failed              pod/api-7f9a1c2e05-k4pmz      Error: ImagePullBackOff
```

Fijate en que los Events se almacenan en etcd con un **TTL de 1 hora por defecto**. Un incidente revisado a la mañana siguiente no tiene Events. Enviálos a tu almacén de logs, o estarás depurando a ciegas.

### 9.2 Catálogo de fallos

| Síntoma | Causas más probables | Primer comando | Evidencia decisiva |
|---|---|---|---|
| `Pending`, sin nodo asignado | Allocatable insuficiente; taints sin toleration; spread topológico insatisfacible; PVC sin enlazar | `kubectl describe pod` | `0/6 nodes are available: 3 Insufficient cpu, 3 node(s) had untolerated taint {...}` |
| `Pending` con `WaitForFirstConsumer` | Normal — el PVC se enlaza tras la planificación. Si se atasca: no hay controlador CSI, o no hay capacidad en la zona | `kubectl describe pvc` | `waiting for first consumer to be created` / `ProvisioningFailed` |
| `ImagePullBackOff` / `ErrImagePull` | Etiqueta incorrecta; registro privado sin `imagePullSecrets`; registro caído; límite de tasa | `kubectl describe pod` | `not found`, `401 Unauthorized`, `toomanyrequests` |
| `CrashLoopBackOff` | La app sale al arrancar; falta configuración; liveness fallando; entrypoint incorrecto | `kubectl logs --previous` | La propia traza de pila de la aplicación |
| `CreateContainerConfigError` | El ConfigMap/Secret o la clave referenciados no existen | `kubectl describe pod` | `secret "api-db" not found` |
| `CreateContainerError` | command/args erróneos; rootfs de solo lectura donde la app escribe; securityContext incorrecto | `kubectl describe pod` | `exec: "/app/serve": stat ... no such file` |
| `RunContainerError` | Desajuste de runtime/driver de cgroup; fallo de hook | `journalctl -u kubelet` | `failed to create containerd task` |
| `OOMKilled` (exit 137) | Límite de memoria por debajo del working set; heap de JVM/Go ajeno al cgroup | `kubectl describe pod` | `Last State: Terminated, Reason: OOMKilled` |
| `Init:CrashLoopBackOff` | Dependencia del init container no lista | `kubectl logs -c <init>` | Salida del init container |
| Pod Ready pero el Service no devuelve nada | El selector no coincide con las etiquetas; `targetPort` incorrecto; readiness nunca verdadero | `kubectl get endpointslices` | `ENDPOINTS: <none>` |
| 502/504 intermitentes durante el despliegue | Sin drenado `preStop`; readiness demasiado optimista; `minReadySeconds: 0` | Prueba de carga durante el despliegue | Los errores se correlacionan exactamente con las terminaciones de pods |
| `Terminating` para siempre | Finalizer no eliminado; desconexión de volumen colgada; nodo NotReady | `kubectl get pod -o yaml` | `metadata.finalizers` poblado |
| Nodo `NotReady` | kubelet caído; CNI caído; presión de disco/memoria; desfase de reloj | `kubectl describe node` | `KubeletNotReady`, `DiskPressure=True` |
| Aparecen pods `Evicted` | Nodo bajo presión de `evictionHard` | `kubectl describe node` | `The node was low on resource: ephemeral-storage` |
| Falla la resolución DNS en todo el clúster | Pods de CoreDNS caídos; NetworkPolicy bloqueando UDP/53; tabla conntrack llena | `kubectl -n kube-system logs -l k8s-app=kube-dns` | `SERVFAIL`, `i/o timeout` |
| El drenado nunca termina | El PDB no puede satisfacerse; pod no gestionado (a secas) | `kubectl get pdb -A` | `ALLOWED DISRUPTIONS: 0` |
| `429 Too Many Requests` de la API | Un controlador en bucle caliente; flujo de APF hambriento | `kubectl get --raw /metrics \| grep apiserver_flowcontrol` | Contadores de peticiones rechazadas subiendo |

### 9.3 Diagnóstico resuelto: pod no planificable

```
$ kubectl -n prod get pods -o wide
NAME                    READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
api-7f9a1c2e05-b3nqz    0/1     Pending   0          4m8s  <none>   <none>   <none>           <none>

$ kubectl -n prod describe pod api-7f9a1c2e05-b3nqz | sed -n '/^Events/,$p'
Events:
  Type     Reason            Age                  From               Message
  ----     ------            ----                 ----               -------
  Warning  FailedScheduling  4m2s                 default-scheduler  0/6 nodes are available: 3 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu, 1 node(s) didn't match pod topology spread constraints. preemption: 0/6 nodes are available: 3 Preemption is not helpful for scheduling, 3 No preemption victims found for incoming pod.

$ kubectl describe node node-08 | sed -n '/Allocated resources/,/^Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                7250m (96%)   4200m (56%)
  memory             13Gi (89%)    15Gi (102%)
  ephemeral-storage  6Gi (12%)     18Gi (37%)

$ kubectl get nodes -L topology.kubernetes.io/zone
NAME      STATUS   ROLES           AGE   VERSION   ZONE
node-07   Ready    <none>          41d   v1.33.2   eu-west-1a
node-08   Ready    <none>          41d   v1.33.2   eu-west-1a
node-09   Ready    <none>          41d   v1.33.2   eu-west-1b
```

Lectura: node-09 (`eu-west-1b`) es el único nodo con capacidad, pero colocar el pod ahí empujaría el desvío de zona más allá de `maxSkew: 1`, y la restricción es `DoNotSchedule`. El arreglo correcto es capacidad en `eu-west-1a`, **no** relajar la restricción — la restricción está expresando un requisito de disponibilidad real.

### 9.4 Diagnóstico resuelto: CrashLoopBackOff

```
$ kubectl -n prod get pod api-7f9a1c2e05-q8wmr
NAME                   READY   STATUS             RESTARTS      AGE
api-7f9a1c2e05-q8wmr   0/1     CrashLoopBackOff   5 (48s ago)   4m12s

$ kubectl -n prod logs api-7f9a1c2e05-q8wmr --previous --tail=20
2026-09-03T10:02:41.118Z INFO  storefront.api  starting, version=2.5.0
2026-09-03T10:02:41.402Z INFO  storefront.db   connecting host=pg-0.pg-headless.data.svc.cluster.local port=5432
2026-09-03T10:02:46.409Z ERROR storefront.db   dial tcp: lookup pg-0.pg-headless.data.svc.cluster.local: i/o timeout
2026-09-03T10:02:46.410Z FATAL storefront      cannot start without database, exiting

$ kubectl -n prod describe pod api-7f9a1c2e05-q8wmr | sed -n '/Last State/,/Ready/p'
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Thu, 03 Sep 2026 10:02:41 +0200
      Finished:     Thu, 03 Sep 2026 10:02:46 +0200
    Ready:          False
```

Exit 1 con un mensaje limpio de la aplicación: esto no es una caída de infraestructura, es un fallo de dependencia. El DNS agotó el tiempo de espera. Confirmalo desde dentro del mismo namespace de red usando un contenedor efímero de depuración — lo que evita la trampa de hacer `exec` en una imagen distroless que no tiene shell:

```
$ kubectl -n prod debug -it api-7f9a1c2e05-q8wmr \
    --image=registry.internal/netshoot:0.13 \
    --target=api --profile=netadmin -- bash
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-9mtqx.

debugger:~# dig +short +time=2 +tries=1 pg-0.pg-headless.data.svc.cluster.local
;; communications error to 10.96.0.10#53: timed out

debugger:~# nc -vz 10.96.0.10 53
nc: connect to 10.96.0.10 port 53 (tcp) failed: Connection timed out
```

El propio DNS es inalcanzable desde este pod. Como CoreDNS está sano en todo el clúster, sospechá de la política:

```
$ kubectl -n prod get networkpolicy
NAME               POD-SELECTOR                    AGE
default-deny-all   <none>                          9m
api-allow          app.kubernetes.io/name=api      9m

$ kubectl -n prod get networkpolicy api-allow -o jsonpath='{.spec.egress[*].ports[*].port}{"\n"}'
5432
```

Causa raíz: `default-deny-all` cerró el egress, y `api-allow` concede egress a PostgreSQL pero **no a kube-dns en UDP/53**. La política de §5.7 incluye esa regla exactamente por este motivo.

### 9.5 Diagnóstico resuelto: Service sin endpoints

```
$ kubectl -n prod get svc api
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
api    ClusterIP   10.107.44.19    <none>        80/TCP    41d

$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
api-7fk2x   IPv4          <unset> <unset>     41d

$ kubectl -n prod get svc api -o jsonpath='{.spec.selector}{"\n"}'
{"app.kubernetes.io/component":"backend","app.kubernetes.io/name":"api"}

$ kubectl -n prod get pods --show-labels | head -3
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
api-6c47d9f8b4-x9pql   1/1     Running   0          22m   app.kubernetes.io/name=api,app.kubernetes.io/component=api-backend,pod-template-hash=6c47d9f8b4

$ kubectl -n prod get pods -l 'app.kubernetes.io/name=api,app.kubernetes.io/component=backend'
No resources found in prod namespace.
```

El Service selecciona `component=backend`; los pods llevan `component=api-backend`. La API aceptó ambos objetos — un selector de Service que no coincide con nada es perfectamente válido. **`ENDPOINTS: <none>` en un Service cuyos pods están Running es siempre una de estas tres cosas: desajuste de etiquetas, readiness que nunca llega a verdadero, o un `targetPort` que nombra un puerto que el contenedor no declara.** Comprobalas en ese orden.

### 9.6 Por debajo del kubelet

```
$ ssh node-08 'sudo journalctl -u kubelet --since "10 min ago" --no-pager | tail -6'
Sep 03 10:07:12 node-08 kubelet[1187]: E0903 10:07:12.443901    1187 pod_workers.go:1301] "Error syncing pod, skipping" err="failed to \"StartContainer\" for \"api\" with CrashLoopBackOff: \"back-off 2m40s restarting failed container=api pod=api-7f9a1c2e05-q8wmr_prod(3f2c...)\"" pod="prod/api-7f9a1c2e05-q8wmr"
Sep 03 10:07:19 node-08 kubelet[1187]: I0903 10:07:19.008233    1187 kubelet_node_status.go:497] "Recording event message for node" node="node-08" event="NodeHasNoDiskPressure"

$ ssh node-08 'sudo crictl ps -a --name api --no-trunc | head -3'
CONTAINER                                                           IMAGE                                                               CREATED             STATE      NAME   ATTEMPT   POD ID
a1f4c9d02b7e3856f0c1a2b3d4e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f80   registry.internal/storefront/api@sha256:5d3b0f2ac71e8fbd...          2 minutes ago       Exited     api    6         9c2e1f7a0d5b3

$ ssh node-08 'sudo crictl logs --tail 5 a1f4c9d02b7e3856f0c1a2b3d4e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f80'
2026-09-03T10:07:10.882Z FATAL storefront      cannot start without database, exiting

$ ssh node-08 'sudo crictl stats --output table | head -4'
CONTAINER           CPU %     MEM       DISK      INODES
0d5b3c2e1f7a9       0.42      182.4MB   28.1MB    142
3e8f1a0c7d2b4       11.83     498.2MB   96.7MB    511
```

`crictl` habla directamente con el socket CRI, saltándose el kubelet y el apiserver. Es la herramienta correcta cuando el propio kubelet es sospechoso, o cuando los contenedores de un pod existen en el runtime pero nunca aparecen en la API.

### 9.7 Diagnóstico del lado de Swarm

```
$ docker service ps storefront_api --no-trunc
ID             NAME                 IMAGE                                    NODE       DESIRED STATE   CURRENT STATE             ERROR                                                                                          PORTS
k9m2p0x7vzqt   storefront_api.3     registry.internal/storefront/api:2.5.0   swarm-04   Ready           Rejected 2 seconds ago    "No such image: registry.internal/storefront/api:2.5.0"
b7f1n4dwsylc    \_ storefront_api.3 registry.internal/storefront/api:2.5.0   swarm-04   Shutdown        Rejected 12 seconds ago   "No such image: registry.internal/storefront/api:2.5.0"
q3h8zkr0tabm    \_ storefront_api.3 registry.internal/storefront/api:2.4.1   swarm-04   Shutdown        Shutdown 15 seconds ago

$ docker service logs --tail 20 --timestamps storefront_api
storefront_api.5.n5j3xghp7oyu@swarm-02 | 2026-09-03T10:11:04.221Z INFO  listening on :8080
storefront_api.6.r2k9lbvs4ndc@swarm-02 | 2026-09-03T10:11:04.918Z INFO  listening on :8080

$ docker inspect --format '{{json .Status}}' $(docker ps -aq --filter label=com.docker.swarm.service.name=storefront_api | head -1) | jq
{
  "State": "failed",
  "Timestamp": "2026-09-03T10:11:31.442017Z",
  "Message": "started",
  "Err": "task: non-zero exit (1)",
  "ContainerStatus": { "ExitCode": 1 }
}
```

El detalle específico de Swarm visible aquí: `Rejected` con `No such image` significa que el *nodo worker* no pudo hacer pull. Los managers no distribuyen imágenes. O bien cada nodo puede alcanzar el registro con credenciales válidas (`docker service create --with-registry-auth` las propaga), o no se planifica nada.

### 9.8 Una lista de verificación que realmente detecta regresiones

```bash
#!/usr/bin/env bash
# verify-rollout.sh — gate a deployment in CI. Exits non-zero on any failure.
set -euo pipefail

NS="${1:?namespace}"; DEPLOY="${2:?deployment}"; TIMEOUT="${3:-600s}"

echo "==> 1. Server-side validation without applying"
kubectl -n "$NS" apply --dry-run=server -f manifests/ >/dev/null

echo "==> 2. Rollout reaches completion within the progress deadline"
kubectl -n "$NS" rollout status "deployment/$DEPLOY" --timeout="$TIMEOUT"

echo "==> 3. Every replica is Ready (guards against a stale Available condition)"
desired=$(kubectl -n "$NS" get "deployment/$DEPLOY" -o jsonpath='{.spec.replicas}')
ready=$(kubectl -n "$NS" get "deployment/$DEPLOY" -o jsonpath='{.status.readyReplicas}')
[[ "${ready:-0}" == "$desired" ]] || { echo "FAIL: ready=${ready:-0}/$desired"; exit 1; }

echo "==> 4. No container has restarted since the rollout"
restarts=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$DEPLOY" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' \
  | awk '{s+=$1} END {print s+0}')
[[ "$restarts" -eq 0 ]] || { echo "FAIL: $restarts restarts observed"; exit 1; }

echo "==> 5. The Service actually has ready endpoints"
eps=$(kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=$DEPLOY" \
  -o jsonpath='{range .items[*]}{range .endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}{end}' \
  | grep -c . || true)
[[ "$eps" -ge 1 ]] || { echo "FAIL: Service $DEPLOY has no ready endpoints"; exit 1; }
echo "    $eps ready endpoints"

echo "==> 6. The PDB can still tolerate a node drain"
allowed=$(kubectl -n "$NS" get "pdb/$DEPLOY" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo 0)
[[ "$allowed" -ge 1 ]] || { echo "FAIL: PDB allows 0 disruptions; the next drain will hang"; exit 1; }

echo "==> 7. No Warning events in the namespace in the last 5 minutes"
if kubectl -n "$NS" get events --field-selector type=Warning \
     -o go-template='{{range .items}}{{.lastTimestamp}} {{.reason}} {{.message}}{{"\n"}}{{end}}' | grep -q .; then
  kubectl -n "$NS" get events --field-selector type=Warning
  echo "FAIL: warning events present"; exit 1
fi

echo "ALL CHECKS PASSED"
```

```
$ ./verify-rollout.sh prod api
==> 1. Server-side validation without applying
==> 2. Rollout reaches completion within the progress deadline
deployment "api" successfully rolled out
==> 3. Every replica is Ready (guards against a stale Available condition)
==> 4. No container has restarted since the rollout
==> 5. The Service actually has ready endpoints
    6 ready endpoints
==> 6. The PDB can still tolerate a node drain
==> 7. No Warning events in the namespace in the last 5 minutes
ALL CHECKS PASSED
```

El paso 5 es el que la mayoría de los pipelines omite, y es el que atrapa la clase de error de §9.5: un despliegue que «tiene éxito» mientras sirve cero tráfico.

### 9.9 Salud del plano de control

```
$ kubectl get --raw '/livez?verbose' | head -14
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/start-kube-apiserver-identity-lease-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]shutdown ok
livez check passed

$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://192.168.178.11:2379,https://192.168.178.12:2379,https://192.168.178.13:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------------+------------------+---------+---------+-----------+-----------+------------+
|           ENDPOINT           |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM | RAFT INDEX |
+------------------------------+------------------+---------+---------+-----------+-----------+------------+
| https://192.168.178.11:2379  | 8e9c1f0a2b3d4e57 |  3.5.16 |  142 MB |      true |        14 |   48211952 |
| https://192.168.178.12:2379  | 1a2b3c4d5e6f7081 |  3.5.16 |  142 MB |     false |        14 |   48211952 |
| https://192.168.178.13:2379  | 9f8e7d6c5b4a3928 |  3.5.16 |  141 MB |     false |        14 |   48211951 |
+------------------------------+------------------+---------+---------+-----------+-----------+------------+

$ kubectl get --raw /metrics | grep -E '^apiserver_request_duration_seconds_bucket\{.*verb="LIST".*le="1"' | head -2
apiserver_request_duration_seconds_bucket{component="apiserver",group="",resource="pods",scope="cluster",subresource="",verb="LIST",version="v1",le="1"} 41283
```

Cuatro señales del plano de control que merecen alerta, por orden de prioridad: p99 de `etcd_disk_wal_fsync_duration_seconds` > 25 ms; `etcd_server_leader_changes_seen_total` en aumento; tasa de `apiserver_request_total{code=~"5.."}`; `apiserver_flowcontrol_rejected_requests_total` distinto de cero.

### 9.10 Caducidad de certificados — la caída programada

Los certificados de cliente y de servidor emitidos por kubeadm son válidos durante un año y se renuevan con `kubeadm upgrade`. Un clúster que nunca se actualiza muere, por tanto, en su primer cumpleaños.

```
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Sep 03, 2027 07:41 UTC   364d            ca                      no
apiserver                  Sep 03, 2027 07:41 UTC   364d            ca                      no
apiserver-etcd-client      Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
apiserver-kubelet-client   Sep 03, 2027 07:41 UTC   364d            ca                      no
controller-manager.conf    Sep 03, 2027 07:41 UTC   364d            ca                      no
etcd-healthcheck-client    Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
etcd-peer                  Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
etcd-server                Sep 03, 2027 07:41 UTC   364d            etcd-ca                  no
front-proxy-client         Sep 03, 2027 07:41 UTC   364d            front-proxy-ca           no
scheduler.conf             Sep 03, 2027 07:41 UTC   364d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Sep 01, 2036 07:41 UTC   9y              no
etcd-ca                 Sep 01, 2036 07:41 UTC   9y              no
front-proxy-ca          Sep 01, 2036 07:41 UTC   9y              no
```

Fijate en que los certificados de *cliente* del kubelet rotan automáticamente (`rotateCertificates: true`); los certificados del plano de control de arriba, no.

---

## 10. Referencia consolidada del operador

```
# --- Kubernetes: state and topology -------------------------------------
kubectl get pods -A -o wide --field-selector status.phase!=Running
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -20
kubectl get events -A --sort-by=.lastTimestamp --field-selector type=Warning
kubectl top nodes ; kubectl top pods -A --sort-by=memory
kubectl describe node <node> | sed -n '/Allocated resources/,/^Events/p'
kubectl api-resources --verbs=list --namespaced -o name
kubectl explain deployment.spec.strategy.rollingUpdate --recursive

# --- Kubernetes: rollout control ----------------------------------------
kubectl rollout status  deployment/<d> -n <ns> --timeout=10m
kubectl rollout history deployment/<d> -n <ns> --revision=4
kubectl rollout pause   deployment/<d> -n <ns>     # batch several edits
kubectl rollout resume  deployment/<d> -n <ns>
kubectl rollout undo    deployment/<d> -n <ns> --to-revision=4
kubectl rollout restart deployment/<d> -n <ns>     # re-pull, re-read secrets

# --- Kubernetes: diagnosis ----------------------------------------------
kubectl logs <pod> -c <ctr> --previous --timestamps --tail=200
kubectl logs -f -l app.kubernetes.io/name=api --max-log-requests=10
kubectl debug -it <pod> --image=netshoot --target=<ctr> --profile=netadmin
kubectl debug node/<node> -it --image=busybox --profile=sysadmin
kubectl auth can-i --list --as=system:serviceaccount:prod:api -n prod
kubectl get --raw '/livez?verbose'
kubectl port-forward -n prod svc/api 8080:80

# --- Kubernetes: node lifecycle -----------------------------------------
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
kubectl uncordon <node>
kubectl taint nodes <node> workload=batch:NoSchedule

# --- CRI (on the node, below the kubelet) -------------------------------
sudo crictl pods ; sudo crictl ps -a ; sudo crictl images
sudo crictl logs <container-id> ; sudo crictl inspectp <pod-id> | jq .status
sudo journalctl -u kubelet -f --no-pager

# --- Docker Swarm --------------------------------------------------------
docker swarm init --advertise-addr <ip> ; docker swarm join-token worker
docker node ls ; docker node ps <node> ; docker node update --availability drain <node>
docker stack deploy -c docker-stack.yml <stack> --with-registry-auth
docker stack services <stack> ; docker stack ps <stack> --no-trunc
docker service scale <svc>=10
docker service update --image <img> --update-order start-first <svc>
docker service rollback <svc>
docker service logs -f --tail 100 <svc>
docker service inspect <svc> --format '{{json .UpdateStatus}}'
```

---

## 11. Resumen de hechos decisivos orientado al examen

- El modelo de orquestación es **reconciliación disparada por nivel**, no ejecución imperativa dirigida por eventos. Los eventos perdidos no corrompen el estado.
- Solo el **apiserver** habla con etcd. El quórum de etcd es `floor(N/2)+1`; usá 3 o 5 miembros, nunca un número par.
- El **planificador ubica pods usando `requests`; el kernel aplica `limits`.** Unas requests incorrectas producen un clúster que está simultáneamente «vacío» y sobrecargado.
- La **clase QoS** (Guaranteed / Burstable / BestEffort) determina el orden de desalojo bajo presión del nodo.
- `maxSurge` redondea **hacia arriba**, `maxUnavailable` redondea **hacia abajo**; ambos no pueden ser cero.
- `progressDeadlineSeconds` marca un despliegue como fallido — **no hace rollback**. Poné la compuerta de CI sobre `kubectl rollout status`.
- Los **StatefulSets** dan identidad de red estable y un PVC por ordinal; las actualizaciones van desde el ordinal más alto hacia abajo, y `partition` es un canario integrado.
- Los **sidecars nativos** son `initContainers` con `restartPolicy: Always`: arrancan primero, se detienen al final, y permiten que los Jobs completen.
- ConfigMap/Secret consumidos como **variables de entorno nunca se actualizan**; los montajes con `subPath` tampoco. Los montajes de volumen sí.
- Un Service con `ENDPOINTS: <none>` mientras los pods están Running es un **desajuste del selector de etiquetas, un fallo de readiness, o un `targetPort` incorrecto** — en ese orden de probabilidad.
- **NetworkPolicy es permitir-por-defecto hasta que una política selecciona el pod**, y entonces pasa a denegar-por-defecto en la dirección seleccionada. Permití siempre el egress a kube-dns explícitamente.
- `ReadWriteOnce` es por **nodo**; `ReadWriteOncePod` es por **pod**.
- **PodDisruptionBudget** gobierna solo la interrupción voluntaria (`drain`, API de eviction). No protege frente a la caída de un nodo.
- En **Swarm**: los managers ejecutan Raft, `mode: global` ≈ DaemonSet, `order: start-first` ≈ despliegue con surge, los Configs son **inmutables** así que versioná el nombre, y las imágenes las descarga cada worker (`--with-registry-auth`).
- Los **Events del clúster tienen un TTL de 1 hora**. Enviálos fuera del clúster o perdés tu post-mortem.

---

## Referencias

**LPI**
- LPI DevOps Tools Engineer — objetivos del examen 701: https://www.lpi.org/our-certifications/exam-701-objectives/
- Visión general de la certificación LPI DevOps Tools Engineer: https://www.lpi.org/our-certifications/devops-overview/

**Kubernetes — conceptos y arquitectura**
- Arquitectura del clúster de Kubernetes: https://kubernetes.io/docs/concepts/architecture/
- Controladores y el bucle de reconciliación: https://kubernetes.io/docs/concepts/architecture/controller/
- Nodos y condiciones de nodo: https://kubernetes.io/docs/concepts/architecture/nodes/
- Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Objetos, nombres y etiquetas: https://kubernetes.io/docs/concepts/overview/working-with-objects/
- Conceptos de la API (list, watch, resourceVersion): https://kubernetes.io/docs/reference/using-api/api-concepts/

**Kubernetes — cargas de trabajo**
- Ciclo de vida del Pod: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Contenedores sidecar: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Configurar sondas de liveness, readiness y startup: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/

**Kubernetes — planificación y recursos**
- Planificador de Kubernetes: https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Asignar Pods a Nodos: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints y tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Restricciones de distribución topológica de Pods: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Prioridad de Pods y preempción: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Desalojo por presión del nodo: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Gestión de recursos para Pods y contenedores: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Clases de calidad de servicio de Pods: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Interrupciones y PodDisruptionBudget: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Autoescalado horizontal de Pods: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

**Kubernetes — redes**
- Modelo de red del clúster: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service: https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- IPs virtuales y proxies de Service (modos de kube-proxy): https://kubernetes.io/docs/reference/networking/virtual-ips/
- DNS para Services y Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Gateway API: https://kubernetes.io/docs/concepts/services-networking/gateway/
- Políticas de red: https://kubernetes.io/docs/concepts/services-networking/network-policies/

**Kubernetes — configuración y almacenamiento**
- ConfigMap: https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Cifrar datos confidenciales en reposo: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/

**Kubernetes — administración del clúster**
- Crear un clúster con kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- Runtimes de contenedores (containerd, drivers de cgroup): https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Referencia de configuración de kubeadm: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Referencia de configuración del kubelet: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Actualizar clústeres de kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Drenar un nodo de forma segura: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Operar clústeres etcd para Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Gestión de certificados con kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- API Priority and Fairness: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/

**Kubernetes — resolución de problemas**
- Depurar Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Depurar Pods en ejecución (contenedores efímeros): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Depurar Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Resolución de problemas de clústeres: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Depurar nodos de Kubernetes con crictl: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- Referencia de kubectl: https://kubernetes.io/docs/reference/kubectl/

**Docker Swarm**
- Visión general del modo Swarm: https://docs.docker.com/engine/swarm/
- Conceptos clave del modo Swarm: https://docs.docker.com/engine/swarm/key-concepts/
- Cómo funcionan los servicios: https://docs.docker.com/engine/swarm/how-swarm-mode-works/services/
- Consenso Raft en Swarm: https://docs.docker.com/engine/swarm/raft/
- Desplegar servicios en un swarm: https://docs.docker.com/engine/swarm/services/
- Actualizaciones progresivas en un swarm: https://docs.docker.com/engine/swarm/swarm-tutorial/rolling-update/
- Desplegar un stack en un swarm: https://docs.docker.com/engine/swarm/stack-deploy/
- Especificación Deploy de Compose: https://docs.docker.com/reference/compose-file/deploy/
- Gestionar secretos de swarm: https://docs.docker.com/engine/swarm/secrets/
- Gestionar configs de swarm: https://docs.docker.com/engine/swarm/configs/
- Redes con redes overlay: https://docs.docker.com/engine/network/drivers/overlay/

**Runtimes, CNI y proyectos relacionados**
- Documentación de containerd: https://containerd.io/docs/
- CRI-O: https://cri-o.io/
- Especificación de Container Network Interface: https://www.cni.dev/docs/spec/
- Documentación de CSI para Kubernetes: https://kubernetes-csi.github.io/docs/
- Plugin de Kubernetes para CoreDNS: https://coredns.io/plugins/kubernetes/
- Guía de operaciones de etcd: https://etcd.io/docs/v3.5/op-guide/
- Proyecto Gateway API: https://gateway-api.sigs.k8s.io/
- Podman Quadlet (integración con systemd): https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- Documentación de HashiCorp Nomad: https://developer.hashicorp.com/nomad/docs