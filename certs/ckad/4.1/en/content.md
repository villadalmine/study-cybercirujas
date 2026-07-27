# 4.1 — Discover and use resources that extend Kubernetes (CRD, Operators)

## Why This Topic Exists

Out of the box, Kubernetes comes with a built-in set of resources: `Pod`, `Deployment`, `Service`, `ConfigMap`, etc. However, the platform is designed to be **extensible**: anyone can define new resource types using **CustomResourceDefinitions (CRDs)** and automate their behavior with **controllers** — a pattern known as the **Operator**.

In the CKAD exam, you will not write an Operator, but you are expected to know how to:

1. **Discover** custom resources in a cluster (`kubectl api-resources`, `kubectl get crd`).
2. **Inspect** their schemas (`kubectl explain`).
3. **Create and manipulate** instances of those custom resources just like native resources.
4. Understand **what an Operator is** and how it relates to CRDs.

---

## 1. Custom Resources and CustomResourceDefinitions

### Concepts

- A **Custom Resource (CR)** is an API extension in Kubernetes: an object of a type not included by default (e.g., `Certificate`, `PrometheusRule`, `Backup`).
- A **CustomResourceDefinition (CRD)** is the *native* resource used to register that new type with the API server: declaring its name, API group, versions, and validation schema.

The relationship is analogous to class and instance: the CRD defines the type; custom resources are instances.

```
CRD (defines type)            Custom Resources (instances)
─────────────────────         ─────────────────────────────
crontabs.stable.example.com → CronTab "my-crontab"
                               CronTab "nightly-backup"
```

Once a CRD is created, the API server exposes REST endpoints for that type, and `kubectl` treats it like any native resource: `get`, `describe`, `create`, `apply`, `delete`, `edit`, etc.

### Anatomy of a CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # Name MUST be <plural>.<group>
  name: crontabs.stable.example.com
spec:
  group: stable.example.com
  scope: Namespaced          # or Cluster
  names:
    plural: crontabs
    singular: crontab
    kind: CronTab
    shortNames:
      - ct
  versions:
    - name: v1
      served: true           # served via API
      storage: true          # persisted to etcd
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cronSpec:
                  type: string
                image:
                  type: string
                replicas:
                  type: integer
```

Key fields worth memorizing for the exam:

| Field | Purpose |
|---|---|
| `metadata.name` | Must be formatted as `<plural>.<group>` |
| `spec.scope` | `Namespaced` (belongs to a namespace) or `Cluster` (global, like a `Node`) |
| `spec.names.kind` | The `kind` used in custom resource manifests |
| `spec.names.shortNames` | `kubectl` alias (like `svc` for `Service`) |
| `versions[].served` | Whether the version is served by the API server |
| `versions[].storage` | Exactly **one** version must have `storage: true` |
| `openAPIV3Schema` | Structural validation: API server rejects CRs violating schema |

### Creating a CRD and Custom Resource

```bash
kubectl apply -f crontab-crd.yaml
```

```
customresourcedefinition.apiextensions.k8s.io/crontabs.stable.example.com created
```

Now you can create instances. Notice that the CR `apiVersion` combines `group` and `version` from the CRD:

```yaml
apiVersion: stable.example.com/v1
kind: CronTab
metadata:
  name: my-crontab
spec:
  cronSpec: "*/5 * * * *"
  image: busybox:1.36
  replicas: 2
```

```bash
kubectl apply -f my-crontab.yaml
kubectl get crontabs
```

```
NAME         AGE
my-crontab   10s
```

Shortnames and standard operations work identically:

```bash
kubectl get ct                    # shortName
kubectl describe crontab my-crontab
kubectl delete crontab my-crontab
```

> **Important:** A CRD alone is *just data*. Creating a `CronTab` executes nothing: objects remain stored in etcd waiting for a controller to process them. That is where Operators come in.

---

## 2. Discovering Resources in a Cluster (Key Exam Skill)

In the exam, you may be given a cluster with pre-installed CRDs and asked to create an instance. The discovery workflow is always identical:

### Step 1 — What resources exist?

```bash
kubectl api-resources
```

```
NAME          SHORTNAMES   APIVERSION                     NAMESPACED   KIND
pods          po           v1                             true         Pod
deployments   deploy       apps/v1                        true         Deployment
crontabs      ct           stable.example.com/v1          true         CronTab
...
```

Useful filters:

```bash
kubectl api-resources --namespaced=true          # namespaced resources only
kubectl api-resources --api-group=stable.example.com
kubectl api-versions                             # list served API groups/versions
```

### Step 2 — What CRDs are installed?

CRDs are cluster-wide resources, listed directly:

```bash
kubectl get crd
```

```
NAME                          CREATED AT
crontabs.stable.example.com   2026-07-14T10:02:11Z
```

Inspect full details (group, versions, schema):

```bash
kubectl describe crd crontabs.stable.example.com
kubectl get crd crontabs.stable.example.com -o yaml
```

### Step 3 — What fields does the resource accept?

`kubectl explain` works with custom resources just like native ones (provided the CRD has a schema):

```bash
kubectl explain crontab.spec
```

```
GROUP:      stable.example.com
KIND:       CronTab
VERSION:    v1

FIELD: spec <Object>

FIELDS:
  cronSpec      <string>
  image         <string>
  replicas      <integer>
```

Use `--recursive` to view the full field tree:

```bash
kubectl explain crontab --recursive
```

This trio — `api-resources`, `get crd`, `explain` — answers almost any exam question on this topic without needing documentation browser tabs.

---

## 3. Operators

### The Pattern

An **Operator** combines:

1. **CRDs** modeling a specific domain or application (e.g., `PostgresCluster`, `Certificate`).
2. A **custom controller** (a Pod running in the cluster, usually as a `Deployment`) observing those resources and executing a **reconciliation loop**: comparing desired state (`spec`) with actual state and acting to converge them.

It follows the same pattern as native controllers (Deployment controller creates ReplicaSets; ReplicaSet controller creates Pods), applied to application-specific operational knowledge: automated provisioning, backups, upgrades, certificate rotations, failover, etc.

```
User                       Operator (controller)          Cluster
───────                    ─────────────────────          ───────
kubectl apply CR  ──────▶  watch: detects CR
                           reconcile: compares desired
                           vs actual state        ──────▶ creates Pods, Secrets,
                                                          Services, etc.
                           updates .status on CR
```

### Concrete Example: cert-manager

**cert-manager** is a widely used Operator managing TLS certificates. It installs CRDs like `Certificate`, `Issuer`, and `ClusterIssuer`:

```bash
kubectl get crd | grep cert-manager
```

```
certificates.cert-manager.io           2026-07-14T09:15:02Z
certificaterequests.cert-manager.io    2026-07-14T09:15:02Z
clusterissuers.cert-manager.io         2026-07-14T09:15:03Z
issuers.cert-manager.io                2026-07-14T09:15:03Z
...
```

The user declares *what* is desired:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: apps
spec:
  secretName: web-tls-secret
  dnsNames:
    - web.example.com
  issuerRef:
    name: my-issuer
    kind: Issuer
```

The cert-manager controller handles the *how*: requests the certificate, renews it before expiration, and stores it in the designated `Secret`. You simply check status:

```bash
kubectl get certificate -n apps
```

```
NAME      READY   SECRET           AGE
web-tls   True    web-tls-secret   2m
```

### Identifying an Installed Operator

In the exam, if you suspect an Operator is in use:

```bash
kubectl get crd                                  # what types were added?
kubectl get pods -A | grep -i operator           # where is controller running?
kubectl get deploy -A                            # often deployed as Deployment
```

### The `status` Field and Subresources

Well-designed CRs separate:

- `spec` — desired state set by user.
- `status` — observed state reported by controller (written by Operator if CRD enables `status` subresource).

To troubleshoot a CR that seems inactive, start with:

```bash
kubectl describe <type> <name>     # check Status and Events
kubectl get <type> <name> -o yaml  # check .status and .metadata
```

If `.status` is empty and no events are logged, the controller is likely not running or not watching that namespace.

---

## 4. Exam Cheat Sheet

```bash
# Discovery
kubectl api-resources                          # all types, shortnames, and groups
kubectl api-resources --api-group=<group>
kubectl get crd                                # installed CRDs
kubectl explain <type> --recursive             # schema breakdown

# Working with custom resources (identical to native resources)
kubectl get <plural|shortname> [-n ns]
kubectl describe <type> <name>
kubectl apply -f cr.yaml
kubectl edit <type> <name>
kubectl delete <type> <name>

# Writing a CR from CRD fields
#   apiVersion: <spec.group>/<versions[].name>
#   kind:       <spec.names.kind>
```

Common mistakes to avoid:

- Using an `apiVersion` that incorrectly combines CRD `group` and `version` (verify via `kubectl get crd <name> -o yaml`).
- Creating a `Namespaced` CR without `-n` in the wrong namespace.
- Expecting a CRD to perform actions on its own: without a controller/Operator, a CR is merely a stored document.
- Forgetting that `kubectl explain` works on custom resources — it is the fastest way to view accepted `spec` fields.

---

## References

- Custom Resources concepts: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend Kubernetes API with CRDs (official tutorial): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Operator pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- CRD versioning: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- `kubectl api-resources` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#api-resources
- `kubectl explain` reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#explain
- cert-manager (Operator example): https://cert-manager.io/docs/
- Official CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
