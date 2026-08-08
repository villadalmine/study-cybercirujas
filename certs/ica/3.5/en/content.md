# 3.5 — Connecting In-Mesh Workloads to External Workloads and Services

> **Domain:** Advanced Scenarios · **Exam weight:** 5%
> **Prerequisites:** VirtualService / DestinationRule / Gateway (Traffic Management), PeerAuthentication and mesh mTLS (Securing Workloads).

This competency covers the *boundary of the mesh* in **both directions**:

1. **Outbound** — an in-mesh Pod calling something the mesh does not manage: a SaaS API, a managed database, a third-party HTTPS endpoint. The primitive is the **`ServiceEntry`**, optionally routed through an **egress `Gateway`**.
2. **Inbound onboarding** — a workload that does not run in Kubernetes (a VM, a bare-metal service) that you want to treat as a *first-class mesh member* — mTLS identity, load balancing, telemetry. The primitives are **`WorkloadGroup`** and **`WorkloadEntry`**, bound to a `ServiceEntry`.

---

## 1. The production problem

The mesh gives you identity, mTLS, retries, timeouts, circuit breaking, and golden-signal telemetry — but **only for traffic between registered endpoints**. Everything the sidecar cannot resolve in the internal service registry falls into one of two default fates:

- **`ALLOW_ANY` (the default `outboundTrafficPolicy.mode`)** — the sidecar ships a catch-all `PassthroughCluster`. Any egress to any host on the internet *just works* as an opaque TCP tunnel. Convenient, and a security auditor's nightmare: there is **no L7 visibility, no policy, no host allow-listing, and a wide-open data-exfiltration path**. A compromised Pod can `curl` an attacker's server and the mesh reports nothing but a byte count to `0.0.0.0`.
- **`REGISTRY_ONLY`** — anything not in the registry hits the `BlackHoleCluster` and fails closed. Secure, but now *every* legitimate external dependency must be explicitly declared. That declaration is the `ServiceEntry`.

The architectural decision is therefore: **fail-open convenience vs. fail-closed control**, and — once you choose control — *where* the control point lives:

- **Sidecar-local egress** — each workload's own Envoy originates TLS and enforces routing. Cheap, no extra hop, but the policy is distributed across every node and a compromised node with `NET_ADMIN` can bypass it.
- **Centralized egress gateway** — all egress is funneled through a dedicated set of Envoy proxies pinned to labeled nodes. This is what you need for **egress firewalling** (only the gateway nodes' egress IPs are allow-listed on the corporate firewall), **centralized TLS origination**, **egress audit logging**, and **compliance** (PCI-DSS §1.3, SOC2 network-egress controls).

The reverse problem — **VM/legacy onboarding** — exists because migrations are never atomic. You have a payments service on a VM that cannot move yet, but the new Kubernetes services calling it still deserve mTLS, mutual identity, and locality-aware load balancing. `WorkloadEntry` gives that VM a mesh SPIFFE identity and makes it addressable exactly like a Pod.

---

## 2. Concepts and comparative trade-offs

### 2.1 The `ServiceEntry` — the single extension point of the registry

A `ServiceEntry` adds hosts to Istio's internal service registry so the sidecars can build clusters/routes for them. Two axes dominate its behavior: **`location`** and **`resolution`**.

| `location` | Meaning | mTLS behavior | Typical use |
|---|---|---|---|
| `MESH_EXTERNAL` | Outside the mesh, not trusted | No Istio mTLS; TLS must be *originated* explicitly | SaaS APIs, public HTTPS, external DBs |
| `MESH_INTERNAL` | Part of the mesh, trusted | Istio mTLS applies (with `WorkloadEntry`) | VMs / non-K8s workloads onboarded to the mesh |

| `resolution` | How Envoy finds endpoints | Requires `endpoints`? | Notes |
|---|---|---|---|
| `NONE` | Passthrough to the original destination IP | No | L4 tunnel; SNI/host routing only, no LB |
| `STATIC` | Uses the IPs in `endpoints` (or `WorkloadEntry`) | Yes | VM onboarding, fixed IP backends |
| `DNS` | Envoy resolves each `hosts` entry via DNS, per-endpoint | No (uses `hosts`) | Standard for external FQDNs |
| `DNS_ROUND_ROBIN` | Resolves **once**, uses a single returned IP until it expires | No | Lower DNS load; good for a single stable A record (1.11+) |

> **Gotcha:** `resolution: NONE` gives you an opaque tunnel — you get telemetry on bytes and SNI, but you **cannot** do HTTP routing, retries, or TLS origination, because Envoy never terminates L7. If you want L7 features you need `DNS` (or `STATIC`) so Envoy owns real endpoints.

### 2.2 Egress control modes

| `meshConfig.outboundTrafficPolicy.mode` | Unknown host → | Security posture | Operational cost |
|---|---|---|---|
| `ALLOW_ANY` (default) | `PassthroughCluster` (works, opaque) | Weak — exfiltration open | Zero |
| `REGISTRY_ONLY` | `BlackHoleCluster` (502 / conn refused) | Strong — deny by default | Every dependency must be declared |

You can override this **per workload** with the `Sidecar` resource's `outboundTrafficPolicy`, letting you run `ALLOW_ANY` mesh-wide during migration while pinning sensitive namespaces to `REGISTRY_ONLY`.

### 2.3 Sidecar-local vs. egress gateway

| Dimension | Sidecar TLS origination | Egress gateway |
|---|---|---|
| Extra network hop | No | Yes (Pod → egress gw → external) |
| Firewall allow-list surface | Every node IP | Only egress-gw node IPs |
| Central audit / L7 logging | Per-Pod, scattered | One choke point |
| TLS/mTLS origination location | Each app's sidecar | Dedicated proxies |
| Blast radius of bypass | Any node | Isolated, dedicated nodes |
| Complexity | Low (1 `DestinationRule`) | High (`Gateway`+`VS`+2×`DR`+`Sidecar`) |
| Compliance fit (PCI/SOC2) | Poor | Strong |

> **Key exam point:** an egress gateway is **not a security boundary by itself**. A malicious workload can ignore the `VirtualService` and go direct unless you *also* (a) set `REGISTRY_ONLY`, (b) restrict egress with a `Sidecar` resource or Kubernetes `NetworkPolicy`, and (c) firewall the cluster so only the egress-gateway nodes can reach the internet.

### 2.4 TLS modes in `DestinationRule.trafficPolicy.tls`

| `mode` | Who initiates TLS | Client cert sent? | Use case |
|---|---|---|---|
| `DISABLE` | Nobody (plaintext) | No | Cleartext backend |
| `SIMPLE` | Istio (one-way TLS) | No | Originate TLS to a public HTTPS endpoint |
| `MUTUAL` | Istio (mTLS w/ your certs) | Yes (`credentialName` / files) | External service requiring client certs |
| `ISTIO_MUTUAL` | Istio using its own SPIFFE certs | Yes (mesh identity) | Sidecar → egress gateway leg |

### 2.5 External workload primitives

| Resource | Analogy | Purpose |
|---|---|---|
| `WorkloadEntry` | A `Pod` object | One non-K8s endpoint (VM): address, labels, `serviceAccount`, network |
| `WorkloadGroup` | A `Deployment`/template | Template + readiness probe enabling **auto-registration** of VMs |
| `ServiceEntry` (`MESH_INTERNAL`, `workloadSelector`) | A `Service` | Groups `WorkloadEntry` endpoints into an addressable host for in-mesh clients |

---

## 3. Complete, unabridged manifests

### 3.1 Fail closed, then declare an external dependency

Enable deny-by-default egress:

```yaml
# meshconfig-registry-only.yaml — applied via the IstioOperator/Helm values
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
    accessLogFile: /dev/stdout          # make egress denials observable
```

Declare an external HTTPS API so in-mesh Pods may reach it:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-payments-api
  namespace: prod
spec:
  hosts:
  - api.payments.example.com
  location: MESH_EXTERNAL
  ports:
  - number: 443
    name: https
    protocol: TLS          # TLS, not HTTPS: Envoy will not terminate, it tunnels by SNI
  resolution: DNS
  exportTo:
  - "."                    # visible only inside the prod namespace, not mesh-wide
```

### 3.2 Sidecar-local TLS origination (offload TLS from the app)

The application talks plain **HTTP on port 80**; the sidecar upgrades to **HTTPS on 443**:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: edition-cnn-com
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
    targetPort: 443        # sidecar connects to 443 upstream…
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80         # …and originates TLS on the port the app used
      tls:
        mode: SIMPLE
        sni: edition.cnn.com
```

### 3.3 Egress gateway with TLS origination (the production pattern)

Five objects: the `ServiceEntry` (external host), the `Gateway` (egress listener, mTLS from sidecars), a `DestinationRule` defining the *gateway subset* (sidecar→gateway leg uses `ISTIO_MUTUAL`), the `VirtualService` stitching mesh→gateway→external, and a `DestinationRule` that originates TLS to the external host.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: cnn
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: prod
spec:
  selector:
    istio: egressgateway          # matches the deployed egress gw Pods
  servers:
  - port:
      number: 443
      name: tls
      protocol: HTTPS
    hosts:
    - edition.cnn.com
    tls:
      mode: ISTIO_MUTUAL          # sidecars authenticate to the gateway with mesh identity
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
  namespace: prod
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: cnn
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 443
        tls:
          mode: ISTIO_MUTUAL      # leg 1: sidecar → egress gateway
          sni: edition.cnn.com
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway            # the Gateway above
  - mesh                           # the reserved keyword = all sidecars
  http:
  - match:
    - gateways:
      - mesh                       # leg 0: sidecar sees app request on port 80
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: cnn
        port:
          number: 443
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway        # leg 2: request arrives at the gateway on 443
      port: 443
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 443
      weight: 100
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE               # leg 3: egress gateway → external, real TLS origination
```

Restrict egress so workloads *cannot* bypass the gateway, closing the security gap noted in §2.3:

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: prod
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"                        # same namespace
    - "istio-system/*"            # control plane + egress gateway
```

### 3.4 mTLS origination to a service that requires client certs

Mount the client credentials as a Kubernetes secret and reference them by `credentialName` (served via SDS — no proxy restart):

```yaml
# kubectl create secret generic client-credential -n istio-system \
#   --from-file=tls.key=client.key \
#   --from-file=tls.crt=client.crt \
#   --from-file=ca.crt=ca.crt
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-mtls-for-partner
  namespace: prod
spec:
  host: api.partner.example.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: MUTUAL
        credentialName: client-credential   # must live where the proxy runs (egress gw ns)
        sni: api.partner.example.com
```

### 3.5 Onboarding a VM: `WorkloadGroup` + auto-registered `WorkloadEntry`

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: forecast
  namespace: forecast
spec:
  metadata:
    labels:
      app: forecast
      class: vm
  template:
    ports:
      http: 8080
    serviceAccount: forecast
    network: vm-network
  probe:
    periodSeconds: 5
    initialDelaySeconds: 1
    httpGet:
      port: 8080
      path: /healthz         # VM is only registered/Ready when this passes
```

Expose the VM endpoints to in-mesh clients as a stable host (note `MESH_INTERNAL` — mTLS applies):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: forecast
  namespace: forecast
spec:
  hosts:
  - forecast.forecast.svc.cluster.local
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
    targetPort: 8080
  resolution: STATIC
  workloadSelector:
    labels:
      app: forecast          # selects the auto-registered WorkloadEntry objects
```

A **manually** declared VM endpoint (no auto-registration) looks like this:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: forecast-vm-1
  namespace: forecast
spec:
  address: 10.128.0.13
  labels:
    app: forecast
    class: vm
  serviceAccount: forecast
  network: vm-network
  ports:
    http: 8080
  weight: 1
```

---

## 4. CLI workflow and real terminal output

### 4.1 Prove the fail-closed behavior

```console
$ export SOURCE_POD=$(kubectl get pod -n prod -l app=sleep -o jsonpath='{.items[0].metadata.name}')

# Before any ServiceEntry, with REGISTRY_ONLY — plain HTTP is black-holed:
$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL http://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
502

# HTTPS passthrough is refused at the TLS layer (curl exit 35 = SSL connect error):
$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL https://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
command terminated with exit code 35
```

After applying the `ServiceEntry` + egress gateway objects from §3.3:

```console
$ kubectl apply -f cnn-egress-gateway.yaml
serviceentry.networking.istio.io/cnn created
gateway.networking.istio.io/istio-egressgateway created
destinationrule.networking.istio.io/egressgateway-for-cnn created
virtualservice.networking.istio.io/direct-cnn-through-egress-gateway created
destinationrule.networking.istio.io/originate-tls-for-edition-cnn-com created

$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL http://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
200
```

### 4.2 Confirm the traffic actually traversed the egress gateway

```console
$ kubectl logs -n istio-system -l istio=egressgateway | tail -1
[2026-08-08T14:22:07.913Z] "GET /politics HTTP/2" 200 - via_upstream -
  "-" 0 1150631 412 411 "10.244.2.19"
  "curl/8.5.0" "b6f2a1c8-..." "edition.cnn.com"
  "outbound|443||edition.cnn.com" 10.244.1.4:41284 10.244.1.4:8443
  10.244.2.19:52180 edition.cnn.com -
```

The line proves both legs: the request entered the gateway (`:8443`) and the upstream cluster is `outbound|443||edition.cnn.com`.

### 4.3 Inspect the generated Envoy config

```console
$ istioctl proxy-config clusters "$SOURCE_POD.prod" | grep -E 'cnn|Passthrough|BlackHole'
edition.cnn.com                          443  -   outbound   DNS
BlackHoleCluster                         -    -   -          STATIC
# (No PassthroughCluster line — because outboundTrafficPolicy is REGISTRY_ONLY)

$ istioctl proxy-config endpoints deploy/istio-egressgateway -n istio-system \
    --cluster "outbound|443||edition.cnn.com"
ENDPOINT             STATUS   OUTLIER CHECK   CLUSTER
151.101.3.5:443      HEALTHY  OK              outbound|443||edition.cnn.com
151.101.67.5:443     HEALTHY  OK              outbound|443||edition.cnn.com
```

### 4.4 Onboard a VM end to end

```console
$ istioctl x workload group create \
    --name forecast --namespace forecast \
    --labels app=forecast --serviceAccount forecast \
    --network vm-network > workloadgroup.yaml
$ kubectl apply -f workloadgroup.yaml
workloadgroup.networking.istio.io/forecast created

# Generate the artifacts the VM needs to join the mesh:
$ istioctl x workload entry configure \
    --file workloadgroup.yaml \
    --output /tmp/vmfiles \
    --clusterID Kubernetes \
    --autoregister
Warning: a security token for namespace "forecast" and service account
"forecast" has been generated and stored at "/tmp/vmfiles/istio-token"
Configuration generation into directory /tmp/vmfiles was successful

$ ls /tmp/vmfiles
cluster.env  hosts  istio-token  mesh.yaml  root-cert.pem
```

Copy those to the VM, install the sidecar, then start it (`systemctl start istio`). Because `--autoregister` was used with a `WorkloadGroup`, the VM registers itself once its probe passes:

```console
$ kubectl get workloadentry -n forecast
NAME                                AGE   ADDRESS       
forecast-10.128.0.13-vm-network     47s   10.128.0.13   

$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -s http://forecast.forecast.svc.cluster.local:8080/api/v1/forecast
{"city":"buenos-aires","tempC":19,"served-by":"vm-10.128.0.13"}
```

Verify the VM leg is genuinely mTLS-encrypted (identity, not just reachability):

```console
$ istioctl x workload entry configure --help >/dev/null   # sanity: version has the subcommand
$ istioctl proxy-config secret "$SOURCE_POD.prod" -o json \
    | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
    X509v3 Subject Alternative Name: critical
        URI:spiffe://cluster.local/ns/prod/sa/sleep
```

---

## 5. Verification and failure diagnosis

**First reflex for any egress problem:** read the *source sidecar's* access log and the response flags, then confirm the config with `istioctl proxy-config`.

```console
$ kubectl logs -n prod "$SOURCE_POD" -c istio-proxy | tail -3
```

| Symptom / signal | Likely cause | Confirm | Fix |
|---|---|---|---|
| `502` on external HTTP, cluster `BlackHoleCluster` in log | `REGISTRY_ONLY` and no `ServiceEntry` for the host | `istioctl pc clusters $POD \| grep <host>` returns nothing | Add a `ServiceEntry` (or scope with `exportTo`) |
| curl **exit 35** to an HTTPS host | Same as above, but at TLS passthrough | log shows no route for SNI | Declare the host with `protocol: TLS`/`HTTPS` |
| Response flag **`NR`** (no route) | `VirtualService`/route mismatch (wrong port or gateway match) | `istioctl pc routes $POD` | Fix the `match.port`/`gateways` block |
| Response flag **`UH`** (no healthy upstream) | Endpoints unresolved | `istioctl pc endpoints` empty | `resolution: DNS` for FQDN, or fix `WorkloadEntry` address |
| Double-encrypted / TLS handshake garbage | App **already** does HTTPS *and* `DestinationRule` originates TLS again | app sends to `:443` not `:80` | Point the app at the HTTP port; originate on that port only |
| Egress gateway ignored, traffic goes direct | Missing `mesh` gateway match, or no `Sidecar`/`REGISTRY_ONLY` lockdown | log shows `outbound|…|<host>` on the *app* sidecar, not the gw | Add the `mesh` match leg **and** `REGISTRY_ONLY` + `Sidecar egress` |
| `credentialName` secret not found | Secret in the wrong namespace | egress gw error log `SDS: failed to fetch` | Put the secret in the **proxy's** namespace (`istio-system`) |
| VM `WorkloadEntry` never appears | Probe failing or token expired | `kubectl get we -n <ns>` empty; VM `istio-proxy` logs | Fix `probe`, re-copy `istio-token` |
| VM reachable but plaintext (no mTLS) | `ServiceEntry` is `MESH_EXTERNAL` | traffic works but no SPIFFE SAN | Set `location: MESH_INTERNAL` |

**Scope pitfalls worth memorizing:**

- **`exportTo`** on a `ServiceEntry`/`DestinationRule`: `"."` = current namespace only, `"*"` = mesh-wide (default). A `ServiceEntry` that "works in dev but not in prod" is almost always an `exportTo` mismatch.
- A `Sidecar` `egress.hosts` list that omits `istio-system/*` will break sidecar→egress-gateway and control-plane traffic.
- `resolution: NONE` **cannot** carry a `DestinationRule` TLS origination — Envoy has no cluster endpoints to originate against. Switch to `DNS`.

**Ambient-mode note:** in ambient dataplane, `ServiceEntry` still registers external hosts, but egress originates from the **waypoint proxy** (for L7) or **ztunnel** (L4); there is no per-Pod egress sidecar, and the `istio-egressgateway` pattern is replaced by a namespace/service **waypoint**. The `WorkloadEntry`/`WorkloadGroup` model is unchanged.

---

## 6. References

- Istio — *Accessing External Services* (`outboundTrafficPolicy`, `ServiceEntry`): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — *Egress TLS Origination* (sidecar-local): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio — *Egress Gateway TLS Origination*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
- Istio — *Egress Gateways*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
- Istio — *Use an egress gateway to enforce egress traffic* (`Sidecar`, `REGISTRY_ONLY`): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — `ServiceEntry` API reference (`location`, `resolution`, `exportTo`, `workloadSelector`): https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio — `WorkloadEntry` API reference: https://istio.io/latest/docs/reference/config/networking/workload-entry/
- Istio — `WorkloadGroup` API reference: https://istio.io/latest/docs/reference/config/networking/workload-group/
- Istio — `Sidecar` API reference (`egress`, `outboundTrafficPolicy`): https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — `DestinationRule` `ClientTLSSettings` (TLS modes): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — *Virtual Machine Installation* (VM onboarding, `istioctl x workload`): https://istio.io/latest/docs/setup/install/virtual-machine/
- Istio — *Bookinfo with a Virtual Machine* (auto-registration walkthrough): https://istio.io/latest/docs/examples/virtual-machines/
- Istio — *Ambient egress / waypoints*: https://istio.io/latest/docs/ambient/usage/
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf