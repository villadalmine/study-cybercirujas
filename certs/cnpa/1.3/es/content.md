# 1.3 Application Environments and Infrastructure Architecture

**Certificación:** CNPA — Cloud Native Platform Engineering Associate (curriculum 2025-04-01)
**Dominio:** 1. Platform Engineering Core Fundamentals
**Peso del tema en el examen:** 7.2 %

---

## 1. Motivación: el problema arquitectónico real

### 1.1 La definición ingenua de "environment" y por qué se rompe en producción

En la mayoría de las organizaciones, "environment" empieza siendo un sustantivo informal: *dev*, *staging*, *prod*. Cuando se lo baja a Kubernetes, la primera traducción suele ser un `Namespace` por entorno dentro de un mismo cluster. Esa traducción es incompleta, y la incompletitud es exactamente donde se generan los incidentes.

Un environment de producción **no es un namespace**. Es un conjunto acoplado de siete cosas que tienen que provisionarse, versionarse y destruirse **juntas**:

| Componente del environment | Qué representa | Dónde vive normalmente |
|---|---|---|
| **Workload set** | El conjunto de servicios desplegados y sus versiones | Deployments/StatefulSets, Git |
| **Infra dependencies** | DB, cache, colas, buckets, DNS, certificados | Cloud provider / Crossplane / Terraform |
| **Configuration** | Valores que difieren entre entornos (endpoints, feature flags, tamaños) | ConfigMap, Secret, external secret store |
| **Identity boundary** | Quién puede actuar, y con qué credenciales hacia la nube | RBAC, ServiceAccount, IRSA / Workload Identity |
| **Network boundary** | Qué puede hablar con qué, en ambas direcciones | NetworkPolicy, VPC, security groups, service mesh |
| **Policy set** | Qué está permitido admitir en el entorno | PSA labels, Kyverno/Gatekeeper, ValidatingAdmissionPolicy |
| **Lifecycle contract** | Cuánto vive, quién lo paga, cómo se promueve | TTL, cost center, promotion rules |

El fallo clásico: el equipo copia los YAML de la app a `envs/prod/`, pero los otros seis componentes se crearon a mano, en momentos distintos, por personas distintas. El resultado es **drift estructural**: staging y prod son isomorfos en el eje "workloads" y divergentes en los otros seis ejes. El deploy pasa todos los tests en staging y falla en prod por una razón que ningún test cubría: el `PodSecurity` de prod es `restricted` y el de staging `baseline`; el Secret está en un vault distinto; el NetworkPolicy de prod bloquea el egress al servicio de licencias.

### 1.2 El postmortem típico (y qué enseña)

> **Incidente**: un release de `payments-api` desplegado a `prod-eu-west-1` entra en `CrashLoopBackOff` 40 s después del sync. En staging había corrido 11 días sin fallos.
>
> **Causa raíz**: la app abre una conexión saliente a `metrics-gw.observability.svc.cluster.local:4317` (OTLP). En staging, el namespace no tenía NetworkPolicy (default allow). En prod, el baseline de plataforma aplica `default-deny-all` + allowlist. El OTLP exporter tiene `BlockOnQueueFull` y el proceso muere en el health check de startup.
>
> **Causa raíz real**: el environment de staging no era una réplica estructural de prod. Era una réplica de *workloads*. La plataforma nunca garantizó parity en el eje "network boundary".

La lección arquitectónica que el CNPA evalúa: **la paridad entre entornos no es una buena práctica cultural, es una propiedad que la plataforma debe producir mecánicamente**. Si la paridad depende de que alguien se acuerde de replicar un YAML, no existe.

### 1.3 Las tres tensiones que definen el diseño

Todo diseño de application environments negocia tres tensiones que no se pueden optimizar simultáneamente:

1. **Isolation vs. Cost.** Cada grado adicional de aislamiento (namespace → vCluster → cluster → cuenta cloud) multiplica el costo fijo y el overhead operativo.
2. **Fidelity vs. Lead time.** Cuanto más fiel a producción es un entorno efímero, más tarda en existir. Un preview environment con una réplica real de la base de datos de prod tarda 40 minutos; con un stub, 90 segundos.
3. **Autonomy vs. Consistency.** Cuanto más libertad tiene el equipo para definir su entorno, menos garantías puede dar la plataforma sobre él (seguridad, costo, upgrade path).

El trabajo del Platform Architect no es resolver estas tensiones, sino **elegir un punto explícito en cada eje, codificarlo en una API, y hacer que el camino elegido sea el más fácil de tomar** (golden path).

---

## 2. Modelo conceptual: el environment como recurso de primera clase

### 2.1 De carpeta a API

La madurez de una plataforma en este tema se mide por cómo se crea un entorno:

| Nivel | Cómo se crea un environment | Lead time típico | Drift observado |
|---|---|---|---|
| **0 — Ad hoc** | Ticket a infra; humanos ejecutan `kubectl`/consola | 3–15 días | Alto e invisible |
| **1 — Scripted** | Repo de Terraform por entorno, `terraform apply` manual | 4–48 h | Alto pero detectable (`plan`) |
| **2 — Templated** | Copia de un directorio de referencia + PR | 1–4 h | Medio; drift por template desactualizado |
| **3 — Declarative fleet** | GitOps reconcilia el entorno completo desde Git | 10–40 min | Bajo; auto-reparación |
| **4 — API-driven** | El dev crea un objeto `Environment`; el control plane lo materializa | 2–15 min | Cercano a cero; el schema es el contrato |

El nivel 4 es el que el curriculum de CNPA llama *platform as a product with APIs*: existe un tipo `Environment` con un schema versionado, y el usuario declara **intención**, no implementación.

```yaml
# Lo que el desarrollador escribe. Todo lo demás es responsabilidad de la plataforma.
apiVersion: platform.example.io/v1alpha1
kind: Environment
metadata:
  name: payments-staging
  namespace: team-payments
spec:
  parameters:
    tier: staging               # gobierna SLO, policy set, y ventana de mantenimiento
    region: eu-west-1
    owner: team-payments
    costCenter: "CC-4471"
    databases:
      - name: ledger
        engine: postgres
        version: "16"
        size: small
    egress:
      - host: api.stripe.com
        port: 443
    ttl: never                  # dev/preview usan "72h"
```

Ese objeto de ~20 líneas expande a ~40 recursos: VPC subnets, security groups, un RDS, un namespace con quota, RBAC bindings, un IAM role federado con el ServiceAccount, políticas de red, entradas de DNS, un `AppProject` de Argo CD y un dashboard.

### 2.2 Separación de responsabilidades

```
┌──────────────────────────────────────────────────────────────────┐
│  Application developer                                            │
│  · Declara: qué app, qué entorno, qué dependencias lógicas        │
│  · NO declara: subnets, AMIs, versiones de CNI, IAM policies      │
└───────────────────────────────┬──────────────────────────────────┘
                                │  Environment / Workload spec
┌───────────────────────────────▼──────────────────────────────────┐
│  Platform engineer                                                │
│  · Define el schema (XRD/CRD) y las composiciones                 │
│  · Garantiza parity, security baseline, upgrade path, costo       │
└───────────────────────────────┬──────────────────────────────────┘
                                │  Cloud APIs / Cluster API
┌───────────────────────────────▼──────────────────────────────────┐
│  Infrastructure (cloud, bare metal, edge)                         │
└──────────────────────────────────────────────────────────────────┘
```

Regla de diseño: **si el desarrollador puede escribir un campo que rompa el security baseline, el schema está mal diseñado.** El schema es el punto donde se hace cumplir la política, no un formulario libre.

---

## 3. Topologías de aislamiento: la decisión central

Esta es la comparativa que más aparece en el examen y la que más plata cuesta si se elige mal.

### 3.1 Tabla de trade-offs

| Criterio | Namespace por env | vCluster por env | Cluster por env | Cuenta/subscription por env |
|---|---|---|---|---|
| **Blast radius de un error de config** | Namespace | vCluster | Cluster | Cuenta |
| **Aislamiento de control plane (API server, etcd)** | Ninguno | Sí (API server propio) | Sí | Sí |
| **Aislamiento de CRDs / versiones de CRD** | No — CRDs son cluster-scoped | Sí | Sí | Sí |
| **Aislamiento de nodos / kernel** | Solo con taints + node pools | Compartido por defecto | Sí | Sí |
| **Aislamiento de IAM cloud** | Por ServiceAccount (IRSA/WI) | Por ServiceAccount | Por cluster role | Fuerte (boundary de cuenta) |
| **Aislamiento de red L3** | NetworkPolicy (opt-in) | NetworkPolicy | VPC / VNet | VPC + boundary de cuenta |
| **Aislamiento de blast radius de upgrade de K8s** | No | Parcial (versión del vCluster) | Sí | Sí |
| **Ruido de vecino (noisy neighbour) en etcd** | Alto | Bajo | Nulo | Nulo |
| **Tiempo de provisión** | 5–30 s | 30–90 s | 12–40 min | 20–90 min |
| **Costo fijo mensual (orden de magnitud)** | ~0 | ~$5–20 | ~$75 (CP) + nodos | CP + nodos + servicios base |
| **Overhead operativo (upgrades/parches)** | 1 cluster | 1 host cluster + N vClusters | N clusters | N clusters + N cuentas |
| **Aptitud para preview environments efímeros** | Buena | **Muy buena** | Mala (lento y caro) | Muy mala |
| **Aptitud para prod multi-tenant hostil** | Insuficiente | Insuficiente sola | Buena | **Muy buena** |
| **Cumple compliance de segregación (PCI, SOC2 CC6.1)** | Difícil de argumentar | Difícil | Aceptable | **Preferida por auditores** |

### 3.2 Cómo se decide

El criterio no es "cuál es mejor" sino **qué grado de confianza tenés en el tenant y qué te exige el auditor**:

- **Tenants confiables + un solo equipo de plataforma + no-prod** → namespace por environment. Es lo correcto y lo más barato. No sobre-ingenierices.
- **Tenants confiables pero que necesitan CRDs propios, operators, o versiones distintas de un CRD** → vCluster. Este es el caso que rompe el modelo de namespace y sorprende a mucha gente: `CustomResourceDefinition` es cluster-scoped, así que dos equipos no pueden tener versiones distintas de la misma CRD en el mismo cluster.
- **Producción, o cualquier entorno con datos regulados** → cluster dedicado como mínimo.
- **Tenants mutuamente desconfiados, o separación exigida por regulación** → cuenta/subscription/project por entorno, con red separada.

**Antipatrón frecuente:** un solo cluster con `prod` y `dev` como namespaces vecinos, y `default-allow` de red. El blast radius de un `kubectl delete -n prod` mal tipeado, de un operator con RBAC cluster-wide, o de un pod de dev que agota el CPU del nodo compartido, es total. La separación por namespace es una separación **administrativa**, no una separación **de seguridad**.

### 3.3 Modelos de multi-tenancy de Kubernetes

El SIG Multi-Tenancy define tres modelos; el CNPA los referencia como vocabulario:

| Modelo | Unidad entregada al tenant | Quién opera el control plane | Herramientas típicas |
|---|---|---|---|
| **Namespaces as a Service** | Uno o varios namespaces | La plataforma | HNC, Capsule, quotas + RBAC |
| **Control planes as a Service** | Un API server virtual | La plataforma (host cluster) | vCluster, Kamaji, kcp |
| **Clusters as a Service** | Un cluster completo | La plataforma (declarativamente) | Cluster API, EKS/AKS/GKE + Crossplane |

Con **soft multi-tenancy** (namespaces) el aislamiento depende de que el kernel y el API server no tengan bugs de escape y de que la política admission sea correcta. Con **hard multi-tenancy** hay una frontera de máquina o de cuenta. Para cargas no confiables (ejecutar código de terceros), se agrega un runtime sandbox: **gVisor** (`runsc`) o **Kata Containers** (microVM), seleccionados con `RuntimeClass`.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    platform.example.io/sandboxed: "true"
  tolerations:
    - key: platform.example.io/sandboxed
      operator: Equal
      value: "true"
      effect: NoSchedule
overhead:
  podFixed:
    cpu: 60m
    memory: 100Mi
```

El campo `overhead` es importante y suele olvidarse: sin él, el scheduler y las `ResourceQuota` subestiman el consumo real de cada pod sandboxeado y el nodo se sobrecomprometete.

---

## 4. Arquitectura de infraestructura en capas

### 4.1 El stack y su orden de bootstrap

Un environment no se materializa de una sola vez: hay un grafo de dependencias estricto. Violarlo es la causa número uno de bootstraps que se cuelgan a medio camino.

```
Layer 5  Application workloads            (Deployment, Rollout, Job)
            ▲ depende de
Layer 4  Application runtime services     (Ingress class, cert issuer, service mesh,
            ▲                              external-secrets, DB operator)
Layer 3  Cluster add-ons / platform svc   (CNI, CSI, CoreDNS, metrics-server,
            ▲                              Karpenter/autoscaler, GitOps agent)
Layer 2  Cluster control plane            (API server, etcd, scheduler, CM)
            ▲
Layer 1  Network                          (VPC/VNet, subnets, routing, NAT, DNS, peering)
            ▲
Layer 0  Landing zone                     (cuenta/subscription/project, IAM base,
                                           org policies, logging destination, budget)
```

**Reglas que se derivan del grafo:**

1. Las capas 0–2 se provisionan con la API de la nube (Terraform, OpenTofu, Crossplane, Cluster API). No se pueden crear con GitOps *desde adentro del cluster que todavía no existe*.
2. La capa 3 debe incluir el agente GitOps, y a partir de ahí el resto se auto-reconcilia. Este es el patrón **GitOps bridge**: la herramienta imperativa crea el mínimo indispensable (cluster + agente GitOps + un secret de acceso al repo) y entrega el control.
3. La capa 4 es la que define la **paridad funcional** entre entornos. Si `prod` tiene `cert-manager` con un `ClusterIssuer` de Let's Encrypt y `staging` tiene certificados autofirmados, cualquier prueba de TLS en staging es teatro.

### 4.2 Management cluster vs. workload cluster (hub-and-spoke)

```
                    ┌──────────────────────────────────┐
                    │      MANAGEMENT CLUSTER (hub)    │
                    │                                  │
                    │  · Cluster API controllers       │
                    │  · Crossplane + providers        │
                    │  · Argo CD / Flux (fleet)        │
                    │  · Policy distribution           │
                    │  · Fleet-wide observability sink │
                    └───────┬──────────┬──────────┬────┘
                            │          │          │
              ┌─────────────▼──┐  ┌────▼───────┐ ┌▼─────────────┐
              │ dev-eu-west-1  │  │ stg-eu-w-1 │ │ prod-eu-w-1  │
              │ (spoke)        │  │ (spoke)    │ │ (spoke)      │
              └────────────────┘  └────────────┘ └──────────────┘
```

Decisiones críticas del hub-and-spoke:

| Decisión | Opción A | Opción B | Recomendación |
|---|---|---|---|
| ¿Dónde corre el agente GitOps? | En el hub (push a spokes) | En cada spoke (pull) | **Pull por spoke** para prod: no requiere credenciales de prod en el hub, y sobrevive a la caída del hub |
| ¿El hub puede desplegar a prod? | Sí | No, solo bootstrap | **Solo bootstrap**; el hub es un blast radius enorme |
| ¿Un hub o uno por región? | Uno global | Uno por región/entorno | Uno por *dominio de fallo* si la disponibilidad del hub afecta el time-to-recover |
| ¿El hub se auto-gestiona? | Sí (pivot con `clusterctl move`) | Bootstrap externo (kind efímero) | Pivot, con backup de etcd verificado |

**El hub es un single point of failure de *provisión*, no de *ejecución*.** Los spokes siguen sirviendo tráfico si el hub muere. Lo que se pierde es la capacidad de crear/escalar/reparar clusters. Ese SLO debe estar documentado explícitamente.

### 4.3 Dominios de fallo dentro de un environment

Un environment de producción se describe también por su topología de fallo:

| Nivel | Etiqueta estándar | Qué protege | Costo |
|---|---|---|---|
| **Nodo** | `kubernetes.io/hostname` | Fallo de máquina, drenaje por upgrade | ~0 |
| **Zona (AZ)** | `topology.kubernetes.io/zone` | Fallo de datacenter, corte de energía | Tráfico cross-AZ ($) |
| **Región** | `topology.kubernetes.io/region` | Desastre regional | Réplica completa + latencia |
| **Proveedor** | (custom) | Fallo del cloud provider | Muy alto; rara vez justificado |

La regla operativa: **el control plane de Kubernetes con etcd requiere quórum**. Con 3 réplicas en 3 AZ, se tolera la pérdida de 1 AZ. Con 3 réplicas en 2 AZ, la pérdida de la AZ que tiene 2 réplicas destruye el quórum. Esto es aritmética, no configuración: verificalo siempre.

---

## 5. Manifiestos completos

### 5.1 Un environment sobre namespace compartido (baseline de plataforma completo)

Este es el conjunto **mínimo** que la plataforma debe emitir por cada environment de namespace. Nada de esto es opcional.

```yaml
# ─────────────────────────────────────────────────────────────────────
# 01-namespace.yaml
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: Namespace
metadata:
  name: payments-staging
  labels:
    # Identidad del environment: estas labels son la clave de todo lo demás
    platform.example.io/environment: staging
    platform.example.io/tier: non-prod
    platform.example.io/application: payments
    platform.example.io/owner: team-payments
    # Pod Security Admission: enforcement en el namespace, no negociable
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.31
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.31
  annotations:
    platform.example.io/cost-center: "CC-4471"
    platform.example.io/slo-availability: "99.0"
    platform.example.io/ttl: "never"
    platform.example.io/managed-by: "crossplane/xenvironment/payments-staging"
---
# ─────────────────────────────────────────────────────────────────────
# 02-quota-compute.yaml
# Cuota de cómputo agregada. Sin esto, un solo entorno puede consumir
# el cluster entero y provocar evicciones en entornos vecinos.
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute
  namespace: payments-staging
spec:
  hard:
    requests.cpu: "24"
    requests.memory: 48Gi
    limits.cpu: "48"
    limits.memory: 96Gi
    requests.ephemeral-storage: 100Gi
    requests.storage: 500Gi
    persistentvolumeclaims: "20"
    # Cuota por StorageClass: evita que se use SSD premium por descuido
    gp3.storageclass.storage.k8s.io/requests.storage: 400Gi
    io2.storageclass.storage.k8s.io/requests.storage: 100Gi
---
# ─────────────────────────────────────────────────────────────────────
# 03-quota-objects.yaml
# Cuota de conteo de objetos. Protege a etcd y al API server,
# que son recursos compartidos por TODOS los tenants del cluster.
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ResourceQuota
metadata:
  name: objects
  namespace: payments-staging
spec:
  hard:
    count/deployments.apps: "40"
    count/statefulsets.apps: "10"
    count/cronjobs.batch: "25"
    count/jobs.batch: "100"
    count/services: "40"
    count/secrets: "80"
    count/configmaps: "80"
    services.loadbalancers: "2"     # cada LB es dinero real
    services.nodeports: "0"          # prohibidos: rompen el modelo de ingress
---
# ─────────────────────────────────────────────────────────────────────
# 04-quota-priority-headroom.yaml
# Reserva de capacidad por PriorityClass: los workloads batch no pueden
# consumir el presupuesto reservado a los servicios de latencia crítica.
# El scopeSelector hace que esta cuota SOLO cuente pods de esa clase.
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ResourceQuota
metadata:
  name: batch-ceiling
  namespace: payments-staging
spec:
  hard:
    requests.cpu: "6"
    requests.memory: 12Gi
    pods: "30"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values: ["platform-batch"]
---
# ─────────────────────────────────────────────────────────────────────
# 05-limitrange.yaml
# Defaults y techos por contenedor. Sin defaultRequest, un pod sin
# requests es BestEffort y es el primero en ser evictado — y además
# rompe la contabilidad de la ResourceQuota (la creación es rechazada).
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: payments-staging
spec:
  limits:
    - type: Container
      default:                     # se aplica a limits si el pod no los define
        cpu: 500m
        memory: 512Mi
        ephemeral-storage: 2Gi
      defaultRequest:              # se aplica a requests si el pod no los define
        cpu: 100m
        memory: 128Mi
        ephemeral-storage: 512Mi
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 10m
        memory: 32Mi
      maxLimitRequestRatio:        # controla el overcommit por contenedor
        cpu: "10"
        memory: "4"
    - type: PersistentVolumeClaim
      max:
        storage: 100Gi
      min:
        storage: 1Gi
    - type: Pod
      max:
        cpu: "8"
        memory: 16Gi
---
# ─────────────────────────────────────────────────────────────────────
# 06-netpol-default-deny.yaml
# Punto de partida obligatorio. Todo lo demás es una excepción explícita.
# ─────────────────────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments-staging
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# ─────────────────────────────────────────────────────────────────────
# 07-netpol-dns.yaml
# Sin esta excepción, NADA funciona: la resolución de nombres muere y
# los síntomas parecen fallos de aplicación, no de red.
# ─────────────────────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments-staging
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# ─────────────────────────────────────────────────────────────────────
# 08-netpol-environment-boundary.yaml
# LA política que produce la frontera del environment: tráfico este-oeste
# permitido SOLO dentro del mismo environment. Un pod de dev no puede
# alcanzar un pod de staging aunque compartan cluster.
# ─────────────────────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-environment
  namespace: payments-staging
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              platform.example.io/environment: staging
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              platform.example.io/environment: staging
---
# ─────────────────────────────────────────────────────────────────────
# 09-netpol-platform-egress.yaml
# Egress a servicios de plataforma (observabilidad) y a Internet
# excluyendo rangos privados y el endpoint de metadatos de la nube
# (169.254.169.254 — vector de robo de credenciales IAM).
# ─────────────────────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-platform-and-internet-egress
  namespace: payments-staging
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: observability
          podSelector:
            matchLabels:
              app.kubernetes.io/name: otel-collector
      ports:
        - protocol: TCP
          port: 4317
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 443
---
# ─────────────────────────────────────────────────────────────────────
# 10-rbac.yaml
# El equipo dueño puede operar su environment; NO puede tocar quotas,
# limitranges ni networkpolicies (eso lo posee la plataforma).
# ─────────────────────────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-payments-operate
  namespace: payments-staging
subjects:
  - kind: Group
    name: "oidc:team-payments"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform:tenant-operator     # ClusterRole definido por la plataforma
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:tenant-operator
rules:
  - apiGroups: ["", "apps", "batch", "autoscaling", "networking.k8s.io"]
    resources:
      - pods
      - pods/log
      - pods/exec
      - pods/portforward
      - services
      - configmaps
      - deployments
      - statefulsets
      - replicasets
      - jobs
      - cronjobs
      - horizontalpodautoscalers
      - ingresses
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]     # lectura sí, escritura no: van por ExternalSecret
  - apiGroups: [""]
    resources: ["resourcequotas", "limitranges"]
    verbs: ["get", "list", "watch"]     # visibles pero inmutables para el tenant
  - apiGroups: ["events.k8s.io", ""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
---
# ─────────────────────────────────────────────────────────────────────
# 11-serviceaccount.yaml
# Identidad federada hacia la nube: sin credenciales de larga vida.
# El role de IAM está scopeado a los recursos de ESTE environment.
# ─────────────────────────────────────────────────────────────────────
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments-staging
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/payments-staging-api"
automountServiceAccountToken: false     # se monta explícitamente donde hace falta
```

### 5.2 El workload, con las restricciones de topología del environment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments-staging
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/version: "2.14.3"
    platform.example.io/environment: staging
spec:
  replicas: 6
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/version: "2.14.3"
        platform.example.io/environment: staging
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: true
      priorityClassName: platform-standard
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      # ── Distribución sobre dominios de fallo ──────────────────────
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule     # duro: nunca concentrar en una AZ
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
          matchLabelKeys:
            - pod-template-hash                # solo compara contra la MISMA revisión
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway    # blando: preferir, no bloquear
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      nodeSelector:
        platform.example.io/pool: general
      tolerations:
        - key: platform.example.io/pool
          operator: Equal
          value: general
          effect: NoSchedule
      containers:
        - name: api
          image: registry.example.io/payments/api@sha256:9f2c1e4b7a3d5f8c6e0b2a4d7f1c3e5a8b0d2f4c6e8a0b2d4f6c8e0a2b4d6f8c
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          env:
            - name: ENVIRONMENT
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['platform.example.io/environment']
            - name: POD_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['topology.kubernetes.io/zone']
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability.svc.cluster.local:4317"
          envFrom:
            - configMapRef:
                name: payments-api-config     # generado por el environment
            - secretRef:
                name: payments-api-db         # producido por ExternalSecret
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 1Gi                     # sin límite de CPU: evita throttling
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: http
            periodSeconds: 3
            failureThreshold: 40              # tolera 120 s de arranque frío
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 6
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sleep", "10"]  # drenaje de endpoints antes de SIGTERM
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 512Mi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments-staging
spec:
  # minAvailable como porcentaje sobrevive al escalado; un número fijo no.
  minAvailable: 60%
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
  unhealthyPodEvictionPolicy: AlwaysAllow   # evita PDB deadlock con pods rotos
```

> **Detalle que cuesta incidentes:** `unhealthyPodEvictionPolicy: AlwaysAllow` (GA desde 1.27). Sin él, si todos los pods están `NotReady`, el PDB bloquea las evicciones y el drenaje de nodos para upgrade se cuelga indefinidamente — justo cuando más necesitás reemplazar los nodos.

### 5.3 Infraestructura de cluster: Cluster API con ClusterClass

`ClusterClass` es el mecanismo que convierte "un cluster" en "una instancia de un template versionado". Es el equivalente a nivel de infraestructura de lo que un Deployment es a nivel de pod: se cambia la clase y todos los clusters derivados convergen.

```yaml
# ─────────────────────────────────────────────────────────────────────
# El template versionado del que derivan TODOS los clusters de la flota.
# API: cluster.x-k8s.io/v1beta1 (contrato estable). Cluster API >= 1.10
# ofrece v1beta2 en paralelo; verificá el contrato de tus providers antes
# de migrar, porque cada infrastructure provider migra por separado.
# ─────────────────────────────────────────────────────────────────────
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterClass
metadata:
  name: platform-aws-v3
  namespace: fleet-system
spec:
  controlPlane:
    ref:
      apiVersion: controlplane.cluster.x-k8s.io/v1beta1
      kind: KubeadmControlPlaneTemplate
      name: platform-aws-v3-control-plane
    machineInfrastructure:
      ref:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: AWSMachineTemplate
        name: platform-aws-v3-control-plane
  infrastructure:
    ref:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
      kind: AWSClusterTemplate
      name: platform-aws-v3
  workers:
    machineDeployments:
      - class: general
        template:
          bootstrap:
            ref:
              apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
              kind: KubeadmConfigTemplate
              name: platform-aws-v3-general
          infrastructure:
            ref:
              apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
              kind: AWSMachineTemplate
              name: platform-aws-v3-general
      - class: memory-optimized
        template:
          bootstrap:
            ref:
              apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
              kind: KubeadmConfigTemplate
              name: platform-aws-v3-memory
          infrastructure:
            ref:
              apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
              kind: AWSMachineTemplate
              name: platform-aws-v3-memory
  variables:
    - name: region
      required: true
      schema:
        openAPIV3Schema:
          type: string
          enum: ["eu-west-1", "eu-central-1", "us-east-1"]
    - name: environmentTier
      required: true
      schema:
        openAPIV3Schema:
          type: string
          enum: ["dev", "staging", "prod"]
    - name: controlPlaneInstanceType
      required: false
      schema:
        openAPIV3Schema:
          type: string
          default: "m6i.large"
    - name: auditPolicyLevel
      required: false
      schema:
        openAPIV3Schema:
          type: string
          enum: ["Metadata", "Request", "RequestResponse"]
          default: "Metadata"
  patches:
    - name: regionPatch
      definitions:
        - selector:
            apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
            kind: AWSClusterTemplate
            matchResources:
              infrastructureCluster: true
          jsonPatches:
            - op: add
              path: /spec/template/spec/region
              valueFrom:
                variable: region
    - name: auditPolicyPatch
      definitions:
        - selector:
            apiVersion: controlplane.cluster.x-k8s.io/v1beta1
            kind: KubeadmControlPlaneTemplate
            matchResources:
              controlPlane: true
          jsonPatches:
            - op: add
              path: /spec/template/spec/kubeadmConfigSpec/clusterConfiguration/apiServer/extraArgs/audit-policy-file
              value: "/etc/kubernetes/audit/policy.yaml"
---
# ─────────────────────────────────────────────────────────────────────
# Una instancia: el cluster de producción. 40 líneas para un cluster
# completo, HA, en tres AZ. Toda la complejidad vive en la ClusterClass.
# ─────────────────────────────────────────────────────────────────────
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: prod-eu-west-1
  namespace: fleet-prod
  labels:
    platform.example.io/environment: prod
    platform.example.io/region: eu-west-1
    platform.example.io/criticality: tier-1
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/12"]
    serviceDomain: cluster.local
  topology:
    class: platform-aws-v3
    version: v1.31.6
    controlPlane:
      replicas: 3                     # quórum de etcd: 3 réplicas, 3 AZ, tolera 1
      metadata:
        labels:
          platform.example.io/role: control-plane
    workers:
      machineDeployments:
        - class: general
          name: general-a
          replicas: 3
          failureDomain: eu-west-1a
        - class: general
          name: general-b
          replicas: 3
          failureDomain: eu-west-1b
        - class: general
          name: general-c
          replicas: 3
          failureDomain: eu-west-1c
        - class: memory-optimized
          name: mem-a
          replicas: 2
          failureDomain: eu-west-1a
    variables:
      - name: region
        value: eu-west-1
      - name: environmentTier
        value: prod
      - name: controlPlaneInstanceType
        value: m6i.xlarge
      - name: auditPolicyLevel
        value: RequestResponse        # prod audita cuerpos completos
```

> **Punto arquitectónico:** un `MachineDeployment` por AZ, en vez de uno solo con `failureDomain` automático, permite drenar y actualizar una zona a la vez y observar el impacto antes de continuar. Con un único MachineDeployment, el rolling update atraviesa las tres zonas simultáneamente y perdés esa palanca de control.

### 5.4 El environment como API: XRD + Composition de Crossplane

```yaml
# ─────────────────────────────────────────────────────────────────────
# EL CONTRATO. Este schema es la API que ve el desarrollador.
# Todo lo que NO está acá, el desarrollador no lo puede cambiar.
# ─────────────────────────────────────────────────────────────────────
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xenvironments.platform.example.io
spec:
  group: platform.example.io
  names:
    kind: XEnvironment
    plural: xenvironments
  claimNames:                        # Crossplane v1.x: el claim es namespaced.
    kind: Environment                # En Crossplane v2 los XR ya son namespaced
    plural: environments             # y los claims quedan deprecados.
  defaultCompositionRef:
    name: environment-aws
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    tier:
                      type: string
                      description: "Clase de entorno; gobierna sizing, política y SLO."
                      enum: ["dev", "staging", "prod"]
                    region:
                      type: string
                      enum: ["eu-west-1", "eu-central-1"]
                    owner:
                      type: string
                      description: "Grupo OIDC dueño; recibe el RoleBinding."
                      pattern: "^team-[a-z0-9-]{2,30}$"
                    costCenter:
                      type: string
                      pattern: "^CC-[0-9]{4}$"
                    ttl:
                      type: string
                      description: "Duración antes del borrado automático, o 'never'."
                      pattern: "^([0-9]+h|never)$"
                      default: "72h"
                    databases:
                      type: array
                      maxItems: 5
                      items:
                        type: object
                        properties:
                          name:
                            type: string
                            pattern: "^[a-z][a-z0-9]{2,20}$"
                          engine:
                            type: string
                            enum: ["postgres", "mysql"]
                          version:
                            type: string
                          size:
                            type: string
                            enum: ["small", "medium", "large"]
                        required: ["name", "engine", "size"]
                  required: ["tier", "region", "owner", "costCenter"]
              required: ["parameters"]
            status:
              type: object
              properties:
                namespace:
                  type: string
                apiEndpoint:
                  type: string
                databaseEndpoints:
                  type: array
                  items:
                    type: string
      additionalPrinterColumns:
        - name: TIER
          type: string
          jsonPath: ".spec.parameters.tier"
        - name: REGION
          type: string
          jsonPath: ".spec.parameters.region"
        - name: NAMESPACE
          type: string
          jsonPath: ".status.namespace"
        - name: READY
          type: string
          jsonPath: ".status.conditions[?(@.type=='Ready')].status"
---
# ─────────────────────────────────────────────────────────────────────
# LA IMPLEMENTACIÓN. Modo Pipeline con composition functions
# (el modo Resources clásico está deprecado desde Crossplane 1.17).
# ─────────────────────────────────────────────────────────────────────
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: environment-aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: platform.example.io/v1alpha1
    kind: XEnvironment
  writeConnectionSecretsToNamespace: crossplane-system
  mode: Pipeline
  pipeline:
    # Paso 1: recursos estáticos con patches desde el claim
    - step: base-resources
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          # ── El namespace del environment ──────────────────────────
          - name: namespace
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: Namespace
                    metadata:
                      labels:
                        pod-security.kubernetes.io/enforce: restricted
                        pod-security.kubernetes.io/enforce-version: v1.31
                providerConfigRef:
                  name: in-cluster
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.manifest.metadata.labels["platform.example.io/environment"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.owner
                toFieldPath: spec.forProvider.manifest.metadata.labels["platform.example.io/owner"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.costCenter
                toFieldPath: spec.forProvider.manifest.metadata.annotations["platform.example.io/cost-center"]
              - type: ToCompositeFieldPath
                fromFieldPath: spec.forProvider.manifest.metadata.name
                toFieldPath: status.namespace
          # ── Subnet privada dedicada al environment ────────────────
          - name: subnet
            base:
              apiVersion: ec2.aws.upbound.io/v1beta1
              kind: Subnet
              spec:
                forProvider:
                  vpcIdSelector:
                    matchLabels:
                      platform.example.io/purpose: workloads
                  mapPublicIpOnLaunch: false
                  tags:
                    ManagedBy: crossplane
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.region
                toFieldPath: spec.forProvider.region
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.costCenter
                toFieldPath: spec.forProvider.tags["CostCenter"]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.tags["Environment"]
          # ── Cuota dimensionada según el tier ──────────────────────
          - name: resource-quota
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: ResourceQuota
                    metadata:
                      name: compute
                    spec:
                      hard: {}
                providerConfigRef:
                  name: in-cluster
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              # El mapa tier→cuota es política de plataforma, no del tenant.
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.manifest.spec.hard["requests.cpu"]
                transforms:
                  - type: map
                    map:
                      dev: "4"
                      staging: "24"
                      prod: "128"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.tier
                toFieldPath: spec.forProvider.manifest.spec.hard["requests.memory"]
                transforms:
                  - type: map
                    map:
                      dev: "8Gi"
                      staging: "48Gi"
                      prod: "256Gi"
    # Paso 2: los recursos variables (N bases de datos) se generan por
    # código, porque patch-and-transform no puede iterar arrays.
    - step: databases
      functionRef:
        name: function-go-templating
      input:
        apiVersion: gotemplating.fn.crossplane.io/v1beta1
        kind: GoTemplate
        source: Inline
        inline:
          template: |
            {{- $spec := .observed.composite.resource.spec.parameters }}
            {{- range $db := $spec.databases }}
            ---
            apiVersion: rds.aws.upbound.io/v1beta2
            kind: Instance
            metadata:
              annotations:
                {{ setResourceNameAnnotation (printf "db-%s" $db.name) }}
            spec:
              forProvider:
                region: {{ $spec.region }}
                engine: {{ $db.engine }}
                engineVersion: "{{ $db.version }}"
                instanceClass: {{ if eq $db.size "small" }}db.t4g.medium{{ else if eq $db.size "medium" }}db.r6g.large{{ else }}db.r6g.2xlarge{{ end }}
                allocatedStorage: {{ if eq $db.size "small" }}20{{ else if eq $db.size "medium" }}100{{ else }}500{{ end }}
                storageEncrypted: true
                multiAz: {{ eq $spec.tier "prod" }}
                deletionProtection: {{ eq $spec.tier "prod" }}
                backupRetentionPeriod: {{ if eq $spec.tier "prod" }}30{{ else }}1{{ end }}
                skipFinalSnapshot: {{ ne $spec.tier "prod" }}
                publiclyAccessible: false
                username: appuser
                autoGeneratePassword: true
                passwordSecretRef:
                  namespace: crossplane-system
                  name: {{ $.observed.composite.resource.metadata.name }}-{{ $db.name }}
                  key: password
                tags:
                  CostCenter: {{ $spec.costCenter }}
                  Environment: {{ $spec.tier }}
              writeConnectionSecretToRef:
                namespace: crossplane-system
                name: {{ $.observed.composite.resource.metadata.name }}-{{ $db.name }}-conn
            {{- end }}
    # Paso 3: no reportar Ready hasta que todo esté realmente listo
    - step: ready-check
      functionRef:
        name: function-auto-ready
```

Fijate en las líneas `multiAz: {{ eq $spec.tier "prod" }}`, `deletionProtection`, `backupRetentionPeriod` y `skipFinalSnapshot`. **Ahí está la diferencia real entre entornos, y la codifica la plataforma, no el desarrollador.** El dev pidió "una base postgres small"; la plataforma decidió que en prod eso significa Multi-AZ con 30 días de backup y protección de borrado, y en dev significa una instancia barata y descartable. Eso es un golden path.

### 5.5 Preview environments efímeros con vCluster + Argo CD

```yaml
# ─────────────────────────────────────────────────────────────────────
# ApplicationSet con PR generator: un environment completo por Pull
# Request, destruido automáticamente al cerrar el PR.
# ─────────────────────────────────────────────────────────────────────
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-previews
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - pullRequest:
        github:
          owner: example
          repo: payments
          tokenRef:
            secretName: github-token
            key: token
          labels:
            - preview                    # opt-in explícito: no todo PR crea entorno
        requeueAfterSeconds: 120
  template:
    metadata:
      name: 'payments-preview-{{.number}}'
      labels:
        platform.example.io/environment: preview
        platform.example.io/ttl: "72h"
      annotations:
        notifications.argoproj.io/subscribe.on-sync-succeeded.github: ""
    spec:
      project: payments-preview
      source:
        repoURL: https://github.com/example/payments.git
        targetRevision: '{{.head_sha}}'
        path: deploy/preview
        helm:
          releaseName: 'pr-{{.number}}'
          valuesObject:
            image:
              tag: '{{.head_sha}}'
            ingress:
              host: 'pr-{{.number}}.preview.example.io'
            resources:
              requests:
                cpu: 50m
                memory: 128Mi
            database:
              mode: ephemeral            # postgres en contenedor + seed sintético
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-pr-{{.number}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 3
          backoff:
            duration: 15s
            factor: 2
            maxDuration: 3m
  # Al cerrarse el PR el generator deja de producir el item y la App se borra.
  # Sin esta política, quedaría huérfana consumiendo recursos.
  syncPolicy:
    applicationsSync: create-delete
    preserveResourcesOnDeletion: false
```

```yaml
# ─────────────────────────────────────────────────────────────────────
# vcluster values: cuando el preview necesita CRDs propios o cluster-scoped
# resources que no caben en un namespace compartido.
# ─────────────────────────────────────────────────────────────────────
controlPlane:
  distro:
    k8s:
      enabled: true
      version: v1.31.6
  backingStore:
    database:
      embedded:
        enabled: true         # SQLite: suficiente para efímeros, NO para prod
  statefulSet:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1Gi
    persistence:
      volumeClaim:
        enabled: true
        size: 5Gi
        storageClass: gp3

sync:
  toHost:
    pods:
      enabled: true
      enforceTolerations:
        - "platform.example.io/pool=preview:NoSchedule"
    services:
      enabled: true
    persistentVolumeClaims:
      enabled: true
    ingresses:
      enabled: true
  fromHost:
    nodes:
      enabled: true
      selector:
        labels:
          platform.example.io/pool: preview
    storageClasses:
      enabled: true

policies:
  resourceQuota:
    enabled: true
    quota:
      requests.cpu: "4"
      requests.memory: 8Gi
      count/pods: "40"
  limitRange:
    enabled: true
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 50m
      memory: 128Mi
  networkPolicy:
    enabled: true

exportKubeConfig:
  context: preview
  server: https://vcluster-preview.example.io
  secret:
    name: vc-kubeconfig
```

### 5.6 Node pools por clase de workload (Karpenter)

La segmentación de nodos es donde el "infrastructure architecture" del environment se vuelve concreto: qué corre sobre qué hardware, y quién puede aterrizar ahí.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: prod-general
spec:
  template:
    metadata:
      labels:
        platform.example.io/pool: general
        platform.example.io/environment: prod
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]            # prod no usa spot para servicios stateful
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
      taints:
        - key: platform.example.io/pool
          value: general
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: prod-default
      expireAfter: 336h                    # 14 días: rotación forzada de AMI
      terminationGracePeriod: 1h           # techo duro; evita drenajes eternos
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "10%"                       # nunca tocar más del 10% simultáneo
      - nodes: "0"                         # congelamiento en horario laboral
        schedule: "0 8 * * mon-fri"
        duration: 10h
  limits:
    cpu: "2000"
    memory: 8000Gi
  weight: 50
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: prod-batch-spot
spec:
  template:
    metadata:
      labels:
        platform.example.io/pool: batch
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]                 # batch tolera interrupciones
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
      taints:
        - key: platform.example.io/pool
          value: batch
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: prod-default
      expireAfter: 168h
      terminationGracePeriod: 5m
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "500"
  weight: 10
```

---

## 6. Paridad y promoción entre entornos

### 6.1 Qué puede variar y qué no

La matriz de variación es un artefacto de arquitectura que hay que escribir explícitamente. Sin ella, "parity" es una opinión.

| Dimensión | ¿Puede variar? | Regla |
|---|---|---|
| Image digest del artefacto | **No** | El mismo digest se promueve; nunca se re-buildea por entorno |
| Versión de Kubernetes | Sí, acotado | prod ≤ staging ≤ dev; máximo una minor de diferencia |
| Réplicas / HPA min-max | Sí | Escala, no forma |
| Requests/limits | Sí | Con el mismo *ratio* limit/request |
| Tamaño de instancia de DB | Sí | Misma *engine* y misma *major version* |
| Pod Security Admission level | **No** | Idéntico en todos los entornos |
| NetworkPolicy set | **No** (estructural) | Mismas reglas; solo cambian los CIDR y hosts |
| Set de admission policies | **No** | Idéntico; si algo se relaja en dev, la prueba no vale |
| Endpoints externos | Sí | Sandbox vs. producción del proveedor |
| Datos | Sí | Nunca datos de producción en no-prod sin anonimizar |
| Feature flags | Sí | Es el mecanismo *legítimo* de variación de comportamiento |
| TLS y certificate issuer | **No** (estructural) | Distinta CA, misma cadena de verificación |
| Observabilidad (métricas, trazas, logs) | **No** | Misma instrumentación y mismo pipeline |

Regla mnemotécnica para el examen: **la escala varía, la estructura no.** Todo lo que cambia la *forma* de la ejecución (política, red, identidad, instrumentación) debe ser idéntico; todo lo que cambia el *tamaño* puede variar.

### 6.2 Estructura de repositorio de promoción

```
payments-config/
├── base/                                  # única fuente de verdad estructural
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── hpa.yaml
│   └── pdb.yaml
├── components/                            # variaciones reutilizables y nombradas
│   ├── multi-az/
│   │   └── kustomization.yaml
│   ├── canary-rollout/
│   │   └── kustomization.yaml
│   └── debug-sidecar/
│       └── kustomization.yaml
└── envs/
    ├── dev/
    │   ├── kustomization.yaml
    │   ├── config.yaml                    # consumido por el ApplicationSet
    │   └── replicas-patch.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   ├── config.yaml
    │   └── replicas-patch.yaml
    └── prod/
        ├── kustomization.yaml
        ├── config.yaml
        └── replicas-patch.yaml
```

```yaml
# envs/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: payments-prod
resources:
  - ../../base
components:
  - ../../components/multi-az
  - ../../components/canary-rollout
labels:
  - includeSelectors: false
    pairs:
      platform.example.io/environment: prod
images:
  # Promoción = cambiar ESTE digest. Nunca un tag mutable como :latest.
  - name: registry.example.io/payments/api
    digest: sha256:9f2c1e4b7a3d5f8c6e0b2a4d7f1c3e5a8b0d2f4c6e8a0b2d4f6c8e0a2b4d6f8c
patches:
  - path: replicas-patch.yaml
    target:
      kind: Deployment
      name: payments-api
replicas:
  - name: payments-api
    count: 24
```

```yaml
# envs/prod/config.yaml — metadata del environment leída por el ApplicationSet
env:
  name: prod
  tier: prod
  region: eu-west-1
  cluster: prod-eu-west-1
  autoSync: false          # prod requiere sync manual o aprobación
  slo: "99.95"
```

```yaml
# ─────────────────────────────────────────────────────────────────────
# ApplicationSet con matrix generator: descubre entornos desde Git
# y los cruza con los clusters registrados que llevan la label correcta.
# Agregar un environment = agregar un directorio. Cero cambios de plataforma.
# ─────────────────────────────────────────────────────────────────────
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: payments-environments
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/example/payments-config.git
              revision: HEAD
              files:
                - path: "envs/*/config.yaml"
          - clusters:
              selector:
                matchLabels:
                  platform.example.io/environment: '{{ .env.tier }}'
  template:
    metadata:
      name: 'payments-{{ .env.name }}'
      labels:
        platform.example.io/environment: '{{ .env.tier }}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: payments
      source:
        repoURL: https://github.com/example/payments-config.git
        targetRevision: HEAD
        path: 'envs/{{ .env.name }}'
      destination:
        server: '{{ .server }}'
        namespace: 'payments-{{ .env.name }}'
      syncPolicy:
        syncOptions:
          - ServerSideApply=true
          - RespectIgnoreDifferences=true
      ignoreDifferences:
        - group: apps
          kind: Deployment
          jsonPointers:
            - /spec/replicas          # el HPA es el dueño de replicas en runtime
  templatePatch: |
    {{- if .env.autoSync }}
    spec:
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
    {{- end }}
```

---

## 7. Comandos CLI y salidas reales

### 7.1 Inventario y salud de la flota

```console
$ kubectl get clusters.cluster.x-k8s.io -A \
    -L platform.example.io/environment,platform.example.io/region
NAMESPACE      NAME                 CLUSTERCLASS       PHASE         AGE    VERSION   ENVIRONMENT   REGION
fleet-dev      dev-eu-west-1        platform-aws-v3    Provisioned   112d   v1.31.6   dev           eu-west-1
fleet-prod     prod-eu-central-1    platform-aws-v3    Provisioned   64d    v1.31.6   prod          eu-central-1
fleet-prod     prod-eu-west-1       platform-aws-v3    Provisioned   211d   v1.31.6   prod          eu-west-1
fleet-staging  staging-eu-west-1    platform-aws-v3    Provisioned   198d   v1.31.6   staging       eu-west-1
```

```console
$ clusterctl describe cluster prod-eu-west-1 -n fleet-prod
NAME                                                          READY  SEVERITY  REASON  SINCE  MESSAGE
Cluster/prod-eu-west-1                                        True                     64d
├─ClusterInfrastructure - AWSCluster/prod-eu-west-1            True                     64d
├─ControlPlane - KubeadmControlPlane/prod-eu-west-1-cp-x9k2m   True                     64d
│ └─3 Machines...                                              True                     64d    See prod-eu-west-1-cp-x9k2m-4tp8w, prod-eu-west-1-cp-x9k2m-b7zqd, ...
└─Workers
  ├─MachineDeployment/prod-eu-west-1-general-a                 True                     64d
  │ └─3 Machines...                                            True                     64d    See prod-eu-west-1-general-a-6f8d94c7b-k2xnp, ...
  ├─MachineDeployment/prod-eu-west-1-general-b                 True                     64d
  │ └─3 Machines...                                            True                     64d    See prod-eu-west-1-general-b-7c9f85d6a-m4qtr, ...
  ├─MachineDeployment/prod-eu-west-1-general-c                 True                     64d
  │ └─3 Machines...                                            True                     64d    See prod-eu-west-1-general-c-5b8e73f2c-w9jhx, ...
  └─MachineDeployment/prod-eu-west-1-mem-a                     True                     31d
    └─2 Machines...                                            True                     31d    See prod-eu-west-1-mem-a-9d4c62e8f-t3vkl, ...
```

Verificación de que el control plane realmente está distribuido en tres AZ (no alcanza con `replicas: 3`):

```console
$ kubectl get machines -n fleet-prod \
    -l cluster.x-k8s.io/control-plane \
    -o custom-columns='NAME:.metadata.name,ZONE:.spec.failureDomain,PHASE:.status.phase,VERSION:.spec.version'
NAME                                ZONE           PHASE     VERSION
prod-eu-west-1-cp-x9k2m-4tp8w       eu-west-1a     Running   v1.31.6
prod-eu-west-1-cp-x9k2m-b7zqd       eu-west-1b     Running   v1.31.6
prod-eu-west-1-cp-x9k2m-r5nvc       eu-west-1c     Running   v1.31.6
```

### 7.2 Estado de las cuotas del environment

```console
$ kubectl get resourcequota -n payments-staging
NAME             AGE   REQUEST                                                                                              LIMIT
batch-ceiling    41d   pods: 4/30, requests.cpu: 1200m/6, requests.memory: 3Gi/12Gi
compute          41d   persistentvolumeclaims: 7/20, requests.cpu: 18500m/24, requests.memory: 37Gi/48Gi, requests.storage: 320Gi/500Gi   limits.cpu: 33/48, limits.memory: 71Gi/96Gi
objects          41d   count/deployments.apps: 27/40, count/secrets: 44/80, count/services: 31/40, services.loadbalancers: 1/2, services.nodeports: 0/0
```

```console
$ kubectl describe resourcequota compute -n payments-staging
Name:                                            compute
Namespace:                                       payments-staging
Resource                                         Used    Hard
--------                                         ----    ----
gp3.storageclass.storage.k8s.io/requests.storage  270Gi   400Gi
io2.storageclass.storage.k8s.io/requests.storage  50Gi    100Gi
limits.cpu                                        33      48
limits.memory                                     71Gi    96Gi
persistentvolumeclaims                            7       20
requests.cpu                                      18500m  24
requests.ephemeral-storage                        14Gi    100Gi
requests.memory                                   37Gi    48Gi
requests.storage                                  320Gi   500Gi
```

Detección de entornos cerca del techo, en toda la flota — la métrica operativa que importa:

```console
$ kubectl get resourcequota -A -o json | jq -r '
    .items[]
    | select(.status.hard["requests.cpu"] != null)
    | . as $q
    | ($q.status.used["requests.cpu"] | rtrimstr("m") | tonumber
       | if ($q.status.used["requests.cpu"] | endswith("m")) then . else . * 1000 end) as $u
    | ($q.status.hard["requests.cpu"] | rtrimstr("m") | tonumber
       | if ($q.status.hard["requests.cpu"] | endswith("m")) then . else . * 1000 end) as $h
    | [$q.metadata.namespace, $q.metadata.name, (($u / $h * 100) | floor)]
    | @tsv' | awk -F'\t' '$3 > 75 {printf "%-24s %-16s %s%%\n", $1, $2, $3}'
payments-staging         compute          77%
checkout-prod            compute          91%
search-prod              compute          83%
```

### 7.3 Verificación de la frontera de red del environment

```console
$ kubectl get networkpolicy -n payments-staging
NAME                                  POD-SELECTOR   AGE
allow-dns-egress                      <none>         41d
allow-platform-and-internet-egress    <none>         41d
allow-same-environment                <none>         41d
default-deny-all                      <none>         41d
```

Prueba positiva (dentro del environment) y negativa (cruzando la frontera):

```console
$ kubectl run netcheck --rm -it --restart=Never \
    -n payments-staging \
    --image=nicolaka/netshoot:v0.13 \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netcheck","image":"nicolaka/netshoot:v0.13","stdin":true,"tty":true,"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    -- bash

netcheck~$ # 1. DNS debe funcionar
netcheck~$ dig +short payments-api.payments-staging.svc.cluster.local
10.96.212.44

netcheck~$ # 2. Mismo environment: PERMITIDO
netcheck~$ nc -zv -w 3 payments-api.payments-staging.svc.cluster.local 8080
Connection to payments-api.payments-staging.svc.cluster.local (10.96.212.44) 8080 port [tcp/http-alt] succeeded!

netcheck~$ # 3. Cruzar a otro environment: DEBE FALLAR
netcheck~$ nc -zv -w 3 payments-api.payments-prod.svc.cluster.local 8080
nc: connect to payments-api.payments-prod.svc.cluster.local (10.96.88.19) port 8080 (tcp) timed out: Operation now in progress

netcheck~$ # 4. Metadatos de la nube: DEBE FALLAR (robo de credenciales IAM)
netcheck~$ curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/
curl: (28) Connection timed out after 3001 milliseconds

netcheck~$ # 5. Egress a Internet permitido (443)
netcheck~$ curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 https://api.stripe.com/v1
401
```

> Interpretación: el timeout es la firma de un `NetworkPolicy` en modo drop. Un `Connection refused` inmediato significa que el paquete **llegó** y el destino no escuchaba — la política **no** lo bloqueó. Distinguir estos dos casos es la técnica de diagnóstico más útil de esta sección.

Con Cilium, la traza es directa en lugar de inferida:

```console
$ cilium policy trace \
    --src-k8s-pod payments-staging:payments-api-7d9f6c5b84-hq2xn \
    --dst-k8s-pod payments-prod:payments-api-5c8b7d9f42-k4mrp \
    --dport 8080
----------------------------------------------------------------
Tracing From: [k8s:io.kubernetes.pod.namespace=payments-staging, ...]
           To: [k8s:io.kubernetes.pod.namespace=payments-prod, ...]

Resolving ingress policy for [k8s:io.kubernetes.pod.namespace=payments-prod ...]
* Rule {"matchLabels":{"k8s:io.kubernetes.pod.namespace":"payments-prod"}}: no match
0/1 rules selected
Found no allow rule
Ingress verdict: denied

Final verdict: DENIED
```

### 7.4 Trazado del environment como recurso compuesto

```console
$ kubectl get environments.platform.example.io -A
NAMESPACE       NAME               TIER      REGION      NAMESPACE          READY   AGE
team-payments   payments-staging   staging   eu-west-1   payments-staging   True    41d
team-payments   payments-prod      prod      eu-west-1   payments-prod      True    198d
team-search     search-dev         dev       eu-west-1   search-dev         False   6m21s
```

```console
$ crossplane beta trace environment search-dev -n team-search
NAME                                          SYNCED   READY   STATUS
Environment/search-dev (team-search)          True     False   Waiting: ...resource claim is waiting for composite resource to become Ready
└─ XEnvironment/search-dev-x7k2p              True     False   Creating: Unready resources: db-catalog
   ├─ Object/search-dev-ns-4mq8t              True     True    Available
   ├─ Object/search-dev-quota-9zk3r           True     True    Available
   ├─ Subnet/search-dev-subnet-2p7wn          True     True    Available
   └─ Instance/search-dev-db-catalog-6t4vx    True     False   Creating: RDS instance is in state "creating"
```

```console
$ kubectl describe environment search-dev -n team-search | sed -n '/^Events:/,$p'
Events:
  Type     Reason                   Age                From                             Message
  ----     ------                   ----               ----                             -------
  Normal   ConfigureCompositeResource  6m21s           offered/platform.example.io/v1alpha1, kind=environment  Successfully composed resources
  Normal   BindCompositeResource       6m20s           offered/platform.example.io/v1alpha1, kind=environment  Successfully bound composite resource
  Warning  ComposeResources            5m58s (x3 over 6m18s)  composite/platform.example.io/v1alpha1, kind=xenvironment  cannot compose resources: pipeline step "databases": cannot run function: rpc error: code = ...
  Normal   ComposeResources            21s (x14 over 6m21s)   composite/platform.example.io/v1alpha1, kind=xenvironment  Unready resources: db-catalog
```

### 7.5 Verificación de topología de un workload

```console
$ kubectl get pods -n payments-prod -l app.kubernetes.io/name=payments-api \
    -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.annotations.topology\.kubernetes\.io/zone,STATUS:.status.phase' \
    --sort-by='.metadata.annotations.topology\.kubernetes\.io/zone'
NAME                            NODE                            ZONE         STATUS
payments-api-6c9d84f7b5-2xkn9   ip-10-0-12-41.ec2.internal      eu-west-1a   Running
payments-api-6c9d84f7b5-7mqvt   ip-10-0-12-88.ec2.internal      eu-west-1a   Running
payments-api-6c9d84f7b5-h4prd   ip-10-0-13-17.ec2.internal      eu-west-1a   Running
payments-api-6c9d84f7b5-k8zwx   ip-10-0-21-59.ec2.internal      eu-west-1b   Running
payments-api-6c9d84f7b5-n3jfc   ip-10-0-21-92.ec2.internal      eu-west-1b   Running
payments-api-6c9d84f7b5-q7tlm   ip-10-0-22-33.ec2.internal      eu-west-1b   Running
payments-api-6c9d84f7b5-v5hqz   ip-10-0-31-14.ec2.internal      eu-west-1c   Running
payments-api-6c9d84f7b5-w9dnk   ip-10-0-31-76.ec2.internal      eu-west-1c   Running
```

Chequeo agregado — la forma correcta de auditar el skew de la flota entera:

```console
$ kubectl get pods -n payments-prod -l app.kubernetes.io/name=payments-api \
    -o json | jq -r '.items[].metadata.annotations["topology.kubernetes.io/zone"]' \
    | sort | uniq -c
      3 eu-west-1a
      3 eu-west-1b
      2 eu-west-1c
```

Skew = 1 con `maxSkew: 1`. Correcto. Si viera `8 eu-west-1a` y nada más, el constraint no se está aplicando: casi siempre porque los nodos no tienen la label `topology.kubernetes.io/zone`, o porque `nodeSelector` restringió el dominio a un solo pool zonal.

### 7.6 Auditoría de paridad entre entornos

```console
$ diff <(kubectl kustomize envs/staging | yq -P 'sort_keys(..)' -) \
       <(kubectl kustomize envs/prod    | yq -P 'sort_keys(..)' -) \
  | grep -E '^[<>]' | grep -vE 'replicas|namespace|environment|host|digest|cpu|memory|storage'
< pod-security.kubernetes.io/enforce: baseline
> pod-security.kubernetes.io/enforce: restricted
```

Esa única línea residual es exactamente el tipo de drift que causa el incidente del §1.2: la estructura difiere en el eje de política. Todo lo filtrado (réplicas, tamaños, hosts) es variación legítima; lo que queda, no lo es.

```console
$ argocd app list -l platform.example.io/environment
NAME                     CLUSTER                          NAMESPACE          PROJECT   STATUS      HEALTH       SYNCPOLICY  CONDITIONS
payments-dev             https://dev-eu-west-1:6443       payments-dev       payments  Synced      Healthy      Auto-Prune  <none>
payments-prod            https://prod-eu-west-1:6443      payments-prod      payments  Synced      Healthy      Manual      <none>
payments-staging         https://staging-eu-west-1:6443   payments-staging   payments  OutOfSync   Progressing  Auto-Prune  <none>
```

```console
$ argocd app diff payments-staging --hard-refresh
===== apps/Deployment payments-staging/payments-api ======
30c30
<       image: registry.example.io/payments/api@sha256:1a4f...c2e9
---
>       image: registry.example.io/payments/api@sha256:9f2c...6f8c
```

---

## 8. Guía de verificación

Ejecutable como gate de aceptación cada vez que la plataforma entrega un environment nuevo. Si alguno falla, el environment **no está listo**, aunque el `Ready: True` diga lo contrario.

```bash
#!/usr/bin/env bash
# verify-environment.sh — acceptance gate for a provisioned environment.
# Usage: ./verify-environment.sh <namespace> <expected-tier>
set -euo pipefail

NS="${1:?namespace required}"
TIER="${2:?tier required}"
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

echo "Verifying environment ${NS} (tier=${TIER})"

# 1. Identity: the namespace carries the environment contract labels.
check "namespace has environment label" \
  bash -c "[[ \$(kubectl get ns '$NS' -o jsonpath='{.metadata.labels.platform\.example\.io/environment}') == '$TIER' ]]"
check "namespace has owner label" \
  bash -c "[[ -n \$(kubectl get ns '$NS' -o jsonpath='{.metadata.labels.platform\.example\.io/owner}') ]]"
check "namespace has cost-center annotation" \
  bash -c "[[ -n \$(kubectl get ns '$NS' -o jsonpath='{.metadata.annotations.platform\.example\.io/cost-center}') ]]"

# 2. Policy: PSA enforcement is present and equals the platform baseline.
check "pod security enforce=restricted" \
  bash -c "[[ \$(kubectl get ns '$NS' -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') == 'restricted' ]]"

# 3. Resource governance.
check "compute quota exists" kubectl get resourcequota compute -n "$NS"
check "object quota exists"  kubectl get resourcequota objects -n "$NS"
check "limitrange exists"    kubectl get limitrange defaults  -n "$NS"

# 4. Network boundary: default-deny must be the first policy in place.
check "default-deny policy exists" kubectl get networkpolicy default-deny-all -n "$NS"
check "dns egress policy exists"   kubectl get networkpolicy allow-dns-egress  -n "$NS"

# 5. Negative test: a privileged pod must be REJECTED by admission.
if kubectl run psa-probe -n "$NS" --image=busybox:1.36 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.36","securityContext":{"privileged":true}}]}}' \
     --dry-run=server >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  privileged pod is rejected (it was ADMITTED)\n'
  FAIL=$((FAIL + 1))
else
  printf '  \033[32mPASS\033[0m  privileged pod is rejected\n'
