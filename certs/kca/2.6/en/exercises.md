# Upgrading Kyverno — Guided Exercises

> **Exam objective 2.6 — Upgrading Kyverno** (weight 3.0). These labs assume a running Kubernetes cluster (kind, minikube, or a managed cluster) with an existing Kyverno installation and `kubectl` + `helm` v3 configured against it. Commands are shown with representative output; your exact versions and pod hashes will differ. Nothing here mutates production — run it against a throwaway cluster.

Kyverno upgrades have three properties that make them different from upgrading a stateless workload, and every exercise below circles back to one of them:

1. **CRDs carry the data.** Your `ClusterPolicy`, `Policy`, `PolicyException` and the generated `PolicyReport` objects live inside CRDs that the upgrade rewrites. Helm's native CRD handling and `kubectl apply` both have sharp edges here.
2. **Minor versions are stepping stones, not waypoints.** Kyverno tests and supports upgrading **one minor version at a time**. Skipping minors is unsupported.
3. **There is no supported downgrade.** Your rollback plan is *restore from backup*, not `helm rollback` to a schema the new data no longer fits.

---

## Exercise 1 — Establish a baseline and plan the upgrade path

**Scenario:** the cluster is running Kyverno **v1.11.4** (Helm chart `3.1.4`) and you have been asked to bring it to **v1.13.4** (chart `3.3.4`).

**Steps**

1. Confirm how Kyverno was installed. A Helm-managed release shows up here; an empty result means it was installed from raw manifests:

   ```bash
   helm list -n kyverno
   ```
   ```
   NAME     NAMESPACE  REVISION  UPDATED                  STATUS    CHART          APP VERSION
   kyverno  kyverno    1         2026-06-01 10:14:22 UTC  deployed  kyverno-3.1.4  v1.11.4
   ```

2. Read the **application** version off the running admission controller, not just off Helm metadata (they can drift if someone edited the deployment by hand):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```
   ```
   ghcr.io/kyverno/kyverno:v1.11.4
   ```

3. Enumerate the four controllers introduced by the 1.10 architecture split, so you know what a healthy install looks like *before* you touch it:

   ```bash
   kubectl get pods -n kyverno
   ```
   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   kyverno-admission-controller-7c9f8d6b4c-abcde    1/1     Running   0          31d
   kyverno-background-controller-6d5f7c8b9d-fghij   1/1     Running   0          31d
   kyverno-cleanup-controller-5b6c7d8e9f-klmno      1/1     Running   0          31d
   kyverno-reports-controller-4a5b6c7d8e-pqrst      1/1     Running   0          31d
   ```

4. Read the release notes for **every** minor between your current and target version — 1.11 → 1.12 → 1.13 — looking specifically for CRD schema changes and removed/renamed fields:

   ```bash
   # Browse https://github.com/kyverno/kyverno/releases and the migration
   # notes at https://kyverno.io/docs/installation/upgrading/
   ```

5. Write down the concrete path. You are on `1.11`, target is `1.13`, so the plan is **two hops**: `1.11 → 1.12`, then `1.12 → 1.13`. You may **not** jump straight to `1.13`.

**Comprehension check**

- **Q1.1** Why is `helm list -n kyverno` the first command rather than checking the image tag first?
- **Q1.2** The `helm list` output shows `CHART kyverno-3.1.4` and `APP VERSION v1.11.4`. Which of those two numbers do you pass to `--version` on `helm upgrade`, and why does the distinction matter?
- **Q1.3** Your target is `v1.13.4` and you are on `v1.11.4`. Write the exact sequence of application versions you will pass through, and state what rule forbids a direct `1.11.4 → 1.13.4` jump.
- **Q1.4** Reports controller shows `Running`, but why is a *pre-upgrade* inventory of all four controllers worth capturing rather than trusting that "Kyverno is up"?

---

## Exercise 2 — Back up policies and custom resources

The upgrade rewrites CRDs. Because downgrade is unsupported, your only real safety net is an export of the custom resources *before* the schema changes under them.

**Steps**

1. Export the policy objects — cluster-scoped and namespaced — plus exceptions:

   ```bash
   kubectl get clusterpolicies.kyverno.io -o yaml > backup-cpol.yaml
   kubectl get policies.kyverno.io -A -o yaml       > backup-pol.yaml
   kubectl get policyexceptions.kyverno.io -A -o yaml > backup-polex.yaml
   ```

2. Export the CRD definitions themselves, so you can inspect exactly which `storedVersions` the API server holds today:

   ```bash
   kubectl get crds -o name | grep -E 'kyverno.io|wgpolicyk8s.io' \
     | xargs -I{} kubectl get {} -o yaml > backup-kyverno-crds.yaml

   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{.status.storedVersions}{"\n"}'
   ```
   ```
   ["v1"]
   ```

3. Capture the Helm values that produced the current release, so the upgrade doesn't silently drop your customizations:

   ```bash
   helm get values kyverno -n kyverno -o yaml > backup-values.yaml
   cat backup-values.yaml
   ```
   ```
   USER-SUPPLIED VALUES:
   admissionController:
     replicas: 3
   backgroundController:
     resources:
       limits:
         memory: 384Mi
   ```

4. (Optional) Snapshot the current reports for comparison after the upgrade. These are regenerated, so this is for *diffing*, not for restore:

   ```bash
   kubectl get policyreports.wgpolicyk8s.io -A -o yaml > backup-polr.yaml
   kubectl get clusterpolicyreports.wgpolicyk8s.io -o yaml > backup-cpolr.yaml
   ```

**Comprehension check**

- **Q2.1** Why is backing up `ClusterPolicy`/`Policy` objects essential, while backing up `PolicyReport` objects is only "nice to have"?
- **Q2.2** What is the practical purpose of recording `.status.storedVersions` on the CRD before upgrading?
- **Q2.3** You run the upgrade, discover a policy behaves differently, and want to go back to `v1.11.4`. Why is "restore from `backup-*.yaml` onto a fresh 1.11 install" the correct recovery, and `helm rollback kyverno` the wrong one?
- **Q2.4** What breaks later if you skip step 3 (`helm get values`) and just run `helm upgrade kyverno kyverno/kyverno`?

---

## Exercise 3 — Upgrade with Helm, one minor version at a time

**Steps**

1. Refresh the repository index so Helm can see the new chart versions:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/   # no-op if already added
   helm repo update
   ```

2. List available chart versions **with their app versions** and build the chart→app mapping for your path:

   ```bash
   helm search repo kyverno/kyverno --versions | head
   ```
   ```
   NAME             CHART VERSION   APP VERSION   DESCRIPTION
   kyverno/kyverno  3.3.4           v1.13.4       Kubernetes Native Policy Management
   kyverno/kyverno  3.2.6           v1.12.6       Kubernetes Native Policy Management
   kyverno/kyverno  3.1.4           v1.11.4       Kubernetes Native Policy Management
   ```
   Your two hops are therefore: **chart `3.2.6`** (app `1.12.6`), then **chart `3.3.4`** (app `1.13.4`).

3. Perform the **first** hop. Pass your saved values, pin the chart version explicitly, and use `--atomic` so a failed rollout auto-reverts instead of leaving you half-upgraded:

   ```bash
   helm upgrade kyverno kyverno/kyverno \
     --namespace kyverno \
     --version 3.2.6 \
     -f backup-values.yaml \
     --atomic --timeout 5m
   ```
   ```
   Release "kyverno" has been upgraded. Happy Helming!
   NAME: kyverno
   LAST DEPLOYED: 2026-08-13 12:02:10 ...
   NAMESPACE: kyverno
   STATUS: deployed
   REVISION: 2
   ```

4. Watch the rollout finish and confirm the CRDs were updated by the chart (the Kyverno chart ships CRDs as **templates**, gated by `crds.install=true`, precisely so `helm upgrade` updates them — unlike Helm's native `crds/` directory, which is install-only):

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-version}{"\n"}' 2>/dev/null
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```
   ```
   deployment "kyverno-admission-controller" successfully rolled out
   ghcr.io/kyverno/kyverno:v1.12.6
   ```

5. Only once `1.12.6` is healthy, perform the **second** hop the same way:

   ```bash
   helm upgrade kyverno kyverno/kyverno \
     --namespace kyverno \
     --version 3.3.4 \
     -f backup-values.yaml \
     --atomic --timeout 5m
   ```

6. If you also manage the Pod Security policies via the companion chart, upgrade it **separately** — it is a different release with its own version stream:

   ```bash
   helm upgrade kyverno-policies kyverno/kyverno-policies \
     --namespace kyverno --version 3.3.4
   ```

**Comprehension check**

- **Q3.1** Why is `-f backup-values.yaml` preferred over `--reuse-values` when upgrading across a minor version?
- **Q3.2** Explain, in terms of *where* the CRDs are stored inside the chart, why `helm upgrade` on the Kyverno chart *does* update CRDs even though "Helm never upgrades CRDs" is a widely repeated rule.
- **Q3.3** What does `--atomic` do if the admission-controller pods fail to become Ready within `--timeout`, and why is that safer here than a plain `helm upgrade`?
- **Q3.4** You ran `helm upgrade ... --version 3.3.4` directly from chart `3.1.4` in one shot. Both revisions show `deployed`. What supported boundary did you just violate, and what is the risk even though nothing errored?

---

## Exercise 4 — Manifest upgrades, the CRD annotation trap, and verification

Not every install is Helm-managed. This exercise covers the raw-manifest path, its signature failure, and how to verify any upgrade regardless of method.

**Steps**

1. Attempt the naive manifest upgrade with `kubectl apply`:

   ```bash
   kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
   ```
   ```
   The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
   metadata.annotations: Too long: must have at most 262144 bytes
   ```
   Kyverno's CRDs are large; client-side apply stuffs the whole object into the
   `kubectl.kubernetes.io/last-applied-configuration` annotation, which overflows
   the 256 KiB annotation limit.

2. Use **server-side apply**, which stores field ownership in managed-fields instead of that annotation, and resolve ownership conflicts:

   ```bash
   kubectl apply --server-side --force-conflicts \
     -f https://github.com/kyverno/kyverno/releases/download/v1.13.4/install.yaml
   ```
   ```
   customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
   ...
   deployment.apps/kyverno-admission-controller serverside-applied
   ```

3. Verify the running versions across all four controllers at once:

   ```bash
   kubectl -n kyverno get deploy \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
   ```
   ```
   NAME                            IMAGE
   kyverno-admission-controller    ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-background-controller   ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-cleanup-controller      ghcr.io/kyverno/kyverno:v1.13.4
   kyverno-reports-controller      ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Confirm the admission webhooks were re-registered and are being served (a stale or missing webhook after upgrade silently stops enforcement):

   ```bash
   kubectl get validatingwebhookconfigurations | grep kyverno
   kubectl get mutatingwebhookconfigurations   | grep kyverno
   ```
   ```
   kyverno-policy-validating-webhook-cfg    1   32d
   kyverno-resource-validating-webhook-cfg  4   40s
   kyverno-resource-mutating-webhook-cfg    3   40s
   ```

5. Functionally validate that policies still enforce after the upgrade with a known-bad object:

   ```bash
   kubectl run nginx --image=nginx:latest --dry-run=server
   ```
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   ...
   require-image-tag: validation error: An image tag is required. ...
   ```

6. Confirm the policy reports repopulated (compare against `backup-polr.yaml` from Exercise 2) and check controller logs are clean:

   ```bash
   kubectl get policyreports.wgpolicyk8s.io -A
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -i error
   ```

**Comprehension check**

- **Q4.1** Explain the root cause of the `metadata.annotations: Too long` error and why `--server-side` avoids it.
- **Q4.2** Why does `--force-conflicts` become necessary specifically when moving an existing client-side-applied install to server-side apply?
- **Q4.3** After a successful image bump, enforcement seems to have stopped. Which single command from step 4 most directly explains that, and what would you look for in its output?
- **Q4.4** Step 5 uses `--dry-run=server`. Why `server` and not `client` for validating that Kyverno enforcement survived the upgrade?
- **Q4.5** You need to move from `v1.13.4` back to `v1.12.6`. `kubectl apply --server-side` of the 1.12 manifest "succeeds." Why is this still not a supported downgrade, and what actually protects your data?

---

## Answers

<details>
<summary>Show answers</summary>

**Exercise 1**

- **A1.1** The installation method dictates the *entire* upgrade procedure. A Helm-managed release must be upgraded with `helm upgrade` (so Helm's release metadata, ownership annotations, and values stay consistent); a manifest install must be upgraded with `kubectl apply`. Mixing them — e.g., `kubectl apply` over a Helm release — corrupts Helm's ownership tracking and causes conflicts on the next `helm` operation. You decide the method before you decide anything else.
- **A1.2** You pass the **chart version** (`3.1.4`) to `--version`; Helm has no `--app-version` flag for upgrades. The distinction matters because they are independent version streams: chart `3.1.x` ships Kyverno app `v1.11.x`, `3.2.x` ships `v1.12.x`, `3.3.x` ships `v1.13.x`. To land on a specific Kyverno version you must look up the chart version that carries it via `helm search repo kyverno/kyverno --versions` and pin *that*.
- **A1.3** Path: `v1.11.4 → v1.12.6 → v1.13.4` (latest patch of each intermediate minor is fine). The rule: Kyverno only supports/tests upgrading **one minor version at a time**; skipping a minor (`1.11 → 1.13` directly) is unsupported because CRD conversions and controller migrations are validated only for the N→N+1 step.
- **A1.4** Because "Kyverno is up" is not the same as "all four controllers are up." Each controller owns a distinct function — admission (enforcement), background (mutate/generate on existing resources), reports (PolicyReport generation), cleanup (TTL/cleanup policies). If one silently fails to roll out after the upgrade, only its function breaks, and without a pre-upgrade inventory you have no baseline to notice the regression.

**Exercise 2**

- **A2.1** `ClusterPolicy`/`Policy`/`PolicyException` objects are *authored state* — if the upgrade corrupts them or you must rebuild the install, they are the source of truth and cannot be regenerated. `PolicyReport` objects are *derived state*: the reports controller rebuilds them by re-evaluating policies against the cluster, so losing them costs a re-scan, not data.
- **A2.2** `storedVersions` tells you which API versions the etcd data is actually persisted as. If a future Kyverno release removes a served/stored version, an upgrade can fail or require a storage-version migration first. Recording it pre-upgrade lets you detect and plan for that instead of discovering it mid-upgrade.
- **A2.3** Kyverno does not support downgrades: the newer install may have converted/rewritten CR data into a schema the older version's CRDs and controllers cannot read. `helm rollback` reverts the *manifests* but not the *data migration*, leaving controllers pointed at data they can't parse. Restoring your exported YAML onto a clean `1.11` install rebuilds known-good objects against known-good CRDs — the only reliable recovery.
- **A2.4** `helm upgrade` without `-f` (and without `--reuse-values`) reverts every value to the *new chart's defaults*, silently dropping your `admissionController.replicas: 3`, custom resource limits, etc. The upgrade "succeeds" while quietly reconfiguring your install.

**Exercise 3**

- **A3.1** `--reuse-values` reuses only the values from the previous revision and does **not** merge in new default keys introduced by the newer chart, so new settings land unset/inconsistent. Passing your own `-f backup-values.yaml` layers your explicit overrides on top of the new chart's fresh defaults, giving you the new defaults *plus* your customizations — and keeps the values in version control.
- **A3.2** The "Helm never upgrades CRDs" rule applies only to CRDs placed in the chart's special `crds/` directory, which Helm installs once and never touches again. Kyverno's chart instead renders its CRDs as **regular templates** (gated by `crds.install=true`), so they are ordinary release-managed resources that `helm upgrade` reconciles like any Deployment. That design choice is exactly why the CRDs get updated on upgrade.
- **A3.3** `--atomic` marks the upgrade to automatically roll back to the previous revision if the release does not reach a ready state within `--timeout`. If the admission-controller pods never become Ready, you end up back on the prior working revision instead of stranded in a partially-applied, half-broken state where enforcement may be inconsistent.
- **A3.4** You skipped the intermediate minor (`1.12`), violating the one-minor-at-a-time support boundary. No error is expected because Helm just applies manifests — but the CRD conversions and controller migrations for the `1.12 → 1.13` step assume the cluster was actually on `1.12` first. Skipping it can leave CRs unconverted or reports/state inconsistent in ways that surface later, not at upgrade time.

**Exercise 4**

- **A4.1** Client-side `kubectl apply` writes the full previous object into the `kubectl.kubernetes.io/last-applied-configuration` annotation to compute diffs. Kyverno's CRDs are large enough that this annotation exceeds Kubernetes' 262144-byte (256 KiB) per-annotation limit, so the apply is rejected. Server-side apply tracks field ownership in `metadata.managedFields` on the server and never writes that annotation, so the size ceiling is never hit.
- **A4.2** The existing objects were created by client-side apply, so their fields are owned by the manager `kubectl-client-side-apply`. When you switch to server-side apply, the manager identity changes and every field it tries to set is a conflict with the old owner. `--force-conflicts` transfers ownership to the server-side-apply manager, letting the apply proceed instead of erroring on each contested field.
- **A4.3** `kubectl get validatingwebhookconfigurations | grep kyverno`. Look at whether the `kyverno-resource-validating-webhook-cfg` exists and how many rules/webhooks it carries (the count column) and its AGE. If it's missing, empty (0 rules), or the AGE didn't reset when the admission controller restarted, Kyverno isn't intercepting requests — the API server has nothing to call, so nothing is enforced regardless of the pod running the new image.
- **A4.4** Client dry-run never contacts the API server, so it never triggers admission webhooks — a client dry-run of a bad Pod would appear to "pass." Server dry-run sends the request through the real admission chain (including Kyverno's validating webhook) but doesn't persist, so a denial proves enforcement is actually working post-upgrade.
- **A4.5** The apply "succeeds" only because it swaps manifests and images; it does nothing to convert the CR data the 1.13 install may have rewritten back into a form 1.12 understands. Downgrade is unsupported precisely because that data migration is one-way. What actually protects you is the Exercise 2 backup restored onto a clean 1.12 install — not the reverse apply.

</details>

---

### Sources

- Kyverno — *Upgrading Kyverno*: https://kyverno.io/docs/installation/upgrading/
- Kyverno — *Installation methods (Helm)*: https://kyverno.io/docs/installation/methods/
- Kyverno — *High Availability / controller architecture*: https://kyverno.io/docs/high-availability/
- Kyverno chart & release notes: https://github.com/kyverno/kyverno/releases and https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Helm — *Custom Resource Definitions* (why `crds/` is install-only): https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Kubernetes — *Server-Side Apply*: https://kubernetes.io/docs/reference/using-api/server-side-apply/