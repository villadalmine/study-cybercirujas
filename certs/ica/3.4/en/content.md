# ICA 3.4 — Configuring Traffic Shifting

> Domain: Traffic Management · Exam weight: 5
> Data plane assumed: Istio sidecar mode (Envoy). Notes for ambient mode are called out where the mechanics differ.
> API version used below: `networking.istio.io/v1` (GA since Istio 1.22). The schema is byte-for-byte identical to `networking.istio.io/v1beta1`, which is still served — swap the `apiVersion` string if your cluster runs an older release.

---

## 1. Motivation and the production architectural problem

Rolling out a new version of a service in a shared mesh is not a binary "old → new" event. The moment `Deployment/reviews-v2` reaches `Ready`, Kubernetes' native `Service` load balancing (kube-proxy / iptables / IPVS) sends it a share of traffic proportional to its endpoint count. That coupling is the root problem:

- **Blast radius is tied to replica count, not to risk.** If v2 has 1 replica and v1 has 9, v2 gets ~10% — but only because of the replica math, not because you decided 10% was a safe canary. Scale v2 up for capacity and you silently scale its exposure.
- **No decoupling of "deployed" from "receiving production traffic."** You cannot bake a version, warm its caches, run smoke tests against real traffic, and *then* promote it.
- **Rollback is a `kubectl rollout undo`** — a full redeploy with its own propagation delay, during which the bad version is still serving.
- **No request-level control.** You cannot say "internal beta users on header `x-canary: true` go to v2, everyone else v1" with plain Services.

Istio moves the routing decision **up to L7, into the Envoy sidecar of the *caller***. A `VirtualService` declares *how* requests to a logical host are split; a `DestinationRule` declares *which* pods constitute each subset. istiod (Pilot) compiles these CRDs into Envoy `RouteConfiguration` objects containing **weighted clusters**, pushed to every sidecar via xDS. Envoy then performs a per-request weighted-random selection across clusters. The consequences:

- Weight is **independent of replica count** — 1% to v2 with 20 replicas behind it is perfectly valid.
- Shifts take effect in **seconds** (a config push), with **no pod restarts** and **no connection draining of the old version**.
- Routing can key off **headers, cookies, source workload, SNI, URI** — enabling A/B testing, dark launches, and progressive delivery.
- The mesh emits **per-version telemetry** (`istio_requests_total{destination_version=...}`), which is the raw material for *automated* canary analysis (Flagger, Argo Rollouts).

The architectural payoff is **separating deployment from release**: `kubectl apply` puts code on the cluster; a `VirtualService` weight change *releases* it to users, gradually and reversibly.

---

## 2. Comparative analysis of traffic-shifting strategies

All of the following are expressed with the *same two CRDs*; they differ only in how you configure the `http` block.

| Strategy | How it's expressed in Istio | Selection unit | Rollback | Best for | Key risk |
|---|---|---|---|---|---|
| **Weighted canary** | `route[].weight` split across subsets, ramped 0→5→25→50→100 | Per request (random) | Set weight back to 0 | Gradual production validation with live metrics | A single user may hit both versions on consecutive requests (no stickiness by default) |
| **Blue-green** | Single `route.destination.subset`, flipped atomically v1→v2 | All-or-nothing | Flip subset back | Fast cutover, DB migrations that can't run mixed | Full blast radius on flip; no partial validation |
| **Header/cookie A/B** | `match[].headers` route rule *before* the weighted catch-all | Per request (deterministic by attribute) | Remove the match rule | Feature testing on internal users / cohorts | Match-order bugs silently route everyone to catch-all |
| **Traffic mirroring (shadowing)** | `route.mirror` + `mirrorPercentage` | Per request, fire-and-forget copy | Remove `mirror` | Testing v2 with real traffic, zero user impact | Mirror side effects (double writes, duplicate emails) if not idempotent |
| **Sticky canary** | Weighted split + `DestinationRule.trafficPolicy.loadBalancer.consistentHash` | Per session (hash of cookie/header) | Same as weighted | A/B where a user must stay on one version | Uneven split if the hash key is skewed |
| **Automated progressive delivery** | Flagger/Argo drives `route[].weight` from SLO metrics | Per request, weights machine-controlled | Automatic on metric breach | Hands-off, metric-gated promotion | Bad/absent metrics → false promotion or stuck rollout |

### Where the decision is enforced

| | Kubernetes-native | Istio sidecar traffic shifting | Istio ambient (waypoint) |
|---|---|---|---|
| Split granularity | Replica-count proportional | Arbitrary % / attribute-based | Arbitrary % / attribute-based |
| Enforcement point | kube-proxy (L4) | Caller's Envoy sidecar (L7) | L4 in ztunnel; **L7 rules require a waypoint proxy** |
| Restart to shift | Yes (scale/redeploy) | No | No |
| Per-version metrics | No | Yes | Yes (via waypoint) |

> **Ambient caveat for the exam:** `VirtualService` weighted routing is an L7 feature. In ambient mode it only takes effect if a **waypoint proxy** is deployed for the destination (`istioctl waypoint apply`). ztunnel alone is L4 and will not honor HTTP weights.

---

## 3. Complete infrastructure and manifests

The running example is the canonical `reviews` service (`v1`, `v2`, `v3`) in namespace `bookinfo`. Namespace must be injection-enabled.

### 3.0 Namespace and workloads

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio-injection: enabled          # sidecar auto-injection
---
apiVersion: v1
kind: Service
metadata:
  name: reviews
  namespace: bookinfo
  labels:
    app: reviews
    service: reviews
spec:
  selector:
    app: reviews                      # NOTE: selects on app only, NOT version —
                                      # every version is an endpoint of this one Service
  ports:
    - name: http                      # port name MUST start with http/http2/grpc
      port: 9080                      # for Istio to apply L7 routing
      targetPort: 9080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v1
  namespace: bookinfo
  labels:
    app: reviews
    version: v1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: reviews
      version: v1
  template:
    metadata:
      labels:
        app: reviews
        version: v1                   # <-- the label DestinationRule subsets match on
    spec:
      serviceAccountName: bookinfo-reviews
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
          ports:
            - containerPort: 9080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v2
  namespace: bookinfo
  labels:
    app: reviews
    version: v2
spec:
  replicas: 3
  selector:
    matchLabels:
      app: reviews
      version: v2
  template:
    metadata:
      labels:
        app: reviews
        version: v2
    spec:
      serviceAccountName: bookinfo-reviews
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v2:1.20.2
          ports:
            - containerPort: 9080
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
```

> Two rules that silently break traffic shifting if violated:
> 1. **The `Service` selects on `app` only.** If you add `version` to the selector, each version becomes a *different* Service and subset routing has nothing to split across.
> 2. **The port must be named `http`, `http2`, or `grpc`** (or use `appProtocol`). An unnamed or `tcp`-named port makes Istio treat traffic as opaque L4 — `VirtualService.http` rules are then ignored and everything falls through to plain round-robin.

### 3.1 DestinationRule — define the subsets

The `VirtualService` can only reference a subset that a `DestinationRule` defines. Create this **first**.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews                       # short name resolves to reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http2MaxRequests: 1000
        maxRequestsPerConnection: 10
    outlierDetection:                 # eject unhealthy endpoints so a bad canary
      consecutive5xxErrors: 5         # sheds itself rather than serving errors
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
    - name: v3
      labels: { version: v3 }
```

### 3.2 VirtualService — weighted canary (mesh-internal)

Start at 100/0, then edit the weights.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews                         # logical host callers use
  # gateways omitted => defaults to ["mesh"] => applies to in-mesh sidecar traffic
  http:
    - name: canary-split
      route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10                  # weights across a single route MUST sum to 100
```

**Ramp sequence** — apply the same object with escalating weights:

| Step | v1 | v2 | Gate before advancing |
|---|---|---|---|
| 0 | 100 | 0 | v2 pods `Ready`, subset visible in Envoy clusters |
| 1 | 95 | 5 | success rate ≥ 99.5%, p99 latency within SLO for 10 min |
| 2 | 75 | 25 | no new 5xx classes, saturation nominal |
| 3 | 50 | 50 | error budget burn rate < 1× |
| 4 | 0 | 100 | soak, then delete v1 Deployment |

### 3.3 Header-based A/B routing (deterministic cohort) + weighted fallback

Match rules are evaluated **top-to-bottom, first match wins**. Put the deterministic cohort rule *above* the weighted catch-all.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - name: internal-beta
      match:
        - headers:
            x-canary:
              exact: "true"           # internal beta cohort -> always v2
        - headers:
            end-user:
              exact: "jason"
      route:
        - destination:
            host: reviews
            subset: v2
    - name: everyone-else              # catch-all: no match => weighted split
      route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10
```

### 3.4 Traffic mirroring (shadow / dark launch)