fi

# 6. Negative test: a pod without requests must still get them from LimitRange.
INJECTED=$(kubectl run lr-probe -n "$NS" --image=busybox:1.36 --restart=Never \
             --dry-run=server -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
check "limitrange injects default requests" bash -c "[[ -n '$INJECTED' ]]"

# 7. RBAC: the owning group can operate but cannot mutate governance objects.
OWNER=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.platform\.example\.io/owner}')
check "owner can create deployments" \
  kubectl auth can-i create deployments -n "$NS" --as-group="oidc:${OWNER}" --as="probe@example.io"
check "owner cannot delete resourcequotas" \
  bash -c "! kubectl auth can-i delete resourcequotas -n '$NS' --as-group='oidc:${OWNER}' --as='probe@example.io' >/dev/null 2>&1"

# 8. Fleet topology: control plane spread across at least 3 failure domains.
if [[ "$TIER" == "prod" ]]; then
  ZONES=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
            -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' \
            | tr ' ' '\n' | sort -u | wc -l)
  check "control plane spans >=3 zones (found ${ZONES})" bash -c "[[ ${ZONES} -ge 3 ]]"
fi

echo
if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: ${FAIL} check(s) failed — environment is NOT ready."
  exit 1
fi
echo "RESULT: all checks passed."
```

```console
$ ./verify-environment.sh payments-staging staging
Verifying environment payments-staging (tier=staging)
  PASS  namespace has environment label
  PASS  namespace has owner label
  PASS  namespace has cost-center annotation
  PASS  pod security enforce=restricted
  PASS  compute quota exists
  PASS  object quota exists
  PASS  limitrange exists
  PASS  default-deny policy exists
  PASS  dns egress policy exists
  PASS  privileged pod is rejected
  PASS  limitrange injects default requests
  PASS  owner can create deployments
  PASS  owner cannot delete resourcequotas

RESULT: all checks passed.
```

---

## 9. Diagnóstico de fallas

### 9.1 Tabla síntoma → causa → comando

| Síntoma observado | Causa raíz más probable | Comando de confirmación |
|---|---|---|
| `Deployment` con `replicas: 6` pero 0 pods y sin eventos en el Deployment | Cuota agotada: el **ReplicaSet** falla, no el Deployment | `kubectl describe rs -n <ns> <rs>` |
| `pods "x-abc-" is forbidden: exceeded quota` | `ResourceQuota` alcanzada | `kubectl describe quota -n <ns>` |
| `must specify limits.memory` al crear un pod | Hay `ResourceQuota` sobre `limits.*` pero falta el `LimitRange` | `kubectl get limitrange -n <ns>` |
| `Pending` con `didn't match pod topology spread constraints` | Nodos sin la label de topología, o dominio restringido por `nodeSelector` | `kubectl get nodes -L topology.kubernetes.io/zone` |
| `Pending` con `had untolerated taint` | El pool está taintado y el workload no tolera | `kubectl get nodes -o json \| jq '.items[].spec.taints'` |
| Conexión con **timeout** entre pods | `NetworkPolicy` la está descartando | `cilium policy trace` / test con `nc -zv` |
| Conexión con **refused** inmediato | El paquete llegó; falla la app o el `Service`/endpoint | `kubectl get endpointslice -n <ns>` |
| DNS falla en todo el namespace | `default-deny` sin excepción de egress a `kube-dns` | `kubectl get netpol -n <ns> -o yaml \| grep -A5 'port: 53'` |
| El `Environment` XR queda `Ready: False` para siempre | Un recurso compuesto no converge (cuota cloud, CIDR agotado, IAM) | `crossplane beta trace environment <n> -n <ns>` |
| Argo CD reporta `OutOfSync` permanente sin diff visible | Campo mutado por otro controlador (HPA sobre `replicas`) | `argocd app diff <app> --hard-refresh` |
| El drenaje de nodos se cuelga en un pod | PDB bloqueando la evicción | `kubectl get pdb -A -o wide` |
| Preview environments que nunca se borran | `applicationsSync` sin `delete`, o finalizer huérfano | `kubectl get app -n argocd -l platform.example.io/environment=preview` |
| Un CRD desaparece de un tenant al desinstalar otro | CRDs son cluster-scoped: no hay aislamiento por namespace | `kubectl get crd <name> -o yaml \| grep ownerReferences -A5` |

### 9.2 Caso 1 — Deployment silencioso por cuota agotada

El síntoma es engañoso: el `Deployment` no muestra ningún evento porque el error ocurre en el `ReplicaSet`.

```console
$ kubectl get deploy payments-worker -n payments-staging
NAME              READY   UP-TO-DATE   AVAILABLE   AGE
payments-worker   4/8     8            4           12m

$ kubectl describe deploy payments-worker -n payments-staging | tail -6
Conditions:
  Type             Status  Reason
  ----             ------  ------
  Available        True    MinimumReplicasAvailable
  ReplicaFailure   True    FailedCreate
  Progressing      True    ReplicaSetUpdated
```

`ReplicaFailure: True` es la pista. El detalle está un nivel abajo:

```console
$ kubectl describe rs -n payments-staging \
    $(kubectl get rs -n payments-staging \
        -l app.kubernetes.io/name=payments-worker \
        --sort-by='.metadata.creationTimestamp' \
        -o jsonpath='{.items[-1:].metadata.name}') | sed -n '/^Events:/,$p'
Events:
  Type     Reason        Age                    From                   Message
  ----     ------        ----                   ----                   -------
  Normal   SuccessfulCreate  12m                replicaset-controller  Created pod: payments-worker-5f9c7d8b64-2xqmv
  Warning  FailedCreate  11m (x9 over 12m)      replicaset-controller  (combined from similar events): Error creating: pods "payments-worker-5f9c7d8b64-w7trn" is forbidden: exceeded quota: compute, requested: requests.memory=2Gi, used: requests.memory=47Gi, limited: requests.memory=48Gi
```

```console
$ kubectl describe quota compute -n payments-staging | grep -E 'requests.memory|requests.cpu'
requests.cpu                                      21500m  24
requests.memory                                   47Gi    48Gi
```

**Resolución.** Tres opciones, en orden de preferencia arquitectónica:

1. Reducir el consumo real (los requests están sobredimensionados — verificar con VPA en modo `Off` para obtener recomendaciones sin mutar).
2. Subir la cuota **por la API del environment**, no con `kubectl edit`: un edit imperativo lo revierte el próximo reconcile del GitOps y el incidente vuelve a las 3 AM.
3. Si el environment legítimamente creció, es señal de que la clase de tier ya no le corresponde: promoverlo a la siguiente clase.

```console
$ kubectl patch environment payments-staging -n team-payments --type=merge \
    -p '{"spec":{"parameters":{"tier":"prod"}}}' --dry-run=server -o yaml | head -20
# Ejecutar el cambio real en Git, no acá. --dry-run=server valida el schema
# y confirma que el enum acepta el valor antes de abrir el PR.
```

### 9.3 Caso 2 — Pods `Pending` por topology spread insatisfacible

```console
$ kubectl get pods -n payments-prod -l app.kubernetes.io/name=payments-api
NAME                            READY   STATUS    RESTARTS   AGE
payments-api-6c9d84f7b5-2xkn9   1/1     Running   0          3h12m
payments-api-6c9d84f7b5-7mqvt   1/1     Running   0          3h12m
payments-api-6c9d84f7b5-h4prd   1/1     Running   0          3h12m
payments-api-6c9d84f7b5-k8zwx   1/1     Running   0          3h12m
payments-api-6c9d84f7b5-n3jfc   0/1     Pending   0          6m41s
payments-api-6c9d84f7b5-q7tlm   0/1     Pending   0          6m41s
```

```console
$ kubectl describe pod payments-api-6c9d84f7b5-n3jfc -n payments-prod | sed -n '/^Events:/,$p'
Events:
  Type     Reason            Age                    From               Message
  ----     ------            ----                   ----               -------
  Warning  FailedScheduling  6m52s                  default-scheduler  0/14 nodes are available: 3 node(s) had untolerated taint {platform.example.io/pool: batch}, 5 node(s) didn't match pod topology spread constraints, 6 Insufficient cpu. preemption: 0/14 nodes are available: 3 Preemption is not helpful for scheduling, 11 No preemption victims found for incoming pod.
  Normal   Nominated         6m50s                  karpenter          Pod should schedule on: nodeclaim/prod-general-x7k9m
  Warning  FailedScheduling  91s (x6 over 6m40s)    default-scheduler  0/15 nodes are available: 3 node(s) had untolerated taint {platform.example.io/pool: batch}, 6 node(s) didn't match pod topology spread constraints, 6 Insufficient cpu.
```

Diagnóstico de la distribución actual y de la capacidad por zona:

```console
$ kubectl get nodes -l platform.example.io/pool=general \
    -L topology.kubernetes.io/zone --no-headers | awk '{print $6}' | sort | uniq -c
      4 eu-west-1a
      4 eu-west-1b
      3 eu-west-1c

$ kubectl get pods -n payments-prod -l app.kubernetes.io/name=payments-api \
    --field-selector status.phase=Running -o json \
  | jq -r '.items[].metadata.annotations["topology.kubernetes.io/zone"]' | sort | uniq -c
      2 eu-west-1a
      2 eu-west-1b
      0
```

Sólo hay pods en dos zonas y ninguno en `eu-west-1c`. Con `maxSkew: 1` y `whenUnsatisfiable: DoNotSchedule`, el scheduler **exige** colocar el próximo pod en `eu-west-1c`; si esa zona no tiene CPU libre, el pod queda `Pending` para siempre, aunque sobre capacidad en las otras dos.

```console
$ kubectl describe node ip-10-0-31-14.ec2.internal | sed -n '/Allocated resources/,/^Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                3750m (94%)   6200m (155%)
  memory             13.5Gi (88%)  22Gi (143%)
  ephemeral-storage  4Gi (5%)      0 (0%)
```

**Resoluciones posibles, con sus trade-offs:**

| Opción | Efecto | Riesgo |
|---|---|---|
| Escalar el `NodePool` en `eu-west-1c` | Resuelve la causa real | Costo; si la zona tiene falta de capacidad en el proveedor, no siempre funciona |
| Bajar el constraint a `ScheduleAnyway` | Los pods arrancan ya | Se pierde la garantía anti-AZ-failure: es un downgrade del SLO, no un fix |
| Agregar `minDomains: 3` | Falla ruidosamente si hay menos de 3 dominios | Sigue sin resolver la falta de capacidad |
| `nodeAffinityPolicy: Honor` + revisar `nodeSelector` | Corrige el cálculo si el selector restringió el dominio | Solo aplica si el diagnóstico fue ese |

La conversión de `DoNotSchedule` a `ScheduleAnyway` bajo presión de incidente es la decisión que más silenciosamente degrada la resiliencia de una plataforma. Si se toma, tiene que quedar registrada como deuda con fecha de reversión.

### 9.4 Caso 3 — Environment que no converge

```console
$ kubectl get xenvironment search-dev-x7k2p -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
Synced	True	ReconcileSuccess
Ready	False	Creating	Unready resources: db-catalog

$ kubectl describe instance.rds.aws.upbound.io search-dev-db-catalog-6t4vx | sed -n '/^Events:/,$p'
Events:
  Type     Reason                   Age                    From                                       Message
  ----     ------                   ----                   ----                                       -------
  Warning  CannotObserveExternalResource  2m (x18 over 9m)  managed/rds.aws.upbound.io/v1beta2, kind=instance  cannot run refresh: refresh failed: creating RDS DB Instance (search-dev-db-catalog): operation error RDS: CreateDBInstance, https response error StatusCode: 400, RequestID: 4c1e..., api error InvalidParameterValue: Cannot find version 16.9 for postgres
```

El campo `version: "16.9"` pasó la validación del XRD (era un `string` libre) pero no existe en el proveedor. **La lección de diseño es del schema, no del incidente:** todo campo que el desarrollador escribe y que se traduce a un identificador del proveedor debe estar restringido por `enum` en el XRD, para que el error aparezca en el `kubectl apply` del PR — donde cuesta segundos — y no nueve minutos después en un reconcile loop.

```yaml
# Corrección en el XRD: el error se mueve del reconcile al admission.
version:
  type: string
  enum: ["14", "15", "16"]       # major versions soportadas por la plataforma
  default: "16"
```

```console
$ kubectl apply -f bad-environment.yaml
The Environment "search-dev" is invalid: spec.parameters.databases[0].version: Unsupported value: "16.9": supported values: "14", "15", "16"
```

### 9.5 Caso 4 — Drenaje de nodos bloqueado por PDB

```console
$ kubectl drain ip-10-0-21-59.ec2.internal --ignore-daemonsets --delete-emptydir-data
node/ip-10-0-21-59.ec2.internal cordoned
evicting pod payments-prod/payments-api-6c9d84f7b5-k8zwx
error when evicting pods/"payments-api-6c9d84f7b5-k8zwx" -n "payments-prod" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod payments-prod/payments-api-6c9d84f7b5-k8zwx
error when evicting pods/"payments-api-6c9d84f7b5-k8zwx" -n "payments-prod" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
^C
```

```console
$ kubectl get pdb -n payments-prod
NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
payments-api   60%             N/A               0                     198d

$ kubectl get pdb payments-api -n payments-prod -o jsonpath='{.status}' | jq
{
  "currentHealthy": 5,
  "desiredHealthy": 5,
  "disruptionsAllowed": 0,
  "expectedPods": 8,
  "observedGeneration": 3
}
```

`currentHealthy: 5` frente a `expectedPods: 8`: tres pods ya están caídos o no-Ready, así que el presupuesto está agotado y el drenaje no puede avanzar. El error no está en el PDB — el PDB está haciendo exactamente su trabajo. **La causa raíz es que hay tres pods enfermos**; el drenaje es la víctima, no el problema.

```console
$ kubectl get pods -n payments-prod -l app.kubernetes.io/name=payments-api \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'
NAME                            READY   RESTARTS   NODE
payments-api-6c9d84f7b5-2xkn9   true    0          ip-10-0-12-41.ec2.internal
payments-api-6c9d84f7b5-7mqvt   true    0          ip-10-0-12-88.ec2.internal
payments-api-6c9d84f7b5-h4prd   true    0          ip-10-0-13-17.ec2.internal
payments-api-6c9d84f7b5-k8zwx   true    0          ip-10-0-21-59.ec2.internal
payments-api-6c9d84f7b5-n3jfc   false   14         ip-10-0-21-92.ec2.internal
payments-api-6c9d84f7b5-q7tlm   false   14         ip-10-0-22-33.ec2.internal
payments-api-6c9d84f7b5-v5hqz   true    0          ip-10-0-31-14.ec2.internal
payments-api-6c9d84f7b5-w9dnk   false   13         ip-10-0-31-76.ec2.internal
```

Con `unhealthyPodEvictionPolicy: AlwaysAllow` en el PDB, esos tres pods rotos sí podrían evictarse (no aportan disponibilidad de todos modos) y el drenaje avanzaría mientras se investiga el CrashLoop en paralelo. Por eso ese campo está en el manifiesto de §5.2: **no es una optimización, es lo que evita que un problema de aplicación se convierta en un bloqueo del ciclo de mantenimiento de la infraestructura.**

---

## 10. Métricas del tema

Lo que el curriculum llama *measuring platform success* aplicado específicamente a environments:

| Métrica | Definición operativa | Objetivo típico | Cómo se obtiene |
|---|---|---|---|
| **Environment provisioning lead time** | p95 de `Ready.lastTransitionTime − metadata.creationTimestamp` | < 15 min (namespace/vCluster), < 45 min (cluster) | Métricas del controlador de composición |
| **Environment parity score** | % de entornos cuyo diff estructural contra el baseline es vacío | > 98 % | Job periódico con el `diff` del §7.6 |
| **Config drift rate** | Recursos con `OutOfSync` no explicados por HPA, por semana | < 2 / semana | `argocd_app_info{sync_status="OutOfSync"}` |
| **Preview environment TTL adherence** | % de entornos efímeros destruidos dentro del TTL declarado | > 99 % | Controlador de TTL + auditoría de Apps huérfanas |
| **Quota headroom** | % de entornos por encima del 85 % de alguna dimensión de cuota | < 10 % | `kube_resourcequota` (kube-state-metrics) |
| **Blast radius de cambio** | Nº de entornos afectados por el rollout de un cambio de plataforma | Acotado y conocido *antes* del rollout | Fleet inventory + labels de `ClusterClass` |
| **Fleet version skew** | Diferencia entre la versión de K8s más nueva y la más vieja de la flota | ≤ 1 minor | `kubectl get clusters -A -o custom-columns=...` |

---

## 11. Puntos de examen — resumen operativo

1. **Un environment no es un namespace.** Es workloads + infra + config + identidad + red + política + ciclo de vida. Que falte cualquiera de los siete es la definición de un entorno incompleto.
2. **Parity estructural ≠ parity de escala.** La escala puede variar entre entornos; política, red, identidad e instrumentación no.
3. **Elegí el nivel de aislamiento por el modelo de confianza y el requisito de compliance**, no por costumbre. Namespace = aislamiento administrativo; cluster/cuenta = aislamiento de seguridad.
4. **`CustomResourceDefinition` es cluster-scoped.** Es el límite duro que rompe el modelo "un namespace por tenant" y lo que justifica vCluster.
5. **La cuota sin `LimitRange` rompe los deploys**: si la quota restringe `limits.*`, todo pod sin `limits` explícitos es rechazado.
6. **Los errores de creación de pods aparecen en el `ReplicaSet`, no en el `Deployment`.** `ReplicaFailure: True` es la señal.
7. **El orden de bootstrap es un grafo:** landing zone → red → control plane → add-ons → runtime → app. GitOps solo puede tomar el control a partir de la capa 3.
8. **El hub (management cluster) es un SPOF de provisión, no de ejecución.** Documentá ese SLO explícitamente.
9. **En NetworkPolicy, timeout = bloqueado; connection refused = permitido pero sin escucha.** Es la primera bifurcación del árbol de diagnóstico de red.
10. **Los entornos efímeros necesitan un TTL con enforcement**, no una convención. Sin controlador de borrado, el costo crece de forma monotónica.
11. **La validación pertenece al schema.** Un `enum` en el XRD convierte un fallo de reconcile de nueve minutos en un rechazo de `kubectl apply` de un segundo.
12. **La promoción es la propagación de un digest inmutable a través de directorios de entorno.** Si un entorno re-buildea la imagen, no está promoviendo: está desplegando otro artefacto.

---

## Referencias

**Currículum y programa de certificación**
- CNCF Curriculum — CNPA (Cloud Native Platform Engineering Associate): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF Training & Certification — CNPA: https://training.linuxfoundation.org/certification/cloud-native-platform-engineering-associate-cnpa/
- CNCF Platforms White Paper (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/

**Kubernetes — aislamiento, cuotas y política**
- Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Multi-tenancy: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Runtime Class: https://kubernetes.io/docs/concepts/containers/runtime-class/

**Kubernetes — topología y disponibilidad**
- Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Well-Known Labels, Annotations and Taints: https://kubernetes.io/docs/reference/labels-annotations-taints/
- Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Options for Highly Available Topology: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/

**Infraestructura declarativa**
- Cluster API — The Cluster API Book: https://cluster-api.sigs.k8s.io/
- Cluster API — ClusterClass and Managed Topologies: https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/
- Crossplane Documentation: https://docs.crossplane.io/
- Crossplane — Composite Resource Definitions: https://docs.crossplane.io/latest/concepts/composite-resource-definitions/
- Crossplane — Composition Functions: https://docs.crossplane.io/latest/concepts/compositions/
- Karpenter — NodePools: https://karpenter.sh/docs/concepts/nodepools/

**Multi-tenancy y entornos**
- Hierarchical Namespace Controller (SIG Multi-Tenancy): https://github.com/kubernetes-sigs/hierarchical-namespaces
- vCluster Documentation: https://www.vcluster.com/docs
- Capsule (CNCF Sandbox): https://capsule.clastix.io/docs/
- gVisor: https://gvisor.dev/docs/
- Kata Containers: https://katacontainers.io/docs/

**Entrega continua y promoción**
- Argo CD — ApplicationSet: https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/
- Argo CD — ApplicationSet Generators (Matrix, Pull Request): https://argocd-applicationset.readthedocs.io/en/stable/Generators/
- Flux — GitOps Toolkit: https://fluxcd.io/flux/concepts/
- OpenGitOps Principles: https://opengitops.dev/
- Kustomize — Components: https://kubectl.docs.kubernetes.io/guides/config_management/components/

**Fundamentos de diseño**
- The Twelve-Factor App — X. Dev/prod parity: https://12factor.net/dev-prod-parity
- CNCF Platform Engineering Working Group: https://tag-app-delivery.cncf.io/wgs/platforms/