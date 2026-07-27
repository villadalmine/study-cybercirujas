# Guided Exercises — 4.1 Discover and use resources that extend Kubernetes (CRD, Operators)

> **Prerequisites:** A practice cluster (minikube, kind, or similar) and configured `kubectl`. All exercises require cluster admin privileges. Teardown commands are at the end.

---

## Exercise 1 — Discover API Resources

Before extending Kubernetes, you must know what resources exist and how to explore them. These discovery tools will be used constantly during the exam.

1. List all resource types known to your cluster:

   ```bash
   kubectl api-resources
   ```

   Observe the columns: `NAME` (plural), `SHORTNAMES`, `APIVERSION`, `NAMESPACED`, and `KIND`.

2. Filter only resources that do **not** live inside a namespace:

   ```bash
   kubectl api-resources --namespaced=false
   ```

3. List resources belonging to a specific API group:

   ```bash
   kubectl api-resources --api-group=apps
   ```

4. Inspect available API **versions** (group/version), which is distinct from resource types:

   ```bash
   kubectl api-versions
   ```

5. Explore a resource schema using `kubectl explain`, navigating down its fields:

   ```bash
   kubectl explain deployments
   kubectl explain deployments.spec.strategy
   kubectl explain deployments.spec.template.spec.containers --recursive | head -30
   ```

**Question 1.** What is the difference between `kubectl api-resources` output and `kubectl api-versions` output?

**Question 2.** In `api-resources` output, what is the `SHORTNAMES` column used for? Provide an everyday example.

**Question 3.** Name two resources with `NAMESPACED=false` and explain why cluster-wide scope makes sense for them.

---

## Exercise 2 — Inspecting Cluster CustomResourceDefinitions

A **CustomResourceDefinition (CRD)** is a Kubernetes resource defining a *new type* of resource. It is the standard mechanism to extend the API without recompiling.

1. List installed CRDs (a fresh cluster may have none; a production cluster usually has several):

   ```bash
   kubectl get crd
   ```

2. Check which API group CRDs *themselves* belong to:

   ```bash
   kubectl api-resources | grep customresourcedefinitions
   ```

3. If your cluster contains an installed CRD (e.g. from an ingress controller or CNI plugin), inspect it:

   ```bash
   kubectl describe crd <name>
   ```

   Search output for: `Group`, `Scope`, `Names` (kind, plural, singular, shortNames), and `Versions`.

**Question 4.** All CRD names follow a mandatory naming format. What is it and why?

**Question 5.** Which API group and version does the `CustomResourceDefinition` resource belong to?

---

## Exercise 3 — Creating Your Own CRD

You will define a new type named `Backup`, complete with schema validation and custom printer columns in `kubectl get`.

1. Create `backup-crd.yaml`:

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     # Mandatory: <plural>.<group>
     name: backups.training.example.com
   spec:
     group: training.example.com
     scope: Namespaced
     names:
       kind: Backup
       plural: backups
       singular: backup
       shortNames:
         - bk
     versions:
       - name: v1
         served: true
         storage: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 required: ["source"]
                 properties:
                   source:
                     type: string
                   schedule:
                     type: string
                   retentionDays:
                     type: integer
                     minimum: 1
         additionalPrinterColumns:
           - name: Source
             type: string
             jsonPath: .spec.source
           - name: Schedule
             type: string
             jsonPath: .spec.schedule
           - name: Age
             type: date
             jsonPath: .metadata.creationTimestamp
   ```

2. Apply it and verify the new type exists:

   ```bash
   kubectl apply -f backup-crd.yaml
   kubectl get crd backups.training.example.com
   ```

3. Confirm API discovery sees the new group:

   ```bash
   kubectl api-resources --api-group=training.example.com
   ```

4. Request schema from API server, just like a native resource:

   ```bash
   kubectl explain backup
   kubectl explain backup.spec
   ```

5. List backups (none created yet):

   ```bash
   kubectl get backups
   ```

**Question 6.** In `spec.versions[]`, what do `served` and `storage` fields mean? How many versions can have `storage: true` simultaneously?

**Question 7.** Step 5 returns no error even though no `Backup` object exists yet. What does this reveal about what the API server did when applying the CRD?

**Question 8.** Why does `kubectl explain backup.spec` work and display fields `source`, `schedule`, and `retentionDays`?

---

## Exercise 4 — Creating and Manipulating Custom Resources

With CRD installed, `Backup` objects are managed using standard verbs: `apply`, `get`, `describe`, `patch`, `delete`.

1. Create `my-backup.yaml`:

   ```yaml
   apiVersion: training.example.com/v1
   kind: Backup
   metadata:
     name: backup-db
   spec:
     source: /data/postgres
     schedule: "0 3 * * *"
     retentionDays: 7
   ```

2. Apply and list using defined shortname and printer columns:

   ```bash
   kubectl apply -f my-backup.yaml
   kubectl get bk
   ```

   You should see columns `SOURCE`, `SCHEDULE`, and `AGE`.

3. Test **schema validation**. Try applying an invalid backup:

   ```bash
   kubectl apply -f - <<EOF
   apiVersion: training.example.com/v1
   kind: Backup
   metadata:
     name: broken-backup
   spec:
     source: /data/mysql
     retentionDays: 0
   EOF
   ```

   Read full error message.

4. Modify existing resource using `patch`:

   ```bash
   kubectl patch backup backup-db --type=merge -p '{"spec":{"retentionDays":30}}'
   kubectl get backup backup-db -o jsonpath='{.spec.retentionDays}{"\n"}'
   ```

5. Inspect complete stored object:

   ```bash
   kubectl get backup backup-db -o yaml
   ```

**Question 9.** Why did step 3 fail? Which component rejected the object and at what phase?

**Question 10.** If you executed `kubectl delete crd backups.training.example.com` now, what would happen to `backup-db` object? (Do not run it yet.)

**Question 11.** `Backup` is created, but no actual backup operation will occur in the cluster. Why?

---

## Exercise 5 — The Operator Pattern

Question 11 touches on the core concept: a CRD merely adds *data schema* to the API. For data to trigger *action*, a **controller** watching those resources is required. **Operator** = CRDs + custom controller executing a *reconciliation loop*: observing desired state (custom resource) and acting so actual state matches desired state.

1. Observe that `Backup` has no `status` field:

   ```bash
   kubectl get backup backup-db -o yaml | grep -A5 "^status:" || echo "no status"
   ```

   In an Operator-managed resource (e.g. cert-manager or database operator), the controller writes observed status there.

2. Learn to **identify installed Operators** in an unfamiliar cluster — an essential exam skill. An Operator typically appears as: (a) one or more CRDs, and (b) a Deployment running the controller. Simulate discovery:

   ```bash
   # (a) custom types and API groups
   kubectl get crd -o custom-columns=NAME:.metadata.name,GROUP:.spec.group

   # (b) deployments acting as controllers/operators
   kubectl get deployments -A | grep -Ei 'operator|controller' || true
   ```

3. Compare mentally with native resources: `Deployment` is also "desired state + controller". Verify its controller runs inside control plane:

   ```bash
   kubectl get pods -n kube-system | grep controller-manager
   ```

   The difference with an Operator is *where* controller runs and *who* wrote it, not the fundamental design pattern.

**Question 12.** Define in your own words what an Operator is and what it adds to a standalone CRD.

**Question 13.** What is a *reconciliation loop* (also called *control loop*)?

**Question 14.** In the exam, you are given a cluster and asked to "create a resource of the type managed by pre-installed Operator X". Write the command sequence to discover kind, API version, and fields without external documentation (other than kubernetes.io).

---

## Teardown

```bash
kubectl delete backup backup-db
kubectl delete crd backups.training.example.com
rm -f backup-crd.yaml my-backup.yaml
```

---

<details>
<summary><strong>Answers</strong></summary>

**Answer 1.** `kubectl api-resources` lists available **resource types** (kinds) with attributes (plural, shortnames, namespaced scope). `kubectl api-versions` lists served **group/version** pairs (e.g. `apps/v1`, `training.example.com/v1`). One answers "what objects can I create?"; the other answers "what API versions exist?".

**Answer 2.** Shortnames are short aliases accepted by `kubectl`. Everyday examples: `po` (pods), `svc` (services), `deploy` (deployments). CRDs can define their own, such as `bk` in Exercise 3.

**Answer 3.** Examples: `nodes` (physical/virtual cluster infrastructure, not namespaced), `persistentvolumes` (cluster-level storage provisioned globally and claimed via PVCs), `namespaces` (cannot live inside itself), and `customresourcedefinitions` (defines types cluster-wide).

**Answer 4.** Mandatory format is `<plural>.<group>`, e.g. `backups.training.example.com`. Ensures global uniqueness: two organizations can define a `Backup` kind without name collisions because domain name group distinguishes them.

**Answer 5.** Group `apiextensions.k8s.io`, version `v1`. CRDs are created using a native API resource — Kubernetes extends itself using its own mechanisms.

**Answer 6.** `served: true` means that version can be read/written via API. `storage: true` designates the version stored in **etcd**. Exactly **one** version can have `storage: true`; multiple `served` versions can exist simultaneously during version migrations.

**Answer 7.** Applying CRD dynamically registered a **new REST endpoint** (`/apis/training.example.com/v1/namespaces/*/backups`) in API server without restarting components. `kubectl get backups` queries that endpoint and receives a valid empty list — type exists even with zero instances.

**Answer 8.** Because CRD includes `openAPIV3Schema` under `spec.versions[].schema`. API server publishes that schema in OpenAPI docs, and `kubectl explain` consumes it identically to native types. Without structural schema (mandatory in `apiextensions.k8s.io/v1`), `explain` has no metadata to display.

**Answer 9.** Failed for schema violation: `retentionDays: 0` violates `minimum: 1`. Rejected by **API server** during **admission validation** (before persisting to etcd). Schema validation is the first line of defense; invalid objects never reach storage.

**Answer 10.** Deleting CRD **cascades to delete all custom resources of that type** (`backup-db` and any other instances) across all namespaces, plus removes the API endpoint. Deleting CRDs in production is high-risk.

**Answer 11.** Because a CRD only defines an API **data type**: `Backup` object is a declarative etcd entry. No **controller** is watching (`watch`) those objects to execute actual backup logic. Without a controller, desired state never translates into action.

**Answer 12.** An Operator combines **custom resources (via CRDs) + a custom controller** encoding operational domain knowledge: install, upgrade, backup, failover. CRD provides the "noun" (declarative type); Operator provides the "verb" (reconciliation process rendering state into reality and reporting progress in `status`).

**Answer 13.** Continuous cycle *observe → compare → act*: controller observes actual system state, compares with desired state in `spec`, and executes actions to converge actual state toward desired state.

**Answer 14.** Sequence:

```bash
# 1. Discover custom types and locate operator CRD
kubectl get crd
kubectl api-resources | grep <group-or-keyword>

# 2. Get exact kind, group/version, and shortnames
kubectl describe crd <plural>.<group>

# 3. Explore spec fields to write manifest
kubectl explain <kind> --recursive | less
kubectl explain <kind>.spec

# 4. (Shortcut) Use existing instance as template if present
kubectl get <kind> -A
kubectl get <kind> <name> -n <ns> -o yaml
```

With `apiVersion` (`<group>/<version>`), `kind`, and `spec` fields, manifest can be drafted and applied.

</details>
