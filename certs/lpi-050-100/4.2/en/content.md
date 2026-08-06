# CNCF / LPI 050-100 Study Guide: Topic 4.2 – Service Provider Business Models

## 1. Production Architectural Problem & Motivation

Modern software engineering relies heavily on Open Source Software (OSS) for fundamental infrastructure components—ranging from relational databases (PostgreSQL) and caching layers (Redis) to distributed message brokers (Apache Kafka) and container orchestrators (Kubernetes). However, operating open-source software at enterprise production scale introduces significant operational overhead: stateful day-2 operations, disaster recovery, zero-downtime upgrades, security patching, high availability (HA) multi-region replication, and strict Service Level Agreements (SLAs).

This operational complexity created the market demand for **Service Provider Business Models**. Organizations transition from self-managed OSS to consuming managed open-source offerings provided by cloud vendors (IaaS/PaaS/SaaS providers) or the primary open-source maintainers themselves.

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

### The Architectural & Economic Problem
To build a sustainable business model around open source without violating open-source licenses, service providers face five critical production challenges:

1. **Multi-Tenancy & Isolation Mechanics**: Service providers must run thousands of tenant workloads on shared compute infrastructure to maximize profit margins. This introduces the risk of "noisy neighbors" (resource exhaustion) and security breaches (cross-tenant data access). Providers must enforce hard isolation across network (CNI eBPF policies), compute (cgroups v2, MicroVMs like Kata Containers/Firecracker), and storage (volume isolation).
2. **License Exploitation & Managed Services Clash**: Cloud Service Providers (CSPs) historically wrapped permissively licensed OSS (e.g., Apache 2.0, BSD, MIT) into profitable hosted services without contributing back to core development. This triggered defensive licensing shifts toward source-available licenses like the Server Side Public License (SSPL), Business Source License (BSL/BSLA), and AGPLv3 with Network Copyleft provisions.
3. **Usage Metering & Consumption-Based Billing**: Service providers require deterministic, tamper-proof telemetry pipelines to calculate billing based on actual resource consumption (CPU core-hours, memory-GiB-hours, network egress, storage IOPS).
4. **SLO/SLA Engineering & Error Budget Management**: Delivering commercial SLAs (e.g., 99.99% uptime) over inherently failure-prone infrastructure requires automated failover, declarative reconciliation operators, and real-time Service Level Indicator (SLI) evaluation via Prometheus metrics.
5. **Open Core vs. Pure SaaS Trade-offs**: Providers must architect software such that core functionality remains freely available under OSI-approved licenses, while proprietary enterprise features (SSO/SAML, granular RBAC, encryption at rest with KMS, audit logging) are implemented via decoupled enterprise plugins or hosted SaaS control planes.

---

## 2. Technical Comparisons & Trade-Off Matrices

### Table 2.1: Open Source Service Provider Business Models

| Model | Revenue Mechanics | Codebase Licensing | Production Advantage | Architectural / Operational Trade-off |
| :--- | :--- | :--- | :--- | :--- |
| **Pure Managed Service / SaaS** | Subscription or Consumption-based billing (e.g., $ / core-hour) | OSS core (Apache 2.0/MIT) or Source-Available (SSPL) | Zero customer operational overhead; rapid user onboarding; fully managed SLAs. | High infrastructure cost for provider; customer cloud vendor lock-in; strict data sovereignty compliance burden. |
| **Open Core** | Tiered licensing: Free community core + Paid Enterprise modules | Dual-licensed or Open Core (GPL/MIT core + Commercial extensions) | Low barrier to entry; strong developer adoption converts to enterprise sales. | Complex code architecture (feature flags/pluggable enterprise modules); maintenance overhead of sync between core and enterprise branches. |
| **Dual Licensing** | Commercial license for closed-source embedding; Copyleft for open use | GPL / AGPLv3 (Community) AND Proprietary Commercial License | Generates revenue from proprietary vendors needing to bypass Copyleft obligations. | Demands 100% Contributor License Agreement (CLA) ownership; weak against cloud providers hosting pure SaaS. |
| **Support, Services & Hosting** | Professional services, training, customized deployments, SLAs | 100% OSI-approved Open Source (Apache 2.0, MIT, GPL) | Maximum open-source trust; zero proprietary code drift; strong community alignment. | Unscalable linear revenue growth tied to headcount; cloud providers can re-sell the exact same OSS code base. |

### Table 2.2: Tenant Isolation Architectural Strategy Matrix

| Strategy | Compute Isolation | Network Isolation | Storage Isolation | Operational Overhead | Cost Efficiency |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Shared Namespace (Soft)** | Linux cgroups v2 + namespaces | Application-level RBAC | Shared DB / Schema-per-tenant | Minimal | Maximum |
| **Dedicated Namespace per Tenant** | Pod limit quotas + NodeSelectors | NetworkPolicy (Default Deny All) | Dedicated PVC per tenant | Moderate | High |
| **Dedicated Cluster per Tenant** | Hard VM / Bare-metal boundary | Physical VLAN / VPC peering | Dedicated Storage Array | Extremely High | Low |
| **MicroVM / Sandbox Containers** | KVM / Firecracker / Kata Containers | eBPF Host Endpoint Filtering | Encrypted PVs per MicroVM | Moderate | Moderate-High |

---

## 3. Complete Syntactically Valid Infrastructure & Platform Manifests

To demonstrate a production multi-tenant managed service platform, the following manifests define:
1. A **Custom Resource Definition (CRD)** for provisioning managed tenant instances (`TenantInstance`).
2. An **Envoy/Traefik IngressRoute & Middleware** for rate limiting and tenant context routing.
3. A **PrometheusRules** definition for evaluating Tenant SLIs and triggering SLA breach alerts.

### Listing 3.1: Custom Resource Definition for Multi-Tenant Managed Instance (`tenantinstance-crd.yaml`)

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

### Listing 3.2: Traefik Multi-Tenant Dynamic Routing & Rate Limit Middleware (`traefik-tenant-routing.yaml`)

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

### Listing 3.3: Prometheus Multi-Tenant Metering & SLA Alerting Rules (`prometheus-tenant-sla.yaml`)

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

## 4. Real CLI Commands & Terminal Execution Outputs

### Command 1: Provisioning a Managed Tenant Instance via Kubernetes API
Execute `kubectl apply` to submit a valid `TenantInstance` manifest to the control plane.

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

#### Expected Terminal Output:
```text
namespace/tenant-acme-corp created
tenantinstance.platform.sre.io/tenant-acme-corp created
```

---

### Command 2: Verifying Tenant Instance Custom Resource Status & Condition
Inspect the reconciliation status driven by the platform operator.

```bash
$ kubectl get tenantinstance tenant-acme-corp -n tenant-acme-corp -o jsonpath='{range .status}{"Phase: "}{.phase}{"\nEndpoints: "}{.endpoints}{"\nSLA Status: "}{.slaCurrentAvailability}{"\n"}{end}'
```

#### Expected Terminal Output:
```text
Phase: Ready
Endpoints: ["acmecorp99-node-0.serviceprovider.internal:6379","acmecorp99-node-1.serviceprovider.internal:6379","acmecorp99-node-2.serviceprovider.internal:6379"]
SLA Status: 99.995%
```

---

### Command 3: Querying Usage Metering Telemetry via Prometheus API (PromQL)
Fetch real-time CPU core usage metrics per tenant namespace for billing calculation.

```bash
$ curl -s -G 'http://prometheus.platform-monitoring.svc.cluster.local:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="tenant-acme-corp"}[1h])) by (namespace)' | jq .
```

#### Expected Terminal Output:
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

### Command 4: Simulating Tenant Rate-Limiting & Validation via cURL
Validate that the Traefik service provider rate-limiting middleware blocks excessive tenant requests (HTTP 429 Too Many Requests).

```bash
$ for i in {1..5}; do curl -s -o /dev/null -w "%{http_code}\n" -H "X-Tenant-ID: acmecorp99" https://api.serviceprovider.io/v1/tenant/acmecorp99/health; done
```

#### Expected Terminal Output:
```text
200
200
200
200
429
```

---

## 5. Verification & Failure Diagnostics Guide

### Diagnostic Workflow: Resolving SLA Breaches & Tenant Resource Contention

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

#### Step 1: Isolate Affected Tenant and Inspect Resource Throttling
When a tenant reports latency degradation violating their SLA, check if the pod is being throttled by kernel cgroups CFS (Completely Fair Scheduler).

```bash
$ kubectl exec -it -n platform-monitoring prometheus-k8s-0 -- promtool query instant http://localhost:9090 \
  'rate(container_cpu_cfs_throttled_periods_total{namespace="tenant-acme-corp"}[5m]) / rate(container_cpu_cfs_periods_total{namespace="tenant-acme-corp"}[5m]) * 100'
```
*Diagnostic Threshold*: If throttled period ratio exceeds **25%**, the tenant workload has hit its strict billing tier CPU limit.

#### Step 2: Validate Network Policy Isolation Enforcement
Ensure cross-tenant network traffic is strictly denied by verifying Cilium / Calico CNI NetworkPolicies.

```bash
$ kubectl describe networkpolicy default-deny-cross-tenant -n tenant-acme-corp
```
Look for explicit `Ingress` and `Egress` isolation blocks:
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

#### Step 3: Audit Tenant License & Feature Access Entitlements
When a tenant requests an enterprise feature (e.g., KMS Encryption at Rest) and receives `403 Forbidden`, verify feature-gate propagation in the enterprise control plane:

```bash
$ kubectl get configmap tenant-entitlements -n tenant-acme-corp -o jsonpath='{.data.entitlements\.json}' | jq .
```
Expected output showing active plan entitlements:
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

## 6. References

- Linux Professional Institute (LPI) Open Source Essentials Overview: https://www.lpi.org/our-certifications/open-source-essentials-overview/
- LPI Wiki Exam 050-100 Objectives: https://wiki.lpi.org
- Open Source Initiative (OSI) Licenses & Standards: https://opensource.org/licenses
- Server Side Public License (SSPL) FAQ: https://www.mongodb.com/licensing/server-side-public-license/faq
- Cloud Native Computing Foundation (CNCF) Multi-Tenancy Benchmarks: https://www.cncf.io
- Prometheus Alerting & Recording Rules Documentation: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Traefik Middleware & IngressRoute Documentation: https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/