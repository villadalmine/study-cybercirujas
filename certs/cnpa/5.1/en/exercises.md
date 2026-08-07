# Exercises — 5.1 Simplified Access to Platform Capabilities for Developers

These guided labs build the developer-facing side of an Internal Developer Platform (IDP): the *interfaces* through which a developer consumes platform capabilities without knowing how they are implemented. You will exercise the three interface styles the CNCF Platforms Working Group names in its whitepaper — a **workload spec** (Score), a **platform API / control plane** (Crossplane), and a **portal + golden path** (Backstage) — and then wrap them in the **guardrails** that make self-service safe. The connecting idea is *reducing cognitive load*: the developer states intent; the platform team owns implementation.

**Prerequisites**
- A local Kubernetes cluster (`kind create cluster` or `minikube start`), `kubectl` ≥ 1.29.
- `docker` and `docker compose` for the Score-to-Compose path.
- Internet access to install `score-compose`, `score-k8s`, and Crossplane.
- Roughly 45–60 minutes.

> Version note: CLI output below reflects the tool versions current at the exam version date (2025-04-01). Minor formatting may differ on your machine — the *shape* of the output is what matters.

---

## Exercise 1 — Score: one workload spec, two target platforms

The point of a workload spec is that the developer describes *what* the workload needs **once**, in a platform-agnostic file, and the platform tooling projects it onto whatever runtime the environment uses. Here you author a single `score.yaml` and generate both a Docker Compose file (for a laptop) and Kubernetes manifests (for the cluster) from it — the developer never writes either target by hand.

**Steps**

1. Install both Score implementations (static binaries; adjust the OS/arch suffix if needed):

   ```bash
   curl -fsSL https://github.com/score-spec/score-compose/releases/latest/download/score-compose_linux_amd64.tar.gz | tar xz
   curl -fsSL https://github.com/score-spec/score-k8s/releases/latest/download/score-k8s_linux_amd64.tar.gz | tar xz
   sudo install score-compose score-k8s /usr/local/bin/
   score-compose --version && score-k8s --version
   ```

2. Author the workload specification. Create `score.yaml`:

   ```yaml
   apiVersion: score.dev/v1b1
   metadata:
     name: hello-world
   containers:
     web:
       image: nginx:1.27-alpine
       variables:
         GREETING: "Hello from Score"
   service:
     ports:
       www:
         port: 8080
         targetPort: 80
   resources:
     dns:
       type: dns
   ```

3. Initialise a Compose project and generate the Docker Compose runtime from the spec:

   ```bash
   score-compose init
   score-compose generate score.yaml --publish 8080:hello-world:8080
   cat compose.yaml
   ```

4. Run it locally and verify, then tear it down:

   ```bash
   docker compose up -d
   curl -s localhost:8080 | head -n 4
   docker compose down
   ```

5. Now project the **same** `score.yaml` onto Kubernetes — no edits to the spec:

   ```bash
   score-k8s init
   score-k8s generate score.yaml
   grep -E '^kind:' manifests.yaml
   kubectl apply -f manifests.yaml
   kubectl get deploy,svc -l app.kubernetes.io/name=hello-world
   ```

**Comprehension check**

1. The developer edited `score.yaml` zero times between step 3 and step 5, yet produced Compose and Kubernetes output. Which team owns the *translation rules* that decide how `resources.dns` becomes a concrete Compose service versus a Kubernetes object, and why does that placement reduce the developer's cognitive load?
2. `score.yaml` declares a `resources.dns` of `type: dns` but never a hostname, image, or provider. What is this pattern called, and how does it relate to the "platform as a product" idea of an interface contract?
3. If your organisation migrated from Docker Compose on laptops to Kubernetes in CI, which files change and which stay constant? What does that tell you about where platform coupling lives?

---

## Exercise 2 — Crossplane: a self-service platform API (XRD + Composition + Claim)

A control-plane interface exposes infrastructure as **Kubernetes-native custom resources**. The platform team publishes a *CompositeResourceDefinition* (the API schema) and a *Composition* (the implementation); the developer creates a small *Claim* and gets a provisioned resource plus a connection secret — a true "database as an API call." We use `provider-nop` so the whole lab runs in `kind` with **no cloud account**.

**Steps**

