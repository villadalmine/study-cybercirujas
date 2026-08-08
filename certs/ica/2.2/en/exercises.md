# ICA 2.2 — Troubleshooting the Mesh Control Plane (Guided Exercises)

> **Scope.** In Istio the mesh control plane is a single binary, **`istiod`**, that fuses the former Pilot (xDS/config distribution), Citadel (CA/identity) and Galley (config validation) responsibilities. "Troubleshooting the control plane" therefore means answering four questions in order: *Is istiod healthy? Is it computing the right config? Is that config reaching the proxies? Are the webhooks and CA that gate the mesh working?* These exercises walk each question with real commands and the outputs you should expect.
>
> **Prerequisites.** A running cluster with Istio installed (`istio-system` namespace), `istioctl` matching your control-plane minor version, `kubectl` context set, and the Bookinfo sample deployed in a sidecar-injected namespace (`default` with `istio-injection=enabled`). Commands assume the default profile; adapt the revision label (`istio.io/rev`) if you run a revisioned/canary install.
>
> **Sources**
> - ICA Curriculum — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
> - Istio — Diagnose your Configuration with `istioctl analyze` — https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
> - Istio — Debugging Envoy and Istiod (`proxy-status`, `proxy-config`) — https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
> - Istio — Component Introspection (ControlZ) — https://istio.io/latest/docs/ops/diagnostic-tools/controlz/
> - Istio — Sidecar Injection Problems — https://istio.io/latest/docs/ops/common-problems/injection/
> - Istio — Deployment Models / Ports & Protocols — https://istio.io/latest/docs/ops/deployment/application-requirements/
> - Istio — Plugin CA Certificates / Cert management — https://istio.io/latest/docs/tasks/security/cert-management/

---

## Exercise 1 — Establish a control-plane baseline (health + version skew)

Before diagnosing *behaviour*, prove istiod is running, ready, and not skewed against your data plane. Version skew is a classic silent failure: proxies stay `SYNCED` but new config semantics are misapplied.

1. Confirm the istiod pods are `Running` and `Ready`, and inspect restarts:

   ```bash
   kubectl -n istio-system get pods -l app=istiod -o wide
   ```

   Expected:

   ```
   NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE
   istiod-5c7b7c9b8-abcde    1/1     Running   0          6d    10.244.1.14   node-1
   ```

2. Check the readiness of the control plane logically (this hits istiod's `/ready` health endpoint, not just the pod phase):

   ```bash
   kubectl -n istio-system get deploy istiod -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
   ```

   Expected: `1/1`.

3. Compare the control-plane version against every injected data-plane proxy in one shot:

   ```bash
   istioctl version
   ```

   Expected (healthy, no skew):

   ```
   client version: 1.20.0
   control plane version: 1.20.0
   data plane version: 1.20.0 (14 proxies)
   ```

   Skewed example (what a problem looks like):

   ```
   client version: 1.20.0
   control plane version: 1.20.0
   data plane version: 1.19.3 (2 proxies), 1.20.0 (12 proxies)
   ```

4. Look at the last events on the deployment to catch OOMKills, image pull errors, or failed rollouts that a `Running` status hides:

   ```bash
   kubectl -n istio-system describe deploy istiod | sed -n '/Conditions:/,/Events:/p'
   kubectl -n istio-system get events --field-selector involvedObject.name=istiod --sort-by=.lastTimestamp | tail -n 5
   ```

**Comprehension check**

- **Q1.1** `kubectl get pods` shows `istiod` as `1/1 Running`, yet `istioctl version` reports two data-plane versions. Is the mesh healthy? What component enforces that a proxy must not be *newer* than istiod?
- **Q1.2** Why is `READY 1/1` (the readiness probe) a stronger signal than `STATUS Running` when triaging the control plane?
- **Q1.3** You see istiod `RESTARTS 7` and its last event is `OOMKilled`. Name two mesh-wide symptoms you would expect while istiod is crash-looping, and one that you would *not* expect.

---

## Exercise 2 — Diagnose configuration distribution with `proxy-status`

`istioctl proxy-status` (alias `istioctl ps`) is the single most important control-plane triage command. It compares, per proxy, the config istiod *last acknowledged* against the config istiod *last computed*, for each xDS type (CDS clusters, LDS listeners, EDS endpoints, RDS routes, ECDS extension config).

1. Get the fleet-wide sync table:

   ```bash
   istioctl proxy-status
   ```

   Expected (a mesh with two distribution problems planted):

   ```
   NAME                                       CLUSTER      CDS      LDS      EDS      RDS       ECDS       ISTIOD                    VERSION
   details-v1-79f774bdb9-6l9zj.default        Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED    NOT SENT   istiod-5c7b7c9b8-abcde    1.20.0
   productpage-v1-6b746f74dc-w2m8p.default     Kubernetes   SYNCED   SYNCED   SYNCED   STALE     NOT SENT   istiod-5c7b7c9b8-abcde    1.20.0
   ratings-v1-b6994bb9-q4dpr.default           Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED    NOT SENT   istiod-5c7b7c9b8-fghij    1.20.0
   reviews-v3-5b9bd44f4-9xqkc.default          Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED    NOT SENT   <error: NR>               1.20.0
   ```

2. Interpret the states. Memorise the vocabulary:
   - **SYNCED** — istiod's last pushed config was ACKed by the proxy. Good.
   - **NOT SENT** — istiod computed nothing to push for this xDS type (e.g. no `EnvoyFilter`/WASM → `ECDS NOT SENT` is normal). Not an error by itself.
   - **STALE** — istiod pushed an update but the proxy has **not ACKed** it. Config is *in flight or stuck*: proxy overloaded, NACKing, or a lost connection.
   - A proxy that appears with no istiod name (or `<error>`) has **no active ADS stream** to any istiod.

3. Drill into the `STALE` proxy. A STALE state usually means the proxy rejected the update (a NACK). Confirm from istiod's side and from the proxy's side:

   ```bash
   # From the proxy: does its running config match what istiod has? A non-empty diff = drift.
   istioctl proxy-config route productpage-v1-6b746f74dc-w2m8p.default --name 9080 -o json | head

   # Ask istiod directly which proxies are connected and their push status (works without port-forward):
   istioctl experimental internal-debug syncz | jq '.[].proxy' 2>/dev/null | head
   ```

4. For the proxy that lists **no istiod** (`<error: NR>` / blank), verify it actually has a sidecar and a live control-plane connection:

   ```bash
   kubectl -n default get pod reviews-v3-5b9bd44f4-9xqkc \
     -o jsonpath='{.spec.containers[*].name}{"\n"}'
   # Expect: reviews istio-proxy   (if 'istio-proxy' is missing → not injected, see Exercise 4)

   kubectl -n default logs reviews-v3-5b9bd44f4-9xqkc -c istio-proxy | grep -Ei 'connect|xds|StreamAggregated|warning|error' | tail
   # Look for: "connection refused" to istiod:15012, TLS handshake failures, or repeated reconnects.
   ```

**Comprehension check**

- **Q2.1** A proxy shows `RDS STALE` while `CDS/LDS/EDS` are `SYNCED`. What does this tell you about *where* the failure is, and why is a stuck `RDS` push often a symptom of a rejected update rather than a slow one?
- **Q2.2** Every proxy in the mesh shows `ECDS NOT SENT`. A teammate opens an incident. Are they right? Explain what `NOT SENT` means versus `STALE`.
- **Q2.3** A proxy row shows no istiod name at all. Is this a control-plane compute problem or a connectivity/identity problem? Which port and protocol does the sidecar use to reach istiod for xDS?
- **Q2.4** Two different istiod pod names appear in the `ISTIOD` column (`...abcde` and `...fghij`). Is that a bug?

---

## Exercise 3 — Read istiod's mind: logs, push errors, ControlZ and debug endpoints

When `proxy-status` shows `STALE`/NACK, istiod's logs and introspection surfaces tell you *why* the computed config was rejected or never produced.

1. Tail the discovery/ADS logs and grep for the push pipeline. `pilot-discovery` inside istiod logs every push and every NACK:

   ```bash
   kubectl -n istio-system logs deploy/istiod | \
     grep -Ei 'ads|push|nack|rejected|error|warn' | tail -n 20
   ```

   Expected NACK evidence (proxy rejected a listener):

   ```
   warn    ads     ADS:LDS: ACK ERROR sidecar~10.244.2.9~productpage-v1-...~default.svc.cluster.local-42
           Internal:Error adding/updating listener(s) 0.0.0.0_9080: paths must refer to an existing name...
   info    ads     Push debounce stable[318] 1 for config VirtualService/default/reviews: ...
   ```

2. Raise istiod's log verbosity **at runtime** for a specific scope (no restart) via ControlZ, istiod's live introspection server:

   ```bash
   # Opens the ControlZ UI (port 9876 in the pod) in your browser.
   istioctl dashboard controlz deployment/istiod.istio-system
   ```

   In ControlZ → *Logging Scopes*, set the `ads` and `model` scopes to `debug`. This is reversible and pod-scoped; remember to set it back.

3. Query istiod's internal debug state directly — the supported, port-forward-free way — to see what istiod *believes* the mesh config and sync state are:

   ```bash
   # Per-proxy sync/ACK state as istiod sees it:
   istioctl experimental internal-debug syncz

   # The service registry istiod has discovered (endpoints it will program as EDS):
   istioctl experimental internal-debug registryz | jq '.[].hostname' | sort -u | head

   # The config istiod has loaded (VirtualServices, DestinationRules, etc.):
   istioctl experimental internal-debug configz | jq '.[].kind' | sort | uniq -c
   ```

4. Correlate a NACK to its source object. If the log says a `VirtualService` produced a bad `RDS`, run the analyzer scoped to that object (bridges to Exercise honed further in Exercise below):

   ```bash
   istioctl analyze -n default
   ```

**Comprehension check**

- **Q3.1** The istiod log shows `ADS:LDS: ACK ERROR ... Internal: Error adding/updating listener(s)`. Map this line to the `proxy-status` state you would see for that proxy's `LDS` column, and say which side (istiod or Envoy) actually rejected the config.
- **Q3.2** You bumped the `ads` logging scope to `debug` via ControlZ and it fixed nothing but flooded your logs. After the incident, what must you remember to do, and why does ControlZ let you avoid a `kubectl rollout restart`?
- **Q3.3** `internal-debug registryz` lists a Service but its endpoints are empty, while `kubectl get endpoints` for that Service is populated. Is the problem in the control plane's registry sync or in the application? What would you check next?

---

## Exercise 4 — Sidecar injection webhook failures (istiod as MutatingWebhook)

istiod serves the **mutating admission webhook** that injects the sidecar. When it misbehaves, pods start *without* a proxy (silent) or fail to schedule (loud) — both are control-plane troubleshooting, not app troubleshooting.

1. Inspect the webhook configuration and its trust anchor (`caBundle`) and failure policy:

   ```bash
   kubectl get mutatingwebhookconfiguration -l app=sidecar-injector \
     -o custom-columns='NAME:.metadata.name,FAILURE:.webhooks[*].failurePolicy,SERVICE:.webhooks[*].clientConfig.service.name'
   ```

   Expected:

   ```
   NAME                        FAILURE   SERVICE
   istio-sidecar-injector      Fail      istiod
   ```

2. Verify the namespace is actually selected for injection. The webhook uses a `namespaceSelector` and/or `objectSelector`:

   ```bash
   kubectl get ns default --show-labels
   # Expect one of: istio-injection=enabled   OR   istio.io/rev=<revision>
   ```

3. Reproduce the "no sidecar" symptom and diagnose it deterministically with the analyzer, which specifically checks injection:

   ```bash
   kubectl -n default run testbox --image=nginx --restart=Never
   kubectl -n default get pod testbox \
     -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}{"\n"}'
   # If output is just "testbox" (no istio-proxy) → injection did not happen.

   istioctl analyze -n default
   # Expect a message like:
   # Info [IST0102] (Namespace default) The namespace is not enabled for Istio injection...
   ```

4. If the namespace *is* labelled but injection still fails, the webhook itself is the suspect. Two classic causes — a stale `caBundle` and `failurePolicy: Fail` blocking all pod creation:

   ```bash
   # a) Does the webhook's caBundle match istiod's current CA? A mismatch → TLS errors, no injection.
   kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
     -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -subject -dates

   # b) Look for API-server side rejections when failurePolicy=Fail and istiod is unreachable:
   kubectl -n default describe rs -l app=reviews | grep -i 'Internal error\|webhook\|failed calling'
   # e.g. "failed calling webhook ... connect: connection refused" or "x509: certificate signed by unknown authority"
   ```

**Comprehension check**

- **Q4.1** A namespace has `istio-injection=enabled`, istiod is healthy, but new pods still come up without a sidecar. The webhook's `caBundle` is empty/old. Explain the exact failure chain from API-server admission call to "no proxy container."
- **Q4.2** With `failurePolicy: Fail`, istiod becomes unavailable during an upgrade. What happens to *every* new pod creation in injected namespaces? Contrast with `failurePolicy: Ignore` — what does each choose to protect?
- **Q4.3** `istioctl analyze` reports `IST0102` for the namespace. Is this a webhook bug or a configuration gap? What single change fixes it?

---

## Exercise 5 — Config validation webhook & `istioctl analyze`

istiod also serves the **validating admission webhook** (rejects malformed `VirtualService`, `DestinationRule`, etc. at apply time) and powers `istioctl analyze` (static analysis of applied config for higher-level mistakes the schema can't catch).

1. Confirm the validating webhook exists and points at istiod:

   ```bash
   kubectl get validatingwebhookconfiguration -l app=istiod \
     -o custom-columns='NAME:.metadata.name,SERVICE:.webhooks[*].clientConfig.service.name,FAILURE:.webhooks[*].failurePolicy'
   ```

2. Prove the webhook *rejects* structurally invalid config at admission (fail fast, before it can ever reach a proxy as a NACK):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: broken-weights
     namespace: default
   spec:
     hosts:
       - reviews
     http:
       - route:
           - destination:
               host: reviews
               subset: v1
             weight: 40
           - destination:
               host: reviews
               subset: v2
             weight: 40      # weights sum to 80, not 100
   EOF
   ```

   Expected — the API server relays istiod's validation rejection:

   ```
   Error from server: error when creating "STDIN": admission webhook
   "validation.istio.io" denied the request: configuration is invalid:
   total destination weight 80 != 100
   ```

3. Now plant a config that is *schema-valid but semantically broken* — it will pass the webhook and reach the proxy as a NACK — then catch it statically:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews-dangling-subset
     namespace: default
   spec:
     hosts: [reviews]
     http:
       - route:
           - destination:
               host: reviews
               subset: v99      # no matching DestinationRule subset exists
   EOF

   istioctl analyze -n default
   ```

   Expected:

   ```
   Warning [IST0135] (VirtualService reviews-dangling-subset.default)
     Referenced host+subset in destinationrule not found: "reviews;v99"
   ```

4. Cross-check the impact on distribution — the dangling subset is exactly the kind of config that turns `RDS` `STALE` in Exercise 2:

   ```bash
   istioctl proxy-status | grep -E 'reviews|productpage'
   istioctl analyze --all-namespaces --output-threshold Warning
   ```

**Comprehension check**

- **Q5.1** The weights-sum-to-80 `VirtualService` was rejected instantly at `kubectl apply`, but the `subset: v99` one applied cleanly and only surfaced later. What is the dividing line between what the **validating webhook** catches and what **`istioctl analyze`** catches?
- **Q5.2** If the validating webhook is *down or misconfigured*, is your mesh safer or more dangerous? What class of bad config can now reach istiod and your proxies?
- **Q5.3** Why is `istioctl analyze` considered a *control-plane* troubleshooting tool even though it makes no change to istiod? What does a `[IST0135]` warning predict about `proxy-status`?

---

## Exercise 6 — Control-plane identity: CA and certificate distribution

istiod is the mesh CA: it signs the workload certificates (SVIDs) that proxies present for mTLS, and distributes the root trust bundle. A control-plane CA problem manifests as data-plane mTLS failures, so you must trace it back to istiod.

1. Confirm istiod is issuing certs — check the CA/secret plumbing on a proxy:

   ```bash
   istioctl proxy-config secret productpage-v1-6b746f74dc-w2m8p.default
   ```

   Expected:

   ```
   RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
   default           Cert Chain     ACTIVE     true           2b:3c:...            2026-08-09T10:14:22Z     2026-08-08T10:12:22Z
   ROOTCA            CA             ACTIVE     true           7f:9a:...            2036-08-05T00:00:00Z     2026-08-05T00:00:00Z
   ```

   Red flags: `VALID CERT false`, a `default` cert whose `NOT AFTER` is in the past, or a missing `default` row entirely.

2. Inspect the SPIFFE identity encoded in the workload cert (this is what mTLS policy authorizes on):

   ```bash
   istioctl proxy-config secret productpage-v1-6b746f74dc-w2m8p.default -o json | \
     jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
     base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
   ```

   Expected:

   ```
   X509v3 Subject Alternative Name:
       URI:spiffe://cluster.local/ns/default/sa/bookinfo-productpage
   ```

3. Confirm every proxy trusts the *same* root as istiod currently serves. After a CA rotation, proxies still holding the old root cannot validate peers signed by the new root:

   ```bash
   # Root istiod distributes (the mesh trust anchor):
   kubectl -n istio-system get configmap istio-ca-root-cert \
     -o jsonpath='{.data.root-cert\.pem}' | openssl x509 -noout -serial -dates

   # Root a given proxy actually holds:
   istioctl proxy-config secret productpage-v1-6b746f74dc-w2m8p.default -o json | \
     jq -r '.dynamicActiveSecrets[] | select(.name=="ROOTCA") .secret.validationContext.trustedCa.inlineBytes' | \
     base64 -d | openssl x509 -noout -serial -dates
   # The two serials must match.
   ```

4. If certs are missing or `VALID CERT false`, look at istiod's CA logs and the proxy's SDS pull:

   ```bash
   kubectl -n istio-system logs deploy/istiod | grep -Ei 'citadel|ca |CSR|sign|x509' | tail
   kubectl -n default logs productpage-v1-6b746f74dc-w2m8p -c istio-proxy | \
     grep -Ei 'sds|secret|certificate|CSR' | tail
   # Healthy proxy: "SDS: PUSH ... resource:default" and "CSR ... succeeded"
   ```

**Comprehension check**

- **Q6.1** Two workloads suddenly fail mTLS with `certificate signed by unknown authority`, but each proxy's own `default` cert shows `VALID CERT true`. Where is the fault — issuance or trust distribution — and which artifact from step 3 would you compare?
- **Q6.2** `istioctl proxy-config secret <pod>` returns **no `default` row**. istiod is `Running`. Name two control-plane causes (hint: one is connectivity/port, one is RBAC/identity) that would prevent the proxy from obtaining a signed cert.
- **Q6.3** Why does an expired or wrong **istiod CA root** present as a *data-plane* symptom (503s, connection resets between apps) rather than an obvious control-plane error, and what makes step 3's serial comparison the fastest way to confirm it?

---

## Consolidated triage flow (mental model)

```
istiod Running & Ready?  ──no──► Exercise 1: pods/events/OOM, version skew
        │ yes
        ▼
proxy-status all SYNCED? ──no──► STALE  ► Exercise 3: istiod logs / NACK reason ► Exercise 5: analyze the offending object
        │ yes                   NOT SENT► usually benign (no such config)
        │                       no istiod► Exercise 2/4: injection & xDS connectivity (:15012)
        ▼
New pods get a sidecar?  ──no──► Exercise 4: MutatingWebhook caBundle / selector / failurePolicy
        │ yes
        ▼
Config applies but breaks? ─────► Exercise 5: ValidatingWebhook (apply-time) vs analyze (semantic)
        │
        ▼
mTLS failing app-to-app?  ─────► Exercise 6: CA issuance + root trust distribution (serial match)
```

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.1** No — it is not healthy in the sense that matters: a version skew exists (some proxies at 1.19.3 under a 1.20.0 control plane). The mesh keeps serving, but new-feature semantics may be misapplied. The **hard rule istiod enforces is that a proxy must never be *newer* than the control plane** — istiod supports proxies at its own version and up to two minors *older*, never newer. A newer sidecar can request xDS resources/fields istiod's schema doesn't know, producing NACKs. The fix is to restart/roll the lagging workloads so they re-inject the current proxy image.

**Q1.2** `STATUS Running` only means the container's main process started and hasn't exited. `READY 1/1` means istiod passed its **readiness probe** (`/ready`), i.e. it has loaded config, connected to the Kubernetes API, and is prepared to *serve xDS/webhooks*. istiod can be `Running` but `0/1 Ready` (e.g. can't list resources due to RBAC, or still warming caches), during which it silently serves nothing new — readiness is the signal that distinguishes "process alive" from "control plane functional."

**Q1.3** Expected during an istiod crash-loop: (1) new/rescheduled pods in injected namespaces fail to get a sidecar or fail admission entirely if `failurePolicy: Fail` (the injection webhook is unreachable); (2) config changes (new `VirtualService`, scaling events changing endpoints) stop propagating — `proxy-status` goes `STALE`/stale, and CSRs for new proxies can't be signed. What you would **not** expect: existing, already-programmed proxies to drop traffic — Envoy keeps running on its last-known-good config and continues serving data-plane traffic while the control plane is down (control/data plane separation).

**Q2.1** `RDS STALE` with the other types `SYNCED` localises the fault to **route configuration only** — the clusters, listeners and endpoints were accepted, but the routing rules were not ACKed. A stuck `RDS` push is typically a **rejected (NACK) update, not a slow one**, because Envoy validates each config atomically: if the new `RouteConfiguration` references something that doesn't exist (a cluster/subset that isn't there), Envoy rejects it and keeps the prior version — istiod records it as un-ACKed → `STALE`. Confirm by reading istiod's `ADS:RDS: ACK ERROR` log line (Exercise 3).

**Q2.2** They are (almost certainly) wrong. `ECDS` (Envoy Extension Config Discovery) is `NOT SENT` whenever there is no `EnvoyFilter`/WASM extension config to distribute — the common case. **`NOT SENT` = istiod had nothing to push for that xDS type; it is not an error.** `STALE` = istiod *did* push and the proxy hasn't ACKed — *that* is the state that signals a distribution problem.

**Q2.3** It is a **connectivity/identity problem, not a compute problem** — the proxy has no active ADS stream to any istiod, so istiod has no sync state to report for it. Either the pod has no sidecar (injection failure, Exercise 4) or the sidecar can't establish its xDS connection. The sidecar connects to **istiod on port `15012` (`istiod.istio-system.svc:15012`), gRPC over mTLS** (the plaintext equivalent is `15010`, discouraged). Check istio-proxy logs for `connection refused`/TLS handshake errors to that port.

**Q2.4** No. With more than one istiod replica (HA), each proxy maintains its ADS stream to *one* replica, so different rows legitimately name different istiod pods. It becomes interesting only if you also see skew or if one istiod's clients are all `STALE` while another's are `SYNCED` (points to a single unhealthy replica).

**Q3.1** `ADS:LDS: ACK ERROR` corresponds to that proxy's **`LDS` column showing `STALE`** in `proxy-status` — istiod pushed a listener update that was not ACKed. The rejection happens on the **Envoy (data-plane) side**: Envoy validated the pushed `Listener`, found it invalid (e.g. a route path referencing a non-existent name), rejected it, and returned a NACK; istiod merely logs the NACK it received. So the "error" is Envoy refusing istiod's computed config — the *cause* is usually an istiod-side config mistake you then chase with `analyze`.

**Q3.2** You must **set the `ads` (and any other) logging scope back to `info`** in ControlZ after the incident — debug logging is expensive and floods storage. ControlZ mutates istiod's log levels **live, in-process**, so you avoid a `kubectl rollout restart deploy/istiod` — a restart would drop every proxy's ADS stream, force full re-pushes across the whole mesh, and briefly re-elect istiod connections, i.e. you'd perturb the very system you're debugging.

**Q3.3** The problem is in the **control plane's service-registry sync**, not the application — the app clearly has endpoints (`kubectl get endpoints` is populated), but istiod's `registryz` (what it will program as EDS) is empty for that service. Next, check: istiod's RBAC/permissions to watch Endpoints/EndpointSlices, whether the Service's selector actually matches the pods, any `Sidecar`/`exportTo` scoping that hides it, and istiod logs for informer/watch errors. Until the registry sees the endpoints, proxies will get empty EDS and traffic to that service 503s.

**Q4.1** Chain: a pod is created → the API server matches it against `MutatingWebhookConfiguration istio-sidecar-injector` (namespaceSelector hit) → the API server makes a **TLS call to the istiod webhook service, validating istiod's serving cert against the webhook's `caBundle`** → because the `caBundle` is empty/stale it can't verify istiod's cert → the TLS/admission call fails → with `failurePolicy: Ignore` the API server **admits the pod anyway, unmutated**, so no `istio-proxy` container is added → the pod runs without a sidecar. (With `failurePolicy: Fail` the pod creation would be rejected instead.) Fix: repair the `caBundle` (istiod/its cert controller normally patches it; a revisioned mismatch or a manual edit is the usual culprit).

**Q4.2** With `failurePolicy: Fail` and istiod down, **every new pod creation in injected namespaces is rejected** by the API server (`failed calling webhook ... connection refused`) — deployments can't roll, HPA can't scale up, nodes draining can't reschedule. It prioritises **correctness/security** (never run a workload that was supposed to be in the mesh but isn't). `failurePolicy: Ignore` instead prioritises **availability**: pods are admitted un-injected during an istiod outage — they run, but *outside* the mesh (no mTLS/policy), which can be a security surprise. Production installs typically scope the webhook narrowly and/or run istiod HA precisely to make `Fail` safe.

**Q4.3** It is a **configuration gap, not a webhook bug** — `IST0102` says the namespace simply isn't labelled for injection, so the webhook's `namespaceSelector` never matched it. Single fix: label the namespace, e.g. `kubectl label ns default istio-injection=enabled` (or `istio.io/rev=<revision>` for a revisioned install), then recreate the pods.

**Q5.1** The **validating webhook enforces the schema and single-object structural invariants at admission time** — things provably wrong from the object alone: weights that don't sum to 100, unknown fields, malformed selectors. It rejects them *before they are ever stored*, so they can never reach a proxy. **`istioctl analyze` catches cross-object / semantic problems** that are individually valid: a `VirtualService` pointing at a `subset` that no `DestinationRule` defines, an `AuthorizationPolicy` referencing a missing service account, host-scoping mistakes. Those need the *whole* config graph to detect, which admission of a single object cannot see — so they pass the webhook and only bite later (as a NACK / `STALE`).

**Q5.2** More dangerous. With the validating webhook down/misconfigured, **structurally invalid config is now accepted into etcd and handed to istiod**, which computes broken xDS and pushes it — proxies NACK (`STALE`), and depending on the object you can get listeners/routes that fail to program, i.e. real traffic breakage. The webhook is a fail-fast guardrail; losing it moves failures from "rejected at apply" to "silently degrading the data plane."

**Q5.3** `istioctl analyze` reads the same applied config and Kubernetes state that istiod consumes and reproduces the higher-level checks istiod (and Envoy) would fail on — so it **predicts control-plane distribution outcomes without mutating anything**. A `[IST0135]` "referenced host+subset not found" warning predicts that the corresponding proxies will show that route type **`STALE`** in `proxy-status` (Envoy will NACK the route that points at the non-existent subset). It's the cheapest way to convert a mystery `STALE` into a named root cause.

**Q6.1** The fault is in **trust distribution, not issuance**: each proxy holds a valid, freshly-signed `default` cert, but peers reject each other → they disagree on the **root/trust anchor**. This is the classic post-rotation state where some proxies still hold the *old* `ROOTCA` while others (and istiod) present certs chained to the *new* root. Compare the artifact from step 3: the **serial (and validity dates) of `istio-ca-root-cert`** that istiod distributes versus the **`ROOTCA` serial each proxy actually holds** (`proxy-config secret ... ROOTCA`). Mismatched serials confirm stale trust; restart the lagging proxies (or fix root propagation) so all hold the current root.

**Q6.2** With istiod `Running` but a proxy getting **no `default` cert**: (1) **connectivity** — the sidecar's SDS agent can't reach istiod's CA/xDS endpoint on **`15012`** (NetworkPolicy, wrong `discoveryAddress`, TLS failure), so its CSR never reaches the CA; (2) **identity/RBAC** — the workload's `ServiceAccount` token can't be validated or authorized to request a cert (missing/rotated projected SA token, `TokenReview` denied, or the SA lacks the identity istiod expects), so istiod refuses to sign. Both leave the SDS `default` secret unpopulated; distinguish via istiod CA logs (`CSR` denied vs never arrived) and the proxy's SDS logs.

**Q6.3** Certificates are consumed by **Envoy for mTLS between workloads**, so when the istiod-issued root is expired/wrong, the *handshake between two apps* fails — you observe 503s, `connection reset`, or `certificate signed by unknown authority` at the **data plane**, with no crash or obvious error on istiod itself (it's happily running, just serving a bad/rotated root or the proxies hold a stale one). Step 3's **serial comparison** is fastest because it directly answers "do istiod and the proxy agree on the trust anchor?" in two commands — skipping the slow path of correlating app-level 503s across many services back to a certificate root.

</details>