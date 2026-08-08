# Guided Exercises — CNPE 2.3: Diagnosing and Remediating Platform Issue and Incident Scenarios

> **Scope.** These labs drill the platform engineer's core loop under an incident: **observe → localize → hypothesize → verify → remediate → prevent**. You will practice reading Kubernetes signals in the correct order, isolating a fault to a layer (workload / scheduling / control-plane / networking / platform add-on), applying a *minimal* remediation, and closing with prevention. The scenarios are deliberately platform-level — a broken admission webhook or an expired CA takes down *everyone's* deployments, not one pod.
>
> **Reference syllabus.** CNPE Curriculum, Domain 2 (Platform Operations), competency 2.3 — <https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf>
>
> **Prerequisites.** A throwaway cluster you can break: `kind create cluster --name cnpe-23` (<https://kind.sigs.k8s.io/>) or minikube. `kubectl` v1.29+ (ephemeral containers and `kubectl debug` are GA). Namespace convention below assumes `kubectl create ns platform`.
>
> **Ground rule.** Never run a remediation you cannot explain. For every `kubectl edit`/`patch`/`delete` you type, you must be able to state *what signal justified it* and *what you expect to change*. That habit is the actual exam objective.

---

## Exercise 1 — The triage funnel: localizing a CrashLoopBackOff

**Scenario.** The platform team ships an internal `notifier` service. After a routine change it will not stay up. You are on call. Resist the urge to guess — walk the funnel.

### Setup (apply the broken workload)

1. Create the namespace and a deliberately broken Deployment:

   ```bash
   kubectl create ns platform
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: notifier
     namespace: platform
   spec:
     replicas: 2
     selector:
       matchLabels: { app: notifier }
     template:
       metadata:
         labels: { app: notifier }
       spec:
         containers:
           - name: notifier
             image: ghcr.io/nonexistent/notifier:v1.4.2
             env:
               - name: SMTP_URL
                 valueFrom:
                   secretKeyRef:
                     name: notifier-smtp
                     key: url
             resources:
               requests: { cpu: 50m, memory: 64Mi }
               limits:   { cpu: 100m, memory: 128Mi }
   EOF
   ```

### Diagnose

2. Get the high-level state. Do **not** skip to logs:

   ```bash
   kubectl -n platform get pods -l app=notifier -o wide
   ```

   Expected (the exact reason may differ by kubelet version):

   ```
   NAME                        READY   STATUS                       RESTARTS   AGE
   notifier-6c9b8f7d5-4xk2p    0/1     CreateContainerConfigError   0          14s
   notifier-6c9b8f7d5-9tzlm    0/1     CreateContainerConfigError   0          14s
   ```

3. Read the *events* — the state field alone rarely names the cause:

   ```bash
   kubectl -n platform describe pod -l app=notifier | sed -n '/Events:/,$p'
   ```

   Expected tail:

   ```
   Warning  Failed   ...  Error: secret "notifier-smtp" not found
   ```

4. Confirm the missing dependency rather than assuming it:

   ```bash
   kubectl -n platform get secret notifier-smtp
   # Error from server (NotFound): secrets "notifier-smtp" not found
   ```

**Questions (block 1a)**
- Q1. Why is the pod status `CreateContainerConfigError` and **not** `CrashLoopBackOff`? What does that distinction tell you about which subsystem failed?
- Q2. You have two failure signals visible so far (the image reference and the secret). Which one is Kubernetes reporting *first*, and why does the ordering of container lifecycle phases explain that?

### Remediate the config fault, then expose the next one

5. Create the missing secret and let the controller reconcile:

   ```bash
   kubectl -n platform create secret generic notifier-smtp \
     --from-literal=url='smtp://mailhog.platform.svc:1025'
   kubectl -n platform rollout status deploy/notifier --timeout=60s || true
   ```

6. Observe the *new* top-of-funnel state:

   ```bash
   kubectl -n platform get pods -l app=notifier
   ```

   Expected:

   ```
   NAME                        READY   STATUS             RESTARTS   AGE
   notifier-6c9b8f7d5-4xk2p    0/1     ImagePullBackOff   0          90s
   ```

7. Confirm the second fault at the events layer and inspect the exact image string:

   ```bash
   kubectl -n platform describe pod -l app=notifier | grep -A3 -i 'Failed to pull\|Back-off pulling'
   kubectl -n platform get deploy notifier -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

**Questions (block 1b)**
- Q3. Fixing the secret did not make the pod Ready — a second, independent fault surfaced. What does that reveal about how you should *sequence* remediations during an incident, and why is "fix one thing, re-observe" safer than batching fixes?
- Q4. `ImagePullBackOff` could be one of at least three distinct root causes. Name them and give the single `kubectl`/`crictl` check that discriminates a *typo in the tag* from a *private-registry auth failure*.

### Final remediation

8. Point the workload at an image that exists (use any small image you can pull, e.g. `registry.k8s.io/pause:3.9` just to reach Running for the drill), and verify Ready:

   ```bash
   kubectl -n platform set image deploy/notifier notifier=registry.k8s.io/pause:3.9
   kubectl -n platform rollout status deploy/notifier --timeout=60s
   kubectl -n platform get pods -l app=notifier
   ```

*Reference:* Debug Running Pods — <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/> · Determine the Reason for Pod Failure — <https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/>

---

## Exercise 2 — A failed admission webhook takes the whole platform down

**Scenario.** After installing a policy controller, *every* `kubectl apply` in the cluster starts hanging or failing. New deployments cannot roll out; even the platform team's own pipelines are stuck. This is the classic self-inflicted platform outage: a **failing admission webhook with `failurePolicy: Fail`** on a broad match, whose backend is unreachable.

### Setup (simulate the outage)

1. Register a validating webhook that points at a Service that does not exist, matching all pods:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingWebhookConfiguration
   metadata:
     name: platform-policy
   webhooks:
     - name: policy.platform.local
       admissionReviewVersions: ["v1"]
       sideEffects: None
       failurePolicy: Fail
       timeoutSeconds: 10
       clientConfig:
         service:
           name: policy-webhook
           namespace: platform
           path: /validate
           port: 443
       rules:
         - apiGroups: [""]
           apiVersions: ["v1"]
           operations: ["CREATE","UPDATE"]
           resources: ["pods"]
           scope: "*"
   EOF
   ```

### Diagnose

2. Reproduce the symptom deterministically and *time it* — latency is a signal:

   ```bash
   time kubectl -n platform run canary --image=registry.k8s.io/pause:3.9 --restart=Never
   ```

   Expected:

   ```
   Error from server (InternalError): Internal error occurred: failed calling webhook
   "policy.platform.local": failed to call webhook: ... service "policy-webhook" not found

   real    0m10.4s
   ```

3. Enumerate *all* webhooks in the cluster — the offender is rarely the one you just remembered:

   ```bash
   kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
     -o custom-columns='KIND:.kind,NAME:.metadata.name'
   ```

4. For each webhook, extract the three fields that decide blast radius — **`failurePolicy`, `rules`, and the backend target**:

   ```bash
   kubectl get validatingwebhookconfiguration platform-policy -o jsonpath='
   failurePolicy={.webhooks[0].failurePolicy}
   resources={.webhooks[0].rules[0].resources}
   service={.webhooks[0].clientConfig.service.namespace}/{.webhooks[0].clientConfig.service.name}
   {"\n"}'
   ```

5. Confirm the backend is genuinely unreachable, not just slow:

   ```bash
   kubectl -n platform get svc,endpoints policy-webhook
   # Error from server (NotFound): services "policy-webhook" not found
   ```

**Questions (block 2a)**
- Q5. Explain precisely why `failurePolicy: Fail` combined with `resources: ["pods"]` and `scope: "*"` produces a *cluster-wide* outage, while `failurePolicy: Ignore` would have degraded to "policy not enforced" instead. Which choice is correct for a **security** policy, and what is the standard mitigation that lets you keep `Fail` without self-destructing?
- Q6. Why did the request take ~10s to fail rather than failing instantly? Which field controls that, and how does a large `timeoutSeconds` on a broad webhook amplify a partial backend outage into a control-plane availability problem?

### Remediate

6. The immediate action in an outage is to **restore admission**, not to fix the webhook backend. Remove the broken configuration (you can re-register it once the backend is healthy):

   ```bash
   kubectl delete validatingwebhookconfiguration platform-policy
   ```

7. Verify admission is restored:

   ```bash
   time kubectl -n platform run canary --image=registry.k8s.io/pause:3.9 --restart=Never
   kubectl -n platform delete pod canary
   ```

**Questions (block 2b)**
- Q7. A colleague proposes fixing this permanently by adding a `namespaceSelector` that **excludes `kube-system` and the webhook's own namespace**. Why is excluding the webhook's own namespace (and the controllers that run it) essential to avoid a *deadlock* where the webhook cannot start because its own admission blocks it?
- Q8. You deleted the `ValidatingWebhookConfiguration` to stop the bleeding. What did that trade away, and what must go into the incident's follow-up so the policy is re-enabled safely rather than left permanently disabled (the classic "temporary" mitigation that never gets reverted)?

*Reference:* Dynamic Admission Control — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/> (see "Availability", "Failure policy", and "Avoiding operating on the kube-system namespace").

---

## Exercise 3 — DNS incident: services can't find each other

**Scenario.** Multiple services start reporting intermittent `no such host` / connection timeouts to their dependencies. Application code did not change. Cross-namespace calls are the loudest. Suspect the platform's DNS layer (CoreDNS).

### Setup (induce a DNS fault)

1. Scale CoreDNS to a single replica and then break its resolution for the cluster domain by shrinking it to zero to simulate an outage window:

   ```bash
   kubectl -n kube-system get deploy coredns
   kubectl -n kube-system scale deploy coredns --replicas=0     # simulate the outage
   ```

### Diagnose

2. From inside the cluster, reproduce with a disposable debug pod (do not trust the host's resolver — you must resolve *from the pod network*):

   ```bash
   kubectl run dns-probe --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
     --restart=Never -- sh -c '
       echo "--- resolv.conf ---"; cat /etc/resolv.conf;
       echo "--- kubernetes.default ---"; nslookup kubernetes.default || true;
     '
   ```

   Expected during the outage:

   ```
   nameserver 10.96.0.10
   ...
   ;; connection timed out; no servers could be reached
   ```

3. Localize: is it the *client*, the *Service VIP*, or the *DNS pods*? Check each layer:

   ```bash
   kubectl -n kube-system get svc kube-dns -o wide          # is the VIP/ClusterIP present?
   kubectl -n kube-system get endpoints kube-dns            # are there backend IPs?  <-- key
   kubectl -n kube-system get pods -l k8s-app=kube-dns      # are the pods Running/Ready?
   ```

   Expected — the smoking gun is **empty endpoints**:

   ```
   NAME       ENDPOINTS   AGE
   kube-dns   <none>      37d
   ```

**Questions (block 3a)**
- Q9. You saw `nameserver 10.96.0.10` in `/etc/resolv.conf` but the lookup timed out. Walk the request path from the pod to a CoreDNS pod (resolver → Service ClusterIP → kube-proxy/iptables|ipvs → endpoint). At which hop does an *empty Endpoints list* break the path, and why does that produce a *timeout* rather than an immediate `NXDOMAIN`?
- Q10. Why is `kubectl get endpoints kube-dns` a more decisive check than `kubectl get svc kube-dns`? What can a healthy-looking Service object hide?

### Remediate

4. Restore capacity and confirm endpoints repopulate:

   ```bash
   kubectl -n kube-system scale deploy coredns --replicas=2
   kubectl -n kube-system rollout status deploy coredns
   kubectl -n kube-system get endpoints kube-dns
   ```

5. Re-run the probe to prove recovery from the *data plane*, not just the control plane:

   ```bash
   kubectl run dns-probe --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
     --restart=Never -- nslookup kubernetes.default
   ```

**Questions (block 3b)**
- Q11. Suppose instead the pods were `Running` but CoreDNS logs showed `plugin/errors ... i/o timeout` when forwarding to the upstream resolver. That is a *different* root cause with the same user symptom. How would you distinguish "CoreDNS is down" from "CoreDNS is up but upstream forwarding is broken," and what does the `forward` plugin's config in the `coredns` ConfigMap have to do with it?
- Q12. Two prevention controls would have blunted this incident: a `PodDisruptionBudget` on CoreDNS and NodeLocal DNSCache. Explain what each one protects against and why they address *different* failure modes.

*Reference:* Debugging DNS Resolution — <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/> · CoreDNS — <https://coredns.io/plugins/forward/> · NodeLocal DNSCache — <https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/>

---

## Exercise 4 — Node pressure and an eviction storm

**Scenario.** An alert fires: pods across a node are being evicted, and a stateful platform component keeps getting killed. You suspect resource exhaustion and missing guardrails (no requests/limits, no PDB).

### Setup (create a memory hog with no limits)

1. Deploy a pod that grows memory unbounded and has **no limits** (so the kubelet — not a cgroup — must react):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata: { name: hog, namespace: platform, labels: { app: hog } }
   spec:
     containers:
       - name: hog
         image: registry.k8s.io/e2e-test-images/agnhost:2.47
         command: ["sh","-c","tail -f /dev/null"]
         resources:
           requests: { memory: 32Mi }
           # NOTE: no limits on purpose
   EOF
   ```

### Diagnose

2. Read node conditions and pressure signals:

   ```bash
   kubectl get nodes -o wide
   kubectl describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
   ```

   Look for:

   ```
   MemoryPressure   True    ...   KubeletHasInsufficientMemory
   ```

3. Find *who is being evicted and why* — evictions leave Pod objects behind with a status reason:

   ```bash
   kubectl get pods -A --field-selector status.phase=Failed
   kubectl -n platform get pod <evicted-pod> -o jsonpath='{.status.reason}: {.status.message}{"\n"}'
   # Evicted: The node was low on resource: memory. ...
   ```

4. Distinguish an **eviction** (kubelet reclaims under node pressure, graceful-ish) from an **OOMKill** (kernel kills a container that hit its cgroup limit):

   ```bash
   kubectl -n platform get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}={.lastState.terminated.reason}{"\n"}{end}'
   # hog=OOMKilled     <-- kernel/cgroup, exit 137
   ```

**Questions (block 4a)**
- Q13. Explain the difference between a **kubelet eviction** under `MemoryPressure` and a **kernel OOMKill**. Which one is triggered by *node-level* pressure and which by a *container's own limit*? Why can a pod with **no memory limit** still be killed (and under which QoS class does it become the *first* victim)?
- Q14. The three QoS classes (`Guaranteed`, `Burstable`, `BestEffort`) determine eviction order. Given the `hog` pod above (request set, no limit), which QoS class is it, and where does it sit in the eviction ranking relative to a `Guaranteed` pod?

### Remediate

5. Apply the missing guardrails — set a limit so the fault is contained to the offending container, and protect the critical component with a PDB:

   ```bash
   kubectl -n platform delete pod hog
   # (in the real component's Deployment) add limits and a PDB:
   cat <<'EOF' | kubectl apply -f -
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata: { name: notifier-pdb, namespace: platform }
   spec:
     minAvailable: 1
     selector:
       matchLabels: { app: notifier }
   EOF
   ```

6. Add a namespace-level default via a `LimitRange` so future workloads cannot ship without limits:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: LimitRange
   metadata: { name: default-limits, namespace: platform }
   spec:
     limits:
       - type: Container
         default:        { cpu: 200m, memory: 256Mi }
         defaultRequest: { cpu: 50m,  memory: 64Mi }
   EOF
   ```

**Questions (block 4b)**
- Q15. A `PodDisruptionBudget` protects against *voluntary* disruptions but **not** node-pressure evictions. Given that, what incident does the PDB actually prevent (think `kubectl drain` during a node upgrade), and why is it the wrong tool to stop the eviction storm you just saw?
- Q16. The `LimitRange` sets *defaults*, while a `ResourceQuota` sets *ceilings*. During this incident, which one would have prevented the unbounded hog from ever being admitted, and which one only makes the *next* team's omission less dangerous? Why do mature platforms deploy both?

*Reference:* Node-pressure Eviction — <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> · QoS Classes — <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/> · PDB — <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/>

---

## Exercise 5 — GitOps drift: a reconciliation that will not converge

**Scenario.** The platform is GitOps-managed (Argo CD or Flux). A change was merged, but the live cluster does not match Git. The app shows `OutOfSync`/`Degraded` and keeps flapping. Something is fighting the reconciler.

> Do this exercise conceptually if you do not have Argo CD installed; the diagnostic *reasoning* is the objective, not the specific CLI.

### Diagnose

1. Establish the source of truth vs. the live state — never remediate a GitOps resource by hand until you know *why* it drifted:

   ```bash
   # Argo CD
   argocd app get platform-notifier
   argocd app diff platform-notifier
   # or, cluster-native:
   kubectl -n argocd get application platform-notifier -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
   ```

2. Read the *reconciliation* condition, not just the sync status — the message names the blocker:

   ```bash
   kubectl -n argocd get application platform-notifier \
     -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
   ```

   Typical culprits you are looking for:

   ```
   ComparisonError: Deployment "notifier" is invalid: spec.template ... field is immutable
   ```

3. Check for a *second controller* mutating the same object (an HPA changing replicas, a mutating webhook injecting fields, a human `kubectl edit`):

   ```bash
   kubectl -n platform get deploy notifier -o yaml \
     | grep -iA3 'managedFields' | grep 'manager:'
   ```

**Questions (block 5a)**
- Q17. Argo CD reports `OutOfSync` forever and re-syncs on a loop. One common cause is a **field owned by another controller** (e.g., an HPA managing `spec.replicas` while Git also declares `replicas`). Explain the fight, and name the Argo CD setting (`ignoreDifferences`) that resolves it *correctly* versus the wrong fix of deleting the HPA.
- Q18. Server-Side Apply records `managedFields`. How does inspecting `managedFields` let you attribute a drift to a specific *field manager*, and why is that more reliable than guessing from the diff alone?

### Remediate

4. If the blocker is an immutable-field error (e.g., changing a Deployment's `selector`), the correct remediation is **recreate, not patch**. Confirm the failing field, then let GitOps recreate:

   ```bash
   # Do NOT hand-edit live state. Fix Git, then:
   argocd app sync platform-notifier --replace   # replace semantics for immutable-field changes
   ```

5. If a controller owns the field, add an explicit ignore in the Application spec so the reconciler stops fighting:

   ```yaml
   spec:
     ignoreDifferences:
       - group: apps
         kind: Deployment
         jsonPointers: ["/spec/replicas"]   # HPA owns replicas
   ```

**Questions (block 5b)**
- Q19. A teammate "fixed" the drift by running `kubectl edit deploy notifier` directly. Why does this *guarantee* the incident recurs within one reconciliation interval, and what does it teach about the correct place to remediate in a GitOps platform (the **source**, not the cluster)?
- Q20. When is disabling auto-sync (`argocd app set --sync-policy none`) the *right* incident action, and what is the risk of leaving it disabled after the incident closes?

*Reference:* Argo CD Sync Options / Diffing — <https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/> · Server-Side Apply & field management — <https://kubernetes.io/docs/reference/using-api/server-side-apply/>

---

## Exercise 6 — Expired certificate silently breaks a webhook / ingress

**Scenario.** At 00:00 UTC, a subset of requests to an internal endpoint start failing with TLS errors, and one admission webhook flips to failing. Nothing was deployed. Time-based failures point at **certificate expiry** — the incident that no code change explains.

### Diagnose

1. Inspect the serving certificate directly (works for ingress, webhooks, API-served endpoints):

   ```bash
   echo | openssl s_client -connect notifier.platform.svc:443 -servername notifier 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates
   ```

   Expected:

   ```
   subject=CN = notifier.platform.svc
   notBefore=... 2025
   notAfter=Aug  6 23:59:59 2026 GMT      <-- yesterday
   ```

2. If cert-manager issues it, read the `Certificate` object's conditions — they tell you renewal state and *why* renewal stalled:

   ```bash
   kubectl -n platform get certificate
   kubectl -n platform describe certificate notifier-tls | sed -n '/Status:/,$p'
   kubectl -n platform get certificaterequest,order,challenge 2>/dev/null
   ```

3. For a webhook, the failure is often a **CA bundle mismatch**: the served cert rotated but the `caBundle` in the webhook config was not updated. Compare them:

   ```bash
   kubectl get validatingwebhookconfiguration platform-policy \
     -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -dates
   ```

**Questions (block 6a)**
- Q21. Give at least three reasons a cert-manager `Certificate` fails to auto-renew before expiry (think ACME challenge failures, a paused issuer, RBAC on the Secret, clock skew). For each, name the object whose `status.conditions` reveals it.
- Q22. Even with a valid, freshly rotated serving certificate, an admission webhook can still fail TLS. Why? Explain the role of the webhook's `clientConfig.caBundle` and why cert rotation and CA-bundle injection must be *coupled* (e.g., cert-manager's `cainjector` or Helm's `--reuse-values` pitfalls).

### Remediate

4. Force an immediate renewal (do not wait for the controller's next cycle during an active outage):

   ```bash
   kubectl -n platform delete secret notifier-tls    # cert-manager re-issues into a fresh Secret
   # or, with newer cmctl:
   cmctl renew notifier-tls -n platform
   kubectl -n platform get certificate notifier-tls -w   # wait for Ready=True
   ```

5. Reconcile the consumers so they pick up the new cert/CA:

   ```bash
   kubectl -n platform rollout restart deploy/notifier          # reload served cert
   # ensure caBundle updated (cainjector annotation on the webhook config)
   ```

**Questions (block 6b)**
- Q23. Why is "delete the Secret to force reissue" safe for a cert-manager-managed `Certificate` but *dangerous* for a hand-managed TLS secret? What is the one-line difference in ownership that makes deletion self-healing in one case and an outage in the other?
- Q24. This class of incident is 100% predictable and therefore 100% preventable. Name two monitoring controls (one metric-based, one synthetic) that would page you *before* expiry, and state a sensible lead time and why 24h is usually too short.

*Reference:* cert-manager troubleshooting — <https://cert-manager.io/docs/troubleshooting/> · cainjector — <https://cert-manager.io/docs/concepts/ca-injector/>

---

## Exercise 7 — From SLO burn-rate alert to root cause to blameless postmortem

**Scenario.** You are not paged on a symptom ("pod down") but on an **SLO burn-rate alert**: the checkout API is burning its 30-day error budget fast. This is the platform-engineering way to run incidents — page on user-visible impact, then drill down.

### Diagnose (top-down, symptom → cause)

1. Confirm the alert and its severity by reading the **burn rate**, not raw error count:

   ```promql
   # 1h fast-burn window (paging): error ratio over the SLO threshold, e.g. 14.4x for a 99.9% SLO
   (
     sum(rate(http_requests_total{job="checkout",code=~"5.."}[1h]))
     /
     sum(rate(http_requests_total{job="checkout"}[1h]))
   ) > (14.4 * (1 - 0.999))
   ```

2. Localize the errors — which dependency, which version, which node? Slice the same metric:

   ```promql
   topk(5,
     sum by (upstream, code) (
       rate(http_requests_total{job="checkout",code=~"5.."}[5m])
     )
   )
   ```

3. Correlate with a deploy or infra change (the highest-prior-probability cause). Check rollout history and recent events:

   ```bash
   kubectl -n shop rollout history deploy/checkout
   kubectl -n shop get events --sort-by=.lastTimestamp | tail -20
   ```

4. Pull the evidence chain together: alert → PromQL slice → correlated change → the specific failing dependency (say, `payments` returning 503 after its own bad rollout).

**Questions (block 7a)**
- Q25. Why does a **multi-window, multi-burn-rate** alert (e.g., 1h *and* 5m windows both breaching) reduce both false pages and slow detection, compared to a simple "error rate > 1%" threshold? What does the short window add that the long window cannot?
- Q26. The burn-rate math `14.4 × (1 − SLO)` for a 1h window corresponds to consuming a fixed fraction of a 30-day budget. Conceptually, what does a "14.4x burn rate" *mean* in plain terms, and why is pairing it with a shorter confirmation window the standard Google SRE recommendation?

### Remediate (stop the bleeding first)

5. The fastest safe remediation for a bad rollout is **roll back**, not debug-in-prod:

   ```bash
   kubectl -n shop rollout undo deploy/payments
   kubectl -n shop rollout status deploy/payments
   ```

6. Verify recovery at the SLI, then confirm the budget stops burning:

   ```promql
   sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
   / sum(rate(http_requests_total{job="checkout"}[5m]))
   ```

### Prevent (close the loop)

7. Draft the blameless postmortem skeleton immediately, while the timeline is fresh:

   ```
   - Impact:            what the user experienced, duration, budget consumed (%)
   - Detection:         how we found out (alert name, time to detect)
   - Timeline (UTC):    change merged → deployed → alert → mitigated → resolved
   - Root cause:        the technical fault (5 whys), not "human error"
   - Trigger:           the change that exposed it
   - Mitigation:        what stopped the bleeding
   - Action items:      each with owner + due date; at least one *systemic* control
   - What went well:    detection, tooling, comms
   ```

**Questions (block 7b)**
- Q27. Distinguish **mitigation** (rollback) from **root-cause remediation** (the code/config fix). Why is it correct to declare the incident *mitigated* before you understand the root cause, and what does that separation protect (MTTR vs. thoroughness)?
- Q28. A "blameless" postmortem still assigns action items. Reconcile those: how do you write a root cause and follow-ups that improve the *system* (guardrails, tests, canary, progressive delivery) without naming a person as the cause — and why does blame *reduce* future reliability?
- Q29. The `payments` bad rollout reached 100% of traffic before the alert fired. Which **progressive delivery** control (canary / blue-green / automated rollback on SLO breach, e.g., Argo Rollouts or Flagger) would have capped the blast radius, and what SLI would you wire it to?

*Reference:* Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate) — <https://sre.google/workbook/alerting-on-slos/> · Postmortem culture — <https://sre.google/sre-book/postmortem-culture/> · Argo Rollouts — <https://argoproj.github.io/argo-rollouts/>

---

## Cleanup

```bash
kubectl delete ns platform --wait=false
kubectl delete validatingwebhookconfiguration platform-policy --ignore-not-found
kind delete cluster --name cnpe-23   # if you created a throwaway cluster
```

---

## Answers

<details>
<summary><strong>Show answers (Exercises 1–7)</strong></summary>

**A1.** `CreateContainerConfigError` is raised during **container *configuration*** — the kubelet is assembling the container's environment (mounting secrets/configmaps) and cannot, so the container process never starts. `CrashLoopBackOff` means the process *did* start and then *exited non-zero repeatedly*. The distinction localizes the fault: config-error → a declared dependency (Secret/ConfigMap/volume) is missing or malformed; CrashLoop → the application itself is failing at runtime. You do not read application logs for a config error — there is no application yet.

**A2.** Kubernetes reports the **secret/config error first**, before the image pull is even attempted in some orderings — but more precisely, the kubelet must *pull the image* and *resolve the container config* as separate phases, and it surfaces whichever phase blocks first. Here the `secretKeyRef` resolution fails during container creation. The lesson: container lifecycle phases (pull → create/config → start → run) fail in order, and each fix can *unmask* the next phase's fault — which is exactly what step 6 demonstrated.

**A3.** Faults are layered; a remediation can *reveal* the next latent fault rather than fully fixing the workload. "Fix one thing, re-observe" keeps a clean causal chain and prevents you from attributing recovery (or a new failure) to the wrong change. Batching fixes during an incident means that if the pod is *still* broken you cannot tell which of your three edits helped, hurt, or did nothing — you have destroyed your own signal.

**A4.** `ImagePullBackOff` root causes: (1) wrong image name/tag (image genuinely does not exist), (2) private registry auth failure (missing/incorrect `imagePullSecrets`), (3) registry unreachable / rate-limited / network-policy block. Discriminator: `kubectl describe pod` events — a **typo** yields `manifest for <img> not found` / `not found: manifest unknown`, whereas an **auth** failure yields `unauthorized` / `denied: requested access to the resource is denied` / `401`. (On the node, `crictl pull <image>` reproduces the exact error out-of-band from Kubernetes.)

**A5.** With `failurePolicy: Fail`, if the webhook backend is unreachable the API server **rejects** the request rather than allowing it. Because the rule matches `pods` at `scope: "*"`, *every* pod create/update across the cluster is gated on a webhook that cannot answer → nothing can be scheduled, rolled out, or self-healed. With `failurePolicy: Ignore`, an unreachable backend causes the API server to **admit** the request unchecked → policy is silently *not enforced* (a security gap) but the platform keeps running. For a **security** policy you want `Fail` (fail-closed). The standard mitigation to keep `Fail` without self-destruction: **high-availability backend** (≥2 replicas, PDB, spread), a **tight `namespaceSelector`/`objectSelector`** to shrink the match set, a short `timeoutSeconds`, and excluding system namespaces so the control plane and the webhook's own dependencies are never gated on it.

**A6.** `timeoutSeconds: 10` — the API server waits up to that long for the webhook to respond before applying `failurePolicy`. A large timeout on a broad rule turns a slow/partial backend into a **latency amplifier**: every matched request stalls for the full timeout, inflating API-server request latency and exhausting client and inflight-request budgets — a partial outage becomes a control-plane availability problem. Keep timeouts small (1–5s) for broad webhooks.

**A7.** Excluding the webhook's own namespace prevents a **bootstrap deadlock**: if the webhook (or its dependencies — cert secret, config) must be created/updated to come up, but *those very operations* are gated on the webhook being available, it can never start. It is a chicken-and-egg lock. Excluding `kube-system` similarly protects the control-plane components the whole cluster depends on. This is why the Kubernetes docs explicitly recommend not operating on `kube-system` and using selectors to exempt the webhook's own namespace.

**A8.** Deleting the `ValidatingWebhookConfiguration` traded away **policy enforcement** — during the window the platform is running without whatever the webhook guaranteed (e.g., no privileged pods, required labels, image provenance). Follow-up must: (a) fix the backend (HA, correct Service/Endpoints), (b) re-register the webhook with a tight selector, `Ignore` or `Fail` chosen deliberately, small timeout, and namespace exclusions, and (c) add an action item + owner so re-enablement actually happens. Otherwise the "temporary" removal becomes a permanent silent security regression.

**A9.** Path: pod resolver reads `nameserver 10.96.0.10` (the `kube-dns` Service ClusterIP) → sends DNS query to that VIP → kube-proxy's iptables/ipvs rules DNAT the VIP to one of the Service's **endpoints** (CoreDNS pod IPs) → CoreDNS answers. With an **empty Endpoints list**, kube-proxy has no backend to DNAT to, so the packet is dropped/blackholed → the client **times out** (no server ever replies). It is not `NXDOMAIN` because `NXDOMAIN` is an *answer from a working resolver saying "that name does not exist"*; here no resolver answers at all, so the client waits and times out.

**A10.** A `Service` object can exist and look perfectly healthy (has a ClusterIP, correct ports, correct selector) while having **zero ready backends** — because Endpoints are populated only by pods matching the selector *and passing readiness*. `kubectl get endpoints` shows the actual data-plane targets; `<none>` proves the traffic path is broken regardless of how correct the Service spec looks. The Service is the *intent*; Endpoints are the *reality*.

**A11.** "CoreDNS down" = pods not Running/Ready, Endpoints empty, lookups of *any* name (including `kubernetes.default`) time out. "CoreDNS up but upstream broken" = CoreDNS pods Running, in-cluster names (`*.svc.cluster.local`) resolve fine, but **external** names (`example.com`) fail, and CoreDNS logs show `forward` errors (`i/o timeout`, `no route to host`) to the upstream. The `forward` plugin in the `coredns` ConfigMap defines the upstream resolvers (often `/etc/resolv.conf` of the node); if that upstream or the node's egress is broken, cluster DNS resolves internal but not external — a fundamentally different fix (node networking / upstream) than "scale CoreDNS."

**A12.** A **PDB** on CoreDNS prevents *voluntary* disruptions (node drains during upgrades, cluster-autoscaler scale-down) from taking all CoreDNS replicas below `minAvailable` at once — it protects against operator/automation actions. **NodeLocal DNSCache** runs a caching agent on every node so pods query a local cache first, which (a) survives brief central CoreDNS unavailability from cache, (b) cuts latency and conntrack pressure, and (c) reduces load on central CoreDNS. Different failure modes: PDB protects *availability of the central replicas during maintenance*; NodeLocal protects *the query path's resilience and performance* independent of central-replica count.

**A13.** A **kubelet eviction** is triggered by **node-level** pressure (`MemoryPressure`, `DiskPressure`): the kubelet proactively reclaims by evicting pods according to QoS and priority, to keep the *node* alive. A **kernel OOMKill** happens when a *container* exceeds its own **cgroup memory limit** — the kernel's OOM killer terminates a process (exit 137). A pod with **no memory limit** has no cgroup ceiling, so it can grow until it causes *node* pressure, at which point the **kubelet evicts** it (and, being `Burstable`/`BestEffort`, it is ranked to go first). So: no-limit pods are killed by *node pressure eviction*, limited pods by *cgroup OOMKill*.

**A14.** `hog` has a memory *request* but **no memory limit** → its requests≠limits and not all resources are bounded → **`Burstable`** QoS. Eviction ranking under node pressure (worst first): `BestEffort` → `Burstable` (those exceeding requests most, first) → `Guaranteed` (last). So `hog` (Burstable, exceeding its 32Mi request) is evicted well before any `Guaranteed` pod.

**A15.** A PDB governs **voluntary** disruptions — the eviction API used by `kubectl drain`, cluster-autoscaler, and rollout tooling. It ensures at least `minAvailable` pods survive a *planned* operation (e.g., draining a node for a kernel upgrade won't take your last replica). It has **no effect** on node-pressure evictions or OOMKills, which are *involuntary* — the kubelet must reclaim to save the node and ignores the PDB. So the PDB prevents the *maintenance-induced* outage, not the *resource-exhaustion* one.

**A16.** A **`LimitRange`** with a default limit would have caused the hog to be **admitted with an injected memory limit** (256Mi here) — so the kernel would OOMKill just that container at 256Mi instead of letting it starve the node; and a `LimitRange` can also set a `max` that *rejects* pods requesting/limiting beyond policy. A **`ResourceQuota`** caps *aggregate* namespace consumption and can require that every pod *declare* requests/limits (admission fails otherwise) — that requirement would have blocked the limitless hog at admission. Mature platforms deploy both: `ResourceQuota` for hard namespace ceilings + mandatory declarations, `LimitRange` for safe per-container defaults so a team's omission degrades gracefully instead of taking a node down.

**A17.** The fight: Git declares `spec.replicas: N`, the HPA also writes `spec.replicas` based on load. Every reconcile, Argo sees live≠desired (HPA changed it), marks `OutOfSync`, re-applies N, HPA changes it back — an infinite oscillation. Correct fix: `spec.ignoreDifferences` on `/spec/replicas` (or remove `replicas` from the Git manifest entirely) so Argo yields ownership of that field to the HPA. Wrong fix: deleting the HPA removes autoscaling — you "fixed" the diff by deleting the feature.

**A18.** Server-Side Apply stamps every field with the **field manager** that last set it, recorded under `metadata.managedFields`. Reading it tells you *which controller/user owns which field* (e.g., `manager: kube-controller-manager` owns `replicas` when an HPA is active, `manager: argocd-controller` owns the rest). That is authoritative attribution from the API server itself, versus inferring intent from a textual diff that only shows *what* differs, not *who* keeps changing it.

**A19.** `kubectl edit` mutates *live cluster state only*; Git — the reconciler's source of truth — is unchanged. On the next sync interval, the GitOps controller compares live vs. Git, sees the hand-edit as drift, and **reverts it back to Git's version**. So the manual fix is guaranteed to be undone within one reconciliation. Lesson: in GitOps the cluster is a *projection* of Git; you remediate at the **source** (open a PR / change the manifest), never in the live cluster, or you are fighting your own automation.

**A20.** Disabling auto-sync is right when the *reconciler itself is amplifying the incident* — e.g., it keeps re-applying a manifest that crashes the app, or you need to hand-stabilize while you prepare a proper Git fix. It buys a controlled window. The risk of leaving it off after the incident: the cluster silently drifts from Git, future PRs don't deploy, and you lose the very guarantee (Git = truth) that makes GitOps safe. Re-enabling auto-sync must be an explicit action item with an owner before the incident is closed.

**A21.** Common auto-renew failures and the object whose `status.conditions` reveals each: (1) **ACME HTTP-01/DNS-01 challenge failing** → the `Challenge` (and its `Order`) object shows `pending`/`invalid` with the reason; (2) **Issuer/ClusterIssuer paused or misconfigured** (bad ACME account, wrong solver) → the `Issuer` conditions and the `CertificateRequest`; (3) **RBAC/permissions on the target Secret** so cert-manager can't write it → the `Certificate`/controller logs; (4) **clock skew / wrong `renewBefore`** → the `Certificate` status `renewalTime`; (5) rate-limited by the ACME CA → `Order` status. The rule: walk `Certificate → CertificateRequest → Order → Challenge` and read conditions at each level.

**A22.** A webhook's `clientConfig.caBundle` is the CA the **API server** uses to verify the webhook's serving certificate during the TLS handshake. If the serving cert rotates to one signed by a (new) CA but the `caBundle` still pins the old CA, the API server rejects the handshake → webhook fails even though the cert is valid. Cert rotation and CA-bundle update must be **coupled**: cert-manager's `cainjector` watches the CA and injects the current `caBundle` into the webhook config automatically; doing rotation without updating the bundle (or a Helm upgrade that resets an injected bundle) breaks TLS.

**A23.** For a cert-manager-managed `Certificate`, the **`Certificate` object owns/controls the Secret** — deleting the Secret triggers the controller to *re-issue* immediately into a fresh Secret (self-healing). For a **hand-managed** TLS Secret there is no controller watching it; deleting it just removes the cert and causes an outage with nothing to recreate it. The one-line difference: *ownership by a reconciling controller* — with it, delete = reissue; without it, delete = data loss.

**A24.** (1) **Metric-based**: alert on cert-manager's `certmanager_certificate_expiration_timestamp_seconds` (or a blackbox-exporter `probe_ssl_earliest_cert_expiry`) crossing `now + lead_time`. (2) **Synthetic/blackbox**: a probe that TLS-connects to each endpoint and alerts on days-to-expiry. Sensible lead time: **2–3 weeks** (e.g., alert at 21 days, page at 7). 24h is too short because renewal itself can be *blocked* (a failing ACME challenge, rate limits, a paused issuer) — you need enough runway to *fix the renewal pipeline*, not just notice the deadline.

**A25.** A single fixed threshold ("error rate > 1%") forces a bad trade: set it sensitive → false pages on brief blips; set it tolerant → slow to detect real fast burns. **Multi-window multi-burn-rate** requires *both* a long window (e.g., 1h, high signal, low noise — confirms the burn is sustained) *and* a short window (e.g., 5m — confirms it's *still happening now*, not a stale long-window average) to breach before paging. The short window adds **fast recovery detection and reduced alert-flap**: it prevents paging for an incident that already ended, and it speeds detection of a sharp spike that a 1h average would smear out.

**A26.** A "14.4x burn rate" means you are consuming error budget **14.4 times faster than the sustainable rate** — at that pace you would exhaust a *30-day* budget in roughly **2 days** (and a 1h breach at 14.4x has already spent ~2% of the whole month's budget). It corresponds to the fast-burn page threshold for a 99.9% SLO. Pairing it with a shorter confirmation window (per Google SRE) filters transient spikes: you page only when a high burn rate is confirmed *both* over the significant window and *right now*, balancing detection time against precision.

**A27.** **Mitigation** stops user-visible impact (rollback restores the last-good version); **root-cause remediation** fixes the underlying defect (the bug in the new `payments` code/config). Declaring "mitigated" before understanding root cause is correct because **MTTR is measured against user impact, not against understanding** — every minute spent debugging in prod while users see 503s is budget burned needlessly. The separation protects both: fast mitigation minimizes MTTR; the unhurried root-cause analysis afterward (in a non-firefighting context) is more thorough and less error-prone.

**A28.** Write the root cause as a **systemic property of the socio-technical system**: "a config change with an invalid value reached 100% of production because there was no canary gate and no schema validation in CI" — not "Alice pushed a bad config." Action items then target the *system*: add schema validation, add a canary stage with automatic SLO-based rollback, add a required review for that config. Blame *reduces* future reliability because it makes engineers hide mistakes, stop reporting near-misses, and act defensively — starving you of the signal you need to harden the system. People act within the affordances the system gives them; fix the affordances.

**A29.** A **canary** (or automated **progressive rollout with SLO-based auto-rollback**, e.g., Argo Rollouts / Flagger) would have shifted only a small percentage of traffic to the new `payments` version first, measured the SLI, and **automatically rolled back** on breach — capping blast radius to that canary slice instead of 100%. Wire the analysis to the **user-facing SLI that defines the SLO** here: the checkout **success ratio / error rate** (and/or p99 latency) for traffic hitting the canary, so the rollout is gated on the exact signal the burn-rate alert watches.

</details>