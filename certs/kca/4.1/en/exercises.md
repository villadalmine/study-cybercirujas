# Exercises — 4.1 Applying Policy in Cluster

> **Scope.** "Policy" in a Kubernetes cluster is not one object — it is a family of enforcement points that a request crosses on its way to `etcd`. This lab walks the full chain: **authorization policy** (RBAC), **admission policy** built into the API server (Pod Security Admission, `ResourceQuota`/`LimitRange`, `ValidatingAdmissionPolicy`), **network policy** (dataplane), and finally an **external policy engine** (Kyverno) for rules the built-ins cannot express. After each block you answer verification questions; all answers are in the collapsible section at the end.

## The mental model: where policy is enforced

Every write request to the API server passes through this pipeline. Knowing *which stage* rejects a request is the single most useful diagnostic skill for this topic.

```
kubectl apply
      │
      ▼
[ Authentication ]  who are you?            → certs / tokens / OIDC
      │
      ▼
[ Authorization ]   are you allowed?        → RBAC (Role/ClusterRole)      ← policy
      │
      ▼
[ Mutating admission ]   rewrite the object → MutatingWebhook, LimitRange defaults  ← policy
      │
      ▼
[ Object schema validation ]  is it valid Kubernetes?
      │
      ▼
[ Validating admission ]   accept / reject  → PodSecurity, ResourceQuota,
      │                                        ValidatingAdmissionPolicy,
      │                                        ValidatingWebhook (Kyverno/Gatekeeper)  ← policy
      ▼
   persisted to etcd
      │
      ▼
[ Dataplane, runtime ]   NetworkPolicy (CNI) enforces pod-to-pod traffic  ← policy
```

Two facts fall out of this diagram and are worth internalizing before you touch a terminal:

1. **RBAC failures return `403 Forbidden` at authorization** — before any object is even parsed. Admission failures also return `403 Forbidden` but the message names the admission plugin (`violates PodSecurity`, `exceeded quota`, `ValidatingAdmissionPolicy ... denied`). The HTTP status is the same; the *message* tells you the stage.
2. **`NetworkPolicy` is enforced by the CNI, not the API server.** The object is always accepted and stored; whether traffic is actually blocked depends entirely on the dataplane plugin.

