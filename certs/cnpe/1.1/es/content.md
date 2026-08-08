# Tema 1.1 — Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> **Dominio:** Platform Architecture · **Peso en el examen:** 5%
> **Perfil:** Platform Architect / SRE Senior · **Fuente base:** CNPE Curriculum (CNCF)

Este tema es el cimiento del examen CNPE: antes de hablar de developer experience, golden paths o GitOps, hay que dejar sanas las tres capas físicas sobre las que corre todo lo demás — **compute, storage y networking**. La certificación no evalúa si sabés qué es un `Pod`; evalúa si sabés **diseñar el sustrato** de una plataforma multi-tenant de producción y justificar cada decisión con sus trade-offs. Ese es el nivel al que apunta este material.

---

## 1. Motivación y el problema arquitectónico de producción

Una **Internal Developer Platform (IDP)** es un producto interno: expone abstracciones (golden paths, self-service APIs) sobre un sustrato de infraestructura compartido. El error clásico —y la razón por la que este tema pesa en el examen— es tratar compute, storage y networking como decisiones de *día 1* aisladas, cuando en realidad son **decisiones de arquitectura acopladas** que determinan el blast radius, el costo unitario y el techo de escalabilidad de la plataforma completa.

El problema concreto que un Platform Architect debe resolver:

- **Multi-tenancy sin aislamiento explícito es un incidente esperando ocurrir.** Un tenant sin `ResourceQuota` puede consumir todo el `compute` del cluster (noisy neighbor); un `Pod` sin `NetworkPolicy` puede alcanzar la base de datos de otro tenant (lateral movement); un `PersistentVolume` con `reclaimPolicy: Delete` mal configurado destruye datos al borrar un `PVC`.
- **La capa que elegís es difícil de revertir.** El CNI se instala una vez y migrarlo (p. ej. de Flannel a Cilium) implica reprogramar el dataplane de cada nodo. El `StorageClass` por defecto define la durabilidad de los datos de todos los que no especifican uno. El `podCIDR` mal dimensionado limita cuántos Pods entran en el cluster para siempre.
- **El costo vive acá.** El 70–90% de la factura cloud es compute + storage + egress de red. Las decisiones de bin-packing, spot vs on-demand, tiering de discos y topology-aware routing son las que mueven la aguja del FinOps, no los dashboards.

El marco de referencia oficial de la CNCF para razonar esto es el **Platform Engineering Maturity Model** y el **CNCF Platforms White Paper** (TAG App Delivery): una plataforma madura ofrece capacidades de compute/storage/network como **servicios self-service, con paved roads y guardrails**, no como tickets manuales.

> **Principio rector del tema:** cada una de las tres capas debe diseñarse con tres propiedades simultáneas — **aislamiento** (un tenant no daña a otro), **elasticidad** (escala con la demanda sin intervención) y **observabilidad/reversibilidad** (podés diagnosticar y deshacer). Si una decisión sacrifica una de las tres, tiene que ser una decisión consciente y documentada.

---

## 2. Compute: diseño del sustrato de cómputo

### 2.1 El problema

El scheduler de Kubernetes hace bin-packing según `requests`, pero **no conoce tu topología de negocio**: no sabe que las cargas de `system` (CoreDNS, CNI, ingress controllers) no deben compartir nodo con batch jobs hostiles, ni que el tenant `payments` exige nodos dedicados por compliance. El diseño de compute consiste en **darle al scheduler las restricciones correctas** vía node pools, taints/tolerations, affinity, topology spread y clases de recursos.

### 2.2 Node pools: segmentación por rol

Un patrón de producción divide el compute en pools por función. Trade-offs:

| Estrategia | Aislamiento | Utilización (bin-packing) | Costo | Cuándo usarla |
|---|---|---|---|---|
| **Cluster único, pool único** | Nulo | Máximo | Mínimo | Dev/PoC, mono-tenant |
| **Pools por rol** (system / general / batch / gpu) | Medio (a nivel nodo) | Alto | Medio | IDP estándar multi-tenant |
| **Pools dedicados por tenant** (taints) | Alto (nodo) | Bajo (fragmentación) | Alto | Compliance, tenants ruidosos |
| **Cluster por tenant** | Máximo | N/A | Muy alto | Aislamiento fuerte / regulatorio |

La regla de oro: **empezá con el aislamiento más débil que cumpla tu requisito de compliance y subí solo cuando un incidente lo justifique.** El aislamiento por nodo cuesta utilización (fragmentación), y la fragmentación es dinero.

### 2.3 Aislar cargas críticas: taints, tolerations y PriorityClass

Nodos de sistema protegidos y clase de prioridad para que las cargas críticas expulsen a las best-effort bajo presión:

```yaml
# priorityclasses.yaml — define el orden de desalojo bajo presión de recursos
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-critical
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Componentes de plataforma (ingress, CNI, DNS, observabilidad)."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: tenant-standard
value: 10000
globalDefault: true          # todo lo que no especifique priorityClassName cae acá
preemptionPolicy: PreemptLowerPriority
description: "Cargas de tenant productivas."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: best-effort-batch
value: 100
globalDefault: false
preemptionPolicy: Never       # los batch NO expulsan a nadie; solo ocupan hueco libre
description: "Jobs batch tolerantes a interrupción (spot-friendly)."
```

Los nodos de sistema se marcan con un taint (`kubectl taint nodes -l pool=system dedicated=system:NoSchedule`) y solo los componentes de plataforma toleran ese taint. Deployment de ejemplo con toleration, anti-affinity y topology spread:

```yaml
# ingress-controller.yaml — carga de plataforma en nodos de sistema, spread por zona
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  replicas: 3
  selector:
    matchLabels: { app: ingress-nginx }
  template:
    metadata:
      labels: { app: ingress-nginx }
    spec:
      priorityClassName: platform-critical
      tolerations:
        - key: dedicated
          operator: Equal
          value: system
          effect: NoSchedule
      nodeSelector:
        pool: system
      # Reparte réplicas entre zonas: máx. 1 de diferencia entre la zona más y menos poblada
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: ingress-nginx }
      # Nunca dos réplicas en el mismo nodo (evita SPOF a nivel host)
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: ingress-nginx }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: controller
          image: registry.k8s.io/ingress-nginx/controller:v1.11.3
          resources:
            requests: { cpu: "200m", memory: "256Mi" }
            limits:   { memory: "512Mi" }   # sin CPU limit: evita throttling innecesario
```

> **Decisión de diseño defendible en el examen:** limitar memoria (recurso no comprimible → OOM si se excede) pero **no** limitar CPU (recurso comprimible → un CPU limit solo introduce throttling y latencia sin proteger al nodo, ya que la presión de CPU se resuelve con `requests` y shares de cgroup). Es una recomendación explícita para cargas latency-sensitive.

### 2.4 QoS classes y el gobierno de recursos

Kubernetes deriva la QoS del Pod de sus `requests`/`limits`, y de ahí el orden de desalojo bajo node-pressure:

| QoS Class | Condición | Orden de eviction bajo presión | Uso recomendado |
|---|---|---|---|
| **Guaranteed** | `requests == limits` en CPU y memoria, todos los contenedores | Último en ser desalojado | Bases de datos, stateful crítico |
| **Burstable** | Tiene requests pero `requests < limits` (o falta alguno) | Intermedio | La mayoría de las cargas web |
| **BestEffort** | Sin requests ni limits | **Primero** en ser desalojado | Solo batch descartable |

El gobierno multi-tenant se impone con `ResourceQuota` (techo agregado por namespace) + `LimitRange` (defaults y topes por contenedor). Los dos juntos, siempre — una `ResourceQuota` que exige `limits` rechaza Pods sin `limits` a menos que un `LimitRange` los inyecte:

```yaml
# tenant-governance.yaml — cuota agregada + defaults por contenedor
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    persistentvolumeclaims: "15"
    requests.storage: 500Gi
    count/deployments.apps: "25"
    services.loadbalancers: "2"        # frena la proliferación de LBs (cada uno cuesta)
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-defaults
  namespace: team-payments
spec:
  limits:
    - type: Container
      default:                 # limits inyectados si el contenedor no los declara
        cpu: "500m"
        memory: 512Mi
      defaultRequest:          # requests inyectados si no se declaran
        cpu: "100m"
        memory: 128Mi
      max: { cpu: "4", memory: 8Gi }     # tope por contenedor
      min: { cpu: "50m", memory: 64Mi }
```

### 2.5 Autoscaling: las tres dimensiones

| Autoscaler | Escala | Señal | Trade-off clave |
|---|---|---|---|
| **HPA** (`autoscaling/v2`) | Réplicas de Pod (horizontal) | CPU/mem/custom/external metrics | Necesita `requests` correctos; reacciona a carga sostenida, no a spikes de <1 min |
| **VPA** | requests/limits de un Pod (vertical) | Uso histórico | En modo `Auto` **recrea el Pod**; incompatible con HPA sobre la misma métrica |
| **Cluster Autoscaler** | Nodos (por node group) | Pods `Pending` por falta de recursos | Escala en minutos; atado a la forma fija de los node groups |
| **Karpenter** | Nodos (sin node groups) | Pods `Pending` | Elige el tipo de instancia óptimo just-in-time; consolida; hoy AWS/Azure |

HPA de producción con comportamiento de escalado afinado (scale-up agresivo, scale-down conservador para evitar flapping):

```yaml
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-gateway
  namespace: team-payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-gateway
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0        # sube ya
      policies:
        - type: Percent
          value: 100                        # puede duplicar réplicas...
          periodSeconds: 30                 # ...cada 30s
    scaleDown:
      stabilizationWindowSeconds: 300       # espera 5 min de calma antes de bajar
      policies:
        - type: Percent
          value: 10                         # baja como mucho 10%...
          periodSeconds: 60                 # ...por minuto (evita flapping)
```

Karpenter reemplaza los node groups estáticos por un `NodePool` declarativo que elige la instancia óptima por Pod pendiente:

```yaml
# karpenter-nodepool.yaml (karpenter.sh/v1)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-spot
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]       # prefiere spot, cae a on-demand
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]          # deja que Karpenter elija ARM si conviene
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h                        # recicla nodos ≤30 días (patching)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m                        # reempaqueta cargas para reducir nodos
  limits:
    cpu: "1000"
    memory: 4000Gi
```

> **Trade-off de spot en una IDP:** spot recorta 60–90% el costo de compute pero puede desaparecer con 2 min de aviso. La plataforma lo absorbe combinando `PriorityClass` (`best-effort-batch` en spot), `PodDisruptionBudget` para cargas stateless y **nunca** poniendo stateful crítico (bases de datos) en spot.

---

## 3. Storage: durabilidad, elasticidad y topología

### 3.1 El problema

En compute, un Pod muerto se recrea sin pérdida. En storage, un error **destruye datos irreversiblemente**. La arquitectura de storage de la plataforma debe: (a) ofrecer clases self-service con garantías claras (performance, durabilidad, reclaim), (b) evitar el binding prematuro que agenda un Pod en una zona sin volumen, y (c) soportar expansión y snapshots sin downtime.

### 3.2 La arquitectura CSI

El **Container Storage Interface (CSI)** desacopla Kubernetes del proveedor de storage. Un driver CSI tiene dos planos:

- **Controller plane** (Deployment): sidecars `external-provisioner` (crea el volumen ante un `PVC`), `external-attacher` (attach/detach al nodo), `external-resizer` (expansión), `external-snapshotter` (snapshots).
- **Node plane** (DaemonSet): `node-driver-registrar` + el driver, que hace el `NodeStage`/`NodePublish` (formatea y monta el volumen en el nodo).

Entender este flujo es clave para diagnosticar: un `PVC` `Pending` es casi siempre el `external-provisioner`; un `Pod` atascado en `ContainerCreating` con "attach" es el `external-attacher` o el node plane.

### 3.3 StorageClass: el contrato de la plataforma

Comparativa de tipos de storage que la plataforma debe ofrecer como clases:

| Tipo | Access modes | Latencia | Uso típico | Trade-off |
|---|---|---|---|---|
| **Block** (EBS, PD, Ceph RBD) | RWO / RWOP | Muy baja | Bases de datos, StatefulSets | Un solo nodo; atado a zona |
| **File** (EFS, Filestore, CephFS, NFS) | RWX | Media | Shared config, media, CI cache | Más caro; posible cuello de red |
| **Object** (S3, GCS) vía CSI/aplicación | N/A (API) | Alta | Backups, artefactos, data lake | No es POSIX; consistencia eventual |
| **Local / ephemeral** (`local` PV, `emptyDir`) | RWO | Mínima | Cache, scratch, datos regenerables | **Sin durabilidad**; atado al nodo |

Los **access modes** son un examen frecuente:

| Modo | Sigla | Semántica |
|---|---|---|
| ReadWriteOnce | RWO | Montable RW por un solo **nodo** (varios Pods del mismo nodo pueden compartirlo) |
| ReadWriteOncePod | RWOP | Montable RW por un solo **Pod** (aislamiento estricto; K8s ≥1.29 GA) |
| ReadOnlyMany | ROX | Montable RO por muchos nodos |
| ReadWriteMany | RWX | Montable RW por muchos nodos (requiere file storage) |

Tres clases de plataforma con la decisión de diseño más importante — `volumeBindingMode`:

```yaml
# storageclasses.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "5000"
  throughput: "250"          # MiB/s (gp3 desacopla IOPS/throughput del tamaño)
  encrypted: "true"
reclaimPolicy: Delete         # el PV se borra con el PVC — apto para datos regenerables
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer   # <-- CLAVE: ver nota
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: retain-critical
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Retain         # el PV sobrevive al PVC — datos que NO se deben perder
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: shared-rwx
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap    # access point por PVC
  fileSystemId: fs-0abc123
  directoryPerms: "700"
reclaimPolicy: Retain
volumeBindingMode: Immediate  # EFS es regional (no atado a zona): Immediate es seguro
```

> **`WaitForFirstConsumer` vs `Immediate` — el error de topología más caro:** con `Immediate`, el volumen se provisiona apenas se crea el `PVC`, en una zona *elegida por el provisioner*. Si el Pod luego se agenda en otra zona, queda `Pending` para siempre porque un EBS/PD **no cruza zonas**. `WaitForFirstConsumer` retrasa el provisioning hasta que el scheduler decide el nodo, garantizando que el volumen nace en la zona correcta. **Para todo block storage zonal, siempre `WaitForFirstConsumer`.** Solo el file storage regional (EFS/Filestore) admite `Immediate` con seguridad.

### 3.4 StatefulSet con volumeClaimTemplates y expansión

```yaml
# postgres-statefulset.yaml — un PVC por réplica, en la clase retain-critical
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: team-payments
spec:
  serviceName: postgres-headless
  replicas: 3
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      priorityClassName: platform-critical
      terminationGracePeriodSeconds: 120     # deja que Postgres haga checkpoint
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: postgres }
      containers:
        - name: postgres
          image: postgres:16.4
          ports: [{ containerPort: 5432, name: pg }]
          resources:
            requests: { cpu: "2", memory: 4Gi }
            limits:   { cpu: "2", memory: 4Gi }   # Guaranteed QoS: stateful crítico
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOncePod"]
        storageClassName: retain-critical
        resources:
          requests:
            storage: 100Gi
```

La expansión online (con `allowVolumeExpansion: true`) es editar el `PVC`, no recrear nada:

```console
$ kubectl -n team-payments patch pvc data-postgres-0 \
    --type merge -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
persistentvolumeclaim/data-postgres-0 patched

$ kubectl -n team-payments get pvc data-postgres-0 -o jsonpath='{.status.conditions[*].type}'
FileSystemResizePending

$ kubectl -n team-payments get pvc data-postgres-0
NAME              STATUS   VOLUME    CAPACITY   ACCESS MODES   STORAGECLASS      AGE
data-postgres-0   Bound    pvc-8f…   200Gi      RWOP           retain-critical   14d
```

### 3.5 Snapshots como capacidad de plataforma

```yaml
# snapshot.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-snapclass
driver: ebs.csi.aws.com
deletionPolicy: Retain          # conserva el snapshot aunque se borre el objeto K8s
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-pre-migration
  namespace: team-payments
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: data-postgres-0
```

Restaurar es crear un `PVC` con `dataSource` apuntando al snapshot — la base de un runbook de recovery self-service.

---

## 4. Networking: conectividad, aislamiento y ruteo

### 4.1 El problema

El modelo de red de Kubernetes exige que **todo Pod alcance a todo Pod sin NAT**. Eso es simple para el desarrollador y peligroso para la plataforma: por defecto, **no hay aislamiento** — el Pod comprometido de un tenant puede escanear y alcanzar los servicios de todos los demás. El diseño de networking resuelve tres cosas: elección del **dataplane (CNI)**, imposición de **aislamiento (NetworkPolicy)** y **exposición/ruteo (Service, Gateway API)** de forma eficiente en costo.

### 4.2 Elección de CNI

| CNI | Dataplane | NetworkPolicy | Diferenciador | Trade-off |
|---|---|---|---|---|
| **Cilium** | eBPF (puede reemplazar kube-proxy) | L3/L4 **y L7** (HTTP, DNS, Kafka) | Hubble (observabilidad), performance, mesh sin sidecar | Curva de aprendizaje; kernel reciente |
| **Calico** | iptables/eBPF | L3/L4 (+ global policies) | Madurez, BGP, políticas globales | L7 requiere componentes extra |
| **AWS VPC CNI** | ENIs nativas | Vía SG for Pods / Calico | IPs de VPC reales (integración) | Límite de IPs por instancia; agota el CIDR |
| **Flannel** | VXLAN | **Ninguna** | Simplicidad | Sin NetworkPolicy — no apto para multi-tenant |

> **Recomendación de arquitectura para una IDP moderna:** Cilium por defecto — el dataplane eBPF elimina el cuello de iptables de kube-proxy a escala (miles de Services), y las L7 policies + Hubble dan aislamiento y observabilidad que las otras opciones cubren solo parcialmente. Flannel queda descartado para multi-tenant por no soportar `NetworkPolicy`.

### 4.3 Aislamiento: default-deny primero

La postura correcta es **zero-trust**: negar todo por namespace y abrir explícitamente. Sin un default-deny, cualquier `NetworkPolicy` de allow es cosmética.

```yaml
# 00-default-deny.yaml — se aplica primero en cada namespace de tenant
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-payments
spec:
  podSelector: {}                 # todos los Pods del namespace
  policyTypes: [Ingress, Egress]  # niega ingress Y egress
---
# 10-allow-dns.yaml — sin esto, el default-deny rompe la resolución DNS (falla sutil)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: team-payments
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
# 20-allow-api-to-db.yaml — solo el api-gateway alcanza a postgres, solo en 5432
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-postgres
  namespace: team-payments
spec:
  podSelector:
    matchLabels: { app: postgres }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: api-gateway }
      ports:
        - { protocol: TCP, port: 5432 }
```

> **La trampa del default-deny:** el `default-deny-all` bloquea también el egress a CoreDNS (kube-system:53). Sin la policy `allow-dns-egress`, toda resolución de nombres falla y el síntoma parece un problema de aplicación, no de red. Es un clásico de diagnóstico del examen.

### 4.4 Exposición y ruteo: Ingress vs Gateway API

La CNCF y SIG-Network posicionan **Gateway API** como el sucesor de `Ingress`: más expresiva, con **separación de roles** (el platform team dueño del `Gateway`, el app team dueño de sus `HTTPRoute`) — exactamente el modelo que una IDP necesita.

| Aspecto | Ingress (`networking.k8s.io/v1`) | Gateway API (`gateway.networking.k8s.io/v1`) |
|---|---|---|
| Expresividad | Básica (host/path); resto vía annotations propietarias | Header/method/weight/mirror nativos, portable |
| Separación de roles | No (un objeto, un dueño) | Sí: GatewayClass / Gateway / HTTPRoute por rol |
| Protocolos | HTTP/HTTPS | HTTP, gRPC, TCP, TLS, UDP |
| Estado | Congelado (feature-frozen) | En evolución activa; GA para HTTP |

```yaml
# gateway.yaml — lo posee el platform team
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels: { gateway-access: "true" }   # solo namespaces marcados
---
# httproute.yaml — lo posee el app team, en su propio namespace
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: team-payments
spec:
  parentRefs:
    - name: platform-gateway
      namespace: gateway-system
  hostnames: ["api.payments.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /v2 }
      backendRefs:
        - name: api-gateway
          port: 80
          weight: 90
        - name: api-gateway-canary       # canary por peso, nativo
          port: 80
          weight: 10
```

### 4.5 Costo de red: Topology Aware Routing

El egress inter-zona se cobra. **Topology Aware Routing** mantiene el tráfico de un Service dentro de la misma zona cuando hay endpoints locales sanos, recortando la factura cross-AZ y la latencia:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
  namespace: team-payments
  annotations:
    service.kubernetes.io/topology-mode: Auto   # prefiere endpoints de la misma zona
spec:
  selector: { app: api-gateway }
  ports:
    - { port: 80, targetPort: 8080 }
```

> **Dimensionamiento de CIDR — decisión irreversible:** el `podCIDR` del cluster y el rango por nodo (`--node-cidr-mask-size`) fijan el techo de Pods. Con AWS VPC CNI las IPs salen de la VPC y un `/22` mal planeado agota el rango sin poder crecer. Calculá `nodos_máx × pods_por_nodo` con holgura **antes** de crear el cluster; no se cambia después.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Compute — Pod `Pending`

```console
$ kubectl -n team-payments get pod api-gateway-6f9c-xk2 -o wide
NAME                   READY   STATUS    RESTARTS   AGE   NODE
api-gateway-6f9c-xk2   0/1     Pending   0          2m    <none>

$ kubectl -n team-payments describe pod api-gateway-6f9c-xk2 | sed -n '/Events/,$p'
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  90s   default-scheduler  0/6 nodes are available:
           3 Insufficient cpu, 3 node(s) had untolerated taint {dedicated: system}.
           preemption: 0/6 nodes are available: 3 No preemption victims found,
           3 Preemption is not helpful for scheduling.
```

Lectura: 3 nodos sin CPU + 3 nodos de sistema con taint no tolerado. La firma `Insufficient cpu` apunta a `requests` altos o cluster saturado → validar Cluster Autoscaler/Karpenter y `ResourceQuota`.

```console
# ¿La cuota del tenant está topada?
$ kubectl -n team-payments describe resourcequota tenant-quota
Name:            tenant-quota
Resource         Used   Hard
--------         ----   ----
requests.cpu     19500m 20
requests.memory  38Gi   40Gi
```

`19500m/20` → casi al tope; el próximo Pod se rechaza por cuota, no por nodos.

### 5.2 Storage — `PVC` atascado

```console
$ kubectl -n team-payments get pvc data-postgres-0
NAME              STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS      AGE
data-postgres-0   Pending                                     retain-critical   3m

$ kubectl -n team-payments describe pvc data-postgres-0 | sed -n '/Events/,$p'
Events:
  Type    Reason                Age   From                         Message
  ----    ------                ----  ----                         -------
  Normal  WaitForFirstConsumer  3m    persistentvolume-controller  waiting for first
          consumer to be created before binding
```

Con `WaitForFirstConsumer`, `Pending` sin consumidor es **esperado**: el `PVC` se liga cuando el Pod se agenda. Si el Pod tampoco arranca, la causa raíz está en el scheduler (5.1), no en storage. Si el mensaje fuera `ProvisioningFailed`, revisar los logs del `external-provisioner`:

```console
$ kubectl -n kube-system logs -l app=ebs-csi-controller -c csi-provisioner --tail=20
... failed to provision volume: rpc error: code = InvalidArgument
    desc = Could not create volume: InvalidParameterValue: iops 16000 exceeds
    the maximum 500:1 ratio for gp3 volumes of size 100Gi
```

Causa raíz clara: ratio IOPS/tamaño inválido en el `StorageClass`.

### 5.3 Networking — conectividad denegada

```console
$ kubectl -n team-payments exec deploy/api-gateway -- \
    sh -c 'nc -zv -w3 postgres 5432; nc -zv -w3 evil-tenant.other 5432'
postgres (10.96.3.14:5432) open
nc: evil-tenant.other:5432 (10.96.9.7:5432): Connection timed out
```

La `NetworkPolicy` funciona: alcanza a `postgres` (allow explícito) y falla al cruzar hacia otro tenant (default-deny). Con Cilium, Hubble muestra el drop con la policy que lo causó:

```console
$ hubble observe --namespace team-payments --verdict DROPPED --last 5
Aug  7 14:22:10  api-gateway-6f9c → evil-tenant/db-0  TCP  DROPPED
    (Policy denied)  SYN
```

Regresión de DNS (la trampa de 4.3):

```console
$ kubectl -n team-payments exec deploy/api-gateway -- nslookup postgres
;; connection timed out; no servers could be reached
# → falta la policy allow-dns-egress hacia kube-system:53
```

### 5.4 Checklist de verificación de la plataforma

```console
# Compute: QoS efectiva de las cargas críticas
$ kubectl -n team-payments get pod postgres-0 -o jsonpath='{.status.qosClass}'
Guaranteed

# Storage: default class y expansión habilitada
$ kubectl get storageclass
NAME                 PROVISIONER       RECLAIMPOLICY  VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
fast-ssd (default)   ebs.csi.aws.com   Delete         WaitForFirstConsumer   true
retain-critical      ebs.csi.aws.com   Retain         WaitForFirstConsumer   true
shared-rwx           efs.csi.aws.com   Retain         Immediate              false

# Networking: todo namespace de tenant tiene un default-deny
$ kubectl get netpol -A --field-selector metadata.name=default-deny-all
NAMESPACE       NAME               POD-SELECTOR   AGE
team-payments   default-deny-all   <none>         21d
```

---

## 6. Referencias

- CNCF — CNPE Curriculum (repositorio oficial de currículos): https://github.com/cncf/curriculum
- CNCF TAG App Delivery — Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- Kubernetes — Managing Resources for Containers (requests/limits): https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes — Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Kubernetes — Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — Node-pressure Eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes — Persistent Volumes (access modes, reclaim, binding mode): https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes — Volume Snapshots: https://kubernetes.io/docs/concepts/storage/volume-snapshots/
- Kubernetes — Storage Capacity: https://kubernetes.io/docs/concepts/storage/storage-capacity/
- Kubernetes CSI Developer Documentation: https://kubernetes-csi.github.io/docs/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Topology Aware Routing: https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/
- Kubernetes Gateway API (SIG Network): https://gateway-api.sigs.k8s.io/
- Karpenter — documentación oficial: https://karpenter.sh/docs/
- Cluster Autoscaler (Kubernetes Autoscaler): https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Cilium — documentación oficial (eBPF dataplane, Hubble, network policies): https://docs.cilium.io/
- Project Calico — documentación oficial: https://docs.tigera.io/calico/latest/about/