1. Install Crossplane and the pieces the Composition needs:

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace --wait
   kubectl apply -f - <<'EOF'
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-nop
   spec:
     package: xpkg.crossplane.io/crossplane-contrib/provider-nop:v0.4.0
   ---
   apiVersion: pkg.crossplane.io/v1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.8.2
   EOF
   kubectl wait provider.pkg/provider-nop function/function-patch-and-transform --for=condition=Healthy --timeout=180s
   ```

2. **Platform team, once:** publish the API surface. This is the entire contract the developer sees:

   ```yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xpostgresqlinstances.platform.example.org
   spec:
     group: platform.example.org
     names:
       kind: XPostgreSQLInstance
       plural: xpostgresqlinstances
     claimNames:
       kind: PostgreSQLInstance
       plural: postgresqlinstances
     versions:
       - name: v1alpha1
         served: true
         referenceable: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   parameters:
                     type: object
                     properties:
                       storageGB:
                         type: integer
                         minimum: 5
                         maximum: 100
                     required: [storageGB]
                 required: [parameters]
   ```

   Save as `xrd.yaml` and `kubectl apply -f xrd.yaml`.

3. **Platform team, once:** publish the implementation the developer never reads:

   ```yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: xpostgresqlinstances.platform.example.org
   spec:
     compositeTypeRef:
       apiVersion: platform.example.org/v1alpha1
       kind: XPostgreSQLInstance
     mode: Pipeline
     pipeline:
       - step: render
         functionRef:
           name: function-patch-and-transform
         input:
           apiVersion: pt.fn.crossplane.io/v1beta1
           kind: Resources
           resources:
             - name: db
               base:
                 apiVersion: nop.crossplane.io/v1alpha1
                 kind: NopResource
                 spec:
                   forProvider:
                     conditionAfter:
                       - conditionType: Ready
                         conditionStatus: "True"
                         time: 5s
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.storageGB
                   toFieldPath: metadata.annotations[storage-gb]
                   transforms:
                     - type: convert
                       convert: { toType: string }
   ```

   Save as `composition.yaml` and `kubectl apply -f composition.yaml`.

4. **Developer:** consume the platform API with the smallest possible intent. Create `claim.yaml`:

   ```yaml
   apiVersion: platform.example.org/v1alpha1
   kind: PostgreSQLInstance
   metadata:
     name: orders-db
     namespace: default
   spec:
     parameters:
       storageGB: 20
   ```

   ```bash
   kubectl apply -f claim.yaml
   kubectl get postgresqlinstance orders-db
   kubectl get xpostgresqlinstance          # the composite the platform created for you
   ```

5. Prove the guardrail is enforced by the schema, not by a reviewer:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.org/v1alpha1
   kind: PostgreSQLInstance
   metadata: { name: too-big, namespace: default }
   spec: { parameters: { storageGB: 500 } }
   EOF
   ```

**Comprehension check**

1. The developer's `claim.yaml` is 8 lines and names no cloud, region, engine version, or networking. Where did all of that go, and what does the term **abstraction** mean concretely in this split between XRD, Composition, and Claim?
2. Step 5 is rejected instantly with a validation error rather than failing later at provision time. Which field in the XRD produced that rejection, and why is *shifting the failure left into the API schema* a developer-experience improvement rather than merely a safety one?
3. A Claim is namespaced and a Composite (XR) is cluster-scoped. Why does the "database as an API call" model deliberately hand developers the namespaced Claim rather than the cluster-scoped XR?
4. If the platform team swaps `provider-nop` for a real RDS provider tomorrow, which of the developer's files must change? What does your answer say about *interface stability* as a platform-engineering value?

---

## Exercise 3 — Backstage: a golden path from a software template

A developer portal exposes capabilities as **self-service actions in a catalog** and **golden-path templates** that scaffold a correct-by-construction starting point. You will author a Backstage Software Template and a component descriptor. (Running a full Backstage instance is out of scope for the exam weight; the deliverable here is the golden-path *definition* a platform team ships, and understanding how a developer consumes it.)

**Steps**

1. Create the component descriptor that registers a service in the catalog. Save as `catalog-info.yaml`:

   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: orders-service
     description: Handles customer orders
     annotations:
       backstage.io/techdocs-ref: dir:.
       github.com/project-slug: acme/orders-service
     tags: [go, payments]
   spec:
     type: service
     lifecycle: production
     owner: team-alpha
     system: commerce
   ```

2. Author the **golden path** as a scaffolder template. Save as `template.yaml`:

   ```yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: go-microservice
     title: Go Microservice (Golden Path)
     description: Scaffolds a production-ready Go service with CI, Dockerfile and catalog entry
     tags: [recommended, go]
   spec:
     owner: team-platform
     type: service
     parameters:
       - title: Service details
         required: [name, owner]
         properties:
           name:
             title: Name
             type: string
             pattern: '^[a-z0-9-]+$'
           owner:
             title: Owner
             type: string
             ui:field: OwnerPicker
     steps:
       - id: fetch
         name: Fetch skeleton
         action: fetch:template
         input:
           url: ./skeleton
           values:
             name: ${{ parameters.name }}
             owner: ${{ parameters.owner }}
       - id: publish
         name: Publish to GitHub
         action: publish:github
         input:
           repoUrl: github.com?owner=acme&repo=${{ parameters.name }}
       - id: register
         name: Register in catalog
         action: catalog:register
         input:
           repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
           catalogInfoPath: /catalog-info.yaml
     output:
       links:
         - title: Open in catalog
           icon: catalog
           entityRef: ${{ steps.register.output.entityRef }}
   ```

3. Trace the developer's journey without writing any of the above yourself. On the portal a developer would: open **Create → Go Microservice (Golden Path)**, fill the two `parameters`, and click **Create**. Map each portal click to a `steps` entry:

   ```text
   Form submit  → step "fetch"    (renders ./skeleton with the answers)
   (automatic)  → step "publish"  (creates the GitHub repo)
   (automatic)  → step "register" (adds catalog-info.yaml to the catalog)
   Success page → output.links    (deep link to the new component)
   ```

4. Validate that the descriptor is well-formed against the entity schema (uses `yq`; any YAML linter works):

   ```bash
   yq e '.apiVersion, .kind, .spec.owner, .spec.lifecycle' catalog-info.yaml
   ```

**Comprehension check**

1. The `template.yaml` bakes in CI, a Dockerfile, and a catalog entry that the developer never chooses. In what sense is a golden path *paved* rather than *mandated*, and why is "the easiest path is also the recommended one" the design goal?
2. Distinguish the two entities you created: what is the difference in purpose between a `kind: Template` and a `kind: Component`, and which one exists *before* any given service and which is created *per* service?
3. The `name` parameter carries `pattern: '^[a-z0-9-]+$'`. How does placing that constraint in the template rather than in a code-review checklist change the developer's experience and the platform team's toil?
4. A `catalog-info.yaml` records `owner: team-alpha` and `system: commerce`. Beyond scaffolding, name one platform capability (discovery, ownership, cost, incident routing) that this metadata unlocks, and explain why the *catalog* — not a wiki — is where it belongs.

---

## Exercise 4 — Guardrails: safe self-service namespaces

Self-service is only *simplified* access if it is also *bounded* access — a developer must be able to deploy freely inside a blast radius they cannot escape. Here you provision a namespace-as-a-service unit: a namespace, a `ResourceQuota`, a `LimitRange`, and least-privilege RBAC, then prove the boundary holds.

**Steps**

1. Apply the self-service unit the platform hands a team. Save as `team-alpha.yaml` and `kubectl apply -f team-alpha.yaml`:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: team-alpha
     labels:
       platform.example.org/self-service: "true"
       team: alpha
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-alpha-quota
     namespace: team-alpha
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
       pods: "20"
       persistentvolumeclaims: "5"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: team-alpha-limits
     namespace: team-alpha
   spec:
     limits:
       - type: Container
         default:        { cpu: 500m, memory: 512Mi }
         defaultRequest: { cpu: 100m, memory: 128Mi }
         max:            { cpu: "2",  memory: 4Gi }
   ---
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: dev
     namespace: team-alpha
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: developer
     namespace: team-alpha
   rules:
     - apiGroups: ["apps", ""]
       resources: ["deployments", "services", "configmaps", "pods", "pods/log"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: developer-binding
     namespace: team-alpha
   subjects:
     - kind: ServiceAccount
       name: dev
       namespace: team-alpha
   roleRef:
     kind: Role
     name: developer
     apiGroup: rbac.authorization.k8s.io
   ```

2. Probe the boundary from the developer's identity — what they *can* do inside, and what they *cannot* do outside:

   ```bash
   SA=system:serviceaccount:team-alpha:dev
   kubectl auth can-i create deployments -n team-alpha --as=$SA
   kubectl auth can-i delete namespaces               --as=$SA
   kubectl auth can-i get secrets -n kube-system      --as=$SA
   kubectl auth can-i create deployments -n default   --as=$SA
   ```

3. Deploy something *without* setting resource requests and watch the `LimitRange` inject defaults so the `ResourceQuota` can account for it:

   ```bash
   kubectl create deployment web --image=nginx:1.27-alpine -n team-alpha
   kubectl get pod -n team-alpha -o jsonpath='{.items[0].spec.containers[0].resources}'; echo
   ```

4. Try to exceed the quota and read the enforcement message:

   ```bash
   kubectl -n team-alpha create deployment big --image=nginx --replicas=50 \
     -o yaml --dry-run=client | \
     kubectl set resources -f - --local -o yaml --requests=cpu=1 | \
     kubectl apply -n team-alpha -f -
   kubectl -n team-alpha describe replicaset -l app=big | grep -A2 -i 'exceeded quota' || \
     kubectl -n team-alpha get events --field-selector reason=FailedCreate
   ```

**Comprehension check**

1. Step 2 shows the developer can create Deployments in `team-alpha` but not in `default` or `kube-system`, and cannot touch namespaces at all. Which two objects together produce that exact scope, and why is a `Role` + `RoleBinding` (not `ClusterRole` + `ClusterRoleBinding`) the correct choice for a self-service tenant?
2. In step 3 the developer set no CPU/memory requests, yet the pod ended up with them. Which object supplied the values, and why is that automatic injection necessary for the `ResourceQuota` on `requests.cpu`/`requests.memory` to admit the pod at all?
3. Distinguish the jobs of `ResourceQuota` and `LimitRange`: one caps an *aggregate*, the other constrains a *single object*. Which is which, and why does robust self-service need both?
4. This whole unit is plain Kubernetes objects. How would you connect it to Exercise 2 or Exercise 3 so that "give team-alpha a bounded namespace" itself becomes a one-line self-service request instead of a hand-applied YAML file?

---

## References

- CNCF TAG App Delivery — *Platforms White Paper* (platform, capabilities, interfaces, product mindset): https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- Score — specification and CLIs (`score-compose`, `score-k8s`): https://docs.score.dev/
- Crossplane — Composite Resources, XRDs, Compositions, Claims: https://docs.crossplane.io/latest/concepts/
- Backstage — Software Catalog (`catalog-info.yaml`): https://backstage.io/docs/features/software-catalog/descriptor-format
- Backstage — Software Templates (Scaffolder): https://backstage.io/docs/features/software-templates/writing-templates
- Kubernetes — RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- CNOE (Cloud Native Operational Excellence) reference IDP: https://cnoe.io/

---

<details>
<summary><strong>Solutions — comprehension answers</strong></summary>

### Exercise 1 — Score

1. **The platform team owns the translation rules**, encoded in `score-compose`/`score-k8s` and their provisioners (the `.score-compose`/`.score-k8s` state and any custom provisioners). The developer's file states *intent* (`type: dns`, a port, an image); the mapping from intent to a concrete Compose service or Kubernetes `Deployment`+`Service` lives in tooling the platform team maintains. This reduces cognitive load because the developer never has to learn two runtime dialects or keep them in sync — they learn one 15-line spec, and correctness of the projection is a platform responsibility, not a per-developer one.
2. It is **resource abstraction via a typed placeholder / dependency-by-type**: the workload declares that it *depends on* a capability of a given `type` and lets a **provisioner** resolve it for the target environment. This is exactly an *interface contract* in the platform-as-a-product sense — the developer codes against a stable capability type (`dns`), and the platform is free to fulfil it differently per environment (a hostname on Kubernetes, a stub locally) without the contract changing.
3. **`compose.yaml` and `manifests.yaml` change; `score.yaml` stays constant.** The generated artifacts are disposable projections. This tells you the platform coupling lives in the *generated* files (and the provisioners that emit them), and the developer-owned spec is deliberately kept free of it — the whole reason a workload spec exists.

### Exercise 2 — Crossplane

1. Cloud, region, engine version, and networking went into the **Composition** (the implementation), and the *shape and constraints* of what a developer may ask for went into the **XRD** (the API schema). "Abstraction" here is concrete: the XRD is the public interface, the Composition is the hidden implementation, and the Claim is a request against the interface. The developer depends only on the interface (`storageGB`), so the implementation can vary freely underneath — the definition of a leak-free abstraction.
2. The rejection came from the **OpenAPI schema in the XRD** — specifically `maximum: 100` on `spec.parameters.storageGB` (500 > 100). Shifting the failure left into the API schema is a *developer-experience* win, not just a safety one, because the developer gets an immediate, local, self-explanatory error at `kubectl apply` time instead of a delayed provisioning failure, a failed pipeline, or a rejected pull request. Fast, precise feedback at the point of intent is the essence of a good self-service interface.
3. The Claim is namespaced so it lives inside the **developer's own tenancy boundary** — it is subject to that namespace's RBAC and quotas, and multiple teams can request the same kind without colliding. The Composite (XR) is cluster-scoped because it represents the *platform team's* aggregate managed resources. Handing developers the namespaced Claim keeps them inside their blast radius while the platform retains the cluster-scoped machinery; it is the same guardrail principle as Exercise 4.
4. **None of the developer's files change** — only the platform team's `composition.yaml` (and installed providers). That is the payoff of *interface stability*: because the developer coded against the XRD, not the implementation, the platform can migrate from a nop resource to real RDS with zero developer churn. A platform interface that stays stable across implementation changes is what lets the platform team evolve independently — a core platform-engineering value.

### Exercise 3 — Backstage

1. A golden path is *paved, not mandated*: nothing stops a developer from building a service by hand, but the template makes the correct-by-construction route (CI, Dockerfile, catalog entry already wired) the **fastest and easiest** one. Adoption is won by making the good path the low-friction path, not by enforcement — which scales far better and generates goodwill instead of resentment.
2. A **`kind: Template`** is a *reusable generator* that the platform team authors once; it exists **before** any given service and produces many. A **`kind: Component`** is the *catalog record of one running service*; it is created **per** service (here, emitted by the template's `catalog:register` step). Template : Component :: class : instance.
3. Placing `pattern: '^[a-z0-9-]+$'` in the template makes an invalid name **impossible to submit** — the portal form rejects it before scaffolding. That removes an entire class of review comments and rework, converting a manual, after-the-fact checklist item into an up-front, self-enforcing constraint. The developer gets instant feedback; the platform team stops policing naming by hand (reduced toil).
4. The `owner`/`system` metadata makes the catalog the source of truth for **ownership and incident routing** (and discovery/dependency graphs, and cost attribution). It belongs in the catalog rather than a wiki because it is *structured and machine-readable*: PagerDuty routing, dependency graphs, and ownership queries can consume it programmatically, and it stays in sync with the entity's lifecycle instead of rotting on a page nobody updates.

### Exercise 4 — Guardrails

1. The **`Role` (namespaced) + `RoleBinding`** together scope the identity: the `Role` grants verbs only on `deployments/services/configmaps/pods` and the `RoleBinding` binds them **only within `team-alpha`**. Because both are namespaced, the grant cannot apply in `default` or `kube-system`, and namespaces themselves (a cluster-scoped resource) are untouched. `Role` + `RoleBinding` is correct for a tenant precisely because it is impossible to accidentally grant cluster-wide reach — a `ClusterRoleBinding` would let the developer act in *every* namespace, breaking the blast-radius guarantee.
2. The **`LimitRange`** supplied the values via its `defaultRequest` (cpu `100m`, memory `128Mi`) and `default` limits. This injection is necessary because the `ResourceQuota` sets hard caps on `requests.cpu`/`requests.memory`; Kubernetes admission requires every container to have those requests set before it can be counted against the quota. Without the `LimitRange` defaulting them, a request-less pod would be **rejected** by the quota controller. The two objects are designed to work as a pair.
3. **`ResourceQuota` caps an aggregate** — the total CPU/memory/pod/PVC consumption of the *whole namespace*. **`LimitRange` constrains a single object** — the min/max/default for *each container or pod*. Self-service needs both: the quota stops one team from starving the cluster, and the LimitRange stops one pod from consuming the team's entire quota (and supplies the defaults the quota needs to do accounting). Aggregate ceiling + per-object floor/ceiling together make the boundary robust.
4. Turn the hand-applied bundle into a **platform API or a golden path**. With Crossplane (Exercise 2): define an XRD like `Environment`/`Namespace` whose Composition emits exactly these `Namespace` + `ResourceQuota` + `LimitRange` + RBAC objects, so a team requests one via a small Claim (`kind: Namespace, spec: { team: alpha, size: small }`). With Backstage (Exercise 3): wrap the same bundle in a scaffolder template so "request a namespace" becomes a portal action. Either way the guardrail set stops being copy-pasted YAML and becomes a single self-service request — the platform capability made *simple to access*, which is the whole subject of this topic.

</details>