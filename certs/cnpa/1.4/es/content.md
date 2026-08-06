# Tema 1.4 — Platform Architecture and Core Capabilities

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) · **Peso:** 7.2 % del examen
> **Dominio:** Platform Engineering Core Fundamentals

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El problema: ticket-ops y carga cognitiva

En una organización sin plataforma, cada equipo de producto que necesita infraestructura (un namespace, una base de datos, un pipeline, un certificado TLS) sigue uno de dos caminos, y ambos fallan a escala:

1. **Ticket-driven operations.** El equipo abre un ticket a operaciones y espera. El *lead time* de un entorno pasa de minutos a días o semanas; el equipo de operaciones se convierte en un cuello de botella lineal (cada solicitud consume tiempo humano) y en un punto único de conocimiento. El resultado medible es el deterioro de las métricas DORA: *deployment frequency* baja y *lead time for changes* sube.

2. **Do-It-Yourself descentralizado.** Cada equipo se autoprovisiona con permisos amplios. El costo aparece más tarde: *snowflake infrastructure* (cada entorno es artesanal e irreproducible), *drift* de configuración, superficie de seguridad sin control (Secrets en texto plano, RBAC permisivo), y una **carga cognitiva** enorme sobre desarrolladores que ahora deben dominar Kubernetes, redes, IAM, observabilidad y CI/CD además de su dominio de negocio.

El **CNCF Platforms White Paper** formaliza la respuesta: una **plataforma interna** es una capa curada de *capabilities* — cómputo, datos, mensajería, identidad, observabilidad, delivery — expuesta detrás de **interfaces consistentes y self-service**, construida y operada como un **producto** cuyos clientes son los equipos internos.

Los atributos que el white paper exige de una buena plataforma son criterio de examen:

- **Platform as a Product:** roadmap, feedback de usuarios, prioridades guiadas por necesidades reales, no por tecnología disponible.
- **User experience consistente:** las mismas capabilities se consumen igual desde portal, CLI o API.
- **Self-service:** el usuario solicita y recibe sin intervención humana del equipo de plataforma.
- **Reduced cognitive load:** la plataforma oculta la implementación (qué cloud, qué operator, qué versión); el usuario declara intención.
- **Opcional y componible:** los equipos pueden adoptar capabilities individualmente; una plataforma obligatoria y monolítica genera *shadow platforms*.
- **Secure by default:** guardrails (policies, quotas, network policies) integrados en el *golden path*, no añadidos después.

### 1.2 El problema arquitectónico

El desafío técnico central del tema 1.4 es: **¿cómo se estructura una plataforma para exponer decenas de capabilities heterogéneas (cloud APIs, operators in-cluster, SaaS externos) detrás de un contrato estable y self-service, sin que la plataforma misma se convierta en un monolito frágil?**

La respuesta cloud native es una arquitectura en capas con un **platform control plane** declarativo en el centro:

```
┌─────────────────────────────────────────────────────────────────┐
│  PLATFORM USERS: app developers, data engineers, SREs de producto│
└──────────────────────────────┬──────────────────────────────────┘
                               │ consumen vía
┌──────────────────────────────▼──────────────────────────────────┐
│  PLATFORM INTERFACES                                             │
│  Portal (Backstage) · CLI · API declarativa (CRDs) · GitOps PRs  │
│  Golden path templates · Docs                                    │
└──────────────────────────────┬──────────────────────────────────┘
                               │ traducen intención a estado deseado
┌──────────────────────────────▼──────────────────────────────────┐
│  PLATFORM CONTROL PLANE (reconciliation loops, KRM)              │
│  Crossplane / Kratix / custom operators · Policy (Kyverno/OPA)   │
│  Orquesta y hace enforcement; NO ejecuta workloads               │
└──────────────────────────────┬──────────────────────────────────┘
                               │ provisiona y compone
┌──────────────────────────────▼──────────────────────────────────┐
│  CAPABILITY PROVIDERS                                            │
│  Clusters de workload (Cluster API) · Cloud managed services     │
│  Operators (CloudNativePG, Strimzi) · SaaS (observability, IdP)  │
└─────────────────────────────────────────────────────────────────┘
```

Principios de diseño que el examen evalúa:

- **La API es el producto; el portal es una vista.** Portal, CLI y GitOps deben ser *frontends* del mismo contrato (habitualmente CRDs sobre el Kubernetes Resource Model). Si el portal hace cosas que la API no puede, la plataforma no es automatizable y la UI se vuelve la fuente de verdad — un antipatrón.
- **Control plane ≠ data plane.** El control plane mantiene estado deseado y reconcilia; los workloads corren en data planes (clusters de aplicación) separados. Esto acota el *blast radius*: la caída del control plane degrada el provisioning, no las aplicaciones en ejecución.
- **Reconciliación continua sobre ejecución puntual.** Un modelo declarativo con *reconciliation loop* (nivel-triggered) detecta y corrige drift permanentemente; un modelo imperativo (script, pipeline de Terraform disparado a mano) solo garantiza el estado en el momento del apply.
- **Composición.** Cada capability es una pieza intercambiable detrás de la abstracción: se puede migrar de RDS a CloudNativePG cambiando la *Composition*, sin tocar el contrato que consumen los equipos.

### 1.3 Catálogo de core capabilities (CNCF Platforms White Paper)

El white paper define el catálogo canónico de capabilities que una plataforma ofrece. Memorizar el mapeo capability → proyectos CNCF representativos:

| Capability | Qué provee | Proyectos CNCF/OSS típicos |
|---|---|---|
| **Web portals** | Observar y provisionar productos y capabilities | Backstage |
| **APIs de provisioning** | Provisionar automáticamente, base de la automatización | Kubernetes API, Crossplane, Operator Framework, Helm |
| **Golden path templates** | Plantillas y docs para crear servicios con buenas prácticas integradas | Backstage Software Templates, Devfile, ArtifactHub |
| **CI / build automation** | Compilar, testear y empaquetar servicios | Tekton, Argo Workflows, Buildpacks |
| **CD / delivery automation** | Desplegar y verificar servicios | Argo CD, Flux, Keptn |
| **Development environments** | Entornos de desarrollo reproducibles | Devfile, Telepresence, Nocalhost |
| **Observability** | Métricas, logs, traces, events; dashboards y alerting | Prometheus, OpenTelemetry, Jaeger, Fluentd, Thanos |
| **Infrastructure services** | Runtimes de cómputo, redes programables, storage | Kubernetes, Knative, KubeVirt, Cilium, Istio, Linkerd, Rook, Longhorn |
| **Data services** | Bases de datos, caches | Vitess, TiKV, etcd |
| **Messaging / eventing** | Brokers, queues, event fabrics | NATS, Strimzi (Kafka), CloudEvents, Knative Eventing |
| **Identity & secrets** | Identidad de servicios y usuarios, certificados, claves, SSO | SPIFFE/SPIRE, cert-manager, Keycloak, External Secrets Operator |
| **Artifact storage** | Registries de imágenes y paquetes, repos de código | Harbor, Distribution, ORAS |
| **Security services** | Análisis estático y runtime, policy enforcement | OPA/Gatekeeper, Kyverno, Falco, in-toto |

### 1.4 Madurez de la plataforma (Platform Engineering Maturity Model)

El **CNCF Platform Engineering Maturity Model** (TAG App Delivery) evalúa cinco aspectos en cuatro niveles. En el examen se pregunta tanto la estructura como el criterio de progresión:

| Aspecto | 1 · Provisional | 2 · Operational | 3 · Scalable | 4 · Optimizing |
|---|---|---|---|---|
| **Investment** | Esfuerzo voluntario, tiempo robado a otros roles | Equipo dedicado | La plataforma se financia como producto | Ecosistema habilitado; los equipos contribuyen capabilities |
| **Adoption** | Errática, por afinidad | Empujada desde arriba (extrinsic push) | Los equipos la eligen por valor (intrinsic pull) | Participativa; los usuarios co-diseñan |
| **Interfaces** | Procesos manuales a medida | Tooling estándar por capability | Self-service consistente | Servicios integrados y transparentes en el flujo de trabajo |
| **Operations** | Reactiva, a pedido | Seguimiento centralizado | Habilitación central, operación delegada | Servicios gestionados con SLOs propios |
| **Measurement** | Ad hoc, anecdótica | Recolección consistente de métricas | Insights accionables (funnels de adopción, time-to-environment) | Mejora continua cuantitativa y cualitativa |

Métricas de producto que un Platform Architect instrumenta desde el nivel 2: **time-to-first-deployment**, **time-to-environment** (del claim al `Ready=True`), tasa de adopción por capability, MTTR del control plane, y las cuatro métricas DORA de los equipos consumidores como *outcome* de la plataforma.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Interfaces de la plataforma

| Interfaz | Audiencia | Fricción de entrada | Auditabilidad | Automatizable | Riesgo principal |
|---|---|---|---|---|---|
| **Portal (Backstage)** | Devs con poca afinidad infra | Muy baja | Media (depende de que el portal escriba vía API/Git) | No es el canal de automatización | Portal como fuente de verdad divergente de la API |
| **API declarativa (CRDs)** | Equipos maduros, otras máquinas | Media | Alta (todo es un recurso versionable) | Sí, nativamente | Requiere diseño de API cuidadoso (versionado, defaults) |
| **GitOps PR sobre repo de claims** | Todos, con revisión | Baja-media | Máxima (historia Git + code review) | Sí | Latencia del ciclo PR; requiere estructura de repos clara |
| **CLI corporativa** | Power users, scripts | Baja | Media | Sí | Duplicar lógica que debería vivir en la API |

**Decisión de arquitectura:** las cuatro son vistas del mismo contrato. El flujo de producción recomendado es portal/CLI → commit en repo GitOps → Argo CD/Flux aplica el claim → control plane reconcilia. Así el portal nunca muta el cluster directamente y toda solicitud queda auditada en Git.

### 2.2 Motor del platform control plane

| Criterio | **Crossplane** | **Terraform / OpenTofu + CI** | **Kratix** | **Operators custom (Kubebuilder)** | **Helm + GitOps solo** |
|---|---|---|---|---|---|
| Modelo | CRDs + Compositions, reconciliación continua | HCL, ejecución puntual (plan/apply) | Promises: contrato + pipeline de fulfillment multi-cluster | Código Go, control total | Templates renderizados, sin abstracción de API |
| Detección de drift | Continua, corrección automática | Solo al siguiente `plan`; corrección manual | Continua (delega en workloads declarativos) | Continua (lo que se programe) | Continua sobre lo desplegado, sin componer servicios externos |
| Estado | El propio cluster (etcd); sin state file | State file (backend remoto, locking, riesgo de corrupción) | Cluster | Cluster | Cluster |
| API self-service para equipos | Nativa (claims namespaced) | No nativa (requiere wrapper: pipeline, portal) | Nativa (Promise → CRD) | Nativa | No |
| Cobertura de providers | Providers para clouds principales + `provider-kubernetes`/`provider-helm` | Máxima (todo el registry de Terraform) | La que implemente el pipeline de la Promise | La que se programe | Solo recursos K8s |
| Curva de aprendizaje | Media (XRD/Composition/functions) | Baja (HCL muy difundido) | Media | Alta (Go + controller-runtime) | Baja |
| Cuándo elegirlo | API de plataforma sobre KRM, multi-cloud, drift correction | Provisioning de foundation (VPCs, clusters base), equipos con inversión previa en HCL | Plataforma multi-cluster con marketplace de Promises | Capability con lógica de dominio compleja (failover, backups) | Solo delivery de apps, no plataforma |

**Patrón de producción frecuente:** Terraform/OpenTofu para la *foundation* (cuentas, redes, el cluster del control plane) y Crossplane encima como API self-service continua. No son excluyentes; el examen espera que se sepa combinar.

### 2.3 Modelo de tenancy del data plane

| Criterio | **Namespace-as-a-Service** | **vcluster (virtual clusters)** | **Cluster-as-a-Service (Cluster API)** |
|---|---|---|---|
| Aislamiento | Lógico: RBAC, NetworkPolicy, quotas; kernel y control plane compartidos | Control plane propio (API server virtual); nodos compartidos | Total: control plane y nodos dedicados |
| CRDs por tenant | Conflictivos (cluster-scoped, versión única global) | Sí, cada vcluster instala los suyos | Sí |
| Costo por tenant | Mínimo | Bajo (pods del control plane virtual) | Alto (nodos + control plane reales) |
| Overhead operativo del platform team | Bajo (1 cluster grande) | Medio | Alto sin automatización; viable solo con Cluster API + GitOps |
| Blast radius | Un upgrade o incidente afecta a todos | Medio | Contenido por cluster |
| Caso de uso | Equipos internos confiables, workloads estándar | Equipos que necesitan CRDs/versiones propias; entornos de prueba de operators | Compliance estricto, tenants externos, aislamiento regulatorio |

### 2.4 Topología del control plane

| Criterio | Control plane **centralizado** (un management cluster) | Control planes **distribuidos** (por región/BU) |
|---|---|---|
| Consistencia de la API | Máxima: un solo catálogo | Requiere sincronizar XRDs/Promises (GitOps del propio control plane) |
| SPOF / blast radius | El provisioning global depende de un cluster | Fallos regionales acotados |
| Escala | Límite del API server/etcd con decenas de miles de managed resources; se mitiga shardeando providers | Escala horizontal natural |
| Operación | Simple | Federación, versionado y rollout por oleadas |

Regla práctica: empezar centralizado; distribuir cuando el número de managed resources o los requisitos de residencia de datos lo exijan. El control plane en sí se gestiona con GitOps — *la plataforma también se despliega como código*.

---

## 3. Implementación completa: una capability self-service con Crossplane

Objetivo: exponer la capability **"AppEnvironment"** — un namespace con quotas, guardrails de red y labels de ownership — como API self-service. El equipo consumidor declara *intención* (team, environment, límites); la plataforma materializa la implementación. Es el patrón exacto de "APIs for automatically provisioning" del white paper, aplicable idéntico a bases de datos o buckets cambiando la Composition.

### 3.1 Instalación del control plane y del provider

`platform/00-provider.yaml` — provider, runtime config y RBAC:

```yaml
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: provider-kubernetes
spec:
  serviceAccountTemplate:
    metadata:
      name: provider-kubernetes
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.15.0
  runtimeConfigRef:
    name: provider-kubernetes
---
# ADVERTENCIA: cluster-admin solo para laboratorio. En produccion se define un
# ClusterRole minimo (namespaces, resourcequotas, networkpolicies).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: provider-kubernetes-admin
subjects:
  - kind: ServiceAccount
    name: provider-kubernetes
    namespace: crossplane-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: in-cluster
spec:
  credentials:
    source: InjectedIdentity
```

`platform/01-functions.yaml` — composition functions (el modo `Pipeline` es el estándar actual; el modo `Resources` embebido está deprecado):

```yaml
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.7.0
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.4.0
```

### 3.2 El contrato: CompositeResourceDefinition (XRD)

`platform/10-xrd.yaml` — define la API pública. El schema OpenAPI **es** el contrato con los equipos: defaults, enums y patterns son los guardrails de entrada.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xappenvironments.platform.acme.io
spec:
  group: platform.acme.io
  names:
    kind: XAppEnvironment
    plural: xappenvironments
  claimNames:
    kind: AppEnvironment
    plural: appenvironments
  defaultCompositionRef:
    name: appenvironment-kubernetes
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
                    team:
                      type: string
                      description: Equipo propietario; prefijo del namespace resultante.
                      pattern: '^[a-z0-9]([a-z0-9-]{0,20}[a-z0-9])?$'
                    environment:
                      type: string
                      description: Tier del entorno.
                      enum:
                        - dev
                        - staging
                        - prod
                    cpuLimit:
                      type: string
                      description: Techo de CPU del ResourceQuota.
                      default: "4"
                    memoryLimit:
                      type: string
                      description: Techo de memoria del ResourceQuota.
                      default: 8Gi
                  required:
                    - team
                    - environment
              required:
                - parameters
```

### 3.3 La implementación: Composition

`platform/20-composition.yaml` — materializa el contrato como Namespace + ResourceQuota + NetworkPolicy *default-deny*. Los equipos nunca ven este archivo: es intercambiable sin romperlos.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: appenvironment-kubernetes
  labels:
    platform.acme.io/provider: kubernetes
spec:
  compositeTypeRef:
    apiVersion: platform.acme.io/v1alpha1
    kind: XAppEnvironment
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: namespace
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                providerConfigRef:
                  name: in-cluster
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: Namespace
                    metadata:
                      labels:
                        platform.acme.io/managed: "true"
            patches:
              - type: CombineFromComposite
                combine:
                  variables:
                    - fromFieldPath: spec.parameters.team
                    - fromFieldPath: spec.parameters.environment
                  strategy: string
                  string:
                    fmt: "%s-%s"
                toFieldPath: spec.forProvider.manifest.metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.team
                toFieldPath: spec.forProvider.manifest.metadata.labels[platform.acme.io/team]
          - name: quota
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                providerConfigRef:
                  name: in-cluster
                forProvider:
                  manifest:
                    apiVersion: v1
                    kind: ResourceQuota
                    metadata:
                      name: platform-quota
                    spec:
                      hard:
                        limits.cpu: "4"
                        limits.memory: 8Gi
            patches:
              - type: CombineFromComposite
                combine:
                  variables:
                    - fromFieldPath: spec.parameters.team
                    - fromFieldPath: spec.parameters.environment
                  strategy: string
                  string:
                    fmt: "%s-%s"
                toFieldPath: spec.forProvider.manifest.metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.cpuLimit
                toFieldPath: spec.forProvider.manifest.spec.hard[limits.cpu]
              - type: FromCompositeFieldPath
                fromFieldPath: spec.parameters.memoryLimit
                toFieldPath: spec.forProvider.manifest.spec.hard[limits.memory]
          - name: default-deny-ingress
            base:
              apiVersion: kubernetes.crossplane.io/v1alpha2
              kind: Object
              spec:
                providerConfigRef:
                  name: in-cluster
                forProvider:
                  manifest:
                    apiVersion: networking.k8s.io/v1
                    kind: NetworkPolicy
                    metadata:
                      name: default-deny-ingress
                    spec:
                      podSelector: {}
                      policyTypes:
                        - Ingress
            patches:
              - type: CombineFromComposite
                combine:
                  variables:
                    - fromFieldPath: spec.parameters.team
                    - fromFieldPath: spec.parameters.environment
                  strategy: string
                  string:
                    fmt: "%s-%s"
                toFieldPath: spec.forProvider.manifest.metadata.namespace
    - step: auto-ready
      functionRef:
        name: function-auto-ready
```

### 3.4 El consumo: Claim del equipo

`teams/checkout/appenv-dev.yaml` — esto es **todo** lo que el equipo escribe (idealmente vía PR a un repo GitOps o desde el portal). Nótese la asimetría: 10 líneas de intención contra ~120 de implementación — esa diferencia *es* la reducción de carga cognitiva.

```yaml
apiVersion: platform.acme.io/v1alpha1
kind: AppEnvironment
metadata:
  name: checkout-dev
  namespace: platform-requests
spec:
  parameters:
    team: checkout
    environment: dev
    cpuLimit: "8"
    memoryLimit: 16Gi
```

---

## 4. Comandos CLI y salidas esperadas

Instalación del control plane:

```
$ helm repo add crossplane-stable https://charts.crossplane.io/stable
$ helm install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait

$ kubectl get pods -n crossplane-system
NAME                                       READY   STATUS    RESTARTS   AGE
crossplane-6b5b8f9d4c-x7klp                1/1     Running   0          96s
crossplane-rbac-manager-7f9d6c58b4-qwvnd   1/1     Running   0          96s
```

Despliegue de provider, functions y API de plataforma:

```
$ kubectl apply -f platform/
deploymentruntimeconfig.pkg.crossplane.io/provider-kubernetes created
provider.pkg.crossplane.io/provider-kubernetes created
clusterrolebinding.rbac.authorization.k8s.io/provider-kubernetes-admin created
providerconfig.kubernetes.crossplane.io/in-cluster created
function.pkg.crossplane.io/function-patch-and-transform created
function.pkg.crossplane.io/function-auto-ready created
compositeresourcedefinition.apiextensions.crossplane.io/xappenvironments.platform.acme.io created
composition.apiextensions.crossplane.io/appenvironment-kubernetes created

$ kubectl get providers,functions
NAME                                             INSTALLED   HEALTHY   PACKAGE                                                             AGE
provider.pkg.crossplane.io/provider-kubernetes   True        True      xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v0.15.0   2m10s

NAME                                                      INSTALLED   HEALTHY   PACKAGE                                                                       AGE
function.pkg.crossplane.io/function-patch-and-transform   True        True      xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.7.0    2m10s
function.pkg.crossplane.io/function-auto-ready            True        True      xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.4.0             2m10s
```

Verificación de que la API de plataforma quedó publicada en el API server — `ESTABLISHED` (el CRD del XR existe) y `OFFERED` (el claim está disponible para namespaces):

```
$ kubectl get xrd
NAME                                ESTABLISHED   OFFERED   AGE
xappenvironments.platform.acme.io   True          True      75s

$ kubectl api-resources --api-group=platform.acme.io
NAME                SHORTNAMES   APIVERSION                  NAMESPACED   KIND
appenvironments                  platform.acme.io/v1alpha1   true         AppEnvironment
xappenvironments                 platform.acme.io/v1alpha1   false        XAppEnvironment
```

Ciclo self-service completo, del claim al entorno listo:

```
$ kubectl create namespace platform-requests
namespace/platform-requests created

$ kubectl apply -f teams/checkout/appenv-dev.yaml
appenvironment.platform.acme.io/checkout-dev created

$ kubectl get appenvironment -n platform-requests
NAME           SYNCED   READY   CONNECTION-SECRET   AGE
checkout-dev   True     True                        48s

$ crossplane beta trace appenvironment checkout-dev -n platform-requests
NAME                                          SYNCED   READY   STATUS
AppEnvironment/checkout-dev (platform-requests)
                                              True     True    Available
└─ XAppEnvironment/checkout-dev-7k2vq         True     True    Available
   ├─ Object/checkout-dev-7k2vq-8dk2m         True     True    Available
   ├─ Object/checkout-dev-7k2vq-mw9xz         True     True    Available
   └─ Object/checkout-dev-7k2vq-t4bqh         True     True    Available

$ kubectl get namespace checkout-dev --show-labels
NAME           STATUS   AGE   LABELS
checkout-dev   Active   60s   kubernetes.io/metadata.name=checkout-dev,platform.acme.io/managed=true,platform.acme.io/team=checkout

$ kubectl get resourcequota,networkpolicy -n checkout-dev
NAME                           AGE   REQUEST   LIMIT
resourcequota/platform-quota   62s             limits.cpu: 0/8, limits.memory: 0/16Gi

NAME                                                 POD-SELECTOR   AGE
networkpolicy.networking.k8s.io/default-deny-ingress   <none>       62s
```

Prueba de reconciliación continua (drift correction) — la propiedad que distingue un control plane de un script:

```
$ kubectl delete resourcequota platform-quota -n checkout-dev
resourcequota "platform-quota" deleted

$ sleep 60 && kubectl get resourcequota -n checkout-dev
NAME             AGE   REQUEST   LIMIT
platform-quota   22s             limits.cpu: 0/8, limits.memory: 0/16Gi
```

El quota reaparece sin intervención: el reconciliation loop detectó la divergencia entre estado deseado y observado y la corrigió.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Metodología

El diagnóstico sigue la cadena de propagación del estado, **de arriba hacia abajo**: Claim → XR (composite) → composed resources → provider → recurso real. `crossplane beta trace` recorre esa cadena automáticamente; `kubectl describe` en el primer eslabón no-Ready muestra la causa en `Status.Conditions` y Events.

```
$ kubectl describe appenvironment checkout-dev -n platform-requests | sed -n '/Conditions/,/Events/p'
```

### 5.2 Tabla de fallas típicas

| Síntoma | Causa probable | Diagnóstico | Corrección |
|---|---|---|---|
| `kubectl get providers` → `HEALTHY: False` | Imagen del package inaccesible o versión incompatible con el core | `kubectl describe provider provider-kubernetes` → evento `cannot unpack package` | Corregir referencia/registry; verificar egress del cluster |
| Claim con `SYNCED: False` y evento `cannot select composition` | Ninguna Composition matchea (`compositionSelector` sin correspondencia, o no hay default) | `kubectl describe` del claim; `kubectl get compositions --show-labels` | Alinear labels o definir `defaultCompositionRef` en la XRD |
| Claim `SYNCED: True`, `READY: False` indefinido | Un composed resource no llega a Ready | `crossplane beta trace` → identificar el `Object` en falla → `kubectl describe object <name>` | Según la causa aguas abajo (habitualmente RBAC o manifest inválido) |
| `Object` con `cannot create object: ... is forbidden` | El ServiceAccount del provider no tiene RBAC suficiente | `kubectl logs -n crossplane-system deploy/provider-kubernetes-<hash>` | Ampliar el ClusterRole del provider (mínimo necesario) |
| Evento `cannot run pipeline step: no such function` o `FunctionRef not found` | La Function referenciada en la Composition no está instalada o no está healthy | `kubectl get functions`; `kubectl describe composition` | Instalar la Function; verificar coincidencia exacta de `functionRef.name` |
| XRD con `ESTABLISHED: False` | Schema OpenAPI inválido o conflicto de nombres de CRD | `kubectl describe xrd xappenvironments.platform.acme.io` | Corregir el schema; revisar colisiones de `group/names` |
| Claim rechazado en admission: `unknown field` / `Invalid value` | El usuario envió parámetros fuera del contrato | El error del `kubectl apply` es autodescriptivo | Es el guardrail funcionando: corregir el claim, no el schema |
| Recursos huérfanos tras borrar el claim | Finalizers eliminados a mano o deletion policy `Orphan` | `kubectl get objects`; revisar `deletionPolicy`/`managementPolicies` | Limpiar manualmente; restablecer la policy por defecto (`Delete`) |
| Reconciliación lenta con miles de recursos | Saturación del provider (rate limits, workers) | Métricas Prometheus del core (`crossplane_managed_resource_*`), CPU del pod del provider | Ajustar `--max-reconcile-rate`, shardear providers, escalar verticalmente |

### 5.3 Ejemplo de diagnóstico real: RBAC insuficiente

```
$ kubectl get appenvironment -n platform-requests
NAME           SYNCED   READY   CONNECTION-SECRET   AGE
checkout-dev   True     False                       6m

$ crossplane beta trace appenvironment checkout-dev -n platform-requests
NAME                                          SYNCED   READY   STATUS
AppEnvironment/checkout-dev (platform-requests)
                                              True     False   Waiting: ...resource claim is waiting for composite resource to become Ready
└─ XAppEnvironment/checkout-dev-7k2vq         True     False   Creating: Unready resources: namespace
   └─ Object/checkout-dev-7k2vq-8dk2m         False    -       ReconcileError: cannot create object: namespaces is forbidden:
                                                               User "system:serviceaccount:crossplane-system:provider-kubernetes"
                                                               cannot create resource "namespaces" in API group "" at the cluster scope
```

La cadena señala exactamente el eslabón (el `Object` del namespace) y la causa (RBAC del ServiceAccount del provider). Tras aplicar el ClusterRoleBinding, la reconciliación converge sola en el siguiente ciclo — no hay "re-run del pipeline" porque no hay pipeline: hay estado deseado pendiente.

### 5.4 Verificación operativa continua del control plane

- **Health**: `kubectl get providers,functions,xrd` con todo `True` es el *smoke test* mínimo post-despliegue; automatizarlo en el pipeline GitOps de la plataforma.
- **Métricas**: el core de Crossplane expone Prometheus metrics; alertar sobre backlog y errores de reconciliación sostenidos, y sobre la latencia claim→Ready (el *time-to-environment* que se promete a los equipos como SLO de plataforma).
- **Auditoría**: todo claim es un recurso Kubernetes → queda en el audit log del API server y, con el flujo GitOps, en la historia del repo. La trazabilidad de "quién pidió qué entorno y cuándo" es un requisito de compliance que esta arquitectura resuelve de forma nativa.

---

## 6. Referencias

- CNCF Platforms White Paper (TAG App Delivery): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- Curriculum oficial CNPA: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Crossplane — documentación oficial: https://docs.crossplane.io/
- Crossplane — Compositions y Composition Functions: https://docs.crossplane.io/latest/concepts/compositions/
- provider-kubernetes (crossplane-contrib): https://github.com/crossplane-contrib/provider-kubernetes
- Backstage — documentación oficial: https://backstage.io/docs/
- Kratix — documentación oficial: https://docs.kratix.io/
- Cluster API: https://cluster-api.sigs.k8s.io/
- vcluster: https://www.vcluster.com/docs
- Team Topologies (fundamento del platform team como *enabling team*): https://teamtopologies.com/
- DORA — métricas de delivery: https://dora.dev/