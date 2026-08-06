# Guided Exercises — Topic 1.4: Platform Architecture and Core Capabilities

**Prerequisites.** A Linux/macOS workstation with `docker`, `kind` (≥ 0.23), `kubectl` (≥ 1.30), `helm` (≥ 3.14) and `yq` (mikefarah, v4). Every exercise is self-contained and idempotent; the cluster is disposable and is deleted at the end.

These exercises build, piece by piece, a **minimal internal developer platform (IDP)** on a local cluster. Each piece maps to one of the capability domains defined in the [CNCF Platforms Whitepaper](https://tag-app-delivery.cncf.io/whitepapers/platforms/), so by the end you will have touched the architecture the CNPA exam expects you to reason about: interfaces vs. capabilities, control plane vs. data plane, self-service provisioning, golden paths, and platform APIs.

---

## Exercise 1 — Build a platform capability inventory

The whitepaper defines a platform as *"an integrated collection of capabilities... framed and presented according to the needs of the platform's users."* Before writing any YAML for a cluster, a platform architect maps **which capabilities exist, who provides them, and where the gaps are**. You will encode that map as data and query it — because in platform engineering, even the platform's own state should be everything-as-code.

1. Create a working directory:

   ```bash
   mkdir -p ~/cnpa-1.4 && cd ~/cnpa-1.4
   ```

2. Create `capability-map.yaml` with the capability domains from the whitepaper, annotated with your (fictional) organization's current state:

   ```yaml
   # capability-map.yaml — capability domains per the CNCF Platforms Whitepaper
   platform: acme-idp
   interfaces:
     - name: web-portal          # e.g. Backstage
       provided: false
     - name: api-cli             # e.g. Kubernetes API + kubectl plugin
       provided: true
     - name: golden-path-templates
       provided: false
   capabilities:
     - { name: ci-build-test,            provided: true,  provider: "GitHub Actions" }
     - { name: cd-delivery-verification, provided: true,  provider: "Argo CD" }
     - { name: development-environments, provided: false, provider: null }
     - { name: observability,            provided: false, provider: null }
     - { name: infrastructure-services,  provided: true,  provider: "Kubernetes + Cluster API" }
     - { name: data-services,            provided: false, provider: null }
     - { name: messaging-event-services, provided: false, provider: null }
     - { name: identity-secret-mgmt,     provided: true,  provider: "cert-manager + External Secrets" }
     - { name: security-services,        provided: false, provider: null }
     - { name: artifact-storage,         provided: true,  provider: "Harbor" }
   ```

3. Query the gaps — the capabilities application teams currently build themselves, duplicating effort:

   ```bash
   yq '.capabilities[] | select(.provided == false) | .name' capability-map.yaml
   ```

   Expected output:

   ```text
   development-environments
   observability
   data-services
   messaging-event-services
   security-services
   ```

4. Count coverage, the first number a platform product owner reports:

   ```bash
   yq '[.capabilities[] | select(.provided == true)] | length' capability-map.yaml
   ```

   Expected output: `5`

**Q1.1** — The map separates `interfaces` from `capabilities`. According to the whitepaper's architecture, what is the difference between a platform *interface* and a platform *capability*, and why can the same capability sit behind several interfaces at once?

**Q1.2** — The whitepaper insists platforms be managed **"as a product."** What does that mean concretely for the five gaps you just listed — who decides which gap gets closed first, and based on what input?

---

## Exercise 2 — Self-service provisioning: Namespace-as-a-Service

The single most common first capability of an IDP is **tenant onboarding**: a developer team requests an environment and receives — without a ticket — a namespace with quotas, safe defaults, RBAC, network isolation, and security guardrails already applied. You will build that bundle and verify each guardrail fires.

1. Create the lab cluster:

   ```bash
   kind create cluster --name platform-lab
   ```

   Expected output (versions may differ):

   ```text
   Creating cluster "platform-lab" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
   Set kubectl context to "kind-platform-lab"
   ```

2. Create `tenant-onboarding.yaml` — the entire tenant contract in one file:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: team-checkout
     labels:
       platform.example.io/tier: standard
       pod-security.kubernetes.io/enforce: baseline
       pod-security.kubernetes.io/warn: restricted
       pod-security.kubernetes.io/audit: restricted
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-checkout-quota
     namespace: team-checkout
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
       pods: "20"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: team-checkout-limits
     namespace: team-checkout
   spec:
     limits:
       - type: Container
         defaultRequest:
           cpu: 100m
           memory: 128Mi
         default:
           cpu: 500m
           memory: 256Mi
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: team-checkout-devs-edit
     namespace: team-checkout
   subjects:
     - kind: Group
       name: team-checkout-devs
       apiGroup: rbac.authorization.k8s.io
   roleRef:
     kind: ClusterRole
     name: edit
     apiGroup: rbac.authorization.k8s.io
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: team-checkout
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   ```

3. Apply it and confirm all five objects land:

   ```bash
   kubectl apply -f tenant-onboarding.yaml
   ```

   Expected output:

   ```text
   namespace/team-checkout created
   resourcequota/team-checkout-quota created
   limitrange/team-checkout-limits created
   rolebinding/team-checkout-devs-edit created
   networkpolicy/default-deny-ingress created
   ```

4. Verify the quota is armed:

   ```bash
   kubectl describe quota team-checkout-quota -n team-checkout
   ```

   Expected output:

   ```text
   Name:            team-checkout-quota
   Namespace:       team-checkout
   Resource         Used  Hard
   --------         ----  ----
   limits.cpu       0     8
   limits.memory    0     16Gi
   pods             0     20
   requests.cpu     0     4
   requests.memory  0     8Gi
   ```

5. Verify RBAC scoping with impersonation — a checkout developer can deploy in their namespace but nowhere else:

   ```bash
   kubectl auth can-i create deployments -n team-checkout \
     --as=jane --as-group=team-checkout-devs
   kubectl auth can-i create deployments -n kube-system \
     --as=jane --as-group=team-checkout-devs
   ```

   Expected output:

   ```text
   yes
   no
   ```

6. Launch a pod **without** declaring resources, and watch the platform's defaults kick in:

   ```bash
   kubectl run probe --image=nginxinc/nginx-unprivileged:1.27-alpine -n team-checkout
   kubectl get pod probe -n team-checkout \
     -o jsonpath='{.spec.containers[0].resources}' ; echo
   ```

   Expected output (note the `Warning:` line — the pod is admitted, but the `restricted` profile flags it):

   ```text
   Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "probe" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "probe" must set securityContext.capabilities.drop=["ALL"]), seccompProfile (pod or container "probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   pod/probe created
   {"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
   ```

**Q2.1** — Which whitepaper capability domain does Namespace-as-a-Service implement, and why is delivering it through the Kubernetes API architecturally superior to delivering it through a ticket queue that a human resolves in a day?

**Q2.2** — In step 6, the pod got CPU/memory values it never asked for. Which object injected them, and what failure mode would occur if the namespace had the `ResourceQuota` but **no** `LimitRange`?

**Q2.3** — The namespace enforces Pod Security level `baseline` but only *warns* at `restricted`. Why is this staged approach (`enforce` low, `warn`/`audit` high) the standard production rollout pattern for a platform team, rather than enforcing `restricted` on day one?

---

## Exercise 3 — A platform API: abstraction with validation at the control plane

Portals come and go; the durable heart of a platform is its **API**. You will extend the Kubernetes control plane with a `WebApp` abstraction: a small, opinionated schema that hides Deployments/Services/HPAs behind a contract, with organizational policy compiled into the API itself using [CEL validation rules](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules).

1. Create `webapp-crd.yaml`:

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: webapps.platform.example.io
   spec:
     group: platform.example.io
     scope: Namespaced
     names:
       plural: webapps
       singular: webapp
       kind: WebApp
       shortNames: [wa]
     versions:
       - name: v1alpha1
         served: true
         storage: true
         additionalPrinterColumns:
           - name: Image
             type: string
             jsonPath: .spec.image
           - name: Replicas
             type: integer
             jsonPath: .spec.replicas
           - name: Tier
             type: string
             jsonPath: .spec.tier
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 required: [image]
                 properties:
                   image:
                     type: string
                     description: "Container image, pinned tag mandatory."
                     x-kubernetes-validations:
                       - rule: "!self.endsWith(':latest') && self.contains(':')"
                         message: "platform policy: image must carry a pinned tag, ':latest' is forbidden"
                   replicas:
                     type: integer
                     default: 2
                     minimum: 1
                     maximum: 10
                   tier:
                     type: string
                     enum: [standard, critical]
                     default: standard
                 x-kubernetes-validations:
                   - rule: "self.tier != 'critical' || self.replicas >= 3"
                     message: "critical tier requires at least 3 replicas"
   ```

2. Install the API and confirm the control plane now serves it:

   ```bash
   kubectl apply -f webapp-crd.yaml
   kubectl explain webapp.spec
   ```

   Expected output (abridged):

   ```text
   customresourcedefinition.apiextensions.k8s.io/webapps.platform.example.io created
   GROUP:      platform.example.io
   KIND:       WebApp
   VERSION:    v1alpha1

   FIELD: spec <Object>
   ...
     image        <string> -required-
       Container image, pinned tag mandatory.
     replicas     <integer>
     tier         <string>
   ```

3. Submit a **valid** claim:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.example.io/v1alpha1
   kind: WebApp
   metadata:
     name: checkout-api
     namespace: team-checkout
   spec:
     image: ghcr.io/acme/checkout:1.4.2
     replicas: 3
     tier: critical
   EOF
   kubectl get webapps -n team-checkout
   ```

   Expected output:

   ```text
   webapp.platform.example.io/checkout-api created
   NAME           IMAGE                         REPLICAS   TIER
   checkout-api   ghcr.io/acme/checkout:1.4.2   3          critical
   ```

4. Try to break both policies and watch the API server — not a linter, not a doc — reject the requests:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.example.io/v1alpha1
   kind: WebApp
   metadata:
     name: search-api
     namespace: team-checkout
   spec:
     image: ghcr.io/acme/search:latest
   EOF
   ```

   Expected output:

   ```text
   The WebApp "search-api" is invalid: spec.image: Invalid value: "string": platform policy: image must carry a pinned tag, ':latest' is forbidden
   ```

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.example.io/v1alpha1
   kind: WebApp
   metadata:
     name: payments-api
     namespace: team-checkout
   spec:
     image: ghcr.io/acme/payments:2.0.1
     replicas: 2
     tier: critical
   EOF
   ```

   Expected output:

   ```text
   The WebApp "payments-api" is invalid: spec: Invalid value: "object": critical tier requires at least 3 replicas
   ```

5. Confirm defaulting — a minimal claim gets the platform's opinions filled in:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: platform.example.io/v1alpha1
   kind: WebApp
   metadata:
     name: catalog-api
     namespace: team-checkout
   spec:
     image: ghcr.io/acme/catalog:0.9.0
   EOF
   kubectl get webapp catalog-api -n team-checkout -o jsonpath='{.spec}' ; echo
   ```

   Expected output:

   ```text
   webapp.platform.example.io/catalog-api created
   {"image":"ghcr.io/acme/catalog:0.9.0","replicas":2,"tier":"standard"}
   ```

**Q3.1** — The `:latest` rejection happened at **admission time**, synchronously, before anything was persisted to etcd. Architecturally, why is that earlier and stronger than catching the same mistake in CI, in a Git pre-commit hook, or in a reconciling controller after the fact?

**Q3.2** — Your `WebApp` objects validate and default, but nothing actually *runs*. Name the missing architectural component, and name at least two CNCF-ecosystem approaches a platform team would use to supply it instead of writing a controller from scratch.

**Q3.3** — Why does encoding "no `:latest`" in the API schema scale better organizationally than publishing the same rule in the platform documentation and trusting teams to follow it? Connect your answer to the whitepaper's goal of *reducing cognitive load*.

---

## Exercise 4 — A golden path template with guardrails built in

A **golden path** is the paved road: a template that produces a service already compliant with the platform's contracts, so the easy way and the correct way are the same way. You will build one with Helm and prove it deploys through Exercise 2's guardrails with zero friction.

1. Scaffold the chart:

   ```bash
   helm create golden-web
   ```

   Expected output:

   ```text
   Creating golden-web
   ```

2. Replace `golden-web/values.yaml` content for these production defaults (pinned unprivileged image, restricted-compliant security context, resources that satisfy the tenant quota):

   ```yaml
   replicaCount: 1

   image:
     repository: nginxinc/nginx-unprivileged
     tag: "1.27-alpine"
     pullPolicy: IfNotPresent

   serviceAccount:
     create: true
     automount: false
     annotations: {}
     name: ""

   podSecurityContext:
     runAsNonRoot: true
     seccompProfile:
       type: RuntimeDefault

   securityContext:
     allowPrivilegeEscalation: false
     capabilities:
       drop: ["ALL"]

   service:
     type: ClusterIP
     port: 8080

   resources:
     requests:
       cpu: 100m
       memory: 128Mi
     limits:
       cpu: 500m
       memory: 256Mi

   livenessProbe:
     httpGet:
       path: /
       port: http
   readinessProbe:
     httpGet:
       path: /
       port: http

   ingress:
     enabled: false
   autoscaling:
     enabled: false
   nodeSelector: {}
   tolerations: []
   affinity: {}
   volumes: []
   volumeMounts: []
   podAnnotations: {}
   podLabels: {}
   imagePullSecrets: []
   nameOverride: ""
   fullnameOverride: ""
   ```

3. Lint and render server-side without persisting anything — the platform's own CI would run exactly this:

   ```bash
   helm lint golden-web
   helm template checkout-web golden-web | kubectl apply -n team-checkout --dry-run=server -f -
   ```

   Expected output:

   ```text
   ==> Linting golden-web
   [INFO] Chart.yaml: icon is recommended

   1 chart(s) linted, 0 chart(s) failed
   serviceaccount/checkout-web-golden-web created (server dry run)
   service/checkout-web-golden-web created (server dry run)
   deployment.apps/checkout-web-golden-web created (server dry run)
   ```

4. Install for real and confirm it comes up clean — **no PodSecurity warning this time**, because the template is `restricted`-compliant by construction:

   ```bash
   helm install checkout-web golden-web -n team-checkout
   kubectl get pods -n team-checkout -l app.kubernetes.io/instance=checkout-web
   ```

   Expected output:

   ```text
   NAME: checkout-web
   NAMESPACE: team-checkout
   STATUS: deployed
   REVISION: 1
   NAME                                       READY   STATUS    RESTARTS   AGE
   checkout-web-golden-web-6d5f9c7b8-x2klp    1/1     Running   0          15s
   ```

5. Watch the tenant quota account for the workload automatically:

   ```bash
   kubectl get quota team-checkout-quota -n team-checkout
   ```

   Expected output (`probe` pod from Exercise 2 plus this release):

   ```text
   NAME                  AGE   REQUEST                                                            LIMIT
   team-checkout-quota   25m   pods: 2/20, requests.cpu: 200m/4, requests.memory: 256Mi/8Gi       limits.cpu: 1/8, limits.memory: 512Mi/16Gi
   ```

**Q4.1** — The template compiles probes, resources, a pinned unprivileged image and a `restricted`-grade `securityContext` into every service by default. Which principle from the platforms whitepaper does this embody, and what is the observable difference between step 4 here and step 6 of Exercise 2?

**Q4.2** — What distinguishes a *golden path* from a *golden cage*? If a team needs `readOnlyRootFilesystem: true` plus an extra sidecar, what must the template's design allow so the path stays golden?

**Q4.3** — Two years from now, 80 services were scaffolded from `golden-web` v1 and the platform team ships v9 with a new mandatory label scheme. What architectural problem is this (name it), and name one mechanism platform teams use to manage it at scale?

---

## Exercise 5 — Observability as a platform-provided capability

Observability is a whitepaper capability domain, and the architectural decision is *who runs it*. Here the **platform** installs the resource-metrics pipeline once, and every tenant consumes it for free.

1. Install metrics-server (the standard implementation of the Kubernetes Resource Metrics API) and apply the kind-specific TLS relaxation:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   kubectl patch deployment metrics-server -n kube-system --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
   ```

   Expected final line:

   ```text
   deployment "metrics-server" successfully rolled out
   ```

2. Confirm the capability is now served **through the same API the rest of the platform uses** (an aggregated API, not a side channel):

   ```bash
   kubectl get apiservices v1beta1.metrics.k8s.io
   ```

   Expected output:

   ```text
   NAME                     SERVICE                      AVAILABLE   AGE
   v1beta1.metrics.k8s.io   kube-system/metrics-server   True        60s
   ```

3. Consume it as a tenant would:

   ```bash
   kubectl top nodes
   kubectl top pods -n team-checkout
   ```

   Expected output (numbers will vary):

   ```text
   NAME                         CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
   platform-lab-control-plane   187m         4%       742Mi           9%
   NAME                                       CPU(cores)   MEMORY(bytes)
   checkout-web-golden-web-6d5f9c7b8-x2klp    1m           8Mi
   probe                                      1m           7Mi
   ```

**Q5.1** — `kubectl top` worked for the tenant with **zero configuration on their side**. Explain, in whitepaper terms, why observability infrastructure belongs to the platform team rather than to each application team, referencing at least two concrete costs of the DIY alternative.

**Q5.2** — metrics-server registered itself as an *aggregated API* (`v1beta1.metrics.k8s.io`). Why does exposing a capability through the platform's existing API surface (same authn/authz, same discovery, same tooling) matter architecturally, compared to handing tenants a separate Grafana URL with separate credentials?

---

## Exercise 6 — Synthesis: read your platform's architecture back

You built five capability slices. Now inventory them and classify what you made — this classification is exactly the mental model the exam probes.

1. List everything the "platform team" (you) owns:

   ```bash
   kubectl get ns team-checkout -o jsonpath='{.metadata.labels}' ; echo
   kubectl get quota,limitrange,networkpolicy,rolebinding -n team-checkout
   kubectl get crd webapps.platform.example.io
   kubectl get apiservices v1beta1.metrics.k8s.io
   ```

2. List everything the "application team" owns:

   ```bash
   kubectl get webapps,deployments,pods -n team-checkout
   ```

3. Tear the lab down:

   ```bash
   kind delete cluster --name platform-lab
   ```

   Expected output:

   ```text
   Deleting cluster "platform-lab" ...
   Deleted nodes: ["platform-lab-control-plane"]
   ```

**Q6.1** — Classify each artifact you created (capability map, tenant bundle, `WebApp` CRD, golden-path chart, metrics-server) as *control plane* or *data plane*, and as *interface* or *capability* in whitepaper terms. One artifact belongs to neither plane — which, and why?

**Q6.2** — Your lab is close to a **Thinnest Viable Platform**. If budget forced you to keep exactly one exercise's artifact in production, which one preserves the most platform value, and what is the argument?

**Q6.3** — The platform is live. Name three metrics you would track to prove it is succeeding *as a product*, and state which whitepaper/maturity-model concern each metric maps to.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — A *capability* is a service the platform integrates and operates: CI, CD, observability, data services, identity and secret management, artifact storage, and so on. An *interface* is how users consume capabilities: web portals, APIs/CLIs, and golden-path templates. They are decoupled layers in the whitepaper's architecture: the platform is a thin, product-managed layer that *presents* capabilities coherently, while the capabilities themselves may be implemented by many providers (managed services, in-house operators, SaaS). Because the interface layer only frames capabilities, one capability — say, provisioning a Postgres instance — can be reached simultaneously through a Backstage portal form, a `kubectl apply` of a claim CR, and a Terraform module: three interfaces, one capability, one implementation behind them.

**A1.2** — "As a product" means the platform has users (developers), a product owner, a roadmap, feedback loops, and success metrics — it is not an infrastructure side-project that ships whatever the platform team finds interesting. Concretely for the five gaps: prioritization is driven by *user research and demand signals* (developer surveys, support-ticket clustering, time lost to DIY solutions), not by technology preference. If four application teams each run their own Prometheus while nobody has asked for messaging, `observability` gets closed first even if an event fabric is more exciting. Product thinking also implies the platform is *optional but compelling*: teams adopt it because it is the best way to ship, which forces the platform team to close the gaps that actually hurt.

### Exercise 2

**A2.1** — It implements **infrastructure services / environment provisioning**, consumed through the **API interface**. The architectural superiority of API-driven onboarding: it is *self-service* (no human in the loop, so latency drops from days to seconds and cognitive load shifts from the developer to the platform), *declarative and repeatable* (the tenant contract is one idempotent file in Git — apply it a hundred times, get the same result), *auditable* (Git history is the change log), and *composable* (a portal, a pipeline, or a GitOps controller can all drive the same API). A ticket queue has none of these properties: it scales linearly with human staffing, produces snowflake namespaces that drift from each other, and its "API" is prose in a ticket description.

**A2.2** — The `LimitRange` injected `defaultRequest` and `default` (limit) values into the container at admission. Without it, a `ResourceQuota` on `requests.*`/`limits.*` makes the namespace **reject every pod that omits resources** — the quota cannot account for a pod with no declared requests, so admission fails with `must specify requests.cpu, requests.memory...`. The failure mode is a hostile developer experience: the guardrail turns into a wall. The pair is the architectural pattern: `ResourceQuota` caps the aggregate, `LimitRange` supplies per-container defaults so the cap is enforceable without requiring every user to be a resource-management expert.

**A2.3** — Enforcing `restricted` immediately would break every workload that hasn't set `runAsNonRoot`, dropped capabilities, and configured seccomp — the platform would be blamed, and teams would demand exemptions, eroding the policy. The staged pattern (`enforce: baseline`, `warn`+`audit: restricted`) blocks only the genuinely dangerous (privileged pods, hostPath, host namespaces) while generating *visible, per-request feedback* and audit-log data on exactly which workloads would fail `restricted`. The platform team measures the warning rate, drives it toward zero by fixing golden paths (see Exercise 4, where the warning disappears), and only then ratchets `enforce` up. Guardrails are rolled out like software: observe, remediate, enforce. Reference: https://kubernetes.io/docs/concepts/security/pod-security-standards/ and https://kubernetes.io/docs/concepts/security/pod-security-admission/.

### Exercise 3

**A3.1** — CEL rules run inside the **kube-apiserver during admission validation**, so an invalid object is rejected synchronously and never reaches etcd. Earlier and stronger than the alternatives because: CI and pre-commit hooks are *bypassable* — they only cover requests that flow through the pipeline; anyone with credentials doing `kubectl apply` or `kubectl edit` skips them entirely. A reconciling controller catches the error *after* persistence: the invalid object exists, may be observed by other consumers, and the failure surfaces asynchronously in a status condition the user has to go find. Admission-time validation is the API contract itself: every client — portal, pipeline, GitOps controller, human — hits the same rule with an immediate, actionable error. In platform architecture terms: policy embedded in the control plane applies to all interfaces at once.

**A3.2** — The missing component is a **controller/reconciler** — the loop that observes `WebApp` objects and drives real resources (Deployment, Service, HPA) to match, then reports status. CNCF-ecosystem options: **Crossplane** (https://www.crossplane.io/) — define a CompositeResourceDefinition and a Composition mapping the claim to managed resources; **KRO / kro.run resource orchestration** or **Helm-rendering operators**; and the general **Operator pattern** built with **Kubebuilder/controller-runtime** (https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) when custom logic is unavoidable. In all cases the architecture is the same: platform API (CRD) at the control plane, reconciliation loop translating intent into capability-provider actions.

**A3.3** — Documentation-based policy costs every developer a read, a memory, and a judgment call on every deploy — that is *distributed* cognitive load, multiplied by team count, and it decays (new hires, forgotten pages, drift). Schema-encoded policy is paid for **once**, by the platform team, and then the correct behavior is the only behavior the API accepts; the error message itself teaches the rule at the exact moment it matters. The whitepaper's core value proposition is reducing developer cognitive load by moving cross-cutting concerns *down* into the platform; a validation rule is that principle applied to governance. Docs still matter — but as explanation of the *why*, not as the enforcement mechanism.

### Exercise 4

**A4.1** — This is **secure/compliant by default** — the "paved road" principle: golden paths make the correct configuration the zero-effort configuration. Observable difference: Exercise 2 step 6 (`kubectl run` with a bare image) produced a `Warning: would violate PodSecurity "restricted:latest"` and relied on `LimitRange` to patch in resources; Exercise 4 step 4 produced **no warning** and satisfied `ResourceQuota` with its own declared values. Same guardrails, but the golden path arrives already conforming — the guardrail never fires because the path never leaves the road. That is the architectural relationship: guardrails (admission policy) are the backstop; golden paths are the mechanism that makes the backstop rarely needed.

**A4.2** — A golden path is *opinionated but escapable*: it optimizes the common case while leaving every opinion overridable, and leaving the path entirely remains allowed (you take back the responsibilities the platform was carrying, but you are not fired from the platform). A golden cage mandates the template and blocks deviation, which drives shadow infrastructure and kills adoption of an optional-by-design platform. For the team needing `readOnlyRootFilesystem: true` and a sidecar, the chart must expose these as values (`securityContext` overrides, an `extraContainers`/`sidecars` list, `volumes`/`volumeMounts` passthrough) so the customization is a values-file diff, not a fork. The design rule: defaults are opinions, values are the escape hatch, forking is the last resort.

**A4.3** — The problem is **template drift** (day-2 lifecycle of scaffolded services): a template is copied at scaffold time, so improvements don't propagate — 80 services are pinned to v1 opinions. Mechanisms platform teams use: publish the golden path as a **versioned dependency** rather than a copy (a Helm library chart or base chart teams inherit, upgraded like any dependency); **automated update campaigns** — bots that open PRs across all consuming repos when the template changes (Renovate-style, or Backstage's scaffolder plus fleet-management tooling); and **conformance scorecards** that continuously measure each service against the current golden standard so drift is visible and prioritized instead of silent. The architectural insight: a golden path is a product with a lifecycle, not a one-shot generator.

### Exercise 5

**A5.1** — The whitepaper lists **observability for workloads and resources** as a platform capability precisely because it is a cross-cutting concern with strong economies of scale. Platform-side ownership means: one team acquires the deep operational expertise (scrape pipelines, cardinality control, retention, HA of the monitoring stack) and every tenant consumes it with zero configuration — as `kubectl top` just demonstrated. DIY costs, concretely: (1) *duplicated toil* — N teams each operating their own Prometheus/metrics stack, N× the upgrades, N× the storage tuning, all off-mission for product teams; (2) *inconsistency* — heterogeneous metric names, retention, and dashboards make cross-service incident correlation and org-wide SLO reporting nearly impossible; add (3) *cost* — redundant storage and compute for overlapping telemetry. Centralizing converts per-team cognitive load into a one-time platform investment.

**A5.2** — Registering through the aggregation layer means the capability inherits the platform's **existing contract**: the same authentication, the same RBAC authorization (you can grant or deny `pods.metrics.k8s.io` per namespace like any resource), the same API discovery (`kubectl api-resources` finds it), the same audit logging, and compatibility with the whole existing toolchain (`kubectl top`, HPA consuming the same endpoint). A separate Grafana URL with separate credentials creates a second identity system to provision and revoke, a second audit trail, and a capability invisible to automation. The general architectural rule: platform capabilities should be *composed into* the platform's API surface, not bolted alongside it — one front door, uniformly governed.

### Exercise 6

**A6.1** —

| Artifact | Plane | Whitepaper role |
|---|---|---|
| `capability-map.yaml` | neither | product-management artifact (platform-as-product) |
| Tenant bundle (Namespace, Quota, LimitRange, RBAC, NetworkPolicy) | control plane | capability: environment/infrastructure provisioning |
| `WebApp` CRD + CEL rules | control plane | interface: platform API (with embedded policy) |
| `golden-web` chart | control plane (authored artifact; its *rendered workload* runs in the data plane) | interface: golden-path template |
| metrics-server | control plane component serving data *about* the data plane | capability: observability |
| The running nginx pods themselves | data plane | the user's workload — not part of the platform |

The odd one out is the **capability map**: it is neither control nor data plane because it is not a runtime artifact at all — it is the product-management view of the platform, which is exactly the whitepaper's point that a platform is more than its running components.

**A6.2** — Keep the **tenant bundle (Exercise 2)**. Argument: it is the Thinnest Viable Platform for this environment — with only namespaces, quotas, defaults, RBAC and isolation, you still have safe multi-tenant self-service on the raw Kubernetes API, and every other capability can be layered on later without rework. The CRD without a controller delivers no runtime value yet; the golden path without an environment to deploy into is inert; metrics without workload isolation observes chaos. The TVP concept (from Team Topologies, adopted by the whitepaper) says: start with the smallest layer that hides enough complexity to be valuable — that layer here is tenancy, not templating or metrics.

**A6.3** — Any three of, for example: **time-to-first-deploy for a new team/service** (onboarding friction — maps to the maturity model's *Interfaces/Adoption* axes: is self-service actually self-service?); **platform adoption rate** — share of workloads on golden paths / tenant namespaces vs. bespoke (maps to *Adoption*: an optional product must win users, and its trend is the single clearest product signal); **guardrail warning rate** (PSA `restricted` warnings, admission rejections per week — maps to *Operations/Security*: measures whether golden paths and policy are converging, as in A2.3); **DORA metrics of tenant teams** (deployment frequency, lead time — maps to *Measurement*: the platform's end purpose is making product teams faster, so their delivery performance is the platform's north-star outcome, per https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/); **developer satisfaction (NPS/survey)** (maps to platform-as-product: users who wouldn't recommend the platform are users you are about to lose to shadow IT).

</details>

---

**Sources**

- CNCF Platforms Whitepaper — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes: CRD validation rules (CEL) — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes: Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes: Resource Quotas and Limit Ranges — https://kubernetes.io/docs/concepts/policy/resource-quotas/ , https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes: Operator pattern — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Helm documentation — https://helm.sh/docs/
- Kubernetes metrics-server — https://github.com/kubernetes-sigs/metrics-server