Sources: [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/) · [Controlling Access to the API](https://kubernetes.io/docs/concepts/security/controlling-access/)

---

## Lab prerequisites

You need a cluster running **Kubernetes v1.30 or newer** (v1.30 is where `ValidatingAdmissionPolicy` reached GA). For **Exercise 4** you need a CNI that *enforces* `NetworkPolicy` — Calico, Cilium, or Antrea. The default `kind` CNI (`kindnet`) creates the objects but silently does **not** enforce them.

```bash
# Option A — minikube with a policy-enforcing CNI
minikube start --kubernetes-version=v1.31.0 --cni=calico

# Option B — kind (fine for Exercises 1,2,3,5; install Calico for Exercise 4)
kind create cluster --image kindest/node:v1.31.0

# Confirm version and that the PodSecurity + ValidatingAdmissionPolicy plugins are active
kubectl version -o json | grep -m1 gitVersion
kubectl api-resources | grep -Ei 'validatingadmissionpolicy|resourcequota|networkpolic'
```

Expected (abridged):

```
"gitVersion": "v1.31.0",
validatingadmissionpolicies             admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicy
validatingadmissionpolicybindings       admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicyBinding
resourcequotas               quotas     v1                                true    ResourceQuota
networkpolicies              netpol     networking.k8s.io/v1              true    NetworkPolicy
```

---

## Exercise 1 — Pod Security Admission (Pod Security Standards)

`PodSecurityPolicy` was removed in v1.25. Its built-in replacement is **Pod Security Admission (PSA)**: a validating admission controller that applies one of three **Pod Security Standards** — `privileged` (no restrictions), `baseline` (blocks known privilege escalations), `restricted` (hardened best-practice) — at the **namespace** level, driven purely by labels.

| Label | Values | Effect |
|---|---|---|
| `pod-security.kubernetes.io/enforce` | `privileged` `baseline` `restricted` | **rejects** non-compliant pods |
| `pod-security.kubernetes.io/audit`   | same | records a violation in the audit log, pod is admitted |
| `pod-security.kubernetes.io/warn`    | same | returns a `Warning:` to the client, pod is admitted |
| `pod-security.kubernetes.io/<mode>-version` | `v1.31` … `latest` | pins the standard to a Kubernetes version |

**Steps**

1. Create a namespace and apply the `restricted` standard in all three modes. Pinning `enforce` to a version while letting `warn`/`audit` track `latest` is the standard rollout pattern — you get forward-looking warnings without breaking existing workloads.

   ```bash
   kubectl create namespace secure

   kubectl label namespace secure \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31 \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

2. Confirm the labels landed:

   ```bash
   kubectl get namespace secure --show-labels
   ```
   ```
   NAME     STATUS   AGE   LABELS
   secure   Active   4s    kubernetes.io/metadata.name=secure,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.31,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/warn=restricted
   ```

3. Try to create a pod with **no** `securityContext`. Save as `legacy-app.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: legacy-app
     namespace: secure
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "sleep 3600"]
   ```
   ```bash
   kubectl apply -f legacy-app.yaml
   ```
   ```
   Error from server (Forbidden): error when creating "legacy-app.yaml": pods "legacy-app" is
   forbidden: violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false
   (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted
   capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to
   "RuntimeDefault" or "Localhost")
   ```

4. Now create a **compliant** pod. Save as `hardened.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
     namespace: secure
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
   ```
   ```bash
   kubectl apply -f hardened.yaml
   kubectl get pod -n secure hardened
   ```
   ```
   pod/hardened created
   NAME       READY   STATUS    RESTARTS   AGE
   hardened   1/1     Running   0          6s
   ```

5. Demonstrate that `enforce` acts on the **namespace, not the workload**. A `Deployment` is admitted (it is not a Pod), but its `ReplicaSet` cannot create the pod — surfacing as `warn` on apply and as an event on the ReplicaSet.

   ```bash
   kubectl create deployment bad --image=busybox:1.36 -n secure -- sleep 3600
   ```
   ```
   Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false ...
   deployment.apps/bad created
   ```
   ```bash
   kubectl get deploy,rs,pod -n secure -l app=bad
   ```
   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/bad   0/1     0            0           10s

   NAME                            DESIRED   CURRENT   READY   AGE
   replicaset.apps/bad-6c9f7bd94   1         0         0       10s
   ```
   ```bash
   kubectl describe rs -n secure -l app=bad | grep -A2 Events
   ```
   ```
   Events:
     Warning  FailedCreate  4s (x3 over 12s)  replicaset-controller  Error creating: pods
     "bad-6c9f7bd94-..." is forbidden: violates PodSecurity "restricted:v1.31": ...
   ```

> **Q1.** A student sets only `pod-security.kubernetes.io/warn=restricted` on a namespace and reports "the policy isn't working — the bad pod still runs." What is actually happening, and which label do they need?
>
> **Q2.** In Step 5 the `kubectl create deployment` command *succeeded* (exit 0) yet no pod ran. Explain precisely why enforcement did not block the `Deployment` object itself, and where the rejection surfaced instead.
>
> **Q3.** Your compliant pod puts `runAsNonRoot`/`seccompProfile` at the **pod** level but `allowPrivilegeEscalation`/`capabilities` at the **container** level. Why can't all four live at the pod level?

Sources: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) · [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) · [Enforce Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)

---

## Exercise 2 — Resource governance: `ResourceQuota` + `LimitRange`

These two objects answer different questions. A **`ResourceQuota`** caps the *aggregate* consumption of a namespace (total CPU, total memory, object counts). A **`LimitRange`** constrains and defaults *individual* objects (per-container min/max, and default requests/limits when the author omits them). They interlock: when a `ResourceQuota` limits a compute resource, **every pod must declare that request/limit** — and a `LimitRange` is what lets developers keep omitting them by supplying defaults at mutating admission.

**Steps**

1. Create a namespace with both objects. Save as `governance.yaml`:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: dev
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-quota
     namespace: dev
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
       count/deployments.apps: "5"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: default-limits
     namespace: dev
   spec:
     limits:
     - type: Container
       default:            # applied as limits if container omits them
         cpu: 500m
         memory: 256Mi
       defaultRequest:     # applied as requests if container omits them
         cpu: 250m
         memory: 128Mi
       max:
         cpu: "2"
         memory: 2Gi
   ```
   ```bash
   kubectl apply -f governance.yaml
   kubectl describe resourcequota team-quota -n dev
   ```
   ```
   Name:                   team-quota
   Namespace:              dev
   Resource                Used  Hard
   --------                ----  ----
   count/deployments.apps  0     5
   limits.cpu              0     4
   limits.memory           0     4Gi
   pods                    0     10
   requests.cpu            0     2
   requests.memory         0     2Gi
   ```

2. Create a pod that declares **no** resources and watch the `LimitRange` inject defaults so the quota is satisfied:

   ```bash
   kubectl run web --image=nginx:1.27-alpine -n dev
   kubectl get pod web -n dev -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
   ```
   ```json
   {
       "limits":   { "cpu": "500m", "memory": "256Mi" },
       "requests": { "cpu": "250m", "memory": "128Mi" }
   }
   ```

3. Now delete the `LimitRange` and repeat — the defaults disappear and the quota rejects the bare pod:

   ```bash
   kubectl delete limitrange default-limits -n dev
   kubectl run web2 --image=nginx:1.27-alpine -n dev
   ```
   ```
   Error from server (Forbidden): pods "web2" is forbidden: failed quota: team-quota: must
   specify limits.cpu for: web2; limits.memory for: web2; requests.cpu for: web2;
   requests.memory for: web2
   ```

4. Recreate the `LimitRange`, then exceed the **aggregate** CPU request quota to see the count-based rejection:

   ```bash
   kubectl apply -f governance.yaml    # restores the LimitRange
   # Each replica requests 250m; 2 CPU quota / 250m ≈ 8 pods, then the 9th trips requests.cpu
   kubectl create deployment fill --image=nginx:1.27-alpine -n dev --replicas=9
   kubectl get deploy fill -n dev
   ```
   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   fill   7/9     7            7           15s
   ```
   ```bash
   kubectl describe rs -n dev -l app=fill | grep -A2 Events
   ```
   ```
   Events:
     Warning  FailedCreate  ...  replicaset-controller  Error creating: pods "fill-..." is
     forbidden: exceeded quota: team-quota, requested: requests.cpu=250m, used:
     requests.cpu=2, limited: requests.cpu=2
   ```

> **Q4.** The `web` pod in Step 2 requested `250m` CPU even though the YAML you applied set no resources at all. Name the two admission stages involved and the order in which they ran.
>
> **Q5.** In Step 4 the Deployment asked for 9 replicas but only 7 came up, and `kubectl get deploy` shows `7/9` indefinitely without any error on the Deployment. Where do you look to find *why* it is stuck, and what is the fix that keeps all 9 within the same quota?
>
> **Q6.** Your teammate says "we have a `LimitRange` with defaults, so we don't need requests in our manifests." Under what quota condition is that statement dangerous, and what is the failure mode if the `LimitRange` is ever deleted?

Sources: [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) · [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)

---

## Exercise 3 — Native admission policy: `ValidatingAdmissionPolicy` (CEL)

Before v1.30 the only way to write custom cluster policy was an external webhook (Gatekeeper/Kyverno) — a network hop, a pod to keep alive, a `failurePolicy` to reason about. **`ValidatingAdmissionPolicy` (VAP)** moves simple rules *in-process*, evaluated in the API server using **CEL** (Common Expression Language). No webhook, no extra pod, no latency. Two objects: the **policy** (the rule) and the **binding** (where it applies).

**Steps**

1. Write a policy that caps Deployment replicas and requires every container to set a memory limit. Save as `vap.yaml`:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: workload-guardrails.policy.example.com
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
       - apiGroups:   ["apps"]
         apiVersions: ["v1"]
         operations:  ["CREATE", "UPDATE"]
         resources:   ["deployments"]
     validations:
       - expression: "object.spec.replicas <= 5"
         message: "Deployments may not exceed 5 replicas in this namespace."
         reason: Invalid
       - expression: >-
           object.spec.template.spec.containers.all(c,
             has(c.resources) && has(c.resources.limits) &&
             has(c.resources.limits.memory))
         message: "Every container must set spec...resources.limits.memory."
         reason: Invalid
   ```

2. The policy alone does **nothing** until a **binding** activates it. Save as `vap-binding.yaml`:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: workload-guardrails-binding.example.com
   spec:
     policyName: workload-guardrails.policy.example.com
     validationActions: ["Deny"]        # Deny | Warn | Audit (combinable)
     matchResources:
       namespaceSelector:
         matchLabels:
           environment: prod
   ```
   ```bash
   kubectl apply -f vap.yaml
   kubectl apply -f vap-binding.yaml
   kubectl create namespace prod
   kubectl label namespace prod environment=prod
   ```

3. Violate the replica cap:

   ```bash
   kubectl create deployment big --image=nginx:1.27-alpine -n prod --replicas=8
   ```
   ```
   error: failed to create deployment: deployments.apps "big" is forbidden:
   ValidatingAdmissionPolicy 'workload-guardrails.policy.example.com' with binding
   'workload-guardrails-binding.example.com' denied request: Deployments may not exceed
   5 replicas in this namespace.
   ```

4. Prove the binding is **namespace-scoped**: the same manifest is accepted in the unlabeled `dev` namespace.

   ```bash
   kubectl create deployment big --image=nginx:1.27-alpine -n dev --replicas=8
   ```
   ```
   deployment.apps/big created
   ```

5. (Advanced) Switch the binding to non-blocking observation before enforcing cluster-wide — the safe rollout order for any policy. Edit `validationActions` to `["Warn", "Audit"]`, re-apply, and a violating create now succeeds with a warning:

   ```bash
   kubectl create deployment big2 --image=nginx:1.27-alpine -n prod --replicas=8
   ```
   ```
   Warning: Validation failed for ValidatingAdmissionPolicy
   'workload-guardrails.policy.example.com' with binding
   'workload-guardrails-binding.example.com': Deployments may not exceed 5 replicas...
   deployment.apps/big2 created
   ```

> **Q7.** You applied the `ValidatingAdmissionPolicy` but a violating Deployment in `prod` was still admitted. You confirm the policy object exists with `kubectl get validatingadmissionpolicy`. What single object are you missing, and what is its role?
>
> **Q8.** `failurePolicy: Fail` on a VAP means something very different from `failurePolicy: Fail` on a `ValidatingWebhookConfiguration` in terms of *availability risk*. Explain the difference and why VAP's version is far safer.
>
> **Q9.** Give the one-line CEL edit that would make the replica rule *skip* Deployments whose `spec.replicas` field is unset (so it never errors on a null), rather than assuming the field is always present.

Sources: [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) · [CEL in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)

---

## Exercise 4 — Network segmentation: `NetworkPolicy`

*(Requires a policy-enforcing CNI — see prerequisites.)* Pods are **non-isolated by default**: any pod can reach any pod. A `NetworkPolicy` selecting a pod flips it to **default-deny for the selected direction**, after which only explicitly allowed traffic passes. Policies are **additive** (whitelist union) and enforced by the CNI at the dataplane — the API server always stores the object.

**Steps**

1. Deploy a three-tier app and confirm open connectivity first:

   ```bash
   kubectl create namespace shop
   kubectl run api      --image=hashicorp/http-echo -n shop -l app=api      -- -text=api -listen=:8080
   kubectl run frontend --image=busybox:1.36        -n shop -l app=frontend -- sleep 3600
   kubectl run attacker --image=busybox:1.36        -n shop -l app=attacker -- sleep 3600
   kubectl expose pod api -n shop --port=8080

   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo
   kubectl exec -n shop attacker -- wget -qO- --timeout=2 http://api:8080; echo
   ```
   ```
   api
   api
   ```

2. Apply a **default-deny-ingress** baseline for the whole namespace. Save as `deny.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: shop
   spec:
     podSelector: {}          # selects every pod in the namespace
     policyTypes:
     - Ingress                # no ingress rules ⇒ deny all inbound
   ```
   ```bash
   kubectl apply -f deny.yaml
   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo "exit=$?"
   ```
   ```
   wget: download timed out
   exit=1
   ```

3. Re-open **only** `frontend → api:8080` with a targeted allow policy. Save as `allow.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-api
     namespace: shop
   spec:
     podSelector:
       matchLabels:
         app: api
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             app: frontend
       ports:
       - protocol: TCP
         port: 8080
   ```
   ```bash
   kubectl apply -f allow.yaml
   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo   # allowed
   kubectl exec -n shop attacker -- wget -qO- --timeout=2 http://api:8080; echo "exit=$?"  # still denied
   ```
   ```
   api
   wget: download timed out
   exit=1
   ```

> **Q10.** Between Step 1 and Step 2 you applied *only* a deny policy and the `frontend → api` call broke. But `attacker → api` also broke. Given the deny policy has an empty `podSelector: {}`, explain why the additive model still ends up blocking `attacker` even after Step 3 re-allows `frontend`.
>
> **Q11.** You apply the exact same manifests on a fresh `kind` cluster with the default CNI and *every* `wget` succeeds, deny policy or not. The objects are present (`kubectl get netpol -n shop` lists them). What is wrong, and why does the API server not warn you?
>
> **Q12.** A colleague adds a second allow policy so `frontend` can also reach `api` on port `9090`. Do they need to modify `allow-frontend-to-api`, or can they add a separate policy? What property of `NetworkPolicy` makes this true?

Sources: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## Exercise 5 — Authorization policy: RBAC + `auth can-i`

RBAC is the policy layer that runs *before* admission: it decides whether the caller may perform a verb on a resource at all. The four objects are `Role`/`ClusterRole` (the permissions) and `RoleBinding`/`ClusterRoleBinding` (who gets them). The best way to *test* an authorization policy without impersonating credentials is `kubectl auth can-i --as`.

**Steps**

1. Create a scoped, least-privilege role for a CI service account — read-only pods, nothing else. Save as `rbac.yaml`:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: ci-bot
     namespace: dev
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: dev
   rules:
   - apiGroups: [""]
     resources: ["pods", "pods/log"]
     verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: ci-bot-reads-pods
     namespace: dev
   subjects:
   - kind: ServiceAccount
     name: ci-bot
     namespace: dev
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f rbac.yaml
   ```

2. Test the policy from the subject's point of view with impersonation (`--as`). The service-account username format is `system:serviceaccount:<namespace>:<name>`:

   ```bash
   kubectl auth can-i list pods   -n dev --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i delete pods -n dev --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i get pods    -n prod --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i get secrets -n dev --as system:serviceaccount:dev:ci-bot
   ```
   ```
   yes
   no
   no
   no
   ```

3. List everything the subject can do — the fastest audit of an authorization policy:

   ```bash
   kubectl auth can-i --list -n dev --as system:serviceaccount:dev:ci-bot
   ```
   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   pods/log                                        []                  []               [get list watch]
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   ...
   ```

> **Q13.** Why did `get pods -n prod` return `no` even though the role grants `get pods`? What one word in the object kinds you created explains it, and which object would you create to grant the same read access cluster-wide?
>
> **Q14.** `kubectl auth can-i --list` shows `selfsubjectaccessreviews ... [create]` for a service account you never granted anything beyond pod reads. Where does that permission come from, and is it a policy misconfiguration?

Sources: [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) · [Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)

---

## Exercise 6 — Extending policy with an engine: Kyverno

The built-ins stop where cross-object logic, generation, or mutation begins: "every namespace must have an owner label," "inject a default `NetworkPolicy` into new namespaces," "block images not from our registry." **Kyverno** is a CNCF policy engine that runs as an admission webhook and expresses these as Kubernetes-native `ClusterPolicy` objects — no new language for the `validate` case.

**Steps**

1. Install Kyverno:

   ```bash
   kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

2. Apply a `validate` policy that blocks images from outside a trusted registry. Save as `kyverno-registry.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-image-registries
   spec:
     validationFailureAction: Enforce      # Enforce blocks; Audit only reports
     background: true
     rules:
     - name: only-trusted-registry
       match:
         any:
         - resources:
             kinds: ["Pod"]
       validate:
         message: "Images must come from registry.example.com/."
         pattern:
           spec:
             containers:
             - image: "registry.example.com/*"
   ```
   ```bash
   kubectl apply -f kyverno-registry.yaml
   kubectl run pub --image=nginx:1.27-alpine -n dev
   ```
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/dev/pub was blocked due to the following policies

   restrict-image-registries:
     only-trusted-registry: 'validation error: Images must come from
       registry.example.com/. rule only-trusted-registry failed at path /spec/containers/0/image/'
   ```

3. Confirm reporting and policy status:

   ```bash
   kubectl get clusterpolicy restrict-image-registries
   ```
   ```
   NAME                        ADMISSION   BACKGROUND   READY   AGE
   restrict-image-registries   true        true         True    30s
   ```

> **Q15.** The Kyverno rejection message names `admission webhook "validate.kyverno.svc-fail"`, while the Exercise 3 VAP rejection named no webhook at all. Trace each rejection to its stage in the admission pipeline and state the operational cost that Exercise 3's mechanism avoids.
>
> **Q16.** Kyverno can do one thing in this exercise family that *none* of the built-in mechanisms (PSA, ResourceQuota, VAP, NetworkPolicy, RBAC) can do at admission time. Name the rule type and give a one-line example of when you'd reach for it.

Sources: [Kyverno Documentation](https://kyverno.io/docs/) · [OPA/Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/docs/) · [Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

## Cleanup

```bash
kubectl delete namespace secure dev prod shop --ignore-not-found
kubectl delete validatingadmissionpolicy workload-guardrails.policy.example.com --ignore-not-found
kubectl delete validatingadmissionpolicybinding workload-guardrails-binding.example.com --ignore-not-found
kubectl delete clusterpolicy restrict-image-registries --ignore-not-found
# Optional: kubectl delete -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
```

---

## Answers

<details>
<summary>Click to reveal answers (Q1–Q16)</summary>

**A1.** `warn` never blocks anything — it only returns a client-side `Warning:` and admits the pod. It exists precisely for *observing* impact before enforcing. To reject non-compliant pods they must set `pod-security.kubernetes.io/enforce=<standard>`. The three modes are independent and additive; a namespace typically carries `enforce` at a pinned version plus `warn`/`audit` at `latest`.

**A2.** PSA is a Pod-level admission controller: it inspects the `Pod` object's `spec`. A `Deployment` is a different kind (`apps/v1`), so nothing in it violates a *pod* standard at the moment you create it — the object is admitted. The Deployment's controller later creates a `ReplicaSet`, whose controller tries to create the actual `Pod`; *that* create hits PSA and is rejected. The failure surfaces as a `Warning` on the initial apply (PSA warns on the enclosing controller) and as recurring `FailedCreate` events on the ReplicaSet — never as a non-zero exit on the `kubectl create deployment` command. This is why enforcement gaps hide: the top-level object looks healthy.

**A3.** `runAsNonRoot` and `seccompProfile` exist in **both** `pod.spec.securityContext` and `container.spec.securityContext`, and a pod-level value applies to every container — so they can be set once at the pod level. `allowPrivilegeEscalation` and `capabilities` exist **only** on the *container* `securityContext` (they are properties of a process/container, not of the shared pod sandbox). There is no pod-level field for them, so they must be repeated per container.

**A4.** (1) **Mutating admission** ran first: the `LimitRange` admission plugin injected `defaultRequest`/`default` into the pod because the author omitted them. (2) **Validating admission** ran next: the `ResourceQuota` plugin then saw a pod that *did* declare requests/limits and admitted it against the quota. Order matters — if quota validation ran before LimitRange mutation, the bare pod would be rejected. The pipeline is mutating → validating for exactly this reason.

**A5.** The Deployment/ReplicaSet objects are fine; the *pods* are being rejected by quota. Look at the ReplicaSet's events (`kubectl describe rs -n dev -l app=fill`) — you'll see `FailedCreate ... exceeded quota: team-quota`. `kubectl get deploy` shows `7/9` with no error because the Deployment controller keeps retrying and the failure lives on the child object. The fix is to fit all 9 within quota: lower the per-container request (e.g. `100m` × 9 = `900m` < `2`) via the `LimitRange` defaults or explicit requests, or raise the quota.

**A6.** It is dangerous whenever the `ResourceQuota` limits a **compute resource** (`requests.cpu`, `limits.memory`, …): the quota then *requires* every pod to declare that request/limit, and the only thing satisfying that requirement is the `LimitRange` default. If the `LimitRange` is deleted (or never existed in a new namespace copied without it), every bare-manifest pod is rejected with `failed quota: ... must specify requests.cpu ...` — a namespace-wide outage for new pods, exactly as shown in Step 3. Defence in depth: put explicit requests/limits in manifests *and* keep the `LimitRange` as a safety net.

**A7.** The **`ValidatingAdmissionPolicyBinding`**. A `ValidatingAdmissionPolicy` is inert on its own — it defines the rule but not where or how it is applied. The binding sets `validationActions` (`Deny`/`Warn`/`Audit`) and `matchResources` (which namespaces/resources). This separation is deliberate: one policy can be bound to many scopes with different actions (e.g. `Deny` in `prod`, `Warn` in `staging`) without duplicating the CEL.

**A8.** For a `ValidatingWebhookConfiguration`, `failurePolicy: Fail` means *if the external webhook pod is unreachable, the request fails* — a crashed or overloaded Gatekeeper/Kyverno deployment can wedge the whole cluster's writes. VAP is evaluated **in-process inside the API server**; there is no external endpoint to be unavailable. `failurePolicy: Fail` there only governs what happens if the CEL expression itself errors at runtime (e.g. type error), which is a bug in the policy, not an availability dependency. VAP removes the "policy engine outage = cluster outage" failure mode entirely.

**A9.** Guard the field access with `has()` and short-circuit:
`expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"`
This admits Deployments that omit `replicas` (the API server later defaults it to 1) instead of erroring on a missing field.

**A10.** `NetworkPolicy` is a **whitelist union with default-deny per selected direction**. The empty `podSelector: {}` in the deny policy selects *every* pod in `shop` and isolates all of them for `Ingress`. Once any policy selects a pod, only traffic matching *some* ingress rule is allowed. The Step 3 allow policy adds a rule permitting `frontend → api:8080`, so that flow is restored — but there is **no rule anywhere** permitting `attacker → api`, so it stays denied. You never "block attacker" explicitly; default-deny plus the absence of an allow rule does it.

**A11.** The `kind` default CNI (`kindnet`) does not implement `NetworkPolicy` enforcement. The objects are valid Kubernetes resources, so the **API server accepts and stores them** — enforcement is entirely the CNI's job at the dataplane, and the API server has no way to know the installed CNI ignores them. This is the classic silent-failure of network policy: `kubectl get netpol` looks correct while nothing is enforced. Fix: install Calico/Cilium/Antrea.

**A12.** They can add a **separate** policy; no edit to the existing one is needed. `NetworkPolicy` rules are **additive** — the effective allow-list for a pod is the union of the ingress rules of *all* policies selecting it. A new policy selecting `app: api` that allows `frontend → 9090` simply adds to what `allow-frontend-to-api` already permits on `8080`. (There is no "deny" rule type to conflict with; you only ever add allowances.)

**A13.** The word is **`Role`** (namespaced), bound by a `RoleBinding` — its grant is confined to namespace `dev`, so the identical verb/resource in `prod` is unauthorized. To grant the same read access across all namespaces, create a **`ClusterRole`** with the same rules and a **`ClusterRoleBinding`** (or a `RoleBinding` per namespace referencing the `ClusterRole` for selective scope).

**A14.** It is not a misconfiguration. `selfsubjectaccessreviews` and `selfsubjectreviews` are granted to the built-in `system:basic-user` / `system:authenticated` groups via default ClusterRoleBindings shipped with every cluster — they let any authenticated identity ask "what can *I* do?" (which is what powers `auth can-i`). They grant no access to real resources, only to introspect one's own permissions, so least-privilege is intact.

**A15.** Kyverno is a **`ValidatingWebhookConfiguration`**: the API server, at the validating-admission stage, makes an outbound HTTPS call to the `kyverno-svc` webhook pod, whose reply denies the request — hence the message names the webhook. Exercise 3's VAP is evaluated **in-process** by the API server (CEL), so no webhook is named. The operational cost VAP avoids: a separately deployed, always-on, latency-adding webhook pod that becomes an availability dependency (see A8) and adds a network round-trip to every matching admission request.

**A16.** **`mutate`** (and `generate`) rules — Kyverno can *rewrite* or *create* objects at admission: inject a default label, add a sidecar, set `imagePullPolicy`, or auto-generate a default-deny `NetworkPolicy` into every new namespace. Of the built-ins, PSA/ResourceQuota-validation/VAP/NetworkPolicy/RBAC are all *validate-or-deny* only (LimitRange mutates but only for its own defaulting); none can add an arbitrary object or field. Example: "on `CREATE Namespace`, generate a `default-deny-ingress` NetworkPolicy in it" — impossible with the built-ins, one `generate` rule in Kyverno.

</details>