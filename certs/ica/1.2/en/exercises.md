# Guided Exercises — Topic 1.2: Installing Istio in Sidecar or Ambient Mode

> **Target certification:** Istio Certified Associate (ICA)
> **Prerequisites:** A running Kubernetes cluster (v1.28+ recommended), `kubectl` configured against it, and cluster-admin privileges. A local `kind` or `k3d` cluster is sufficient for every exercise below.
> **Convention:** Wherever you see `1.24.0`, substitute the Istio release you actually downloaded. Pin the version explicitly in production — never let a script float to `latest`.

Each exercise is a numbered sequence you execute against a live cluster, followed by comprehension questions. All answers are in the collapsible section at the end.

---

## Exercise 1 — Obtain `istioctl` and run the pre-install check

The single most common ICA-adjacent mistake is installing onto a cluster that silently fails a prerequisite (missing CRD support, an admission webhook conflict, an incompatible Kubernetes version). `istioctl` ships a precheck for exactly this.

**Steps**

1. Download the release and put `istioctl` on your `PATH`:

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -
   cd istio-1.24.0
   export PATH="$PWD/bin:$PATH"
   ```

2. Confirm the client is present and note that the control plane is *not* yet installed:

   ```bash
   istioctl version
   ```

   Expected output (the control plane line is the key signal):

   ```
   client version: 1.24.0
   control plane version: 1.24.0
   no ready Istio pods in "istio-system"
   ```

3. Run the pre-installation validation against your current kube-context:

   ```bash
   istioctl x precheck
   ```

   Expected output on a healthy cluster:

   ```
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

4. List the built-in configuration profiles so you know what you are choosing between:

   ```bash
   istioctl profile list
   ```

   Expected output:

   ```
   Istio configuration profiles:
       ambient
       default
       demo
       empty
       minimal
       openshift
       openshift-ambient
       preview
       remote
       stambient
   ```

**Comprehension questions**

- **Q1.1** In step 2, `istioctl version` reported a `control plane version` even though nothing is installed. What is that line actually telling you, and why does it *not* mean Istio is running?
- **Q1.2** What is the practical difference between the `default` profile and the `demo` profile, and why should you never use `demo` in production?
- **Q1.3** Why is `istioctl x precheck` a distinct step from `istioctl verify-install`? At what point in the lifecycle does each one belong?

---

## Exercise 2 — Install the sidecar data plane with `istioctl`

Sidecar mode is the classic Istio architecture: an Envoy proxy is injected as an extra container into every application Pod, and it intercepts all inbound/outbound traffic for that Pod.

**Steps**

1. Install using the `default` profile (production-shaped: `istiod` + an ingress gateway, no egress gateway, no demo-grade tracing):

   ```bash
   istioctl install --set profile=default -y
   ```

   Expected output:

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ Ingress gateways installed 🛬
   ✔ Installation complete
   Made this installation the default for cluster-wide operations.
   ```

2. Inspect what was actually created in the control-plane namespace:

   ```bash
   kubectl get pods -n istio-system
   ```

   Expected output:

   ```
   NAME                                    READY   STATUS    RESTARTS   AGE
   istio-ingressgateway-6b8d9f7c5-fghij    1/1     Running   0          58s
   istiod-5f6b8d9c7-klmno                  1/1     Running   0          75s
   ```

3. Confirm the mutating admission webhook that performs sidecar injection is registered:

   ```bash
   kubectl get mutatingwebhookconfigurations
   ```

   Expected output (name may carry a revision suffix):

   ```
   NAME                     WEBHOOKS   AGE
   istio-sidecar-injector   2          80s
   ```

4. Verify the control plane matches the manifest that was applied:

   ```bash
   istioctl verify-install
   ```

   Expected tail of output:

   ```
   ✔ Istiod: istiod.istio-system.svc                     checked successfully
   Checked 15 custom resource definitions
   Checked 2 Istio Deployments
   ✔ Istio is installed and verified successfully
   ```

**Comprehension questions**

- **Q2.1** After step 1, `istiod` is running but no application Pod has a sidecar yet. Which component injects the sidecar, *when* does it act, and what triggers it?
- **Q2.2** The `default` profile installed an ingress gateway but not an egress gateway. What is `istiod` itself responsible for, that neither gateway provides?
- **Q2.3** `istioctl verify-install` with no arguments checked the *live* cluster. How would you instead verify a rendered manifest *before* applying it, and why would you want to?

---

## Exercise 3 — Enable sidecar injection and confirm the proxy is present

Installing the control plane does nothing to your workloads by itself. Injection is opt-in per namespace (or per Pod).

**Steps**

1. Label a namespace to opt every new Pod in it into sidecar injection:

   ```bash
   kubectl create namespace demo-app
   kubectl label namespace demo-app istio-injection=enabled
   ```

2. Deploy a workload and watch the container count:

   ```bash
   kubectl -n demo-app create deployment web --image=nginx
   kubectl -n demo-app get pods
   ```

   Expected output — note `2/2`, not `1/1`:

   ```
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6f9c8d7b5-pqrst    2/2     Running   0          20s
   ```

3. Prove the second container is the Envoy sidecar:

   ```bash
   kubectl -n demo-app get pod -l app=web \
     -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   ```

   Expected output:

   ```
   nginx istio-proxy
   ```

4. Confirm the sidecar has connected to `istiod` and its configuration is synchronized:

   ```bash
   istioctl proxy-status
   ```

   Expected output — all columns should read `SYNCED`:

   ```
   NAME                              CLUSTER      CDS     LDS     EDS     RDS     ISTIOD                    VERSION
   web-6f9c8d7b5-pqrst.demo-app      Kubernetes   SYNCED  SYNCED  SYNCED  SYNCED  istiod-5f6b8d9c7-klmno    1.24.0
   ```

5. Run the analyzer over the namespace to catch misconfiguration the raw status cannot see:

   ```bash
   istioctl analyze -n demo-app
   ```

   Expected output on a clean namespace:

   ```
   ✔ No validation issues found when analyzing namespace: demo-app.
   ```

**Comprehension questions**

- **Q3.1** In step 2 the Pod is `2/2`. A colleague labels the namespace *after* the Deployment already exists and is confused that the running Pod is still `1/1`. Why, and what single command fixes it?
- **Q3.2** What is the difference between the `istio-injection=enabled` label and the revision label `istio.io/rev=<revision>`? When are you *forced* to use the revision form?
- **Q3.3** `istioctl proxy-status` showed every column `SYNCED`. What does `STALE` in the `RDS` column mean, and is it always an error?

---

## Exercise 4 — Install the ambient data plane

Ambient mode removes the per-Pod sidecar. L4 security (mTLS, TCP authorization, telemetry) is handled by a per-node **ztunnel** DaemonSet; optional L7 features are handled by **waypoint** proxies you add only where needed. The `istio-cni` component is mandatory in ambient — it programs the traffic redirection that used to be the sidecar's `init` container.

> If you have Exercise 2's sidecar installation running, tear it down first (`istioctl uninstall --purge -y`) — do not stack profiles on top of each other.

**Steps**

1. Install with the `ambient` profile:

   ```bash
   istioctl install --set profile=ambient -y
   ```

   Expected output:

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ CNI installed 🪢
   ✔ Ztunnel installed 🔒
   ✔ Installation complete
   ```

2. Inspect the control-plane namespace — the component set is different from sidecar mode:

   ```bash
   kubectl get pods -n istio-system
   ```

   Expected output (one `istio-cni-node` and one `ztunnel` per node; single-node cluster shown):

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   istio-cni-node-4x7pd      1/1     Running   0          40s
   istiod-7c9d8f6b4-abcde    1/1     Running   0          70s
   ztunnel-9zk2m             1/1     Running   0          40s
   ```

3. Confirm `istio-cni` and `ztunnel` are DaemonSets (node-scoped), not Deployments:

   ```bash
   kubectl get daemonset -n istio-system
   ```

   Expected output:

   ```
   NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
   istio-cni-node   1         1         1       1            1           55s
   ztunnel          1         1         1       1            1           55s
   ```

4. Enroll a namespace into the ambient mesh — note the label is **not** the sidecar label:

   ```bash
   kubectl create namespace shop
   kubectl label namespace shop istio.io/dataplane-mode=ambient
   ```

5. Deploy a workload and confirm it is captured by the mesh **without gaining a sidecar**:

   ```bash
   kubectl -n shop create deployment catalog --image=nginx
   kubectl -n shop get pods
   ```

   Expected output — still `1/1`, the container count is unchanged:

   ```
   NAME                        READY   STATUS    RESTARTS   AGE
   catalog-7d9f8c6b5-uvwxy     1/1     Running   0          15s
   ```

**Comprehension questions**

- **Q4.1** In step 5 the Pod is `1/1`, yet it is inside the mesh and its traffic is mTLS-encrypted. If there is no sidecar container in the Pod, *where* is the encryption actually being performed?
- **Q4.2** Why is `istio-cni` a hard requirement for ambient but only optional for sidecar mode? What job did it take over?
- **Q4.3** A student enrolls the `shop` namespace with `istio-injection=enabled` (the sidecar label) instead of `istio.io/dataplane-mode=ambient`. What happens to Pods in that namespace, and why?

---

## Exercise 5 — Add a waypoint proxy for L7 policy in ambient

ztunnel is deliberately L4-only. The moment you need L7 behavior — HTTP routing, header-based authorization, request-level telemetry — you deploy a waypoint. Waypoints are provisioned through the Kubernetes **Gateway API**, so that CRD set must be installed.

**Steps**

1. Install the Gateway API CRDs if the cluster does not already have them (ambient's L7 layer depends on them):

   ```bash
   kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
     kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
   ```

2. Deploy a waypoint for the whole `shop` namespace:

   ```bash
   istioctl waypoint apply -n shop --enroll-namespace
   ```

   Expected output:

   ```
   ✓ waypoint shop/waypoint applied
   ✓ namespace shop labeled with "istio.io/use-waypoint: waypoint"
   ```

3. Confirm the waypoint is a real, running Gateway-backed Deployment:

   ```bash
   kubectl get pods -n shop -l gateway.networking.k8s.io/gateway-name=waypoint
   ```

   Expected output:

   ```
   NAME                        READY   STATUS    RESTARTS   AGE
   waypoint-5c7d9f8b6-zzz01    1/1     Running   0          30s
   ```

4. List waypoints and their binding status:

   ```bash
   istioctl waypoint list -n shop
   ```

   Expected output:

   ```
   NAME       REVISION   PROGRAMMED
   waypoint   default    True
   ```

**Comprehension questions**

- **Q5.1** ztunnel already gives you mTLS and L4 authorization for the `shop` namespace. Name one specific policy that *requires* the waypoint you just added and would not work with ztunnel alone.
- **Q5.2** `istioctl waypoint apply --enroll-namespace` created a `Gateway` resource *and* added a label. What is the role of the `istio.io/use-waypoint` label, and could you scope a waypoint to a single service instead of the whole namespace?
- **Q5.3** A request from a Pod in `shop` to another Pod in `shop` now traverses more hops than in sidecar mode. Trace the L7 data path: which components does the packet pass through, in order?

---

## Exercise 6 — Install with Helm (production-friendly path)

`istioctl install` is imperative. Teams that manage everything through GitOps or a Helm-based CD pipeline install the same components via the official charts. Chart *order* matters: the CRDs (`base`) must exist before `istiod`, and in ambient the `cni` and `ztunnel` charts come last.

**Steps**

1. Add and refresh the official chart repository:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   ```

2. Install the CRDs and cluster-scoped resources first:

   ```bash
   helm install istio-base istio/base -n istio-system --create-namespace --wait
   ```

3. Install the control plane. For **sidecar** mode:

   ```bash
   helm install istiod istio/istiod -n istio-system --wait
   ```

   For **ambient** mode, set the profile and add the two data-plane charts:

   ```bash
   helm install istiod   istio/istiod   -n istio-system --set profile=ambient --wait
   helm install istio-cni istio/cni     -n istio-system --set profile=ambient --wait
   helm install ztunnel  istio/ztunnel  -n istio-system --wait
   ```

4. Confirm the release set is what you expect:

   ```bash
   helm ls -n istio-system
   ```

   Expected output (ambient shown):

   ```
   NAME        NAMESPACE     REVISION   STATUS     CHART           APP VERSION
   istio-base  istio-system  1          deployed   base-1.24.0     1.24.0
   istio-cni   istio-system  1          deployed   cni-1.24.0      1.24.0
   istiod      istio-system  1          deployed   istiod-1.24.0   1.24.0
   ztunnel     istio-system  1          deployed   ztunnel-1.24.0  1.24.0
   ```

5. Verify the outcome is equivalent to an `istioctl` install:

   ```bash
   istioctl verify-install
   ```

**Comprehension questions**

- **Q6.1** Why must `istio-base` be installed *before* `istiod`? What would fail if you reversed the order?
- **Q6.2** The ingress gateway is a separate chart (`istio/gateway`) and was not installed above. Is that a bug in this exercise, or a deliberate design choice in the chart layout? Justify it.
- **Q6.3** You installed with Helm but ran `istioctl verify-install` to check it. Is mixing the two tools like this safe? What is the one thing you must keep consistent between them?

---

## Exercise 7 — Canary upgrade with revisions (advanced)

Production Istio is upgraded with **revision-based canary** installs: the new control plane runs *beside* the old one under a distinct revision label, and you migrate namespaces one at a time by relabeling and restarting. This is examinable because it is the safe upgrade path.

**Steps**

1. Install a named revision alongside whatever is already running:

   ```bash
   istioctl install --set profile=default --set revision=1-24-0 -y
   ```

   Expected output:

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ Ingress gateways installed 🛬
   ✔ Installation complete
   ```

2. Observe both control planes coexisting:

   ```bash
   kubectl get pods -n istio-system -l app=istiod
   ```

   Expected output:

   ```
   NAME                            READY   STATUS    RESTARTS   AGE
   istiod-5f6b8d9c7-klmno          1/1     Running   0          20m
   istiod-1-24-0-79b6c5f8d-qrstu   1/1     Running   0          40s
   ```

3. Point a namespace at the new revision and roll its workloads so injection re-runs:

   ```bash
   kubectl label namespace demo-app istio.io/rev=1-24-0 istio-injection- --overwrite
   kubectl -n demo-app rollout restart deployment web
   ```

4. Confirm the workload's proxy is now managed by the new revision:

   ```bash
   istioctl proxy-status
   ```

   Expected output — the `ISTIOD` column now names the revisioned control plane:

   ```
   NAME                              CLUSTER      CDS     ...   ISTIOD                          VERSION
   web-8a7b6c5d4-vwxyz.demo-app      Kubernetes   SYNCED  ...   istiod-1-24-0-79b6c5f8d-qrstu   1.24.0
   ```

**Comprehension questions**

- **Q7.1** In step 3 you removed `istio-injection` and added `istio.io/rev` in the *same* command. What breaks if both labels are present on a namespace at once?
- **Q7.2** Why does the namespace relabel alone not move existing Pods to the new control plane? What does the `rollout restart` accomplish that the label does not?
- **Q7.3** Once all namespaces are migrated, what is the command to remove the *old* revision cleanly, and why must you confirm `proxy-status` shows no clients on it first?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **A1.1** `istioctl version` reports the version *baked into the client binary* and then separately probes `istio-system` for running `istiod` Pods. The `control plane version: 1.24.0` line is the client echoing what it *would* install, not a live reading — the authoritative signal is the third line, `no ready Istio pods in "istio-system"`, which confirms nothing is deployed. Once a control plane is running, the control-plane version is read from the live `istiod` Pods instead.
- **A1.2** The `default` profile is production-shaped: `istiod` plus an ingress gateway, conservative resource requests, and no demo-only features. The `demo` profile additionally enables an egress gateway, high log verbosity, 100% trace sampling, and generous access logging — all of which are expensive and information-leaking. `demo` exists to make tutorials observable, not to run real traffic; its tracing/logging defaults alone make it unsuitable for production. Source: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- **A1.3** `istioctl x precheck` runs *before* installation and validates that the target cluster can host Istio (Kubernetes version, CRD support, conflicting webhooks, permissions). `istioctl verify-install` runs *after* installation and confirms the applied resources match the intended manifest and are healthy. One gates entry; the other confirms the outcome.

### Exercise 2

- **A2.1** The sidecar injector — a **mutating admission webhook** served by `istiod` — injects the sidecar. It acts at Pod *creation* time: the API server calls the webhook during admission, and the webhook rewrites the Pod spec to add the `istio-proxy` container (and an init container or CNI-programmed redirection). It therefore only affects Pods created *after* injection is enabled; existing Pods are untouched until they are recreated. Source: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- **A2.2** `istiod` is the control plane: it performs service discovery, translates Istio APIs (VirtualService, DestinationRule, etc.) into Envoy xDS configuration, distributes that config to every proxy, issues and rotates the workload mTLS certificates (its built-in CA / SDS), and serves the injection webhook. The gateways are just data-plane Envoys at the mesh edge; none of the control-plane responsibilities live there.
- **A2.3** Render and check the manifest without touching the cluster by generating it with `istioctl manifest generate ...` and validating the YAML, or by running `istioctl verify-install -f <rendered-manifest>.yaml` against a rendered file. You do this to catch a bad profile/override *before* it mutates a live cluster — verifying after `apply` is too late if the apply itself was wrong.

### Exercise 3

- **A3.1** Namespace injection only affects Pods created *after* the label is applied; the existing `web` Pod was admitted before the webhook was relevant to it, so it never got a sidecar and stays `1/1`. Fix it by recreating the Pods: `kubectl -n demo-app rollout restart deployment web`.
- **A3.2** `istio-injection=enabled` is the legacy, revision-agnostic label — it binds to the "default" (unrevisioned) control plane. `istio.io/rev=<revision>` binds the namespace to a *specific* named control-plane revision. You are forced to use the revision label whenever the control plane was installed with a `revision=` value (e.g. during canary upgrades) — the legacy label does not select a revisioned `istiod`.
- **A3.3** `STALE` in `RDS` means `istiod` pushed a route configuration that the proxy has not yet acknowledged. Momentarily during a config change it is normal and self-clears within seconds. Persistent `STALE` indicates a real problem — the proxy cannot accept the pushed config (often a rejected/invalid resource or a connectivity issue to `istiod`) — and should be investigated with `istioctl proxy-config` and `istiod` logs.

### Exercise 4

- **A4.1** By the **ztunnel** DaemonSet on the Pod's node. In ambient mode `istio-cni` redirects the Pod's traffic into the local ztunnel, which establishes the mTLS (HBONE / HTTP CONNECT over TLS) tunnel to the destination node's ztunnel. Encryption happens at the node level, not inside the Pod, which is exactly why the Pod remains `1/1`. Source: https://istio.io/latest/docs/ambient/architecture/
- **A4.2** In ambient there is no per-Pod init container to program `iptables`/redirection inside the Pod's network namespace, so the redirection must be installed from the node — that is `istio-cni`'s job, and without it ztunnel would never receive the workload's traffic. In sidecar mode the same redirection can be done by a privileged `istio-init` container in each Pod, so `istio-cni` is merely an optional way to avoid needing `NET_ADMIN` on every workload. Source: https://istio.io/latest/docs/setup/additional-setup/cni/
- **A4.3** The Pods get **sidecars injected** (they become `2/2`) but they are *not* part of the ambient mesh — ztunnel ignores namespaces that are not labeled `istio.io/dataplane-mode=ambient`. You end up with a sidecar-mode namespace running on top of an ambient control plane, which is valid (the two modes can coexist) but is almost certainly not what the student intended. The correct ambient enrollment label is `istio.io/dataplane-mode=ambient`.

### Exercise 5

- **A5.1** Any L7 policy: HTTP route matching (VirtualService host/path/header routing), an `AuthorizationPolicy` that matches on HTTP method/path/headers, request-level metrics, or L7 traffic shifting. ztunnel is L4-only — it can allow/deny by identity, port and protocol, but it cannot parse HTTP, so a `when: request.headers[...]` or path-based rule requires the waypoint. Source: https://istio.io/latest/docs/ambient/usage/waypoint/
- **A5.2** The `istio.io/use-waypoint: waypoint` label tells the mesh that traffic *to* the labeled resource must be routed through the named waypoint for L7 processing. You can scope it more narrowly than a namespace: label an individual `Service` (or use `istioctl waypoint apply --for service`) so only that service's traffic is sent through a waypoint, leaving the rest of the namespace at L4-only. Source: https://istio.io/latest/docs/ambient/usage/waypoint/
- **A5.3** Source Pod → source node **ztunnel** (mTLS/HBONE) → the destination's **waypoint** proxy (L7 policy, routing, telemetry) → destination node **ztunnel** → destination Pod. The waypoint is inserted into the path only because the destination namespace carries `istio.io/use-waypoint`; without it, the L7 hop is skipped and the path is ztunnel-to-ztunnel only.

### Exercise 6

- **A6.1** `istio-base` installs the CustomResourceDefinitions (and cluster roles) that `istiod` depends on. If you install `istiod` first, its controllers reference CRDs (Gateways, VirtualServices, the Istio config types) that do not yet exist, so reconciliation and validation webhooks fail. CRDs must exist before any controller that watches them.
- **A6.2** Deliberate. The gateway is a separate `istio/gateway` chart precisely so gateways can be installed, scaled, versioned and placed in their own namespaces independently of the control plane — you may run zero, one, or many gateways, in namespaces other than `istio-system`. Bundling it into `istiod` would force a topology the chart authors intentionally keep decoupled. Source: https://istio.io/latest/docs/setup/install/helm/
- **A6.3** It is safe. The one invariant is **version consistency**: the `istioctl` binary version must match the installed chart/control-plane version. A mismatched `istioctl` may verify against the wrong expected manifest or report spurious differences. Keep the client and the control plane on the same release.

### Exercise 7

- **A7.1** If both `istio-injection=enabled` and `istio.io/rev=<revision>` are present, the injection behavior is ambiguous — historically the legacy `istio-injection` label takes precedence and the revision label is ignored, so Pods bind to the *default* control plane instead of the revision you intended. The migration must therefore remove the legacy label (`istio-injection-`) in the same operation that adds the revision label, which is exactly what the `--overwrite` command in step 3 does. Source: https://istio.io/latest/docs/setup/upgrade/canary/
- **A7.2** Injection is decided at Pod admission time, so relabeling the namespace changes only what happens to *future* Pods; the already-running Pods still carry sidecars configured by the old revision. `rollout restart` recreates the Pods, which re-triggers the injection webhook — now under the new revision label — so the fresh Pods get sidecars managed by the new control plane.
- **A7.3** Uninstall the specific revision with `istioctl uninstall --revision 1-24-0 -y` (or remove the corresponding Helm releases for that revision). You must first confirm via `istioctl proxy-status` that no proxies still list the old `istiod` in their `ISTIOD` column — removing a control plane that still has connected data-plane clients cuts those proxies off from config and certificate rotation, breaking the workloads that were never migrated.

</details>

---

**Reference sources**
- Istio getting started: https://istio.io/latest/docs/setup/getting-started/
- `istioctl` install: https://istio.io/latest/docs/setup/install/istioctl/
- Helm install: https://istio.io/latest/docs/setup/install/helm/
- Configuration profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Sidecar injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Ambient mode overview & install: https://istio.io/latest/docs/ambient/ and https://istio.io/latest/docs/ambient/getting-started/
- Ambient waypoints: https://istio.io/latest/docs/ambient/usage/waypoint/
- Canary upgrades / revisions: https://istio.io/latest/docs/setup/upgrade/canary/
- ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf