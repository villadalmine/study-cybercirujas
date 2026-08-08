# Exercises — 3.5 Connecting In-Mesh Workloads to External Workloads and Services

> **Scope.** These guided labs take an in-mesh client (a sidecar-injected pod) and progressively connect it to workloads that live *outside* the mesh: public HTTP/TLS endpoints, TLS-originated services, traffic funneled through a dedicated egress gateway, and finally a non-Kubernetes (VM) workload joined to the mesh. You will register external endpoints in Istio's service registry, lock egress down, and expose an external workload as a first-class mesh service.
>
> **Estimated time:** 60–90 min · **Exam weight:** 5

## Lab prerequisites

- A Kubernetes cluster (kind/minikube/managed) with `kubectl` context set.
- `istioctl` matching your control-plane version (`istioctl version`).
- Istio installed with the `demo` profile (it ships the egress gateway you need in Exercise 4):

```bash
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite
```

Verify the egress gateway exists — several later steps depend on it:

```bash
kubectl get deploy -n istio-system
```

```
NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
istio-egressgateway     1/1     1            1           40s
istio-ingressgateway    1/1     1            1           40s
istiod                  1/1     1            1           55s
```

> Sources: [Istio install profiles](https://istio.io/latest/docs/setup/additional-setup/config-profiles/) · [Accessing external services](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/)

---

## Exercise 1 — Register an external service with a `ServiceEntry`

The mesh only knows about hosts in its service registry. `ServiceEntry` adds an external host to that registry so Envoy sidecars can route to it and Istio can apply routing, retries, timeouts, and telemetry — even though the destination is outside the cluster.

1. Deploy the `curl` sample as your in-mesh client and capture its pod name:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/curl/curl.yaml
export SOURCE_POD=$(kubectl get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$SOURCE_POD"
```

```
NAME                    READY   STATUS    RESTARTS   AGE
curl-7b549f5c4-2m9pn    2/2     Running   0          20s
```

> The `2/2` confirms the sidecar (`istio-proxy`) was injected alongside the `curl` container. If you run an older Istio, the equivalent sample is `samples/sleep/sleep.yaml` with `app=sleep`.

2. Confirm the sidecar does **not** yet have a cluster for `httpbin.org`:

```bash
istioctl proxy-config cluster "$SOURCE_POD" --fqdn httpbin.org
```

```
SERVICE FQDN     PORT     SUBSET     DIRECTION     TYPE     DESTINATION RULE
```

*(empty — the host is unknown to this proxy)*

3. Reach the external host anyway and note it still works:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.org/get
```

```
200
```

4. Create a `ServiceEntry` so the host becomes a registered, first-class mesh destination:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-ext
spec:
  hosts:
    - httpbin.org
  ports:
    - number: 80
      name: http
      protocol: HTTP
    - number: 443
      name: https
      protocol: TLS
  location: MESH_EXTERNAL
  resolution: DNS
```

```bash
kubectl apply -f httpbin-se.yaml
istioctl proxy-config cluster "$SOURCE_POD" --fqdn httpbin.org
```

```
SERVICE FQDN     PORT     SUBSET     DIRECTION     TYPE     DESTINATION RULE
httpbin.org      80       -          outbound      STRICT_DNS
httpbin.org      443      -          outbound      STRICT_DNS
```

**Comprehension check**

- **Q1.** In step 3 the request to `httpbin.org` returned `200` *before* any `ServiceEntry` existed. What mesh-wide setting made that possible, and what would break if you flipped it?
- **Q2.** The `ServiceEntry` uses `location: MESH_EXTERNAL` and `resolution: DNS`. What does each field tell the sidecar to do?
- **Q3.** Why does adding the `ServiceEntry` matter even though connectivity already worked? Name two capabilities you gain.

---

## Exercise 2 — Lock down egress with `REGISTRY_ONLY`

The default outbound policy (`ALLOW_ANY`) lets pods reach *any* external address — convenient, but the opposite of least-privilege. Switching to `REGISTRY_ONLY` blocks everything the registry doesn't know, turning `ServiceEntry` into an allow-list.

1. Inspect the current outbound traffic policy:

```bash
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | grep -A1 outboundTrafficPolicy
```

If nothing prints, the mode is the implicit default `ALLOW_ANY`.

2. Switch the mesh to `REGISTRY_ONLY`:

```bash
istioctl install --set profile=demo \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
```

3. Try an external host that has **no** `ServiceEntry`:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://example.com
```

```
000
command terminated with exit code 56
```

> Envoy has no cluster for `example.com`, so the request is routed to the built-in `BlackHoleCluster` and reset. Exit code `56` / HTTP `000` is the fingerprint of a registry-blocked egress.

4. Confirm the host you registered in Exercise 1 still works:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.org/get
```

```
200
```

5. Prove the block is registry-driven by adding `example.com`:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: example-ext
spec:
  hosts:
    - example.com
  ports:
    - number: 80
      name: http
      protocol: HTTP
  location: MESH_EXTERNAL
  resolution: DNS
```

```bash
kubectl apply -f example-se.yaml
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://example.com
```

```
200
```

**Comprehension check**

- **Q4.** Describe the exact path a request to an unregistered host takes under `REGISTRY_ONLY`. What Envoy cluster handles it, and how does that differ from a route to a `PassthroughCluster`?
- **Q5.** A teammate says "`REGISTRY_ONLY` is a firewall." Why is that only partially true — what layer is actually enforcing it, and how could a workload bypass it if it were *not* in the mesh?

---

## Exercise 3 — Originate TLS at the sidecar

Applications often speak plain HTTP internally while the external endpoint requires HTTPS. Instead of embedding TLS in the app, let the sidecar *originate* TLS: the app sends HTTP to port 80, and Envoy upgrades it to HTTPS on the wire.

1. Register the external host, declaring an HTTP port that is redirected to the TLS port:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: edition-cnn-com
spec:
  hosts:
    - edition.cnn.com
  ports:
    - number: 80
      name: http-port
      protocol: HTTP
      targetPort: 443
    - number: 443
      name: https-port
      protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
```

2. Add a `DestinationRule` that tells the sidecar to originate TLS for traffic arriving on port 80:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: edition-cnn-com
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 80
        tls:
          mode: SIMPLE
          sni: edition.cnn.com
```

```bash
kubectl apply -f cnn-se.yaml -f cnn-dr.yaml
```

3. Send **plain HTTP** on port 80 and observe a successful HTTPS fetch:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sSL -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
```

```
200
```

4. Confirm the app never sent TLS itself — the sidecar did. Watch that a raw `https://` call on the app side is unnecessary and that the `targetPort` mapping did the redirect:

```bash
istioctl proxy-config listener "$SOURCE_POD" --port 80 -o json | grep -i sni
```

```
"sni": "edition.cnn.com"
```

**Comprehension check**

- **Q6.** The app connects to `http://edition.cnn.com` on port 80, yet the connection to CNN is HTTPS. Trace how the request is transformed. What role does `targetPort: 443` play, and what does `tls.mode: SIMPLE` add?
- **Q7.** When would you set `tls.mode: MUTUAL` instead of `SIMPLE` in this `DestinationRule`, and what extra configuration would that require?

---

## Exercise 4 — Funnel egress through an egress gateway

A `ServiceEntry` lets *any* node's sidecar egress directly. Regulated environments often require all outbound traffic to leave through a small set of controlled, monitorable nodes. The egress gateway is a dedicated Envoy at the mesh edge that all egress is forced through.

1. Define a `Gateway` on the egress deployment for the target host:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - edition.cnn.com
```

2. Create a `DestinationRule` subset for the egress gateway, and a `VirtualService` that steers mesh traffic to the gateway, then out to CNN:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
    - name: cnn
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
spec:
  hosts:
    - edition.cnn.com
  gateways:
    - istio-egressgateway
    - mesh
  http:
    - match:
        - gateways:
            - mesh
          port: 80
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: cnn
            port:
              number: 80
          weight: 100
    - match:
        - gateways:
            - istio-egressgateway
          port: 80
      route:
        - destination:
            host: edition.cnn.com
            port:
              number: 80
          weight: 100
```

```bash
kubectl apply -f egress-gw.yaml -f egress-vs.yaml
```

3. Generate traffic, then confirm it actually transited the egress gateway by reading the gateway's logs:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sSL -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
kubectl logs -n istio-system -l istio=egressgateway --tail=1
```

```
200
[2026-08-08T12:41:07.512Z] "GET /politics HTTP/1.1" 301 - via_upstream - "-" 0 887 42 41 "10.244.0.14" "curl/8.5.0" "..." "edition.cnn.com" "151.101.65.67:80" outbound|80||edition.cnn.com ...
```

> A log line on the egress gateway proves the hop happened. No line means your `VirtualService` `match` on `gateways: [mesh]` didn't catch the sidecar's traffic.

**Comprehension check**

- **Q8.** The `VirtualService` lists two `gateways` (`mesh` and `istio-egressgateway`) and two `http` match blocks. Explain what each block routes and why *both* are required for a single logical flow.
- **Q9.** The `mesh` reserved gateway keyword appears in the first match. What does `mesh` represent, and what would happen to the sidecar→egress hop if you removed it from the `gateways` list?
- **Q10.** The egress gateway improves control, but a pod could still `curl` CNN directly and skip the gateway. What single change (covered earlier) makes the egress gateway *mandatory* rather than optional?

---

## Exercise 5 — Join a non-Kubernetes workload with `WorkloadEntry` / `WorkloadGroup`

The reverse direction: bring an external workload (a VM, a bare-metal host) *into* the mesh so in-mesh pods address it like any Service, with mTLS identity and telemetry. `WorkloadEntry` declares one instance; `WorkloadGroup` is the template that auto-registers many.

1. Create a namespace and service account for the VM identity:

```bash
kubectl create namespace vm-ns
kubectl create serviceaccount vm-sa -n vm-ns
```

2. Declare a single external instance with a `WorkloadEntry`:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: vmapp-1
  namespace: vm-ns
spec:
  address: 10.10.0.42
  labels:
    app: vmapp
    class: vm
  serviceAccount: vm-sa
  network: vm-network
```

3. Front the workload with a `ServiceEntry` whose `workloadSelector` matches the entry's labels, exposing it as an internal mesh service:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: vmapp-svc
  namespace: vm-ns
spec:
  hosts:
    - vmapp.vm-ns.svc.cluster.local
  location: MESH_INTERNAL
  ports:
    - number: 80
      name: http
      protocol: HTTP
      targetPort: 8080
  resolution: STATIC
  workloadSelector:
    labels:
      app: vmapp
```

```bash
kubectl apply -f vm-workloadentry.yaml -f vm-serviceentry.yaml
```

4. From an in-mesh pod, call the VM-backed host as if it were a normal service:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://vmapp.vm-ns.svc.cluster.local
```

```
200
```

5. For fleets, generate the config bundle from a `WorkloadGroup` instead of hand-writing each entry:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: vmapp
  namespace: vm-ns
spec:
  metadata:
    labels:
      app: vmapp
      class: vm
  template:
    ports:
      http: 8080
    serviceAccount: vm-sa
    network: vm-network
  probe:
    httpGet:
      path: /ready
      port: 8080
```

```bash
kubectl apply -f vm-workloadgroup.yaml
istioctl x workload entry configure \
  -f vm-workloadgroup.yaml \
  -o /tmp/vm-files --autoregister
ls /tmp/vm-files
```

```
cluster.env  hosts  istio-token  mesh.yaml  root-cert.pem
```

> These files are copied to the VM; the VM runs the Istio sidecar, presents `istio-token` for its `vm-sa` identity, and — because of `--autoregister` — a `WorkloadEntry` is *created automatically* on connect and removed when the VM disconnects. `class: vm` in `spec.metadata.labels` is inherited by every auto-registered instance.

**Comprehension check**

- **Q11.** The VM `ServiceEntry` uses `location: MESH_INTERNAL` and `resolution: STATIC`, whereas the httpbin one in Exercise 1 used `MESH_EXTERNAL` and `DNS`. Explain each difference and its consequence for mTLS.
- **Q12.** How does the `ServiceEntry`'s `workloadSelector` connect it to the `WorkloadEntry`? What ties them together, and what would a stray/mismatched label cause?
- **Q13.** Contrast `WorkloadEntry` and `WorkloadGroup`. When you run `istioctl x workload entry configure ... --autoregister`, which object is the template and which is the runtime artifact, and who creates the latter?
- **Q14.** The VM presents `istio-token` to obtain its identity. Whose identity does it assume, and where in the manifests was that decided?

---

## Answers

<details>
<summary>Show answers</summary>

**Q1.** The default `meshConfig.outboundTrafficPolicy.mode` is `ALLOW_ANY`. Under it, traffic to unknown hosts is handled by Envoy's `PassthroughCluster`, which forwards to the original destination without a registry entry. Flipping it to `REGISTRY_ONLY` (Exercise 2) makes that same request fail — only registry-known hosts remain reachable.

**Q2.** `location: MESH_EXTERNAL` marks the host as *outside* the mesh: Istio will not attempt mTLS to it and treats it as a plain external client from a policy standpoint. `resolution: DNS` tells the sidecar to resolve the host's IP(s) itself via DNS at request time (Envoy `STRICT_DNS`), rather than being given static IPs. Together they mean "external host, discovered by DNS."

**Q3.** Registering the host promotes it from opaque pass-through traffic to a modeled destination. Two concrete gains: (1) Istio telemetry now attributes metrics/traces to `httpbin.org` instead of lumping it into `PassthroughCluster`; (2) you can attach `VirtualService`/`DestinationRule` policy — timeouts, retries, circuit breaking, TLS origination, egress-gateway routing — none of which apply to pass-through traffic. It is also the prerequisite for `REGISTRY_ONLY`.

**Q4.** Under `REGISTRY_ONLY`, a request to an unregistered host has no matching Envoy cluster, so the listener routes it to the built-in `BlackHoleCluster`, which immediately resets/denies the connection (curl exit 56, HTTP `000`). This is the opposite of `ALLOW_ANY`, where the same request would hit the `PassthroughCluster` and be forwarded transparently to its original destination.

**Q5.** It is enforced at L7/L4 by the *sidecar Envoy* configured from the registry — not by a network firewall. So it only governs workloads that actually have a sidecar and whose traffic is captured by Istio's iptables/CNI redirection. A pod without injection (or one that escapes redirection) is not subject to it at all; for a true perimeter you still need `NetworkPolicy`/firewall/egress-gateway-plus-network-controls. `REGISTRY_ONLY` is an application-mesh allow-list, not a substitute for network security.

**Q6.** The app opens plain HTTP to `edition.cnn.com:80`. The `ServiceEntry` maps that port's `targetPort` to `443`, so Envoy actually dials the upstream on 443. The `DestinationRule` `tls.mode: SIMPLE` (with `sni`) then makes Envoy originate a one-way TLS handshake to CNN on that connection. Net effect: HTTP in from the app, HTTPS out to the internet — the sidecar performed the TLS upgrade, the app stayed TLS-unaware. `SIMPLE` = server-auth TLS (client validates the server cert); `targetPort: 443` = which upstream port to actually connect to.

**Q7.** Use `MUTUAL` when the external service requires client-certificate authentication (mTLS to a partner API, for example). That requires supplying the client credentials to the `DestinationRule` — `clientCertificate`, `privateKey`, and `caCertificates` (file paths mounted into the proxy, or a `credentialName` referencing a Kubernetes secret). `SIMPLE` needs none of these because only the server is authenticated.

**Q8.** The two blocks are the two hops of one flow. Block 1 matches `gateways: [mesh]` (traffic from application sidecars) on port 80 and routes it to the egress gateway's `cnn` subset. Block 2 matches `gateways: [istio-egressgateway]` (traffic *arriving at* the egress gateway) on port 80 and routes it out to `edition.cnn.com`. Both are required because the `VirtualService` must describe sidecar→gateway *and* gateway→internet; omitting either breaks that leg.

**Q9.** `mesh` is the reserved keyword for all sidecars in the mesh (every injected workload's Envoy). It's how a `VirtualService` targets east-west/egress traffic originating from application sidecars rather than from a named gateway. Remove it and block 1 no longer matches sidecar traffic, so pods keep going *directly* to CNN — the egress gateway is bypassed entirely and its log stays empty.

**Q10.** Set `outboundTrafficPolicy.mode: REGISTRY_ONLY` (Exercise 2). With direct egress blocked by the registry, the only permitted path to CNN is the one the `VirtualService` defines *through* the egress gateway, making the gateway mandatory. (Belt-and-suspenders in production: also enforce at the network layer so nodes can only reach the internet from the egress gateway's egress IPs.)

**Q11.** `MESH_INTERNAL` declares the workload as part of the mesh, so Istio issues/expects a SPIFFE identity and can do mTLS to it — the VM is a peer, not a foreign endpoint (contrast `MESH_EXTERNAL`, where no mTLS identity is assumed). `resolution: STATIC` means the endpoints are the explicit addresses supplied by matching `WorkloadEntry` objects, not DNS-resolved — appropriate because a VM's identity/labels, not a hostname lookup, define the backend. `DNS` would have Envoy resolve a name instead of using the declared `WorkloadEntry` addresses.

**Q12.** The `ServiceEntry.spec.workloadSelector.labels` (`app: vmapp`) is matched against the labels on `WorkloadEntry` objects in the same namespace. Any `WorkloadEntry` carrying `app: vmapp` becomes a backend endpoint of that `ServiceEntry`. A mismatched or missing label means the `WorkloadEntry` is never selected, so the service has zero endpoints and calls fail (no healthy upstream) — even though both objects exist.

**Q13.** `WorkloadEntry` is the *runtime artifact*: one row in the registry representing a single external instance (address, labels, identity). `WorkloadGroup` is the *template* describing how instances of a logical group look (labels, ports, service account, readiness probe). `istioctl x workload entry configure --autoregister` bootstraps a VM against the group; when that VM connects to istiod it auto-*creates* its own `WorkloadEntry` (and deletes it on disconnect). So the group is authored by you; the entry is created by the control plane at connect time.

**Q14.** It assumes the `vm-sa` ServiceAccount identity in `vm-ns` — i.e., its SPIFFE ID is `spiffe://<trust-domain>/ns/vm-ns/sa/vm-sa`. That was decided by `serviceAccount: vm-sa` in the `WorkloadEntry`/`WorkloadGroup` (and the SA created in step 1). The `istio-token` is a bound token for that SA, which the VM's sidecar presents to istiod to obtain workload certificates.

</details>

> **Cleanup:** `kubectl delete serviceentry,destinationrule,virtualservice,gateway,workloadentry,workloadgroup --all -A` and, if you changed it, revert `outboundTrafficPolicy` to `ALLOW_ANY`.
>
> **References:** [ServiceEntry](https://istio.io/latest/docs/reference/config/networking/service-entry/) · [Egress control](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/) · [Egress TLS origination](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/) · [Egress gateway](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/) · [WorkloadEntry](https://istio.io/latest/docs/reference/config/networking/workload-entry/) · [WorkloadGroup](https://istio.io/latest/docs/reference/config/networking/workload-group/) · [Virtual Machine installation](https://istio.io/latest/docs/setup/install/virtual-machine/)