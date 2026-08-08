# Topic 1.3 — Customizing your Istio Installation
## Guided Exercises

> **Domain:** Istio Installation, Upgrade & Configuration · **Exam weight:** ~5%
> **What you will be able to do afterwards:** read a profile before applying it, express a full installation as a declarative `IstioOperator` manifest, reshape the generated Kubernetes objects with overlays, turn components on and off, tune the data-plane through `MeshConfig`, and detect configuration drift on both the `istioctl` and Helm paths.

**Mental model to hold throughout.** Every Istio install — whether you type `istioctl install`, apply an `IstioOperator`, or run `helm install` — is a *rendering pipeline*: a **profile** supplies defaults, your **overrides** are merged on top, and the result is a set of plain Kubernetes manifests. `istioctl install` = "render, then apply and reconcile"; `istioctl manifest generate` = "render, then print" (never touches the cluster). Customizing Istio is nothing more than controlling the inputs to that merge. Two override surfaces exist and they are *not* interchangeable:
> - **`spec.meshConfig`** and **`spec.components.*.k8s`** → the typed, first-class `IstioOperator` API.
> - **`spec.values`** → a passthrough to the underlying Helm chart values (`global.*`, `pilot.*`, …), used when the typed API has no field for what you need.

**A word on the operator.** The *in-cluster* IstioOperator controller (`istioctl operator init`) is **deprecated and removed** in current releases. The `IstioOperator` **API object** you pass to `istioctl install -f` is *not* deprecated — it remains the canonical way to describe a customized install. Do not confuse the two.

**Environment assumed:** a working `kubectl` context against a throwaway cluster (kind/minikube/k3d), and `istioctl` on `PATH` matching the control-plane version you intend to install. Commands show Istio `1.22.x`; adapt the version string to yours.

```bash
# Confirm your tooling before anything else
istioctl version --remote=false
# client version: 1.22.0
kubectl config current-context
# kind-ica-lab
```

Sources (official, current): Istio *Customizing the configuration* (https://istio.io/latest/docs/setup/additional-setup/customize-installation/), *Configuration profiles* (https://istio.io/latest/docs/setup/additional-setup/config-profiles/), *Installing with istioctl* (https://istio.io/latest/docs/setup/install/istioctl/), *Install with Helm* (https://istio.io/latest/docs/setup/install/helm/), the `IstioOperator` API reference (https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/) and the `MeshConfig` reference (https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/). Exam scope: CNCF ICA curriculum (https://github.com/cncf/curriculum).

---

## Exercise 1 — Read the profiles before you touch the cluster

A profile is a named bundle of defaults. Knowing what one *contains* — and how two differ — is the difference between an intentional install and a surprise.

1. List every profile shipped with your `istioctl`:

   ```bash
   istioctl profile list
   ```
   ```
   Istio configuration profiles:
       ambient
       default
       demo
       empty
       external
       minimal
       openshift
       preview
       remote
       stable
   ```

2. Dump the fully-resolved `default` profile to a file so you can read the effective values (not just your overrides — *everything* the profile sets):

   ```bash
   istioctl profile dump default > default-profile.yaml
   wc -l default-profile.yaml
   # 240 default-profile.yaml   (exact count varies by version)
   ```

3. Dump a single sub-tree instead of the whole document, using the config-path selector:

   ```bash
   istioctl profile dump --config-path components.egressGateways default
   ```
   ```yaml
   - enabled: false
     k8s:
       resources:
         requests:
           cpu: 100m
           memory: 128Mi
     name: istio-egressgateway
   ```

4. Diff two profiles to see exactly what changes between them:

   ```bash
   istioctl profile diff default demo
   ```
   ```
   The difference between profiles:
    components:
      egressGateways:
   -  - enabled: false
   +  - enabled: true
        name: istio-egressgateway
   ...
      values:
        global:
          proxy:
   -        resources:
   -          requests:
   -            cpu: 100m
   -            memory: 128Mi
   +        resources:
   +          requests:
   +            cpu: 10m
   +            memory: 40Mi
   ```

5. Render (do **not** apply) the manifests a profile would produce, then inspect them offline:

   ```bash
   istioctl manifest generate --set profile=demo > demo-manifest.yaml
   grep -c '^kind:' demo-manifest.yaml
   # 40
   grep '^kind:' demo-manifest.yaml | sort | uniq -c
   #   2 kind: Deployment
   #   1 kind: HorizontalPodAutoscaler
   #  12 kind: CustomResourceDefinition
   #   ...
   ```

**Comprehension questions**

- **Q1.1** What is the practical difference between `istioctl profile dump default` and `istioctl manifest generate --set profile=default`?
- **Q1.2** You run `istioctl profile diff default demo` and see `istio-egressgateway` flip from `enabled: false` to `true`, and the proxy CPU request drop from `100m` to `10m`. Which profile is meant for production and why?
- **Q1.3** Why is `manifest generate` the safest first command to run against a customization you are unsure about?

---

## Exercise 2 — Declarative install with an `IstioOperator` manifest

Typing `--set` flags is fine for a demo and terrible for reproducibility. Production installs live in a file, under version control.

1. Write `iop-control-plane.yaml`. It starts from `default`, adds two `meshConfig` behaviours, and sizes `istiod`:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     meshConfig:
       # Emit Envoy access logs to stdout (off by default in `default`)
       accessLogFile: /dev/stdout
       defaultConfig:
         # Block traffic until the sidecar is ready — avoids startup 503s
         holdApplicationUntilProxyStarts: true
     components:
       pilot:
         k8s:
           resources:
             requests:
               cpu: 500m
               memory: 2048Mi
           hpaSpec:
             minReplicas: 2
             maxReplicas: 5
     values:
       global:
         proxy:
           logLevel: warning
   ```

2. Render it first and confirm your overrides actually landed (never install blind):

   ```bash
   istioctl manifest generate -f iop-control-plane.yaml \
     | grep -A2 accessLogFile
   #     accessLogFile: /dev/stdout
   ```

3. Apply it. `istioctl install` is idempotent — running it again converges the cluster to the manifest, it does not stack duplicates:

   ```bash
   istioctl install -f iop-control-plane.yaml -y
   ```
   ```
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Installation complete
   ```

4. Verify the *rendered intent* matches what is *actually running* in the cluster:

   ```bash
   istioctl verify-install -f iop-control-plane.yaml
   ```
   ```
   ✔ Istiod pods are ready
   Checked 15 custom resource definitions
   Checked 1 Istio Deployments
   ✔ Istio is installed and verified successfully
   ```

5. Confirm the HPA and the effective mesh config landed:

   ```bash
   kubectl get hpa -n istio-system
   # NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS
   # istiod    Deployment/istiod    3%/80%    2         5         2

   kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' \
     | grep -E 'accessLogFile|holdApplication'
   # accessLogFile: /dev/stdout
   #   holdApplicationUntilProxyStarts: true
   ```

**Comprehension questions**

- **Q2.1** You installed with `profile: default` yet the manifest only lists `meshConfig`, `pilot`, and `values`. Where did the ingress gateway, CRDs, and `istiod` Deployment come from?
- **Q2.2** A teammate runs `istioctl install -f iop-control-plane.yaml -y` a second time by mistake. What happens to the cluster?
- **Q2.3** `holdApplicationUntilProxyStarts: true` fixes a specific class of failures. Describe the failure it prevents and the trade-off it introduces at pod startup.
- **Q2.4** Under which top-level key would you put `proxy.logLevel`, and why is it there rather than under `meshConfig`?

---

## Exercise 3 — Kubernetes overlays: sizing and hardening the ingress gateway

The `IstioOperator` typed API covers common knobs (`replicaCount`, `resources`, `hpaSpec`, `service`). When you need a field the API does **not** expose, you drop to a **raw Kubernetes overlay**: a JSON-patch-style edit applied to the generated object.

1. Extend the manifest so the ingress gateway is HA, exposes explicit ports, and — via an overlay — gets a `preStop` hook the typed API has no field for:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     components:
       ingressGateways:
       - name: istio-ingressgateway
         enabled: true
         k8s:
           replicaCount: 3
           resources:
             requests:
               cpu: 200m
               memory: 256Mi
             limits:
               cpu: "1"
               memory: 512Mi
           hpaSpec:
             minReplicas: 3
             maxReplicas: 10
             metrics:
             - type: Resource
               resource:
                 name: cpu
                 target:
                   type: Utilization
                   averageUtilization: 70
           service:
             type: LoadBalancer
             ports:
             - name: status-port
               port: 15021
               targetPort: 15021
             - name: http2
               port: 80
               targetPort: 8080
             - name: https
               port: 443
               targetPort: 8443
           # Raw overlay: the typed API has no `lifecycle` field
           overlays:
           - kind: Deployment
             name: istio-ingressgateway
             patches:
             - path: spec.template.spec.containers.[name:istio-proxy].lifecycle
               value:
                 preStop:
                   exec:
                     command: ["sleep", "5"]
   ```

2. Dry-run and prove the overlay merged into the rendered Deployment:

   ```bash
   istioctl manifest generate -f iop-ingress.yaml \
     | grep -A4 preStop
   #             preStop:
   #               exec:
   #                 command:
   #                 - sleep
   #                 - "5"
   ```

3. Apply and confirm the replica count and HPA target:

   ```bash
   istioctl install -f iop-ingress.yaml -y
   kubectl get deploy istio-ingressgateway -n istio-system
   # NAME                   READY   UP-TO-DATE   AVAILABLE
   # istio-ingressgateway   3/3     3            3

   kubectl get hpa istio-ingressgateway -n istio-system
   # NAME                   REFERENCE                         TARGETS   MINPODS   MAXPODS
   # istio-ingressgateway   Deployment/istio-ingressgateway   4%/70%    3         10
   ```

4. Inspect the overlay result directly on the live object:

   ```bash
   kubectl get deploy istio-ingressgateway -n istio-system \
     -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].lifecycle.preStop}'
   # {"exec":{"command":["sleep","5"]}}
   ```

**Comprehension questions**

- **Q3.1** When would you reach for `k8s.overlays` instead of a typed field like `k8s.resources` — and what is the maintenance risk of overlays that typed fields don't carry?
- **Q3.2** In the overlay path `spec.template.spec.containers.[name:istio-proxy].lifecycle`, what does the `[name:istio-proxy]` segment select, and why not just write `containers.0`?
- **Q3.3** The gateway `service.ports` map port `443` to `targetPort: 8443`, not `443`. Why does the Envoy sidecar listen on `8443` rather than binding `443` directly?

---

## Exercise 4 — Enabling, disabling, and multiplying components

Customization includes *removing* what you don't run and *adding* extra copies of what you do.

1. Turn the egress gateway off (it is on in `demo`, off in `default` — be explicit either way) and stand up a **second, internal-only** ingress gateway in its own namespace:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     components:
       egressGateways:
       - name: istio-egressgateway
         enabled: false
       ingressGateways:
       - name: istio-ingressgateway     # public, keep default
         enabled: true
       - name: internal-ingressgateway  # second gateway, internal LB
         enabled: true
         namespace: istio-system
         label:
           istio: internal-ingressgateway
         k8s:
           service:
             type: LoadBalancer
             ports:
             - name: http2
               port: 80
               targetPort: 8080
           serviceAnnotations:
             networking.gke.io/load-balancer-type: "Internal"
   ```

2. Generate and confirm the egress Deployment is **absent** and two ingress Deployments are **present**:

   ```bash
   istioctl manifest generate -f iop-components.yaml \
     | grep -E 'name: (istio-egressgateway|istio-ingressgateway|internal-ingressgateway)$'
   #   name: istio-ingressgateway
   #   name: internal-ingressgateway
   ```

3. Apply and verify both gateways plus the removal:

   ```bash
   istioctl install -f iop-components.yaml -y
   kubectl get deploy -n istio-system -l 'istio in (ingressgateway,internal-ingressgateway)'
   # NAME                       READY   UP-TO-DATE   AVAILABLE
   # internal-ingressgateway    1/1     1            1
   # istio-ingressgateway       1/1     1            1

   kubectl get deploy istio-egressgateway -n istio-system
   # Error from server (NotFound): deployments.apps "istio-egressgateway" not found
   ```

4. Prove the two gateways are independently selectable — their `istio` label differs, which is what a `Gateway` resource's selector will match:

   ```bash
   kubectl get pods -n istio-system -l istio=internal-ingressgateway
   # NAME                                       READY   STATUS
   # internal-ingressgateway-6b9c...            1/1     Running
   ```

**Comprehension questions**

- **Q4.1** Two ingress gateways run in the same namespace. What single piece of metadata lets a `Gateway` custom resource target one and not the other?
- **Q4.2** You removed the egress gateway. Does that *block* egress traffic from the mesh? Explain the difference between "no egress gateway deployed" and `outboundTrafficPolicy.mode: REGISTRY_ONLY`.
- **Q4.3** After the install in step 3, someone runs a *different* manifest that omits `internal-ingressgateway` entirely and applies it. Is the second gateway pruned, and what does that tell you about `istioctl install`'s reconciliation model?

---

## Exercise 5 — Tuning the mesh: `MeshConfig` and proxy defaults

`spec.meshConfig` is the single most consequential customization surface: it is the runtime configuration the whole data plane reads.

1. Layer several mesh-wide behaviours into one manifest:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     meshConfig:
       accessLogFile: /dev/stdout
       accessLogEncoding: JSON
       # Fail closed: only allow egress to services known to the registry
       outboundTrafficPolicy:
         mode: REGISTRY_ONLY
       enableAutoMtls: true
       defaultConfig:
         holdApplicationUntilProxyStarts: true
         # Sidecar concurrency = 2 worker threads
         concurrency: 2
         proxyStatsMatcher:
           inclusionRegexps:
           - ".*circuit_breakers.*"
           - ".*upstream_rq_retry.*"
   ```

2. Apply and read the resulting `istio` ConfigMap — this is the source of truth every sidecar pulls:

   ```bash
   istioctl install -f iop-mesh.yaml -y
   kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}'
   ```
   ```yaml
   accessLogEncoding: JSON
   accessLogFile: /dev/stdout
   defaultConfig:
     concurrency: 2
     holdApplicationUntilProxyStarts: true
     proxyStatsMatcher:
       inclusionRegexps:
       - .*circuit_breakers.*
       - .*upstream_rq_retry.*
   enableAutoMtls: true
   outboundTrafficPolicy:
     mode: REGISTRY_ONLY
   ```

3. Deploy a test workload, then confirm the *effective* proxy config on a running sidecar (not the mesh default — the merged, per-pod value):

   ```bash
   kubectl create namespace demo
   kubectl label namespace demo istio-injection=enabled
   kubectl run client --image=curlimages/curl -n demo --command -- sleep 3600
   kubectl wait --for=condition=Ready pod/client -n demo

   istioctl proxy-config bootstrap client.demo \
     | grep -i concurrency
   #   "concurrency": 2
   ```

4. Observe `REGISTRY_ONLY` in action — a call to an unknown external host is now blocked by design:

   ```bash
   kubectl exec -n demo client -- curl -sS -o /dev/null -w "%{http_code}\n" http://example.com
   # 502
   # (BlackHoleCluster — no ServiceEntry / egress rule permits it)
   ```

**Comprehension questions**

- **Q5.1** You changed `outboundTrafficPolicy.mode` to `REGISTRY_ONLY` and existing sidecars picked it up without a restart. Through what mechanism does a live sidecar learn about a `MeshConfig` change?
- **Q5.2** `defaultConfig.concurrency: 2` is a `ProxyConfig` setting, not a top-level `MeshConfig` setting. What is the difference in scope between `meshConfig.<field>` and `meshConfig.defaultConfig.<field>`?
- **Q5.3** The `client` pod got a sidecar automatically. Which one label made that happen, and where was it applied?
- **Q5.4** Give one production reason to narrow `proxyStatsMatcher` inclusions rather than leaving the full Envoy stats set exposed.

---

## Exercise 6 — The Helm path and drift detection

The Helm charts are the *same* rendering engine `istioctl` uses internally, exposed directly. Knowing both, and how to compare them, is exam-relevant and operationally essential.

1. Install the control plane with Helm, customizing through values. `base` (CRDs) first, then `istiod`:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   kubectl create namespace istio-system

   helm install istio-base istio/base -n istio-system --wait

   helm install istiod istio/istiod -n istio-system --wait \
     --set meshConfig.accessLogFile=/dev/stdout \
     --set pilot.resources.requests.cpu=500m \
     --set pilot.autoscaleMin=2
   ```
   ```
   NAME: istiod
   LAST DEPLOYED: ...
   STATUS: deployed
   ```

2. Install a gateway from its own chart, with a values file:

   ```yaml
   # ingress-values.yaml
   service:
     type: LoadBalancer
     ports:
     - name: http2
       port: 80
       targetPort: 8080
     - name: https
       port: 443
       targetPort: 8443
   autoscaling:
     enabled: true
     minReplicas: 2
     maxReplicas: 5
   ```
   ```bash
   kubectl create namespace istio-ingress
   helm install istio-ingressgateway istio/gateway \
     -n istio-ingress -f ingress-values.yaml --wait
   ```

3. Verify the Helm install with the same `istioctl` tool used for the operator path:

   ```bash
   istioctl verify-install
   # ✔ Istio is installed and verified successfully
   ```

4. Detect drift between what you *declared* and what is *running*. `manifest diff` compares two rendered manifests; `helm diff` (plugin) or `helm get values` shows applied Helm state:

   ```bash
   # What values are actually applied to the release?
   helm get values istiod -n istio-system
   # USER-SUPPLIED VALUES:
   # meshConfig:
   #   accessLogFile: /dev/stdout
   # pilot:
   #   autoscaleMin: 2
   #   resources:
   #     requests:
   #       cpu: 500m

   # Compare two candidate renderings before upgrading
   istioctl manifest generate --set profile=default > a.yaml
   istioctl manifest generate -f iop-mesh.yaml         > b.yaml
   istioctl manifest diff a.yaml b.yaml | head
   ```

**Comprehension questions**

- **Q6.1** Why must `istio/base` be installed (or its CRDs otherwise present) before `istio/istiod`?
- **Q6.2** On the Helm path a value is `meshConfig.accessLogFile`; on the `IstioOperator` path it is `spec.meshConfig.accessLogFile`. What does this tell you about how `istioctl install` and `helm install` relate under the hood?
- **Q6.3** Your team runs `helm install` for Istio but a colleague later runs `istioctl install -f iop.yaml` against the same cluster. Why is mixing the two management paths on one control plane a supportability hazard?
- **Q6.4** Which command answers "does the running cluster match my declared manifest?" and which answers "what would my new manifest change?"

---

## Answers

<details>
<summary>Click to reveal answers</summary>

**Q1.1** `profile dump` prints the fully-resolved **`IstioOperator` input** (the effective configuration values after profile defaults are applied) — YAML you could feed back into `install -f`. `manifest generate` runs that input through the rendering engine and prints the **Kubernetes objects** (Deployments, Services, CRDs, ConfigMaps) that would be applied. One is the *intent*, the other is the *output*. Neither touches the cluster.

**Q1.2** `default` is the production profile. `demo` enables the egress gateway, turns on more tracing/logging, and — critically — drops proxy resource requests to `10m` CPU / `40Mi` memory so it fits on a laptop; those requests are far too small to schedule or protect real traffic. `default` sizes `istiod` and proxies for a real cluster and enables only the ingress gateway plus the control plane. Rule of thumb: `demo` for learning, `minimal`/`default` (customized) for production.

**Q1.3** `manifest generate` is a pure function with **no side effects** — it renders to stdout without contacting the API server to apply anything. You can read the exact objects, `grep` for the field you changed, and diff against the current manifest, all before a single resource is created or mutated. It is the cheapest possible feedback loop for validating an override.

**Q2.1** From the `default` **profile**. `spec.profile: default` seeds the entire configuration with the profile's values; your `meshConfig`/`pilot`/`values` blocks are *merged on top* of that base. Anything you don't mention keeps the profile default — hence CRDs, `istiod`, and the ingress gateway appear even though your file never named them.

**Q2.2** Nothing changes. `istioctl install` is **idempotent** and reconciling: it renders the manifest and converges the cluster to that desired state. A second identical apply is a no-op — no duplicate Deployments, no stacked resources. (This is also why it is safe in CI.)

**Q2.3** Without it, the application container can start and send/receive traffic **before the Envoy sidecar has finished starting**, producing connection failures / `503`s during the race window (and, on shutdown, dropped in-flight requests). `holdApplicationUntilProxyStarts: true` makes the app container wait until the proxy reports ready. The trade-off: **slower pod startup** — every pod's readiness is gated on the sidecar, which lengthens rollouts and scale-ups.

**Q2.4** Under **`spec.values`** (`values.global.proxy.logLevel`). It is a **Helm chart value** with no dedicated typed field in the `IstioOperator` API, so it goes through the `values` passthrough. `meshConfig` is reserved for fields defined by the `MeshConfig`/`ProxyConfig` API; putting `logLevel` there would be rejected or ignored.

**Q3.1** Reach for `k8s.overlays` **only when the typed API exposes no field** for what you need (here, container `lifecycle`/`preStop`). Prefer typed fields whenever they exist. The maintenance risk: an overlay is a raw JSON patch bound to the *rendered structure* of the object. If a future Istio version renames a container, reorders fields, or restructures the Deployment, the overlay's `path` can silently stop matching — typed fields are version-stable and validated; overlays are not.

**Q3.2** `[name:istio-proxy]` is a **key-based selector** into the `containers` list: "the array element whose `name` field equals `istio-proxy`." You avoid `containers.0` because list *order is not guaranteed* — an injected init or extra container can shift indices, so `containers.0` might target the wrong container after a version bump, while the name selector is stable.

**Q3.3** Envoy runs as **non-root** inside the gateway pod, and binding to privileged ports (`<1024`, e.g. `443`) normally requires elevated capabilities. Istio instead has the container listen on unprivileged high ports (`8080`/`8443`) and lets the **Kubernetes `Service`** map the well-known external ports (`80`/`443`) to those `targetPort`s. The Service does the privileged-port exposure; the proxy stays unprivileged.

**Q4.1** The **`istio` label** on the gateway pods (`istio: istio-ingressgateway` vs `istio: internal-ingressgateway`). A `Gateway` custom resource's `spec.selector` matches pods by label, so distinct labels make the two gateways independently addressable even in one namespace.

**Q4.2** No — removing the egress **gateway Deployment** does not block egress. By default (`outboundTrafficPolicy.mode: ALLOW_ANY`) sidecars still let pods reach external hosts directly. The egress gateway is an *optional, dedicated exit point* for policy/observability, not an enforcement switch. Enforcement comes from **`outboundTrafficPolicy.mode: REGISTRY_ONLY`**, which makes sidecars drop traffic to any host not in the mesh registry (a `ServiceEntry` or known Service). The two are orthogonal: one is "is there an exit gateway," the other is "is unknown egress allowed."

**Q4.3** Yes — the second gateway is **pruned**. `istioctl install` is a full reconciler: it treats the applied `IstioOperator` as the *complete desired state* and removes owned resources that the new manifest no longer declares. The lesson: always apply the *entire* intended configuration; a partial manifest is a request to delete everything it omits, not to patch-in a delta.

**Q5.1** `istiod` **watches the `istio` ConfigMap**; when `MeshConfig` changes it recomputes the affected xDS configuration and **pushes the update to every connected sidecar over the xDS (gRPC) stream**. Sidecars apply it live — no pod restart needed for most `MeshConfig` fields. (Some `defaultConfig`/`ProxyConfig` changes that affect bootstrap do require a proxy restart.)

**Q5.2** Top-level `meshConfig.<field>` is **mesh-wide control-plane/data-plane behaviour** (e.g. `accessLogFile`, `outboundTrafficPolicy`, `enableAutoMtls`). `meshConfig.defaultConfig.<field>` is the **default `ProxyConfig`** — per-proxy settings (concurrency, stats matchers, tracing) that apply to every sidecar *but can be overridden per workload* via a `proxy.istio.io/config` pod annotation or a `ProxyConfig`/`Sidecar`-scoped resource. Scope: mesh-global vs per-proxy-default.

**Q5.3** The namespace label **`istio-injection=enabled`**, applied to the `demo` namespace. The sidecar-injector mutating webhook watches for that label and injects the Envoy sidecar into every new pod created there. (The revision-based equivalent is `istio.io/rev=<revision>`.)

**Q5.4** Envoy's full stats set is large and high-cardinality; scraping and storing all of it strains Prometheus (memory, series churn) and adds proxy overhead. Narrowing `proxyStatsMatcher` to the metrics you actually alert on (circuit breakers, retries, etc.) **cuts cardinality and cost** while keeping the signals that matter — a standard production hardening step.

**Q6.1** `istio/base` installs the **Istio CRDs** (and cluster-scoped resources). `istiod` and the config objects reference those CRDs; if the CRDs are absent when `istiod`'s resources are applied, the API server rejects the unknown kinds. CRDs must exist **before** the controllers and custom resources that depend on them — a hard ordering constraint, which is why `base` is a separate, first chart.

**Q6.2** They share the **same underlying Helm charts and value schema**. `istioctl install` renders those charts internally; `spec.values` in `IstioOperator` is a passthrough to the same values `helm install --set` sets. The parallel field names (`meshConfig.accessLogFile` either way) reveal that `istioctl` is a higher-level wrapper over the identical rendering engine — not a separate implementation.

**Q6.3** Because each path believes it **owns** the control-plane resources. `istioctl install` reconciles against its `IstioOperator` state; Helm reconciles against its release state and ownership annotations/labels. Running one after the other produces conflicting ownership, and a later `istioctl install` (full reconcile) or `helm upgrade` can prune or fight resources the other manages — leading to unexpected deletions and unsupportable state. Pick **one** management path per control plane and stay on it.

**Q6.4** `istioctl verify-install` (optionally `-f manifest.yaml`) answers **"does the running cluster match my declared manifest?"** — it checks live objects against the rendered intent. `istioctl manifest diff a.yaml b.yaml` answers **"what would my new manifest change?"** — it compares two *renderings* before you apply either. (`helm get values` / `helm diff` are the Helm-side equivalents for applied vs proposed state.)

</details>