Real production requests are *copied* to v2; v2's responses are **discarded** and never affect the user. The mirrored host gets a `-shadow` suffix on its `Host`/`Authority` header so it is distinguishable in logs.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
            subset: v1                # 100% of live traffic still served by v1
          weight: 100
      mirror:
        host: reviews
        subset: v2                    # a fire-and-forget copy goes to v2
      mirrorPercentage:
        value: 100.0                  # mirror 100% of requests (double for 50%, etc.)
```

> **Idempotency warning:** mirrored requests are *real* requests to v2. If v2 writes to a database, sends emails, or charges cards, mirroring doubles those side effects. Shadow only read paths, or point v2 at a shadow datastore.

### 3.5 Blue-green (atomic cutover)

```yaml
# Green live:
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews, namespace: bookinfo }
spec:
  hosts: [reviews]
  http:
    - route:
        - destination: { host: reviews, subset: v1 }   # 100% by omission of weight
# Flip to blue: change subset to v2 and re-apply. Single-object atomic switch.
```

### 3.6 Sticky canary (session affinity)

Add consistent hashing to the DestinationRule so a given user always lands on the same version across requests.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: canary-session
          ttl: 3600s               # sticks the user to one hashed endpoint for 1h
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
```

### 3.7 Shifting traffic at the ingress edge

For external traffic, bind the `VirtualService` to a `Gateway`. The weight split then happens at the ingress gateway's Envoy.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: bookinfo-gw
  namespace: bookinfo
spec:
  selector:
    istio: ingressgateway            # the istio-ingressgateway Deployment's label
  servers:
    - port: { number: 80, name: http, protocol: HTTP }
      hosts: ["bookinfo.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: bookinfo-edge
  namespace: bookinfo
spec:
  hosts:
    - "bookinfo.example.com"         # must match the Gateway host (FQDN, not short name)
  gateways:
    - bookinfo-gw                    # binds this VS to the ingress gateway
  http:
    - route:
        - destination:
            host: productpage.bookinfo.svc.cluster.local
            port: { number: 9080 }
            subset: v1
          weight: 80
        - destination:
            host: productpage.bookinfo.svc.cluster.local
            port: { number: 9080 }
            subset: v2
          weight: 20
```

> On the edge, always use the **FQDN** for `destination.host`; short names resolve against the *gateway's* namespace, which is usually `istio-system`, not your app's namespace.

### 3.8 Automated progressive delivery (Flagger)

Manual weight-editing does not scale and is error-prone. Flagger watches SLO metrics and drives the `VirtualService` weights for you, promoting or rolling back automatically.

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: reviews
  namespace: bookinfo
spec:
  provider: istio
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: reviews                     # Flagger creates reviews-primary + reviews-canary
  progressDeadlineSeconds: 600
  service:
    port: 9080
    targetPort: 9080
    gateways: ["mesh"]
    hosts: ["reviews"]
  analysis:
    interval: 1m                      # evaluate metrics every minute
    threshold: 5                      # abort after 5 failed checks
    maxWeight: 50                     # ramp canary up to 50% before promoting
    stepWeight: 10                    # +10% each successful interval
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }   # abort if success rate < 99%
        interval: 1m
      - name: request-duration
        thresholdRange: { max: 500 }  # abort if p99 latency > 500ms
        interval: 1m
    webhooks:
      - name: load-test
        url: http://flagger-loadtester.bookinfo/
        timeout: 5s
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://reviews-canary.bookinfo:9080/"
```

Flagger generates `reviews-primary`/`reviews-canary` Deployments and owns the `VirtualService` — **do not hand-edit weights when Flagger is managing the object**; it will revert your change on the next reconcile.

---

## 4. CLI workflow with real terminal output

```console
$ istioctl version --short
client version: 1.24.1
control plane version: 1.24.1
data plane version: 1.24.1 (18 proxies)
```

Apply and confirm the CRDs:

```console
$ kubectl apply -f reviews-destinationrule.yaml -f reviews-virtualservice.yaml
destinationrule.networking.istio.io/reviews created
virtualservice.networking.istio.io/reviews created

$ kubectl -n bookinfo get virtualservice reviews -o jsonpath='{.spec.http[0].route[*].weight}{"\n"}'
90 10
```

Static config validation *before* trusting the split:

```console
$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.
```

A deliberately broken VS (subset `v2` not in the DestinationRule) is caught here:

```console
$ istioctl analyze -n bookinfo
Error [IST0101] (VirtualService reviews.bookinfo) Referenced host+subset in destinationrule not found:
  "reviews+v2"
Error: Analyzers found issues when analyzing namespace: bookinfo.
```

### Confirm istiod actually compiled the weights into the caller's Envoy

Pick the *caller* pod (e.g. `productpage`, which calls `reviews`), not the destination:

```console
$ POD=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config routes "$POD.bookinfo" --name 9080 -o json | \
    jq '.[].virtualHosts[] | select(.name|test("reviews")) | .routes[].route.weightedClusters'
{
  "clusters": [
    {
      "name": "outbound|9080|v1|reviews.bookinfo.svc.cluster.local",
      "weight": 90
    },
    {
      "name": "outbound|9080|v2|reviews.bookinfo.svc.cluster.local",
      "weight": 10
    }
  ],
  "totalWeight": 100
}
```

The two subset **clusters** must exist and each must have endpoints:

```console
$ istioctl proxy-config clusters "$POD.bookinfo" --fqdn reviews.bookinfo.svc.cluster.local
SERVICE FQDN                            PORT   SUBSET  DIRECTION  TYPE  DESTINATION RULE
reviews.bookinfo.svc.cluster.local      9080   -       outbound   EDS   reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080   v1      outbound   EDS   reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080   v2      outbound   EDS   reviews.bookinfo

$ istioctl proxy-config endpoints "$POD.bookinfo" --cluster \
    "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.1.37:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
10.244.2.19:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
10.244.3.44:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
```

### Empirically measure the split

Fire N requests from an in-mesh client and tally which version answered (the Bookinfo reviews pod echoes its version; substitute your own signal):

```console
$ for i in $(seq 1 100); do
    kubectl -n bookinfo exec deploy/ratings -c ratings -- \
      curl -s reviews:9080/reviews/0 | jq -r '.podname' ;
  done | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c
     91 reviews-v1
      9 reviews-v2
```

91/9 against a configured 90/10 — within expected variance for n=100. Live shift to 50/50:

```console
$ kubectl -n bookinfo patch virtualservice reviews --type merge -p \
  '{"spec":{"http":[{"route":[
     {"destination":{"host":"reviews","subset":"v1"},"weight":50},
     {"destination":{"host":"reviews","subset":"v2"},"weight":50}]}]}}'
virtualservice.networking.istio.io/reviews patched
```

No pods restarted; the new `weightedClusters` reach every sidecar within a couple of seconds.

### Watch Flagger drive a canary

```console
$ kubectl -n bookinfo describe canary reviews | sed -n '/Events/,$p'
Events:
  Type     Reason  Age    From     Message
  ----     ------  ----   ----     -------
  Normal   Synced  6m     flagger  New revision detected! Scaling up reviews.bookinfo
  Normal   Synced  5m     flagger  Starting canary analysis for reviews.bookinfo
  Normal   Synced  5m     flagger  Advance reviews.bookinfo canary weight 10
  Normal   Synced  4m     flagger  Advance reviews.bookinfo canary weight 20
  Normal   Synced  3m     flagger  Advance reviews.bookinfo canary weight 30
  Normal   Synced  2m     flagger  Advance reviews.bookinfo canary weight 40
  Normal   Synced  1m     flagger  Advance reviews.bookinfo canary weight 50
  Normal   Synced  30s    flagger  Copying reviews.bookinfo template spec to reviews-primary
  Normal   Synced  10s    flagger  Promotion completed! Scaling down reviews.bookinfo
```

An aborted rollout looks like this instead:

```console
  Warning  Synced  2m     flagger  Halt reviews.bookinfo advancement success rate 87.34% < 99%
  Warning  Synced  1m     flagger  Rolling back reviews.bookinfo failed checks threshold reached 5
  Warning  Synced  30s    flagger  Canary failed! Scaling down reviews.bookinfo
```

---

## 5. Verification and failure diagnosis

### The verification ladder

1. **Config parses & references resolve** → `istioctl analyze` (catches missing subsets, host typos, port-name mistakes — free, static).
2. **istiod compiled it** → `istioctl proxy-config routes` shows `weightedClusters` with your weights.
3. **Subset clusters have endpoints** → `istioctl proxy-config clusters` + `endpoints` show `HEALTHY`.
4. **Traffic actually splits** → curl loop tally *and* Prometheus by-version rate.
5. **Split is safe** → success-rate / latency SLIs per version.

### Prometheus verification (source of truth for automation)

Per-version request rate:

```promql
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local"
}[1m])) by (destination_version)
```

Per-version success rate (the metric Flagger gates on):

```promql
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local",
  response_code!~"5.."}[1m])) by (destination_version)
/
sum(rate(istio_requests_total{
  destination_service="reviews.bookinfo.svc.cluster.local"}[1m])) by (destination_version)
```

Per-version p99 latency:

```promql
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{
    destination_service="reviews.bookinfo.svc.cluster.local"}[1m]))
  by (le, destination_version))
```

Kiali renders the same data as a live graph with the weight labels on each edge — the fastest visual confirmation that traffic is flowing to both subsets in the configured ratio.

### Failure catalog

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| **All traffic to one version regardless of weights** | Port not named `http`/`http2`/`grpc` → treated as L4, `http` rules ignored | `istioctl proxy-config listeners` shows a TCP proxy, not an HTTP conn manager, on 9080 | Rename the Service port (or set `appProtocol: http`) and re-apply |
| **`503 UC` / `503 NR`** (no route / no cluster) | VS references a subset with no matching `DestinationRule` subset or no `Ready` pods | `istioctl analyze` → IST0101; `proxy-config endpoints` shows the subset cluster empty | Add the subset to the DR, or ensure pods carry the `version` label and are `Ready` |
| **`503 UH`** (no healthy upstream) | Outlier detection ejected all endpoints of a bad canary | `proxy-config endpoints` shows `OUTLIER CHECK: FAILED` | Set canary weight to 0; investigate the 5xx source |
| **Weights ignored, VS seems absent** | VS in wrong namespace, or `hosts`/`gateways` don't match the traffic | `proxy-config routes` shows no `weightedClusters` for the host | Put VS in the client-reachable namespace; for edge traffic bind `gateways:` and use FQDN + matching `hosts` |
| **A/B match never triggers** | Match rule ordered *after* the weighted catch-all (first match wins) | Inspect `http[]` order; catch-all with no `match` swallows everything above it | Move the `match` rule above the catch-all |
| **Split ratio wildly off configured %** | Consistent-hash LB with a skewed key, or too few requests | `DestinationRule.trafficPolicy.loadBalancer.consistentHash` present; low sample size | Use a higher-cardinality hash key, or increase sample size before judging |
| **Mirrored version causing data corruption / dupes** | Non-idempotent write path being shadowed | Check for `-shadow` suffixed `Host` in v2 logs | Shadow read paths only, or route mirror to a sandbox datastore |
| **Weights revert on their own** | Flagger/Argo owns the VirtualService and reconciled your manual edit away | `kubectl get canary`; ownerReferences on the VS | Change the rollout via the `Canary`/`Rollout` CR, not the VS |
| **Ambient: L7 weights have no effect** | No waypoint proxy for the destination; ztunnel is L4-only | `istioctl waypoint list` shows none for the namespace/service | `istioctl waypoint apply` and label the service to use it |

### Quick triage script

```console
$ CALLER=$(kubectl -n bookinfo get pod -l app=productpage -o name | head -1 | cut -d/ -f2)
$ echo "== analyze ==" && istioctl analyze -n bookinfo
$ echo "== routes ==" && istioctl pc routes "$CALLER.bookinfo" --name 9080 -o json \
    | jq '.[].virtualHosts[].routes[].route.weightedClusters'
$ echo "== endpoints v2 ==" && istioctl pc endpoints "$CALLER.bookinfo" \
    --cluster "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
```

If all three are green and traffic *still* misbehaves, the fault is in the application/data layer of the canary, not in the mesh routing — pivot to the per-version success-rate query.

---

## 6. References

- Istio — Traffic Management (concepts, VirtualService, DestinationRule): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — Traffic Shifting task (weighted canary walkthrough): https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio — Request Routing (subsets, match rules): https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio — Mirroring / shadow traffic task: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio — VirtualService API reference (`http`, `route`, `weight`, `mirror`, `mirrorPercentage`): https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — DestinationRule API reference (`subsets`, `trafficPolicy`, `loadBalancer`, `outlierDetection`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Gateway API reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — `istioctl proxy-config` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- Istio — `istioctl analyze` and configuration analysis messages (IST0101): https://istio.io/latest/docs/reference/config/analysis/
- Istio — Standard metrics (`istio_requests_total`, `istio_request_duration_milliseconds`): https://istio.io/latest/docs/reference/config/metrics/
- Istio — Ambient mesh, waypoint proxies and L7 policy: https://istio.io/latest/docs/ambient/usage/waypoint/
- Flagger — Istio Canary Deployments (progressive delivery): https://docs.flagger.app/tutorials/istio-progressive-delivery
- Flagger — Canary custom resource reference: https://docs.flagger.app/usage/how-it-works
- Argo Rollouts — Traffic management with Istio: https://argoproj.github.io/argo-rollouts/features/traffic-management/istio/
- CNCF — ICA curriculum (Traffic Management domain): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf