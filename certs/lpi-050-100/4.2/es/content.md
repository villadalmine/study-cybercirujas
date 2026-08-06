# CNCF / LPI 050-100 Guía de Estudio: Tema 4.2 – Modelos de Negocio de Service Providers

## 1. Problema Arquitectónico de Producción y Motivación

La ingeniería de software moderna depende en gran medida del Open Source Software (OSS) para componentes fundamentales de infraestructura, desde bases de datos relacionales (PostgreSQL) y capas de almacenamiento en caché (Redis) hasta distribuidores de mensajes (Apache Kafka) y orquestadores de contenedores (Kubernetes). Sin embargo, operar software de código abierto a escala de producción empresarial introduce un overhead operativo significativo: operaciones stateful de día 2 (day-2 operations), disaster recovery, actualizaciones sin tiempo de inactividad (zero-downtime upgrades), parches de seguridad (security patching), replicación multirregión de alta disponibilidad (HA), y estrictos Acuerdos de Nivel de Servicio (SLAs).

Esta complejidad operativa creó la demanda del mercado para los **Service Provider Business Models**. Las organizaciones transicionan desde un OSS autogestionado (self-managed) hacia el consumo de ofertas administradas de código abierto (managed open-source offerings) provistas por proveedores de la nube (IaaS/PaaS/SaaS providers) o por los propios mantenedores principales del software de código abierto.

```
+-----------------------------------------------------------------------------------+
|                            SERVICE PROVIDER ARCHITECTURE                          |
+-----------------------------------------------------------------------------------+
|  [ Tenant A ]       [ Tenant B ]       [ Tenant C ]  <-- Consumers / Customers    |
+-------+------------------+-------------------+------------------------------------+
|       | (REST / gRPC)    | (TLS Termination) | (API Gateway & Multi-Tenant Auth) |
|       v                  v                   v                                    |
| +-------------------------------------------------------------------------------+ |
| | API Gateway Layer (Traefik / Envoy Rate-Limiting & Metering Middleware)       | |
| +-------------------------------------------------------------------------------+ |
|                                       |                                           |
|       +-------------------------------+-------------------------------+           |
|       |                               |                               |           |
|       v                               v                               v           |
| +-------------------+       +-------------------+           +-------------------+ |
| | Namespace: t-alpha|       | Namespace: t-beta |           | Namespace: t-gamma| |
| | (Managed Redis)   |       | (Managed Redis)   |           | (Managed Redis)   | |
| | [Pod] [NetPolicy] |       | [Pod] [NetPolicy] |           | [Pod] [NetPolicy] | |
| +-------------------+       +-------------------+           +-------------------+ |
|       |                               |                               |           |
|       +-------------------------------+-------------------------------+           |
|                                       |                                           |
|                                       v                                           |
| +-------------------------------------------------------------------------------+ |
| | Telemetry & Billing Ingestion (Prometheus / Thanos / Vector -> Metering Engine)| |
| +-------------------------------------------------------------------------------+ |
+-----------------------------------------------------------------------------------+
```

### El Problema Arquitectónico y Económico
Para construir un modelo de negocio sostenible alrededor del código abierto sin violar las licencias de código abierto, los service providers se enfrentan a cinco desafíos críticos de producción:

1. **Multi-Tenancy & Isolation Mechanics**: Los service providers deben ejecutar miles de cargas de trabajo de inquilinos (tenant workloads) en infraestructura de cómputo compartida para maximizar los márgenes de beneficio. Esto introduce el riesgo de "noisy neighbors" (agotamiento de recursos) y brechas de seguridad (acceso a datos cross-tenant). Los proveedores deben aplicar un aislamiento estricto (hard isolation) a nivel de red (CNI eBPF policies), cómputo (cgroups v2, MicroVMs como Kata Containers/Firecracker) y almacenamiento (volume isolation).
2. **License Exploitation & Managed Services Clash**: Los Cloud Service Providers (CSPs) históricamente empaquetaron OSS con licencias permisivas (por ejemplo, Apache 2.0, BSD, MIT) en servicios alojados rentables sin contribuir al desarrollo del núcleo. Esto desencadenó cambios defensivos de licencias hacia licencias de tipo source-available como la Server Side Public License (SSPL), Business Source License (BSL/BSLA) y AGPLv3 con provisiones de Network Copyleft.
3. **Usage Metering & Consumption-Based Billing**: Los service providers requieren pipelines de telemetría deterministas e inalterables para calcular la facturación basada en el consumo real de recursos (CPU core-hours, memory-GiB-hours, network egress, storage IOPS).
4. **SLO/SLA Engineering & Error Budget Management**: Entregar SLAs comerciales (por ejemplo, 99.99% de tiempo de actividad) sobre infraestructura inherentemente propensa a fallas requiere failover automatizado, operadores de reconciliación declarativos y evaluación en tiempo real de Indicadores de Nivel de Servicio (SLI) a través de métricas de Prometheus.
5. **Open Core vs. Pure SaaS Trade-offs**: Los proveedores deben diseñar la arquitectura del software de modo que la funcionalidad central permanezca disponible gratuitamente bajo licencias aprobadas por OSI, mientras que las características empresariales propietarias (SSO/SAML, RBAC granular, encriptación en reposo con KMS, audit logging) se implementen mediante plugins empresariales desacoplados o planos de control SaaS alojados.

---

## 2. Comparaciones Técnicas y Matrices de Trade-Offs

### Tabla 2.1: Modelos de Negocio de Service Providers de Código Abierto

| Modelo | Mecánica de Ingresos | Licenciamiento del Codebase | Ventaja de Producción | Trade-off Arquitectónico / Operativo |
| :--- | :--- | :--- | :--- | :--- |
| **Pure Managed Service / SaaS** | Facturación basada en suscripción o consumo (ej., $ / core-hour) | Núcleo OSS (Apache 2.0/MIT) o Source-Available (SSPL) | Zero overhead operativo para el cliente; rápida incorporación de usuarios (user onboarding); SLAs totalmente administrados. | Alto costo de infraestructura para el proveedor; lock-in del cliente con el cloud vendor; estricta carga de cumplimiento de soberanía de datos. |
| **Open Core** | Licenciamiento por niveles: Núcleo comunitario gratuito + Módulos Enterprise de pago | Licenciamiento dual o Open Core (núcleo GPL/MIT + extensiones comerciales) | Baja barrera de entrada; una fuerte adopción por parte de desarrolladores se convierte en ventas enterprise. | Arquitectura de código compleja (feature flags/módulos enterprise enchufables); overhead de mantenimiento de sincronización entre ramas core y enterprise. |
| **Dual Licensing** | Licencia comercial para integración de código cerrado (closed-source embedding); Copyleft para uso abierto | GPL / AGPLv3 (Comunitaria) Y Licencia Comercial Propietaria | Genera ingresos a partir de proveedores propietarios que necesitan eludir las obligaciones de Copyleft. | Exige la propiedad del 100% del Contributor License Agreement (CLA); débil frente a proveedores cloud que alojan pure SaaS. |
| **Support, Services & Hosting** | Servicios profesionales, capacitación, despliegues personalizados, SLAs | 100% Open Source aprobado por OSI (Apache 2.0, MIT, GPL) | Máxima confianza en el código abierto; zero drift de código propietario; fuerte alineación con la comunidad. | Crecimiento de ingresos lineal no escalable vinculado al headcount; los proveedores cloud pueden re-vender exactamente el mismo codebase OSS. |

### Tabla 2.2: Matriz de Estrategia Arquitectónica de Aislamiento de Inquilinos

| Estrategia | Aislamiento de Cómputo | Aislamiento de Red | Aislamiento de Almacenamiento | Overhead Operativo | Eficiencia de Costos |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Shared Namespace (Soft)** | Linux cgroups v2 + namespaces | RBAC a nivel de aplicación | DB compartida / Esquema por inquilino | Mínimo | Máxima |
| **Dedicated Namespace per Tenant** | Cuotas de límite de Pod + NodeSelectors | NetworkPolicy (Default Deny All) | PVC dedicado por inquilino | Moderado | Alta |
| **Dedicated Cluster per Tenant** | Límite estricto de VM / Bare-metal | VLAN física / Peering de VPC | Array de almacenamiento dedicado | Extremadamente alto | Baja |
| **MicroVM / Sandbox Containers** | KVM / Firecracker / Kata Containers | Filtrado de endpoints del host con eBPF | PVs encriptados por MicroVM | Moderado | Moderada-Alta |

---

## 3. Manifiestos de Infraestructura y Plataforma Sintácticamente Válidos y Completos

Para demostrar una plataforma de servicios administrados multitenant en producción, los siguientes manifiestos definen:
1. Una **Custom Resource Definition (CRD)** para el aprovisionamiento de instancias gestionadas de inquilinos (`TenantInstance`).
2. Un **Envoy/Traefik IngressRoute & Middleware** para limitación de tasa (rate limiting) y enrutamiento de contexto de inquilino.
3. Una definición de **PrometheusRules** para evaluar los SLIs de inquilinos y activar alertas por incumplimiento de SLA.

### Listing 3.1: Custom Resource Definition para Instancia Gestionada Multitenant (`tenantinstance-crd.yaml`)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: tenantinstances.platform.sre.io
spec:
  group: platform.sre.io
  names:
    kind: TenantInstance
    listKind: TenantInstanceList
    plural: tenantinstances
    singular: tenantinstance
    shortNames:
      - ti
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - tenantId
                - planTier
                - engineVersion
                - capacity
              properties:
                tenantId:
                  type: string
                  pattern: '^[a-z0-9]{5,16}$'
                planTier:
                  type: string
                  enum: ["developer", "business-critical", "enterprise"]
                engineVersion:
                  type: string
                capacity:
                  type: object
                  required:
                    - replicas
                    - cpuMillicores
                    - memoryMiB
                  properties:
                    replicas:
                      type: integer
                      minimum: 1
                      maximum: 9
                    cpuMillicores:
                      type: integer
                      minimum: 250
                    memoryMiB:
                      type: integer
                      minimum: 512
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: ["Pending", "Provisioning", "Ready", "Degraded", "Terminating"]
                endpoints:
                  type: array
                  items:
                    type: string
                slaCurrentAvailability:
                  type: string
```

### Listing 3.2: Middleware de Enrutamiento Dinámico y Rate Limit Multitenant de Traefik (`traefik-tenant-routing.yaml`)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: tenant-rate-limit
  namespace: platform-gateway
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1s
    sourceCriterion:
      requestHeaderName: "X-Tenant-ID"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: tenant-header-injection
  namespace: platform-gateway
spec:
  headers:
    customRequestHeaders:
      X-Platform-Provider: "SRE-Managed-Services"
      X-Forwarded-Proto: "https"
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: tenant-service-router
  namespace: platform-gateway
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`api.serviceprovider.io`) && PathPrefix(`/v1/tenant/{tenantId:[a-z0-9-]+}`)
      kind: Rule
      middlewares:
        - name: tenant-rate-limit
          namespace: platform-gateway
        - name: tenant-header-injection
          namespace: platform-gateway
      services:
        - name: tenant-router-service
          port: 8080
  tls:
    secretName: serviceprovider-wildcard-cert
```

### Listing 3.3: Reglas de Alerta de SLA y Metering Multitenant de Prometheus (`prometheus-tenant-sla.yaml`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: tenant-sla-and-metering-rules
  namespace: platform-monitoring
  labels:
    role: alert-rules
spec:
  groups:
    - name: tenant.metering.rules
      rules:
        - record: tenant:cpu_usage_seconds:rate5m
          expr: |
            sum(rate(container_cpu_usage_seconds_total{container!="",namespace=~"tenant-.*"}[5m])) 
            by (namespace, pod)
        - record: tenant:memory_bytes:actual
          expr: |
            sum(container_memory_working_set_bytes{container!="",namespace=~"tenant-.*"}) 
            by (namespace, pod)

    - name: tenant.sla.alerting
      rules:
        - record: tenant:availability:ratio_5m
          expr: |
            sum(rate(http_requests_total{status!~"5..",namespace=~"tenant-.*"}[5m])) by (namespace)
            /
            sum(rate(http_requests_total{namespace=~"tenant-.*"}[5m])) by (namespace)

        - alert: TenantSLABreachRisk
          expr: tenant:availability:ratio_5m < 0.999
          for: 2m
          labels:
            severity: critical
            tier: service-provider-sla
          annotations:
            summary: "Tenant {{ $labels.namespace }} SLA availability dropped below 99.9%"
            description: "Current 5m availability for tenant in {{ $labels.namespace }} is {{ $value | printf \"%.4f\" }}. Error budget burning fast."
```

---

## 4. Comandos CLI Reales y Salidas de Ejecución en Terminal

### Comando 1: Aprovisionamiento de una Instancia Gestionada de Inquilino a través de la API de Kubernetes
Ejecutá `kubectl apply` para enviar un manifiesto `TenantInstance` válido al plano de control (control plane).

```bash
$ cat <<EOF | kubectl apply -f -
apiVersion: platform.sre.io/v1alpha1
kind: TenantInstance
metadata:
  name: tenant-acme-corp
  namespace: tenant-acme-corp
spec:
  tenantId: "acmecorp99"
  planTier: "business-critical"
  engineVersion: "7.2.4"
  capacity:
    replicas: 3
    cpuMillicores: 2000
    memoryMiB: 4096
EOF
```

#### Salida de Terminal Esperada:
```text
namespace/tenant-acme-corp created
tenantinstance.platform.sre.io/tenant-acme-corp created
```

---

### Comando 2: Verificación del Estado y Condición del Custom Resource de la Instancia de Inquilino
Inspeccioná el estado de reconciliación impulsado por el operador de la plataforma.

```bash
$ kubectl get tenantinstance tenant-acme-corp -n tenant-acme-corp -o jsonpath='{range .status}{"Phase: "}{.phase}{"\nEndpoints: "}{.endpoints}{"\nSLA Status: "}{.slaCurrentAvailability}{"\n"}{end}'
```

#### Salida de Terminal Esperada:
```text
Phase: Ready
Endpoints: ["acmecorp99-node-0.serviceprovider.internal:6379","acmecorp99-node-1.serviceprovider.internal:6379","acmecorp99-node-2.serviceprovider.internal:6379"]
SLA Status: 99.995%
```

---

### Comando 3: Consulta de Telemetría de Usage Metering a través de la API de Prometheus (PromQL)
Obtené métricas de uso de núcleos de CPU en tiempo real por namespace de inquilino para el cálculo de facturación.

```bash
$ curl -s -G 'http://prometheus.platform-monitoring.svc.cluster.local:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="tenant-acme-corp"}[1h])) by (namespace)' | jq .
```

#### Salida de Terminal Esperada:
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "namespace": "tenant-acme-corp"
        },
        "value": [
          1723000000.123,
          "4.81249102"
        ]
      }
    ]
  }
}
```

---

### Comando 4: Simulación de Rate-Limiting y Validación de Inquilinos a través de cURL
Validá que el middleware de rate-limiting del service provider Traefik bloquee peticiones excesivas de inquilinos (HTTP 429 Too Many Requests).

```bash
$ for i in {1..5}; do curl -s -o /dev/null -w "%{http_code}\n" -H "X-Tenant-ID: acmecorp99" https://api.serviceprovider.io/v1/tenant/acmecorp99/health; done
```

#### Salida de Terminal Esperada:
```text
200
200
200
200
429
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas

### Flujo de Trabajo de Diagnóstico: Resolución de Incumplimientos de SLA y Contención de Recursos de Inquilinos

```
+-----------------------------------------------------------------------------------+
|                           SLA BREACH DIAGNOSTIC FLOW                              |
+-----------------------------------------------------------------------------------+
| 1. Alert Triggers: TenantSLABreachRisk (Availability < 99.9%)                     |
|                                       |                                           |
|                                       v                                           |
| 2. Check Platform Operator Logs -> Is instance reconciling or failing healthcheck?|
|                                       |                                           |
|                  +--------------------+--------------------+                      |
|                  |                                         |                      |
|                  v                                         v                      |
|      [ Status: Reconciliation Error ]         [ Status: Operator Healthy ]        |
|                  |                                         |                      |
|                  v                                         v                      |
|      Inspect CRD Events & K8s Events          3. Check Resource Contention        |
|      `kubectl describe ti <name>`             `kubectl top pod -n <tenant-ns>`    |
|                                                            |                      |
|                                                            v                      |
|                                               4. Evaluate cgroups CPU Throttling  |
|                                               Inspect container_cpu_cfs_throttled |
|                                                            |                      |
|                                                            v                      |
|                                               5. Check Network Isolation Policy   |
|                                               `cilium monitor --to-namespace`     |
+-----------------------------------------------------------------------------------+
```

#### Paso 1: Aislar al Inquilino Afectado e Inspeccionar el Throttling de Recursos
Cuando un inquilino reporta degradación de latencia violando su SLA, verificá si el Pod está siendo limitado (throttled) por el kernel cgroups CFS (Completely Fair Scheduler).

```bash
$ kubectl exec -it -n platform-monitoring prometheus-k8s-0 -- promtool query instant http://localhost:9090 \
  'rate(container_cpu_cfs_throttled_periods_total{namespace="tenant-acme-corp"}[5m]) / rate(container_cpu_cfs_periods_total{namespace="tenant-acme-corp"}[5m]) * 100'
```
*Umbral de Diagnóstico*: Si la proporción del período de throttling supera el **25%**, la carga de trabajo del inquilino ha alcanzado su límite estricto de CPU de su nivel de facturación (billing tier).

#### Paso 2: Validar la Aplicación del Aislamiento mediante Network Policy
Asegurá que el tráfico de red cross-tenant esté strictly denegado verificando las NetworkPolicies del CNI Cilium / Calico.

```bash
$ kubectl describe networkpolicy default-deny-cross-tenant -n tenant-acme-corp
```
Buscá bloques explícitos de aislamiento `Ingress` y `Egress`:
```text
Spec:
  PodSelector: <none> (Matches all pods in namespace)
  PolicyTypes:
    Ingress
    Egress
  Ingress:
    - From:
        - NamespaceSelector:
            MatchLabels:
              kubernetes.io/metadata.name: platform-gateway
  Egress:
    - To:
        - NamespaceSelector:
            MatchLabels:
              kubernetes.io/metadata.name: platform-monitoring
```

#### Paso 3: Auditar la Licencia del Inquilino y las Atribuciones de Acceso a Funcionalidades (Feature Access Entitlements)
Cuando un inquilino solicita una característica enterprise (por ejemplo, encriptación KMS en reposo) y recibe `403 Forbidden`, verificá la propagación del feature-gate en el plano de control empresarial:

```bash
$ kubectl get configmap tenant-entitlements -n tenant-acme-corp -o jsonpath='{.data.entitlements\.json}' | jq .
```
Salida esperada que muestra las atribuciones activas del plan:
```json
{
  "tenantId": "acmecorp99",
  "plan": "business-critical",
  "features": {
    "multiRegionReplication": true,
    "customKMS": false,
    "auditLogStreaming": true
  }
}
```

---

## 6. Referencias

- Visión General de Open Source Essentials de Linux Professional Institute (LPI): https://www.lpi.org/our-certifications/open-source-essentials-overview/
- Objetivos del Examen 050-100 en la Wiki de LPI: https://wiki.lpi.org
- Licencias y Estándares de Open Source Initiative (OSI): https://opensource.org/licenses
- Preguntas Frecuentes (FAQ) de Server Side Public License (SSPL): https://www.mongodb.com/licensing/server-side-public-license/faq
- Benchmarks de Multi-Tenancy de Cloud Native Computing Foundation (CNCF): https://www.cncf.io
- Documentación de Reglas de Alerta y Grabación de Prometheus: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Documentación de Middleware e IngressRoute de Traefik: https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/