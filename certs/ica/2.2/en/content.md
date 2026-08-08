# ICA 2.2 — Troubleshooting the Mesh Control Plane

> **Domain 2 — Operating the Service Mesh · Sub-topic 2.2 · Exam weight: 7**
> Level: Principal Platform Architect / Senior SRE. Focus: `istiod` internals, xDS distribution failures, injection and validation webhooks, CA/mTLS bootstrap, and control-plane capacity engineering.

---

## 1. Motivation: why the control plane is the mesh's single most dangerous failure domain

In a service mesh the **data plane** (the Envoy sidecars) is what actually moves traffic, but every sidecar is *dumb by design*: it ships with a near-empty bootstrap config and depends on the control plane to tell it which listeners to open, which clusters exist, which endpoints back them, which routes apply, and which certificates to present. That dependency is the architectural problem you are hired to reason about.

`istiod` is the unified control plane (since Istio 1.5 it fuses the former Pilot, Citadel and Galley into one binary). It plays four roles simultaneously, and **each role fails differently**:

| Role | What it does | Port(s) | Failure blast radius |
|---|---|---|---|
| **xDS server** (ex-Pilot) | Watches Kubernetes + Istio CRDs, builds a `PushContext`, translates it to Envoy xDS, streams over ADS | 15010 (plaintext), 15012 (mTLS) | Config stops propagating → data plane serves **stale** rules silently |
| **CA / SDS issuer** (ex-Citadel) | Signs workload certs (SVIDs) requested by `istio-agent` over the secure xDS channel | 15012 | New/rotated workloads can't get certs → **mTLS handshake failures**, `503 UF/URX` |
| **Sidecar injector** | Mutating admission webhook that patches the Envoy container into pods | 443 → 15017 | Pods start **without** a sidecar, or (with `failurePolicy: Fail`) can't be created at all |
| **Config validator** (ex-Galley) | Validating admission webhook that rejects malformed Istio CRs | 443 → 15017 | Bad config is admitted (fail-open) or **all** Istio `kubectl apply` blocked (fail-closed) |

The reason this sub-topic carries weight is a property unique to control planes: **failures are usually silent and delayed**. When `istiod` stops pushing, nothing crashes. Envoy keeps forwarding traffic using the last config it acknowledged. A new `VirtualService` you applied "works on my cluster" because your proxy synced before the fault; the canary that rolled out five minutes later got the stale snapshot and routes 100% to `v1`. The mean-time-to-*detect* on a broken control plane is dominated by how fast you can answer one question:

> **Is the config the operator *authored* the same config the proxy is *running*?**

Everything in this chapter is machinery to answer that question fast, then to localize the break to one of the four roles above.

### The distribution pipeline you are debugging

```
   Kubernetes API server
   (Service, Endpoints/EndpointSlice, Pod,
    VirtualService, DestinationRule, Gateway,
    Sidecar, PeerAuthentication, ...)
            │  watch (informers)
            ▼
   ┌───────────────────────────────────────────────┐
   │                  istiod                         │
   │                                                 │
   │  ConfigController ─┐                            │
   │  ServiceController ├─► debounce ─► PushContext  │  ← full mesh snapshot
   │  (endpoints)       ┘   (100ms..10s)   (cache)   │
   │                                   │             │
   │                                   ▼             │
   │                          xDS generators         │
   │                       CDS│EDS│LDS│RDS│SDS│ECDS   │
   │                                   │             │
   │                            ADS gRPC stream       │
   └───────────────────────────────────┼─────────────┘
                                        │ :15012 (mTLS)
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
        istio-agent               istio-agent               istio-agent
        (pilot-agent)             + Envoy                   + Envoy
        SDS  ── UDS ──► Envoy      ACK/NACK per type         ACK/NACK per type
```

Three ideas govern every diagnosis:

1. **Debounce + snapshot.** `istiod` does not push per-event. It coalesces bursts (`PILOT_DEBOUNCE_AFTER=100ms`, capped by `PILOT_DEBOUNCE_MAX=10s`) and rebuilds a `PushContext`. A change that "isn't showing up" may simply be inside a debounce window on a busy mesh.
2. **ACK/NACK is per xDS type.** Envoy acknowledges each of CDS/LDS/EDS/RDS independently. A single malformed route makes RDS go `STALE`/`NACK` while CDS stays `SYNCED`. The column that is *not* green tells you which generator produced bad config.
3. **`STALE` ≠ `NOT SENT`.** `NOT SENT` means istiod had nothing to send (usually fine). `STALE` means istiod sent an update and Envoy has **not acknowledged** it — that is always a signal: Envoy rejected it, the stream is wedged, or the proxy is unreachable.

---

## 2. Technical comparisons and trade-offs

### 2.1 The diagnostic tools, and which question each answers

| Tool | Question it answers | Data source | Cost / caveat |
|---|---|---|---|
| `istioctl proxy-status` (`ps`) | Is every proxy in sync, and with which istiod? | istiod `/debug/syncz` | Cheapest first move; shows the *symptom*, not the cause |
| `istioctl proxy-config <type>` (`pc`) | What config does **this Envoy actually have**? | Envoy admin `:15000/config_dump` | Ground truth of the data plane; large output |
| `istioctl x internal-debug <endpoint>` | What did **istiod compute** for the mesh? | istiod debug endpoints (secure) | Compares istiod's view vs Envoy's |
| `istioctl analyze` | Is the config *statically* wrong or conflicting? | K8s API (no runtime data) | Free, offline; can't see propagation, only authoring errors |
| `istioctl x precheck` / `experimental precheck` | Is the cluster/version safe for install/upgrade? | K8s API, webhooks, CRDs | Pre-flight only |
| istiod metrics (`:15014/metrics`) | Is the control plane healthy *in aggregate*? | Prometheus | Trend/alert, not per-proxy root cause |
| ControlZ (`:9876`) | Can I change a log scope live / inspect istiod env? | istiod introspection UI | Per-pod; use for deep log capture |
| istiod logs | Why did a push fail / a cert get rejected? | `kubectl logs` | Distroless image → no shell; use `--tail`/scopes |

**Rule of escalation:** `proxy-status` → (if a column is red) `proxy-config` for that type on the affected proxy → compare against `internal-debug configz`/`analyze` → istiod logs. Do not jump to logs first; on a large mesh the logs are a firehose and the answer is usually one line of `proxy-status`.

### 2.2 xDS transport: 15010 vs 15012

| | **15010** (`grpc-xds`) | **15012** (`tls-xds` / `https-dns`) |
|---|---|---|
| Transport | Plaintext gRPC | mTLS gRPC (Istio-issued certs) |
| Carries | xDS only | xDS **and** CA (CSR) — the SDS bootstrap path |
| Trust bootstrap | none | agent verifies istiod with the mesh root from the `istio-ca-root-cert` ConfigMap |
| Production use | **Never** — debugging/legacy only; disable it | Default and required for CA |
| Failure signature if misused | works, but unauthenticated; a NetworkPolicy that blocks 15012 pushes traffic onto 15010 and hides a real security gap | agent can't fetch certs → workload never gets an SVID → sidecar not `Ready` on 15021 |

**Trade-off:** 15012 couples xDS and CA on one secure port, which is operationally clean but means a **single NetworkPolicy mistake takes out both config distribution and certificate issuance at once**. When new pods across many namespaces are stuck `0/2 Running` with agents logging `connection refused` to istiod:15012, suspect a NetworkPolicy or mesh-wide `PeerAuthentication STRICT` applied before the control-plane path was allowlisted.

### 2.3 Webhook `failurePolicy`: `Fail` vs `Ignore`

| | `failurePolicy: Fail` | `failurePolicy: Ignore` |
|---|---|---|
| istiod healthy | Correct behavior; guarantees injection/validation | Same |
| **istiod down** | **API calls that match the webhook are rejected** — new pods can't be created (injector) or Istio CRs can't be applied (validator) | Pods are created **without a sidecar**; bad CRs are **admitted** |
| Blast radius | Availability incident: workloads can't schedule | Security/correctness incident: unmeshed pods, invalid config live |
| Mitigation | `namespaceSelector`/`objectSelector` to scope the webhook narrowly; run istiod HA (≥2 replicas, PDB) | Reconcile drift later; monitor `sidecar_injection_failure_total` |

Istio deliberately scopes the **injector** webhook with an `objectSelector`/`namespaceSelector` so a control-plane outage only blocks pods that *asked* to be meshed, and configures the **validating** webhook to be effectively fail-open until istiod has proven it can validate (the classic "chicken-and-egg": you must be able to create the very config that fixes istiod). Knowing which webhook is `Fail` vs `Ignore` is the difference between "why won't my pods start?" and "why is my invalid Gateway live?".

### 2.4 Control-plane HA topologies

| Topology | Availability | Config-freshness during upgrade | When |
|---|---|---|---|
| Single istiod | None; OOM/restart = mesh-wide `STALE` window | N/A | dev / labs only |
| istiod ≥2 replicas + PDB + HPA | Survives node loss; rolling restart keeps ≥1 serving | Proxies reconnect and resync in seconds | production baseline |
| Revisioned (canary) control plane (`istio.io/rev`) | Two istiods (`stable`, `canary`) run side by side | Data plane migrates namespace-by-namespace by relabeling | safe upgrades / multi-version |
| Multi-primary / remote (multicluster) | Per-cluster istiod; `CLUSTER` column in `proxy-status` | Cross-cluster endpoint sync via remote secrets | multi-cluster |

---

## 3. Complete manifests and infrastructure (unabridged)

### 3.1 Production-grade istiod: HA, resource governance, and push tuning

The single most common control-plane incident is **istiod OOMKilled on a large mesh**, which drops every ADS stream and turns the whole `proxy-status` table `STALE` until proxies reconnect. This `IstioOperator` hardens istiod: pinned resources, HPA, a PodDisruptionBudget, and the environment variables that govern the push pipeline.

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: default
  meshConfig:
    # Reduce PushContext size: only build config for namespaces the mesh cares about.
    discoverySelectors:
      - matchLabels:
          istio-discovery: "enabled"
    accessLogFile: /dev/stdout          # make data-plane failures observable
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
      holdApplicationUntilProxyStarts: true   # avoid app traffic before Envoy syncs
    enableTracing: false
  components:
    pilot:
      k8s:
        replicaCount: 3
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            memory: "4Gi"               # NO cpu limit: CPU throttling delays pushes
        hpaSpec:
          minReplicas: 3
          maxReplicas: 8
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 70
        podDisruptionBudget:
          minAvailable: 2
        env:
          # --- Push pipeline governance ---
          - name: PILOT_PUSH_THROTTLE          # max concurrent proxy pushes
            value: "100"
          - name: PILOT_DEBOUNCE_AFTER         # coalesce bursts of config changes
            value: "100ms"
          - name: PILOT_DEBOUNCE_MAX           # hard cap on debounce window
            value: "10s"
          - name: PILOT_ENABLE_EDS_DEBOUNCE    # debounce endpoint churn separately
            value: "true"
          # Trim per-proxy config when Sidecar resources are not exhaustive.
          - name: PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
            value: "true"
        overlays:
          - kind: Deployment
            name: istiod
            patches:
              - path: spec.template.spec.containers.[name:discovery].readinessProbe.periodSeconds
                value: 5
  values:
    pilot:
      autoscaleEnabled: true
    global:
      # Force the secure xDS/CA port; never fall back to 15010 in prod.
      pilotCertProvider: istiod
```

> **Why no CPU limit on istiod:** CFS throttling of the discovery container stretches `pilot_proxy_convergence_time` — the control plane appears "up" while pushes queue. Requests reserve capacity; limits on istiod cause exactly the latency you're trying to prevent. This is a documented best practice.

### 3.2 Scoping config with a `Sidecar` resource (the real fix for istiod memory)

`discoverySelectors` shrinks what istiod *watches*; a `Sidecar` shrinks what each proxy *receives*. Without it, every sidecar gets clusters/listeners for the **entire mesh** — the dominant driver of both istiod memory and Envoy memory at scale.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: payments
spec:
  egress:
    - hosts:
        - "./*"                     # same namespace
        - "istio-system/*"          # control plane
        - "observability/*"         # only the deps this namespace actually calls
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY             # deny egress to unknown hosts (also a security control)
```

### 3.3 The two webhooks you will inspect (read, don't hand-author these)

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: istio-sidecar-injector
  labels:
    istio.io/rev: default
webhooks:
  - name: rev.namespace.sidecar-injector.istio.io
    clientConfig:
      service:
        name: istiod
        namespace: istio-system
        path: /inject
        port: 443
    namespaceSelector:
      matchExpressions:
        - key: istio-injection
          operator: DoesNotExist
        - key: istio.io/rev
          operator: In
          values: ["default"]
    objectSelector:
      matchExpressions:
        - key: sidecar.istio.io/inject
          operator: NotIn
          values: ["false"]
    failurePolicy: Fail            # <-- if istiod is down, meshed pods can't be created
    reinvocationPolicy: Never
    sideEffects: None
    admissionReviewVersions: ["v1"]
```

The **validating** webhook mirrors this but targets Istio CRDs (`networking.istio.io`, `security.istio.io`) with a fail-open posture during control-plane bring-up.

### 3.4 Scraping the control plane (Prometheus)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istiod
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: istiod
  podMetricsEndpoints:
    - port: http-monitoring        # 15014
      path: /metrics
      interval: 15s
```

---

## 4. Real CLI commands and terminal output

> Environment: Istio 1.20, `istiod` in `istio-system`, Bookinfo in `default`.

### 4.1 First move — is the mesh in sync?

```console
$ istioctl proxy-status
NAME                                     CLUSTER      CDS        LDS        EDS        RDS        ECDS       ISTIOD                     VERSION
details-v1-698b5d8c98-4n2xq.default      Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-6b9f9d5c4-abcde     1.20.0
productpage-v1-6b746f74dc-7pk4t.default  Kubernetes   SYNCED     SYNCED     SYNCED     STALE      NOT SENT   istiod-6b9f9d5c4-abcde     1.20.0
ratings-v1-5967f59c58-9r7qz.default      Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-6b9f9d5c4-abcde     1.20.0
reviews-v1-9c6bb6658-lm2vx.default       Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-6b9f9d5c4-abcde     1.20.0
reviews-v2-8454bb78d8-tt6zp.default      Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-6b9f9d5c4-abcde     1.20.0
```

Reading it: `productpage` has **RDS: STALE** while everything else is `SYNCED`. Diagnosis path is now narrow — a **route** update was pushed to `productpage` and Envoy did not acknowledge it. `NOT SENT` on ECDS is normal (no extension configs). Column meanings:

| Status | Meaning | Action |
|---|---|---|
| `SYNCED` | Envoy acknowledged (ACK) istiod's latest | none |
| `NOT SENT` | istiod had nothing of this type to send | usually none |
| `STALE` | istiod sent an update; Envoy has **not** ACK'd (or NACK'd) | investigate — this is a fault |

### 4.2 Get ground truth from the affected proxy

```console
$ istioctl proxy-config routes productpage-v1-6b746f74dc-7pk4t.default --name 9080 -o json | jq '.[0].virtualHosts[].routes[].match'
{
  "prefix": "/"
}
# Expected an added header match from the new VirtualService — it is absent.
```

Compare with what istiod *thinks* it computed:

```console
$ istioctl experimental internal-debug configz istiod-6b9f9d5c4-abcde.istio-system | \
    jq '.[] | select(.kind=="VirtualService" and .metadata.name=="productpage-route")'
{
  "kind": "VirtualService",
  "metadata": { "name": "productpage-route", "namespace": "default" },
  "spec": { "http": [ { "match": [ { "headers": { "x-user": { "exact": "tester" } } } ] } ] }
}
```

istiod **has** the config; Envoy does **not**. The update was sent (STALE), so Envoy rejected it. Confirm with the NACK counter and istiod logs (§4.4).

### 4.3 Static analysis — catch authoring errors before they ever push

```console
$ istioctl analyze -n default
Error [IST0101] (VirtualService productpage-route.default) Referenced host+subset in destination "reviews" subset "v4" not found
  Error [IST0105] (VirtualService productpage-route.default) DestinationRule reviews.default does not define subset "v4" used in route
Error: Analyzers found issues when analyzing namespace: default.
See https://istio.io/v1.20/docs/reference/config/analysis for more information about causes and resolutions.
```

`analyze` is offline — it never touches the data plane, so it finds the *cause* (a route to a non-existent subset) that produced the NACK you saw in `proxy-status`.

### 4.4 The NACK, confirmed in metrics and logs

```console
$ kubectl -n istio-system exec deploy/istiod -c discovery -- \
    curl -s localhost:15014/metrics | grep -E 'pilot_(total_xds_rejects|xds_rds_reject)'
pilot_total_xds_rejects 1
pilot_xds_rds_reject{type="type.googleapis.com/envoy.config.route.v3.RouteConfiguration"} 1
```

```console
$ kubectl -n istio-system logs deploy/istiod -c discovery --tail=20 | grep -i 'rds\|nack\|reject'
2026-08-08T14:22:07.913Z  warn  ads  ADS:RDS: ACK ERROR productpage-v1-6b746f74dc-7pk4t.default-12
    Internal:Error adding/updating listener(s) 0.0.0.0_9080: subset "v4" for host "reviews.default.svc.cluster.local" has no matching endpoints
```

Root cause chain, fully closed: `VirtualService` routes to `reviews` subset `v4` → no `DestinationRule` subset `v4` exists → istiod builds an RDS update → Envoy NACKs it → RDS stays `STALE` → traffic keeps using the last good routes. Fix: add the subset (or remove the route), and RDS goes `SYNCED`.

### 4.5 Debug endpoints via `internal-debug` (secure, works with distroless istiod)

```console
$ istioctl experimental internal-debug syncz | jq -r '.[].proxy' | head
productpage-v1-6b746f74dc-7pk4t.default
reviews-v1-9c6bb6658-lm2vx.default
...

$ istioctl experimental internal-debug registryz istiod-6b9f9d5c4-abcde.istio-system \
    | jq -r '.[].hostname' | grep reviews
reviews.default.svc.cluster.local

$ istioctl experimental internal-debug endpointz istiod-6b9f9d5c4-abcde.istio-system \
    | jq '.[] | select(.svc | test("reviews")) | {svc, ep: (.eps|length)}'
{ "svc": "reviews.default.svc.cluster.local:9080", "ep": 3 }
```

Useful endpoints: `syncz` (sync state), `configz` (all config istiod holds), `registryz` (service registry), `endpointz`/`edsz` (endpoints — for "service has no endpoints" bugs), `adsz` (live ADS connections + push counts), `authorizationz` (AuthorizationPolicies applied), `mesh`/`meshconfigz` (effective MeshConfig).

### 4.6 Live log scoping with ControlZ (no restart needed)

```console
$ istioctl dashboard controlz deployment/istiod -n istio-system
http://localhost:9876
# In the UI (or via API) raise the 'ads' and 'xds' scopes to 'debug' to capture a single push,
# then drop them back to 'info'. Avoid mesh-wide debug logging on a large control plane.

$ curl -s -X PUT localhost:9876/scopej/ads -H 'Content-Type: application/json' \
    -d '{"name":"ads","output_level":"debug"}'
```

### 4.7 Injection troubleshooting

```console
$ kubectl get ns default -o jsonpath='{.metadata.labels}'
{"kubernetes.io/metadata.name":"default"}          # <-- no istio-injection / istio.io/rev label!

$ kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'
Fail

$ istioctl experimental check-inject deploy/productpage -n default
NAMESPACE     LABELS                        INJECTED?     REASON
default       (none)                        false         Namespace not enabled and no pod override
```

Fix and verify the webhook actually fires:

```console
$ kubectl label namespace default istio-injection=enabled --overwrite
namespace/default labeled
$ kubectl rollout restart deploy/productpage -n default
$ kubectl get pod -l app=productpage -n default
NAME                              READY   STATUS    RESTARTS   AGE
productpage-v1-7d8c9f6b4-xkq2m    2/2     Running   0          14s     # 2/2 = sidecar injected
```

If `failurePolicy: Fail` **and** istiod is down, the symptom instead is `Error creating: Internal error occurred: failed calling webhook "...istio.io": ... connection refused` on the ReplicaSet — an availability incident, not a "missing label" one.

### 4.8 CA / mTLS bootstrap troubleshooting

```console
$ istioctl proxy-config secret productpage-v1-7d8c9f6b4-xkq2m.default
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2f:1a:...:9c         2026-08-09T14:20:11Z     2026-08-08T14:18:11Z
ROOTCA            CA             ACTIVE     true           01                   2036-08-05T09:00:00Z     2026-08-05T09:00:00Z
```

A workload stuck without a cert (`VALID CERT: false`, or the pod never reaching `Ready` on 15021) points at the agent→istiod:15012 path:

```console
$ kubectl logs productpage-v1-7d8c9f6b4-xkq2m -c istio-proxy --tail=5
2026-08-08T14:18:05Z  warn  sds  failed to warm certificate: failed to generate workload certificate:
    create certificate: rpc error: code = Unavailable desc = connection error:
    desc = "transport: Error while dialing dial tcp 10.96.0.10:15012: connect: connection refused"

$ kubectl -n istio-system exec deploy/istiod -c discovery -- \
    curl -s localhost:15014/metrics | grep -E 'citadel_server_(csr_count|success_cert_issuance)'
citadel_server_csr_count 4213
citadel_server_success_cert_issuance_count_total 4210
```

Cause here is 15012 unreachable — check NetworkPolicy, a too-early STRICT `PeerAuthentication`, or istiod not `Ready`. If CSRs arrive but fail issuance, suspect clock skew (`NOT BEFORE` in the future) or a rotated/mismatched mesh root in the `istio-ca-root-cert` ConfigMap.

### 4.9 Version skew (a frequent, silent cause)

```console
$ istioctl version
client version: 1.20.0
control plane version: 1.20.0
data plane version: 1.18.2 (23 proxies), 1.20.0 (2 proxies)   # <-- 23 proxies never restarted after upgrade
```

Data-plane proxies far behind istiod can reject config the new istiod emits. Restart those workloads (`kubectl rollout restart`) so their sidecars match.

---

## 5. Verification and failure-diagnosis playbook

### 5.1 The universal triage ladder

```
1. istioctl proxy-status
   ├─ all SYNCED ......................... control-plane distribution is healthy; look at data plane / policy
   ├─ a column STALE ..................... that xDS type was NACK'd → go to step 2 for that type
   ├─ a proxy missing entirely ........... proxy never connected → agent/15012/injection (step 4/5)
   └─ ISTIOD column differs / empty ...... revision mismatch or istiod down → step 6

2. istioctl proxy-config <type> <pod>     # what Envoy runs
   istioctl x internal-debug configz      # what istiod computed
   └─ istiod has it, Envoy doesn't ....... NACK → step 3

3. metrics: pilot_total_xds_rejects, pilot_xds_<type>_reject   (increasing?)
   istiod logs: grep 'NACK|ACK ERROR|reject|Internal:'
   istioctl analyze                        # find the authoring error that caused it

4. Injection: 2/2 vs 1/1 containers
   kubectl get ns <ns> -o jsonpath='{.metadata.labels}'   # istio-injection / istio.io/rev
   kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml   # failurePolicy, selectors
   istioctl x check-inject <resource>

5. Cert/mTLS: istioctl proxy-config secret <pod>          # VALID CERT true?
   kubectl logs <pod> -c istio-proxy | grep -i sds        # 15012 reachable?
   metrics: citadel_server_* ; check clock skew & ca-root ConfigMap

6. Control-plane health:
   kubectl -n istio-system get pods -l app=istiod         # Ready? restarts? OOMKilled?
   kubectl -n istio-system top pod -l app=istiod          # memory near limit?
   metrics: pilot_xds (client count), pilot_proxy_convergence_time, container_memory_working_set_bytes
```

### 5.2 Symptom → likely cause → confirming signal

| Symptom | Likely cause | Confirm with |
|---|---|---|
| One xDS column `STALE` on some proxies | NACK: invalid CR (bad subset/host/filter) | `pilot_xds_<type>_reject`↑, istiod log `ACK ERROR ... Internal:`, `istioctl analyze` |
| **All** proxies `STALE` at once, then recover | istiod restart / OOMKilled → streams dropped | istiod `RESTARTS`↑, `Reason: OOMKilled`, memory at limit |
| New pods `1/1` (no sidecar) | namespace not labeled / `sidecar.istio.io/inject: false` / webhook selector miss | ns labels, `istioctl x check-inject`, `sidecar_injection_*` metrics |
| New pods can't be created (`connection refused` webhook) | istiod down + injector `failurePolicy: Fail` | ReplicaSet events, istiod not `Ready` |
| `kubectl apply` of Istio CR rejected unexpectedly | validating webhook + istiod down (fail-closed window) | `galley_validation_failed`, validator webhook state |
| Pod never `Ready`, `503 UF/URX`, TLS errors | agent can't reach istiod:15012 → no SVID | `proxy-config secret` (VALID CERT false), agent SDS logs, NetworkPolicy on 15012 |
| Config applies but never takes effect anywhere | change inside debounce window / istiod not watching that CRD | `pilot_debounce`*, `pilot_k8s_cfg_events`, restart-free after `internal-debug configz` shows it |
| Endpoints missing for a healthy Service | EDS/registry gap | `internal-debug endpointz`/`edsz`, `pilot_xds_eds_reject` |
| Proxies split across two istiod versions | in-flight revision migration / stale sidecars | `istioctl version` data-plane skew, `ISTIOD` column |

### 5.3 Control-plane health SLIs to alert on (istiod `:15014`)

| Metric | Meaning | Alert heuristic |
|---|---|---|
| `pilot_proxy_convergence_time` (histogram) | change → all proxies synced | p99 rising / > seconds sustained |
| `pilot_total_xds_rejects` | proxies NACK'ing config | any sustained increase |
| `pilot_xds` | connected xDS clients | sharp drop = mass disconnect (istiod restart / network) |
| `pilot_xds_pushes{type=...}` | push volume per type | runaway = config churn / debounce ineffective |
| `pilot_xds_push_context_errors` | failures building the snapshot | any nonzero |
| `sidecar_injection_failure_total` | injector rejections | any increase |
| `citadel_server_csr_count` vs `..._success_cert_issuance_count_total` | CA issuance gap | success lagging requests |
| `container_memory_working_set_bytes{container="discovery"}` | istiod memory | approaching limit → OOM risk |

### 5.4 Distroless caveat

Production istiod and the sidecars ship on **distroless** images — no shell, no `curl` inside the container by default. Use `istioctl x internal-debug`, `istioctl proxy-config`, `kubectl logs`, and `kubectl debug --image=curlimages/curl` ephemeral containers rather than `kubectl exec ... sh`. The `curl localhost:15014/...` examples above work because the `discovery`/`istio-proxy` containers ship a pilot-agent `curl` shim on the health path; when they don't, prefer the `istioctl` equivalents, which reach the same endpoints over the secure channel.

---

## 6. References

- ICA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
- Debugging Envoy and Istiod (`proxy-status`, `proxy-config`) — https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Component debugging & istiod debug endpoints — https://istio.io/latest/docs/ops/diagnostic-tools/component-debugging/
- Configuration analysis with `istioctl analyze` — https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Understanding your mesh with ControlZ — https://istio.io/latest/docs/ops/diagnostic-tools/controlz/
- Common problems: sidecar injection — https://istio.io/latest/docs/ops/common-problems/injection/
- Common problems: configuration validation — https://istio.io/latest/docs/ops/common-problems/validation/
- Common problems: traffic management (STALE/NACK, propagation) — https://istio.io/latest/docs/ops/common-problems/network-issues/
- Common problems: security / mTLS & certs — https://istio.io/latest/docs/ops/common-problems/security-issues/
- Performance and scalability (debounce, push throttle, sizing) — https://istio.io/latest/docs/ops/deployment/performance-and-scalability/
- Deployment best practices (istiod HA, resources) — https://istio.io/latest/docs/ops/best-practices/deployment/
- Istio DNS certificates / CA & SDS architecture — https://istio.io/latest/docs/tasks/security/cert-management/
- Safe canary upgrades with revisions — https://istio.io/latest/docs/setup/upgrade/canary/
- `pilot-discovery` (istiod) reference & env vars — https://istio.io/latest/docs/reference/commands/pilot-discovery/
- `istioctl` command reference — https://istio.io/latest/docs/reference/commands/istioctl/
- MeshConfig / `discoverySelectors` reference — https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Envoy xDS protocol (ADS, ACK/NACK semantics) — https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol