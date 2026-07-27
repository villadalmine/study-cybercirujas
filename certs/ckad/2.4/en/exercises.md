# Exercises: 2.4 Understand API deprecations (CKAD v1.35)

## Exercise 1: Explore Active apiVersions in the Cluster

1. List all apiVersions exposed by the API server:
   ```bash
   kubectl api-versions | sort
   ```
2. Filter resources belonging to the `batch` group:
   ```bash
   kubectl api-resources --api-group=batch
   ```
3. Confirm which version `CronJob` currently uses:
   ```bash
   kubectl explain cronjob | head -5
   ```
4. Repeat step 3 for `poddisruptionbudget` (group `policy`) and `ingress` (group `networking.k8s.io`).

**Questions**
1. `CronJob` reached GA in `batch/v1` in Kubernetes 1.21. Which apiVersion did it use previously, and which command did you use to confirm the active version?
2. What is the difference between `kubectl api-versions` and `kubectl api-resources`?

---

## Exercise 2: Reproduce an Error from a Removed apiVersion

1. Create `cronjob-old.yaml` with a deprecated apiVersion:
   ```yaml
   apiVersion: batch/v1beta1
   kind: CronJob
   metadata:
     name: demo-cron
   spec:
     schedule: "*/5 * * * *"
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: hello
               image: busybox
               command: ["echo", "hello"]
             restartPolicy: OnFailure
   ```
2. Attempt to apply it:
   ```bash
   kubectl apply -f cronjob-old.yaml
   ```
3. Read the error message returned by `kubectl` (something like `no matches for kind "CronJob" in version "batch/v1beta1"`).
4. Fix the manifest by changing `apiVersion` to `batch/v1` and apply it again. Confirm the `CronJob` is created:
   ```bash
   kubectl get cronjob demo-cron
   ```

**Questions**
1. Why does step 2 fail? Does this error indicate that the API is "deprecated" or that it has already been "removed" from the API server?
2. According to the [Kubernetes Deprecation Policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/), what is the difference between those two API states?

---

## Exercise 3: Migrate Manifests with `kubectl-convert`

1. Install the `convert` plugin via `krew` (if not already installed):
   ```bash
   kubectl krew install convert
   ```
2. Create `pdb-old.yaml` with a deprecated `PodDisruptionBudget` version:
   ```yaml
   apiVersion: policy/v1beta1
   kind: PodDisruptionBudget
   metadata:
     name: demo-pdb
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app: demo
   ```
3. Convert the manifest to current stable version:
   ```bash
   kubectl-convert -f pdb-old.yaml --output-version policy/v1
   ```
4. Compare `apiVersion` in output against the original.

**Questions**
1. What advantage does using `kubectl-convert` have over editing `apiVersion` manually in large manifests?
2. What does `kubectl-convert` **not** guarantee, which you should still validate yourself before applying the output to a real cluster?

---

## Exercise 4: Detect Deprecated APIs Before an Upgrade with `kubent`

1. Install [kube-no-trouble (`kubent`)](https://github.com/doitintl/kube-no-trouble):
   ```bash
   sh -c "$(curl -sSL https://git.io/install-kubent)"
   ```
2. Run it against your current cluster:
   ```bash
   kubent
   ```
3. Review the report: columns `KIND`, `NAMESPACE`, `NAME`, `API_VERSION`, `REPLACE_WITH`, `SINCE`, `REPLACED_IN`, `REMOVED_IN`.
4. Choose a reported resource (if any exist) and migrate it to the suggested apiVersion in `REPLACE_WITH`.

**Questions**
1. Why is it recommended to run a tool like `kubent` (or [`pluto`](https://github.com/FairwindsOps/pluto)) **before** upgrading cluster minor version, rather than after?
2. In the `kubent` report, which column tells you if you still have room before the API stops working, and which tells you what to migrate to?

---

## Exercise 5: Deprecation Warnings Emitted by API Server

1. Check if your cluster still exposes any resources in `v1beta1` or `v1beta2` version:
   ```bash
   kubectl api-resources -o wide | grep -E "v1beta"
   ```
2. If any are found, apply a manifest using that apiVersion and observe `kubectl` output (not just `stdout`, but any line starting with `Warning:`).
3. If none are found, run `kubectl get` with `-v=6` on any resource and observe HTTP response headers:
   ```bash
   kubectl get deployment -v=6
   ```

**Questions**
1. Since Kubernetes 1.19, what HTTP mechanism does API server use to communicate that an apiVersion or field is deprecated without blocking request processing? (see [kubernetes.io/blog/2020/09/03/warnings](https://kubernetes.io/blog/2020/09/03/warnings/))
2. Does this mechanism apply only to `kubectl`, or also to any client speaking directly to REST API?

<details>
<summary>Answers</summary>

**Exercise 1**
1. `CronJob` used `batch/v1beta1` before graduating to `batch/v1` in Kubernetes 1.21. Confirmed with `kubectl explain cronjob`, showing `VERSION:` field with active apiVersion in current API server.
2. `kubectl api-versions` lists enabled API groups/versions (`group/version`, e.g. `batch/v1`). `kubectl api-resources` lists available *resources* (kinds), along with their `APIVERSION`, whether they are namespaced, and their `SHORTNAMES`; it is more useful for finding which kind lives in which group.

**Exercise 2**
1. It fails because `batch/v1beta1` has already been **removed** from the API server (not merely deprecated): the server has no registered handler for that group/version, so `kubectl` responds "no matches for kind ... in version ...". If it were merely deprecated but still supported, `apply` would have succeeded, displaying a `Warning:` in output instead.
2. "Deprecated" means the API continues to work but its replacement and eventual removal in a future release have been announced (clients receive warnings). "Removed" means the API server no longer registers that version: any request against it fails immediately, regardless of client used.

**Exercise 3**
1. `kubectl-convert` automatically rewrites the complete manifest structure (apiVersion and, if applicable, fields that changed shape/name between versions), avoiding manual errors when migrating many files or complex manifests.
2. It does not guarantee identical runtime behavior (for instance, different defaults, stricter validations in the new version, or fields with changed semantics). Therefore, diff review and testing in non-production environments are recommended before applying to a real cluster.

**Exercise 4**
1. Because once minor version upgrade occurs, if that release removes an apiVersion you were using, manifests, Helm charts, or controllers depending on it immediately fail upon apply or reconciliation. Running `kubent`/`pluto` before upgrade allows proactive migration without forced downtime.
2. `REMOVED_IN` indicates the Kubernetes version where that apiVersion ceases to exist (your margin before breaking); `REPLACE_WITH` indicates the stable apiVersion to migrate manifests to.

**Exercise 5**
1. The API server sends standard HTTP header `Warning` (RFC 7234) in the response when request uses a deprecated apiVersion, field, or value. `kubectl` (and any client respecting that header, including `client-go`) prints it as a `Warning: ...` line without blocking operation.
2. It applies to any client speaking Kubernetes REST API, not just `kubectl`: `Warning` header travels in the HTTP response itself, so tools like `curl`, Helm, or controllers written in `client-go` can also read it.

</details>
